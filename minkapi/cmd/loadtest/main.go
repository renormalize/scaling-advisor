// SPDX-FileCopyrightText: 2026 SAP SE or an SAP affiliate company and Gardener contributors
//
// SPDX-License-Identifier: Apache-2.0

// Command loadtest is a standalone diagnostic that drives an already-running minkapi
// over its HTTP (network) path. It creates --nodes Ready nodes concurrently, then
// --pods pending pods, then watches (via a single List+Watch informer) until every
// pod is bound by an external kube-scheduler (or the context is cancelled with Ctrl-C).
//
// Both minkapi and the kube-scheduler must be started separately; this tool only
// needs the base kubeconfig minkapi serves. Example:
//
//	go run ./cmd/loadtest --kubeconfig /tmp/minkapi.yaml --nodes 10000 --pods 10000
//
// To target a kwok cluster instead, add --kwok: this stamps every node with the kwok
// manage annotation and taint, and gives every pod the matching toleration, without
// which kwok leaves all pods Pending. kwok bundles its own kube-scheduler, so nothing
// else needs to run. Example:
//
//	go run ./cmd/loadtest --kubeconfig ./kwok-kubeconfig.yaml --nodes 10000 --pods 10000 --kwok
package main

import (
	"context"
	"flag"
	"fmt"
	"net/http"
	"os"
	"os/signal"
	"runtime"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/informers"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/tools/cache"
	"k8s.io/client-go/tools/clientcmd"
)

const (
	loadTestLabelKey   = "loadtest"
	loadTestLabelValue = "minkapi"
	loadTestSelector   = loadTestLabelKey + "=" + loadTestLabelValue
	// schedulerName is pinned on every pending pod so an external kube-scheduler
	// configured with a matching profile picks it up. An empty spec.schedulerName
	// defaults to "default-scheduler", which the sample config also serves.
	schedulerName = "default-scheduler"

	// kwok tags: kwok manages fake nodes and taints them so real workloads do not
	// land on them. When --kwok is set we stamp nodes with the manage annotation and
	// the taint, and give pods the matching toleration; otherwise a kwok cluster
	// leaves every pod Pending forever. These are no-ops for minkapi.
	kwokNodeAnnotationKey   = "kwok.x-k8s.io/node"
	kwokNodeAnnotationValue = "fake"
	kwokTaintKey            = "kwok.x-k8s.io/node"
	kwokTaintValue          = "fake"
)

type options struct {
	pods       int
	nodes      int
	workers    int
	kubeConfig string
	namespace  string
	kwok       bool
}

func parseFlags() options {
	var o options
	flag.IntVar(&o.pods, "pods", 10000, "number of pending pods to create")
	flag.IntVar(&o.nodes, "nodes", 10000, "number of schedulable nodes to create")
	flag.IntVar(&o.workers, "workers", 100, "number of concurrent create workers")
	flag.StringVar(&o.kubeConfig, "kubeconfig", "", "path to the base kubeconfig minkapi serves (required)")
	flag.StringVar(&o.namespace, "namespace", "default", "namespace to create pods in")
	flag.BoolVar(&o.kwok, "kwok", false, "target a kwok cluster: stamp nodes with the kwok manage annotation + taint and give pods the matching toleration (nothing schedules on kwok without this)")
	flag.Parse()
	return o
}

func main() {
	o := parseFlags()
	if err := run(o); err != nil {
		fmt.Fprintf(os.Stderr, "loadtest failed: %v\n", err)
		os.Exit(1)
	}
}

