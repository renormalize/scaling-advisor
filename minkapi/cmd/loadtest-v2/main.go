// SPDX-FileCopyrightText: 2026 SAP SE or an SAP affiliate company and Gardener contributors
//
// SPDX-License-Identifier: Apache-2.0

// Command loadtest-v2 is a variant of cmd/loadtest, retuned to stress the *API server*
// (minkapi) rather than the *scheduler*.
//
// Why a v2 at all
// ---------------
// The original cmd/loadtest is a worst-case *scheduling* storm: every node advertises
// 8 CPU and every pod requests 8 CPU, so NodeResourcesFit places exactly one pod per
// node and the scheduler must scan an ever-fuller cluster for each bind. In that shape
// the kube-scheduler is the pole in the tent (~10-11 cores of CPU, a multi-GiB cache),
// while minkapi's own CPU plateaus around 5-6 cores and is never the bottleneck. It
// answers "how hard can we push the scheduler", not "how hard can we push the apiserver".
//
// minkapi's cost, from prior pprof passes, concentrates in the request-serve and
// watch-fan-out path: decode request -> mutate store -> DeepCopy the object out ->
// JSON-encode a watch event -> Write/Flush it to *every* watcher (~40% of CPU is socket
// Write/Flush, ~16% is building/encoding events), plus full-collection marshalling on
// every LIST. So to make minkapi the bottleneck we invert every lever the original test
// pulls toward the scheduler:
//
//  1. Trivial scheduling (--node-cpu >> --pod-cpu): many pods fit per node and the first
//     node almost always fits, so the scheduler's per-pod work collapses to near-constant
//     and stops gating throughput. Each bind still costs minkapi a full write + watch
//     event, so minkapi's per-op cost is unchanged while the *rate* climbs.
//  2. Many concurrent watchers (--watchers N): minkapi encodes+DeepCopies+socket-writes
//     each event once PER watcher, so N informers multiply its dominant hot path N-fold
//     while barely touching the scheduler. This is the purest amplifier of minkapi's cost.
//  3. Sustained write churn (--churn-workers N, --churn-duration): instead of create-once-
//     then-wait, workers continuously Patch pods for the whole window. Every write fans a
//     watch event to all watchers — turning a one-shot create burst into continuous
//     write+watch pressure, which is what a busy real apiserver actually sees.
//  4. Repeated full LISTs (--list-workers N): the original test deliberately switched to a
//     single informer to AVOID re-Listing (the old dominant cost); v2 does the opposite on
//     purpose. Each LIST marshals the entire collection server-side — the single most
//     expensive minkapi operation per call — so a pool of listers is a brutal, direct
//     apiserver stressor.
//  5. Optional no-scheduler mode (--no-scheduler): to size minkapi's serve/watch/write
//     ceiling in isolation, don't run a scheduler at all. Create + churn + many-watchers +
//     repeated-lists against minkapi and profile it; nothing competes, so minkapi-usage.log
//     and its /debug/pprof CPU profile are unambiguously minkapi's.
//
// Everything else (unthrottled client, connection pooling, deterministic names, --kwok
// tagging) is carried over unchanged from cmd/loadtest so the two are directly comparable.
//
// Both minkapi and (unless --no-scheduler) the kube-scheduler must be started separately;
// this tool only needs the base kubeconfig minkapi serves. Example — a pure apiserver
// stress with no scheduler, loose fit, heavy fan-out and churn:
//
//	go run ./cmd/loadtest-v2 --kubeconfig /tmp/minkapi.yaml \
//	    --nodes 2000 --pods 100000 --node-cpu 128 --pod-cpu 100m \
//	    --watchers 200 --churn-workers 100 --list-workers 20 \
//	    --no-scheduler --duration 300s
//
// To target a kwok cluster instead, add --kwok (stamps the kwok manage annotation + taint
// on nodes and the matching toleration on pods); kwok bundles its own scheduler.
package main

import (
	"context"
	"flag"
	"fmt"
	"math/rand"
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
	"k8s.io/apimachinery/pkg/types"
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
	nodeCPU      string
	kubeConfig   string
	namespace    string
	podCPU       string
	nodes        int
	workers      int
	pods         int
	watchers     int
	churnWorkers int
	listWorkers  int
	duration     time.Duration
	kwok         bool
	noScheduler  bool
}

func parseFlags() options {
	var o options
	flag.IntVar(&o.pods, "pods", 10000, "number of pods to create")
	flag.IntVar(&o.nodes, "nodes", 10000, "number of schedulable nodes to create")
	flag.IntVar(&o.workers, "workers", 100, "number of concurrent create workers")
	flag.StringVar(&o.kubeConfig, "kubeconfig", "", "path to the base kubeconfig minkapi serves (required)")
	flag.StringVar(&o.namespace, "namespace", "default", "namespace to create pods in")
	flag.BoolVar(&o.kwok, "kwok", false, "target a kwok cluster: stamp nodes with the kwok manage annotation + taint and give pods the matching toleration (nothing schedules on kwok without this)")

	// v2 knobs.
	flag.StringVar(&o.nodeCPU, "node-cpu", "128", "per-node allocatable CPU. Make this >> --pod-cpu for a loose fit so the scheduler stops being the bottleneck (v1 used 8 vs 8 for one-pod-per-node)")
	flag.StringVar(&o.podCPU, "pod-cpu", "100m", "per-pod CPU request. Small relative to --node-cpu means many pods fit per node and scheduling is cheap")
	flag.IntVar(&o.watchers, "watchers", 50, "number of concurrent List+Watch informers. minkapi encodes+writes each watch event once PER watcher, so this multiplies its dominant cost")
	flag.IntVar(&o.churnWorkers, "churn-workers", 50, "number of goroutines that continuously Patch pods for --duration, generating sustained write+watch load (0 to disable)")
	flag.IntVar(&o.listWorkers, "list-workers", 10, "number of goroutines issuing repeated full LISTs of pods for --duration; each LIST marshals the whole collection server-side (0 to disable)")
	flag.DurationVar(&o.duration, "duration", 120*time.Second, "how long to sustain churn/list/watch pressure after the initial create burst")
	flag.BoolVar(&o.noScheduler, "no-scheduler", false, "do not wait for pods to bind (use when no scheduler is running); the sustained churn/list/watch load runs regardless")
	flag.Parse()
	return o
}

func main() {
	o := parseFlags()
	if err := run(o); err != nil {
		fmt.Fprintf(os.Stderr, "loadtest-v2 failed: %v\n", err)
		os.Exit(1)
	}
}