func run(o options) error {
	if o.kubeConfig == "" {
		return fmt.Errorf("--kubeconfig is required (path to the kubeconfig of the already-running minkapi)")
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	cs, err := newClient(o.kubeConfig, o.workers)
	if err != nil {
		return err
	}

	// 1. Create all nodes concurrently and wait.
	fmt.Printf("creating %d schedulable nodes using %d workers ...\n", o.nodes, o.workers)
	nodeRes := createNodes(ctx, cs, o)
	fmt.Printf("nodes created    : %d (errors %d) in %s\n", nodeRes.created, nodeRes.errors, nodeRes.elapsed.Round(time.Millisecond))
	for i, e := range nodeRes.sampleErrs {
		fmt.Printf("  node error #%d  : %v\n", i+1, e)
	}
	if ctx.Err() != nil {
		return nil
	}

	// 2. Create all pending pods concurrently and wait.
	fmt.Printf("creating %d pending pods using %d workers ...\n", o.pods, o.workers)
	podRes := createPods(ctx, cs, o)
	fmt.Printf("pods created     : %d (errors %d) in %s\n", podRes.created, podRes.errors, podRes.elapsed.Round(time.Millisecond))
	for i, e := range podRes.sampleErrs {
		fmt.Printf("  pod error #%d   : %v\n", i+1, e)
	}
	printMem()
	if ctx.Err() != nil {
		return nil
	}

	// The scheduling target is the number of pods actually in the store, taken from a
	// List. With explicit unique names this equals the create-success count; a
	// shortfall means pods from a prior run still exist under the same names (restart
	// minkapi for a clean count) or creates failed.
	_, listed, err := countBound(ctx, cs, o.namespace)
	if err != nil {
		return fmt.Errorf("initial pod list failed: %w", err)
	}
	total := int64(listed)
	fmt.Println("=============================================")
	fmt.Printf("%d Ready nodes and %d pending pods are in minkapi (kubeconfig %s).\n",
		nodeRes.created, total, o.kubeConfig)
	if total != podRes.created {
		fmt.Printf("(note: %d pod creates succeeded but List found %d pods; likely leftover pods "+
			"from a prior run reusing the same names — restart minkapi for a clean count)\n",
			podRes.created, total)
	}
	fmt.Println("Watching for bound pods; press Ctrl-C to stop.")
	fmt.Println("=============================================")

	// 3. Poll until every pod is bound or the context is cancelled.
	return pollUntilBound(ctx, cs, o, total)
}

func newClient(kubeConfigPath string, workers int) (kubernetes.Interface, error) {
	restCfg, err := clientcmd.BuildConfigFromFlags("", kubeConfigPath)
	if err != nil {
		return nil, fmt.Errorf("cannot build rest config from %q: %w", kubeConfigPath, err)
	}
	// Effectively unthrottle the client; default QPS 5 / Burst 10 would make 100k
	// creates take hours. minkapi is JSON-only, so pin the content type.
	restCfg.QPS = 20000
	restCfg.Burst = 20000
	restCfg.ContentType = "application/json"
	// Crucial at scale: keepalive/connection reuse. client-go's default transport
	// caps MaxIdleConnsPerHost at 25 (< our worker count), so under high
	// concurrency it opens a fresh socket per request and exhausts ephemeral ports
	// (dial tcp: can't assign requested address, TIME_WAIT buildup). Bump idle
	// conns to at least the worker count so connections are pooled and reused.
	restCfg.WrapTransport = func(rt http.RoundTripper) http.RoundTripper {
		if tr, ok := rt.(*http.Transport); ok {
			tr.MaxIdleConns = workers * 2
			tr.MaxIdleConnsPerHost = workers * 2
			tr.MaxConnsPerHost = workers * 2
			tr.IdleConnTimeout = 90 * time.Second
		}
		return rt
	}
	cs, err := kubernetes.NewForConfig(restCfg)
	if err != nil {
		return nil, fmt.Errorf("cannot build clientset: %w", err)
	}
	return cs, nil
}

type createResult struct {
	created    int64
	errors     int64
	elapsed    time.Duration
	sampleErrs []error
}

func createPods(ctx context.Context, cs kubernetes.Interface, o options) createResult {
	podsClient := cs.CoreV1().Pods(o.namespace)
	return createConcurrent(ctx, o.pods, o.workers, "pods", func(ctx context.Context, index int) error {
		_, err := podsClient.Create(ctx, newPod(o.namespace, podName(index), o.kwok), metav1.CreateOptions{})
		return err
	})
}

func createNodes(ctx context.Context, cs kubernetes.Interface, o options) createResult {
	nodesClient := cs.CoreV1().Nodes()
	return createConcurrent(ctx, o.nodes, o.workers, "nodes", func(ctx context.Context, index int) error {
		node := newNode(nodeName(index), o.kwok)
		created, err := nodesClient.Create(ctx, node, metav1.CreateOptions{})
		if err != nil {
			return err
		}
		// minkapi has no node status subresource controller; the status we sent on
		// Create is persisted as-is, so no follow-up UpdateStatus is needed. Guard
		// against an unexpectedly empty status just in case.
		if len(created.Status.Allocatable) == 0 {
			return fmt.Errorf("node %q created without allocatable capacity", created.Name)
		}
		return nil
	})
}

// createConcurrent runs createOne count times across workers goroutines, tracking
// success/error counts and capturing the first few errors. Each invocation receives a
// unique index in [0, count) so callers can mint collision-free object names. label is
// used only for progress output.
func createConcurrent(ctx context.Context, count, workers int, label string, createOne func(ctx context.Context, index int) error) createResult {
	var (
		created   atomic.Int64
		errCount  atomic.Int64
		attempted atomic.Int64
		firstErr  atomic.Bool
		errMu     sync.Mutex
		errs      []error
		wg        sync.WaitGroup
	)

	work := make(chan int, workers*2)
	progressEvery := int64(10000)
	if count < 10000 {
		progressEvery = 1000
	}

	start := time.Now()
	for range workers {
		wg.Go(func() {
			for i := range work {
				if err := createOne(ctx, i); err != nil {
					errCount.Add(1)
					// Surface the very first failure immediately. Otherwise a run where
					// every create errors just sits silent (the success-based progress
					// line below never fires) and looks like a hang.
					if firstErr.CompareAndSwap(false, true) {
						fmt.Printf("  !! first %s create error: %v\n", label, err)
					}
					errMu.Lock()
					if len(errs) < 5 {
						errs = append(errs, err)
					}
					errMu.Unlock()
				} else {
					n := created.Add(1)
					if n%progressEvery == 0 {
						fmt.Printf("  ... %d %s created (%s elapsed)\n", n, label, time.Since(start).Round(time.Millisecond))
					}
				}
				// Progress on total attempts too, so an all-erroring run still shows
				// forward motion (and its error count) instead of appearing stuck.
				a := attempted.Add(1)
				if a%progressEvery == 0 {
					fmt.Printf("  ... %d %s attempted (%d ok, %d err, %s elapsed)\n",
						a, label, created.Load(), errCount.Load(), time.Since(start).Round(time.Millisecond))
				}
			}
		})
	}

	for i := 0; i < count; i++ {
		select {
		case <-ctx.Done():
			// Interrupted: stop enqueueing.
			i = count
		case work <- i:
		}
	}
	close(work)
	wg.Wait()

	return createResult{
		created:    created.Load(),
		errors:     errCount.Load(),
		elapsed:    time.Since(start),
		sampleErrs: errs,
	}
}

// newPod returns a pending (unscheduled) pod. spec.nodeName is left empty and
// spec.schedulerName is pinned to a profile the external scheduler serves so it gets
// picked up. It requests the node's full allocatable CPU (see newNode: 8) so
// NodeResourcesFit places exactly one pod per node. When kwok is true the pod also
// tolerates the kwok node taint, without which a kwok cluster never schedules it.
func newPod(namespace, name string, kwok bool) *corev1.Pod {
	pod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name:      name,
			Namespace: namespace,
			Labels:    map[string]string{loadTestLabelKey: loadTestLabelValue},
		},
		Spec: corev1.PodSpec{
			SchedulerName:                 schedulerName,
			TerminationGracePeriodSeconds: new(int64),
			Containers: []corev1.Container{
				{
					Name:  "pause",
					Image: "registry.k8s.io/pause:3.5",
					Resources: corev1.ResourceRequirements{
						Requests: corev1.ResourceList{
							corev1.ResourceCPU:    resource.MustParse("8"),
							corev1.ResourceMemory: resource.MustParse("256Mi"),
						},
					},
				},
			},
		},
	}
	if kwok {
		pod.Spec.Tolerations = []corev1.Toleration{
			{
				Key:      kwokTaintKey,
				Operator: corev1.TolerationOpExists,
				Effect:   corev1.TaintEffectNoSchedule,
			},
		}
	}
	return pod
}