func run(o options) error {
	if o.kubeConfig == "" {
		return fmt.Errorf("--kubeconfig is required (path to the kubeconfig of the already-running minkapi)")
	}
	// Validate the resource quantities up front so a typo fails fast, not mid-run.
	if _, err := resource.ParseQuantity(o.nodeCPU); err != nil {
		return fmt.Errorf("invalid --node-cpu %q: %w", o.nodeCPU, err)
	}
	if _, err := resource.ParseQuantity(o.podCPU); err != nil {
		return fmt.Errorf("invalid --pod-cpu %q: %w", o.podCPU, err)
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	cs, err := newClient(o.kubeConfig, o.workers)
	if err != nil {
		return err
	}

	// 1. Create all nodes concurrently and wait.
	fmt.Printf("creating %d schedulable nodes (%s CPU each) using %d workers ...\n", o.nodes, o.nodeCPU, o.workers)
	nodeRes := createNodes(ctx, cs, o)
	fmt.Printf("nodes created    : %d (errors %d) in %s\n", nodeRes.created, nodeRes.errors, nodeRes.elapsed.Round(time.Millisecond))
	for i, e := range nodeRes.sampleErrs {
		fmt.Printf("  node error #%d  : %v\n", i+1, e)
	}
	if ctx.Err() != nil {
		return nil
	}

	// 2. Create all pods concurrently and wait.
	fmt.Printf("creating %d pods (%s CPU each) using %d workers ...\n", o.pods, o.podCPU, o.workers)
	podRes := createPods(ctx, cs, o)
	fmt.Printf("pods created     : %d (errors %d) in %s\n", podRes.created, podRes.errors, podRes.elapsed.Round(time.Millisecond))
	for i, e := range podRes.sampleErrs {
		fmt.Printf("  pod error #%d   : %v\n", i+1, e)
	}
	printMem()
	if ctx.Err() != nil {
		return nil
	}

	_, listed, err := countBound(ctx, cs, o.namespace)
	if err != nil {
		return fmt.Errorf("initial pod list failed: %w", err)
	}
	total := int64(listed)
	fmt.Println("=============================================")
	fmt.Printf("%d Ready nodes and %d pods are in minkapi (kubeconfig %s).\n",
		nodeRes.created, total, o.kubeConfig)
	if total != podRes.created {
		fmt.Printf("(note: %d pod creates succeeded but List found %d pods; likely leftover pods "+
			"from a prior run reusing the same names — restart minkapi for a clean count)\n",
			podRes.created, total)
	}

	// 3. Spin up the sustained apiserver-stress load: many watchers, a churn loop, and a
	//    repeated-LIST loop, all bounded by --duration (or Ctrl-C). This is the part that
	//    makes minkapi — not the scheduler — the pole in the tent.
	stressCtx, cancelStress := context.WithTimeout(ctx, o.duration)
	defer cancelStress()

	var stressWG sync.WaitGroup

	if o.watchers > 0 {
		fmt.Printf("starting %d concurrent watchers (each a full List+Watch informer) ...\n", o.watchers)
		startWatchers(stressCtx, &stressWG, cs, o)
	}
	if o.churnWorkers > 0 {
		fmt.Printf("starting %d churn workers (continuous Patch of pods) ...\n", o.churnWorkers)
		startChurn(stressCtx, &stressWG, cs, o, total)
	}
	if o.listWorkers > 0 {
		fmt.Printf("starting %d list workers (repeated full LIST of pods) ...\n", o.listWorkers)
		startListers(stressCtx, &stressWG, cs, o)
	}

	// 4. In parallel with the stress load, either wait for the scheduler to bind
	//    everything, or (no-scheduler mode) just report bound counts periodically until
	//    the window elapses.
	fmt.Println("Sustaining apiserver stress load; press Ctrl-C to stop early.")
	fmt.Println("=============================================")
	if o.noScheduler {
		waitForWindow(stressCtx, cs, o, total)
	} else {
		pollUntilBound(stressCtx, cs, o, total)
	}

	// 5. Wind down: stop the stress goroutines and wait for them to drain.
	cancelStress()
	stressWG.Wait()
	fmt.Println("stress load stopped.")
	printMem()
	return nil
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
	// caps MaxIdleConnsPerHost at 25 (< our worker count), so under high concurrency it
	// opens a fresh socket per request and exhausts ephemeral ports. Bump idle conns to
	// at least the worker count so connections are pooled and reused. v2 fans out to many
	// watchers/churn/list workers too, so size against the largest of those.
	pool := workers
	restCfg.WrapTransport = func(rt http.RoundTripper) http.RoundTripper {
		if tr, ok := rt.(*http.Transport); ok {
			tr.MaxIdleConns = pool * 4
			tr.MaxIdleConnsPerHost = pool * 4
			tr.MaxConnsPerHost = pool * 4
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
	sampleErrs []error
	created    int64
	errors     int64
	elapsed    time.Duration
}

func createPods(ctx context.Context, cs kubernetes.Interface, o options) createResult {
	podsClient := cs.CoreV1().Pods(o.namespace)
	return createConcurrent(ctx, o.pods, o.workers, "pods", func(ctx context.Context, index int) error {
		_, err := podsClient.Create(ctx, newPod(o.namespace, podName(index), o.podCPU, o.kwok), metav1.CreateOptions{})
		return err
	})
}

func createNodes(ctx context.Context, cs kubernetes.Interface, o options) createResult {
	nodesClient := cs.CoreV1().Nodes()
	return createConcurrent(ctx, o.nodes, o.workers, "nodes", func(ctx context.Context, index int) error {
		node := newNode(nodeName(index), o.nodeCPU, o.kwok)
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
// unique index in [0, count) so callers can mint collision-free object names.
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

// startWatchers launches o.watchers independent shared informers, each doing its own
// initial List and then a long-lived Watch scoped to the loadtest pods. This is the
// primary apiserver amplifier: minkapi DeepCopies, JSON-encodes and socket-writes every
// watch event once per watcher, so N watchers multiply the dominant hot path N-fold.
// Each informer runs until stressCtx is cancelled.
func startWatchers(ctx context.Context, wg *sync.WaitGroup, cs kubernetes.Interface, o options) {
	for range o.watchers {
		wg.Go(func() {
			factory := informers.NewSharedInformerFactoryWithOptions(cs, 0,
				informers.WithNamespace(o.namespace),
				informers.WithTweakListOptions(func(lo *metav1.ListOptions) {
					lo.LabelSelector = loadTestSelector
				}),
			)
			podInformer := factory.Core().V1().Pods().Informer()
			// No-op handlers: we only care that the informer maintains its List+Watch and
			// drains events, forcing minkapi to encode+write to this watcher's socket.
			_, _ = podInformer.AddEventHandler(cache.ResourceEventHandlerFuncs{})
			factory.Start(ctx.Done())
			cache.WaitForCacheSync(ctx.Done(), podInformer.HasSynced)
			<-ctx.Done()
		})
	}
}

// startChurn launches o.churnWorkers goroutines that continuously Patch existing pods
// (a strategic-merge patch bumping an annotation) until stressCtx is cancelled. Each
// successful write mutates the store and fans a watch event to every watcher, so this
// turns the one-shot create burst into sustained write+watch pressure — the shape a busy
// real apiserver sees. Pods are addressed by their deterministic names.
func startChurn(ctx context.Context, wg *sync.WaitGroup, cs kubernetes.Interface, o options, total int64) {
	if total <= 0 {
		return
	}
	podsClient := cs.CoreV1().Pods(o.namespace)
	var patches atomic.Int64
	var errs atomic.Int64
	start := time.Now()

	for c := range o.churnWorkers {
		id := c
		wg.Go(func() {
			// Each worker gets its own RNG so they touch different pods without contending
			// on a shared source.
			rng := rand.New(rand.NewSource(time.Now().UnixNano() + int64(id)))
			for {
				select {
				case <-ctx.Done():
					return
				default:
				}
				idx := rng.Int63n(total)
				name := podName(int(idx))
				// A tiny strategic-merge patch: bump one annotation. Cheap to build,
				// forces a full store mutate + watch-event fan-out on minkapi's side.
				patch := fmt.Appendf(nil,
					`{"metadata":{"annotations":{"loadtest.v2/churn":"%d"}}}`, patches.Load())
				_, err := podsClient.Patch(ctx, name, types.StrategicMergePatchType, patch, metav1.PatchOptions{})
				if err != nil {
					// ctx cancellation surfaces as an error; don't count it as a real failure.
					if ctx.Err() != nil {
						return
					}
					errs.Add(1)
					continue
				}
				n := patches.Add(1)
				if n%50000 == 0 {
					rate := float64(n) / time.Since(start).Seconds()
					fmt.Printf("  ... %d pod patches (%.0f/s, %d err, %s elapsed)\n",
						n, rate, errs.Load(), time.Since(start).Round(time.Millisecond))
				}
			}
		})
	}
	// A reporter that prints the final churn tally when the window ends.
	wg.Go(func() {
		<-ctx.Done()
		fmt.Printf("churn total      : %d patches (%d errors) over %s\n",
			patches.Load(), errs.Load(), time.Since(start).Round(time.Millisecond))
	})
}

// startListers launches o.listWorkers goroutines that issue repeated full LISTs of the
// loadtest pods until stressCtx is cancelled. Each LIST forces minkapi to marshal the
// entire pod collection server-side — the single most expensive per-call operation — so a
// pool of listers is a direct, brutal apiserver read stressor. (The original loadtest
// deliberately avoids this via a single informer; v2 does it on purpose.)
func startListers(ctx context.Context, wg *sync.WaitGroup, cs kubernetes.Interface, o options) {
	podsClient := cs.CoreV1().Pods(o.namespace)
	var lists atomic.Int64
	var errs atomic.Int64
	start := time.Now()

	for range o.listWorkers {
		wg.Go(func() {
			for {
				select {
				case <-ctx.Done():
					return
				default:
				}
				_, err := podsClient.List(ctx, metav1.ListOptions{LabelSelector: loadTestSelector})
				if err != nil {
					if ctx.Err() != nil {
						return
					}
					errs.Add(1)
					continue
				}
				n := lists.Add(1)
				if n%1000 == 0 {
					rate := float64(n) / time.Since(start).Seconds()
					fmt.Printf("  ... %d full LISTs (%.1f/s, %d err, %s elapsed)\n",
						n, rate, errs.Load(), time.Since(start).Round(time.Millisecond))
				}
			}
		})
	}
	wg.Go(func() {
		<-ctx.Done()
		fmt.Printf("list total       : %d LISTs (%d errors) over %s\n",
			lists.Load(), errs.Load(), time.Since(start).Round(time.Millisecond))
	})
}

// newPod returns a pod requesting cpuReq CPU. With a loose fit (node CPU >> cpuReq) many
// pods land per node and scheduling is cheap, so the scheduler stops gating throughput.
// spec.schedulerName is pinned so an external scheduler (if any) picks it up; in
// --no-scheduler mode nothing binds it and that is fine — the stress load does not depend
// on binding. When kwok is true the pod tolerates the kwok node taint.
func newPod(namespace, name, cpuReq string, kwok bool) *corev1.Pod {
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
							corev1.ResourceCPU:    resource.MustParse(cpuReq),
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

// newNode returns a Ready, schedulable node advertising cpu allocatable CPU. Set cpu
// large relative to the pod request for a loose fit (many pods per node) so scheduling is
// cheap and minkapi, not the scheduler, is the bottleneck. When kwok is true the node
// carries the kwok manage annotation and taint.
func newNode(name, cpu string, kwok bool) *corev1.Node {
	capacity := corev1.ResourceList{
		corev1.ResourceCPU:    resource.MustParse(cpu),
		corev1.ResourceMemory: resource.MustParse("512Gi"),
		corev1.ResourcePods:   resource.MustParse("10000"),
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
// We assign explicit names instead of using generateName because minkapi generates the
// suffix server-side with a small (5-char) space and upserts on duplicate keys, so
// generateName silently drops objects at scale (birthday collisions). The churn loop
// relies on these names to address existing pods.
func podName(index int) string { return fmt.Sprintf("load-%09d", index) }

func nodeName(index int) string { return fmt.Sprintf("node-%09d", index) }

// waitForWindow (no-scheduler mode) simply reports the bound count on a ticker until the
// stress window elapses or ctx is cancelled. Nothing is expected to bind (no scheduler),
// so this is purely a heartbeat while the churn/list/watch load runs.
func waitForWindow(ctx context.Context, cs kubernetes.Interface, o options, total int64) {
	ticker := time.NewTicker(10 * time.Second)
	defer ticker.Stop()
	start := time.Now()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			bound, _, err := countBound(ctx, cs, o.namespace)
			if err != nil {
				if ctx.Err() != nil {
					return
				}
				fmt.Printf("  (heartbeat list failed: %v)\n", err)
				continue
			}
			fmt.Printf("heartbeat        : %d / %d pods bound (%s elapsed, no-scheduler mode)\n",
				bound, total, time.Since(start).Round(time.Second))
		}
	}
}

// pollUntilBound watches loadtest pods via a single dedicated List+Watch informer (in
// addition to the --watchers fan-out) and reports progress until every pod is bound or
// ctx is cancelled. Unlike v1 this returns when the window ends even if not all pods are
// bound, since v2's point is sustained load, not measuring time-to-bind-all.
func pollUntilBound(ctx context.Context, cs kubernetes.Interface, o options, total int64) {
	start := time.Now()

	factory := informers.NewSharedInformerFactoryWithOptions(cs, 0,
		informers.WithNamespace(o.namespace),
		informers.WithTweakListOptions(func(lo *metav1.ListOptions) {
			lo.LabelSelector = loadTestSelector
		}),
	)
	podInformer := factory.Core().V1().Pods().Informer()

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
		fmt.Printf("cannot add pod informer event handler: %v\n", err)
		return
	}

	factory.Start(ctx.Done())
	if !cache.WaitForCacheSync(ctx.Done(), podInformer.HasSynced) {
		return
	}
	report()

	select {
	case <-done:
		bound := countBoundFromStore(podInformer.GetStore())
		fmt.Printf("all %d pods bound in %s. OK\n", bound, time.Since(start).Round(time.Millisecond))
	case <-ctx.Done():
		fmt.Printf("\nwindow ended: %d / %d pods bound after %s\n",
			lastReported, total, time.Since(start).Round(time.Second))
	}
}

// countBoundFromStore counts pods in the informer's local cache that have a non-empty
// spec.nodeName. This reads the watch-maintained cache; it does not issue any request to
// minkapi.
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

// countBound lists all loadtest pods and returns how many have spec.nodeName set, plus
// the total listed. Used to establish the initial target and as the no-scheduler
// heartbeat.
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