// newNode returns a Ready, schedulable node with capacity/allocatable set so the
// scheduler's NodeResourcesFit plugin can place pods on it. No taints, no kubelet.
// When kwok is true the node carries the kwok manage annotation and the kwok taint
// (mirroring how kwok tags nodes it manages); pods tolerate that taint (see newPod).
func newNode(name string, kwok bool) *corev1.Node {
	capacity := corev1.ResourceList{
		corev1.ResourceCPU:    resource.MustParse("8"),
		corev1.ResourceMemory: resource.MustParse("32Gi"),
		corev1.ResourcePods:   resource.MustParse("110"),
	}
	node := &corev1.Node{
		ObjectMeta: metav1.ObjectMeta{
			Name: name,
			Labels: map[string]string{
				loadTestLabelKey:          loadTestLabelValue,
				"kubernetes.io/hostname":  name,
				"kubernetes.io/os":        "linux",
				"node.kubernetes.io/role": "worker",
			},
		},
		Status: corev1.NodeStatus{
			Capacity:    capacity,
			Allocatable: capacity,
			Conditions: []corev1.NodeCondition{
				{
					Type:   corev1.NodeReady,
					Status: corev1.ConditionTrue,
					Reason: "KubeletReady",
				},
			},
			Phase: corev1.NodeRunning,
		},
	}
	if kwok {
		node.Annotations = map[string]string{kwokNodeAnnotationKey: kwokNodeAnnotationValue}
		node.Spec.Taints = []corev1.Taint{
			{
				Key:    kwokTaintKey,
				Value:  kwokTaintValue,
				Effect: corev1.TaintEffectNoSchedule,
			},
		}
	}
	return node
}

// podName and nodeName mint deterministic, collision-free names from the worker index.
// We assign explicit names instead of using generateName because minkapi generates
// the suffix server-side with a small (5-char) space and upserts on duplicate keys, so
// generateName silently drops ~0.04% of objects at 10k scale (birthday collisions).
func podName(index int) string  { return fmt.Sprintf("load-%09d", index) }
func nodeName(index int) string { return fmt.Sprintf("node-%09d", index) }

// pollUntilBound watches loadtest pods via a single List+Watch (a shared informer)
// instead of re-Listing the whole set every tick. The informer does exactly one
// initial List against minkapi and then stays current over a long-lived Watch,
// which avoids re-marshalling the full pod list on minkapi on every progress check
// (the dominant cost seen in profiling). Bound pods (non-empty spec.nodeName;
// minkapi has no server-side fieldSelector, so we filter client-side) are counted
// from the informer's local cache. It returns when all pods are bound or ctx is
// cancelled.
func pollUntilBound(ctx context.Context, cs kubernetes.Interface, o options, total int64) error {
	start := time.Now()

	// Scope the informer's List+Watch to the loadtest pods in our namespace.
	factory := informers.NewSharedInformerFactoryWithOptions(cs, 0,
		informers.WithNamespace(o.namespace),
		informers.WithTweakListOptions(func(lo *metav1.ListOptions) {
			lo.LabelSelector = loadTestSelector
		}),
	)
	podInformer := factory.Core().V1().Pods().Informer()

	// done is closed once every pod is observed bound, so the watch loop can exit
	// promptly on the event that crosses the threshold rather than waiting for a tick.
	done := make(chan struct{})
	var (
		lastReported int64 = -1
		closeOnce    sync.Once
	)

	report := func() {
		bound := countBoundFromStore(podInformer.GetStore())
		if bound != lastReported {
			fmt.Printf("bound            : %d / %d (%s elapsed)\n",
				bound, total, time.Since(start).Round(time.Second))
			lastReported = bound
		}
		if total > 0 && bound >= total {
			closeOnce.Do(func() { close(done) })
		}
	}

	handler := cache.ResourceEventHandlerFuncs{
		AddFunc:    func(any) { report() },
		UpdateFunc: func(any, any) { report() },
		DeleteFunc: func(any) { report() },
	}
	if _, err := podInformer.AddEventHandler(handler); err != nil {
		return fmt.Errorf("cannot add pod informer event handler: %w", err)
	}

	factory.Start(ctx.Done())
	if !cache.WaitForCacheSync(ctx.Done(), podInformer.HasSynced) {
		if ctx.Err() != nil {
			return nil
		}
		return fmt.Errorf("timed out waiting for pod informer cache sync")
	}
	// The initial List may already satisfy the target (e.g. a rerun against an
	// already-scheduled store), and cache-sync events fire before our handler is
	// wired up, so evaluate once after sync.
	report()

	select {
	case <-done:
		bound := countBoundFromStore(podInformer.GetStore())
		fmt.Printf("all %d pods bound in %s. OK\n", bound, time.Since(start).Round(time.Millisecond))
		return nil
	case <-ctx.Done():
		fmt.Printf("\ninterrupted: %d / %d pods bound after %s\n",
			lastReported, total, time.Since(start).Round(time.Second))
		return nil
	}
}

// countBoundFromStore counts pods in the informer's local cache that have a
// non-empty spec.nodeName. This reads the watch-maintained cache; it does not
// issue any request to minkapi.
func countBoundFromStore(store cache.Store) int64 {
	var bound int64
	for _, obj := range store.List() {
		pod, ok := obj.(*corev1.Pod)
		if !ok {
			continue
		}
		if pod.Spec.NodeName != "" {
			bound++
		}
	}
	return bound
}

// countBound lists all loadtest pods and returns how many have spec.nodeName set,
// plus the total listed. Used only once to establish the initial scheduling target;
// steady-state progress is tracked via a watch (see pollUntilBound).
func countBound(ctx context.Context, cs kubernetes.Interface, namespace string) (bound int64, listed int, err error) {
	list, err := cs.CoreV1().Pods(namespace).List(ctx, metav1.ListOptions{LabelSelector: loadTestSelector})
	if err != nil {
		return 0, 0, err
	}
	for i := range list.Items {
		if list.Items[i].Spec.NodeName != "" {
			bound++
		}
	}
	return bound, len(list.Items), nil
}

func printMem() {
	runtime.GC()
	var m runtime.MemStats
	runtime.ReadMemStats(&m)
	fmt.Printf("mem heap alloc   : %d MiB\n", m.HeapAlloc/(1024*1024))
	fmt.Printf("mem sys          : %d MiB\n", m.Sys/(1024*1024))
}
