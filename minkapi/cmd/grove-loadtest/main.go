// SPDX-FileCopyrightText: 2026 SAP SE or an SAP affiliate company and Gardener contributors
//
// SPDX-License-Identifier: Apache-2.0

// Command grove-loadtest is the grove counterpart of ./cmd/loadtest. It drives an
// already-running minkapi over its HTTP path and exercises the full create -> update
// -> delete lifecycle of every grove custom resource minkapi now serves:
//
//	PodCliqueSet, PodClique, PodCliqueScalingGroup, ClusterTopologyBinding (grove.io/v1alpha1)
//	PodGang                                                                (scheduler.grove.io/v1alpha1)
//
// For each kind it concurrently creates --count objects, then updates each (spec +
// status subresource), then deletes each, while a single List+Watch informer per kind
// tracks ADDED/MODIFIED/DELETED events. minkapi must be started separately; this tool
// only needs the base kubeconfig minkapi serves. Example:
//
//	go run ./cmd/grove-loadtest --kubeconfig /tmp/minkapi.yaml --count 2000 --workers 100
package main

import (
	"context"
	"flag"
	"fmt"
	"net/http"
	"os"
	"os/signal"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	groveopcorev1alpha1 "github.com/ai-dynamo/grove/operator/api/core/v1alpha1"
	groveschedv1alpha1 "github.com/ai-dynamo/grove/scheduler/api/core/v1alpha1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/runtime/serializer"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/clientcmd"
)

const (
	loadTestLabelKey   = "loadtest"
	loadTestLabelValue = "grove"
	loadTestSelector   = loadTestLabelKey + "=" + loadTestLabelValue
)

type options struct {
	count      int
	workers    int
	kubeConfig string
	namespace  string
}

func parseFlags() options {
	var o options
	flag.IntVar(&o.count, "count", 2000, "number of objects to create per grove kind")
	flag.IntVar(&o.workers, "workers", 100, "number of concurrent workers")
	flag.StringVar(&o.kubeConfig, "kubeconfig", "", "path to the base kubeconfig minkapi serves (required)")
	flag.StringVar(&o.namespace, "namespace", "default", "namespace for namespaced grove kinds")
	flag.Parse()
	return o
}

func main() {
	if err := run(parseFlags()); err != nil {
		fmt.Fprintf(os.Stderr, "grove-loadtest failed: %v\n", err)
		os.Exit(1)
	}
}

// scheme holds every grove type so the REST clients can (de)serialize them.
var scheme = runtime.NewScheme()

func init() {
	if err := groveopcorev1alpha1.AddToScheme(scheme); err != nil {
		panic(err)
	}
	if err := groveschedv1alpha1.AddToScheme(scheme); err != nil {
		panic(err)
	}
}

// kindDescriptor describes one grove kind and how to drive its lifecycle. The builders
// return typed runtime.Objects; minkapi does no admission validation, so a minimal
// object (TypeMeta + ObjectMeta + a trivial spec) is enough to exercise every route.
type kindDescriptor struct {
	gvr        schema.GroupVersionResource
	namespaced bool
	// newObject mints a fresh object with the given name (and namespace, if namespaced).
	newObject func(namespace, name string) runtime.Object
	// mutateSpec bumps a spec field in place so an Update produces an observable change.
	mutateSpec func(obj runtime.Object)
	// mutateStatus bumps a status field in place for the status-subresource update.
	mutateStatus func(obj runtime.Object)
}

func groveGVR(gv schema.GroupVersion, resource string) schema.GroupVersionResource {
	return gv.WithResource(resource)
}

func descriptors() []kindDescriptor {
	opGV := groveopcorev1alpha1.SchemeGroupVersion
	schedGV := groveschedv1alpha1.SchemeGroupVersion
	// Each object needs its OWN label map: the JSON decoder writes into the object's
	// Labels map on Get(...).Into(...), so a shared map would be written concurrently
	// by parallel update workers (fatal: concurrent map writes).
	newLabels := func() map[string]string { return map[string]string{loadTestLabelKey: loadTestLabelValue} }

	return []kindDescriptor{
		{
			gvr:        groveGVR(opGV, "podcliquesets"),
			namespaced: true,
			newObject: func(ns, name string) runtime.Object {
				return &groveopcorev1alpha1.PodCliqueSet{
					TypeMeta:   metav1.TypeMeta{APIVersion: opGV.String(), Kind: "PodCliqueSet"},
					ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: ns, Labels: newLabels()},
					Spec:       groveopcorev1alpha1.PodCliqueSetSpec{Replicas: 1},
				}
			},
			mutateSpec:   func(o runtime.Object) { o.(*groveopcorev1alpha1.PodCliqueSet).Spec.Replicas = 2 },
			mutateStatus: func(o runtime.Object) { o.(*groveopcorev1alpha1.PodCliqueSet).Status.Replicas = 2 },
		},
		{
			gvr:        groveGVR(opGV, "podcliques"),
			namespaced: true,
			newObject: func(ns, name string) runtime.Object {
				return &groveopcorev1alpha1.PodClique{
					TypeMeta:   metav1.TypeMeta{APIVersion: opGV.String(), Kind: "PodClique"},
					ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: ns, Labels: newLabels()},
					Spec:       groveopcorev1alpha1.PodCliqueSpec{RoleName: "worker", Replicas: 1},
				}
			},
			mutateSpec:   func(o runtime.Object) { o.(*groveopcorev1alpha1.PodClique).Spec.Replicas = 2 },
			mutateStatus: func(o runtime.Object) { o.(*groveopcorev1alpha1.PodClique).Status.Replicas = 2 },
		},
		{
			gvr:        groveGVR(opGV, "podcliquescalinggroups"),
			namespaced: true,
			newObject: func(ns, name string) runtime.Object {
				return &groveopcorev1alpha1.PodCliqueScalingGroup{
					TypeMeta:   metav1.TypeMeta{APIVersion: opGV.String(), Kind: "PodCliqueScalingGroup"},
					ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: ns, Labels: newLabels()},
					Spec:       groveopcorev1alpha1.PodCliqueScalingGroupSpec{Replicas: 1, CliqueNames: []string{"worker"}},
				}
			},
			mutateSpec:   func(o runtime.Object) { o.(*groveopcorev1alpha1.PodCliqueScalingGroup).Spec.Replicas = 2 },
			mutateStatus: func(o runtime.Object) { o.(*groveopcorev1alpha1.PodCliqueScalingGroup).Status.Replicas = 2 },
		},
		{
			gvr:        groveGVR(opGV, "clustertopologybindings"),
			namespaced: false,
			newObject: func(_, name string) runtime.Object {
				return &groveopcorev1alpha1.ClusterTopologyBinding{
					TypeMeta:   metav1.TypeMeta{APIVersion: opGV.String(), Kind: "ClusterTopologyBinding"},
					ObjectMeta: metav1.ObjectMeta{Name: name, Labels: newLabels()},
					Spec: groveopcorev1alpha1.ClusterTopologyBindingSpec{
						Levels: []groveopcorev1alpha1.TopologyLevel{{Domain: "rack", Key: "topology.kubernetes.io/rack"}},
					},
				}
			},
			mutateSpec: func(o runtime.Object) {
				o.(*groveopcorev1alpha1.ClusterTopologyBinding).Spec.Levels[0].Key = "topology.kubernetes.io/zone"
			},
			mutateStatus: func(o runtime.Object) {
				o.(*groveopcorev1alpha1.ClusterTopologyBinding).Status.ObservedGeneration = 2
			},
		},
		{
			gvr:        groveGVR(schedGV, "podgangs"),
			namespaced: true,
			newObject: func(ns, name string) runtime.Object {
				return &groveschedv1alpha1.PodGang{
					TypeMeta:   metav1.TypeMeta{APIVersion: schedGV.String(), Kind: "PodGang"},
					ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: ns, Labels: newLabels()},
					Spec: groveschedv1alpha1.PodGangSpec{
						PodGroups: []groveschedv1alpha1.PodGroup{{Name: "worker", MinReplicas: 1}},
					},
				}
			},
			mutateSpec: func(o runtime.Object) {
				o.(*groveschedv1alpha1.PodGang).Spec.PodGroups[0].MinReplicas = 2
			},
			mutateStatus: func(o runtime.Object) {
				o.(*groveschedv1alpha1.PodGang).Status.Phase = groveschedv1alpha1.PodGangPhaseRunning
			},
		},
	}
}

func run(o options) error {
	if o.kubeConfig == "" {
		return fmt.Errorf("--kubeconfig is required (path to the kubeconfig of the already-running minkapi)")
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	restCfg, err := buildRestConfig(o.kubeConfig, o.workers)
	if err != nil {
		return err
	}

	for _, d := range descriptors() {
		if ctx.Err() != nil {
			return nil
		}
		client, err := restClientForGroup(restCfg, d.gvr.GroupVersion())
		if err != nil {
			return fmt.Errorf("cannot build client for %s: %w", d.gvr.GroupVersion(), err)
		}
		if err := exerciseKind(ctx, client, d, o); err != nil {
			return fmt.Errorf("%s: %w", d.gvr.Resource, err)
		}
	}
	return nil
}

// buildRestConfig returns an unthrottled, connection-pooled JSON rest.Config. Mirrors
// the tuning in ./cmd/loadtest so high create concurrency does not exhaust ports.
func buildRestConfig(kubeConfigPath string, workers int) (*rest.Config, error) {
	cfg, err := clientcmd.BuildConfigFromFlags("", kubeConfigPath)
	if err != nil {
		return nil, fmt.Errorf("cannot build rest config from %q: %w", kubeConfigPath, err)
	}
	cfg.QPS = 20000
	cfg.Burst = 20000
	cfg.WrapTransport = func(rt http.RoundTripper) http.RoundTripper {
		if tr, ok := rt.(*http.Transport); ok {
			tr.MaxIdleConns = workers * 2
			tr.MaxIdleConnsPerHost = workers * 2
			tr.MaxConnsPerHost = workers * 2
			tr.IdleConnTimeout = 90 * time.Second
		}
		return rt
	}
	return cfg, nil
}

// restClientForGroup builds a scheme-backed REST client rooted at /apis/<group>/<version>.
func restClientForGroup(base *rest.Config, gv schema.GroupVersion) (rest.Interface, error) {
	cfg := rest.CopyConfig(base)
	cfg.GroupVersion = &gv
	cfg.APIPath = "/apis"
	cfg.ContentType = "application/json"
	cfg.NegotiatedSerializer = serializer.NewCodecFactory(scheme).WithoutConversion()
	return rest.RESTClientFor(cfg)
}

func exerciseKind(ctx context.Context, client rest.Interface, d kindDescriptor, o options) error {
	fmt.Printf("=============================================\n")
	fmt.Printf("kind %-24s (%s, namespaced=%t)\n", d.gvr.Resource, d.gvr.GroupVersion(), d.namespaced)

	watchStop := startWatch(ctx, client, d, o.namespace)
	defer watchStop()

	created := concurrent(ctx, o.count, o.workers, func(ctx context.Context, i int) error {
		obj := d.newObject(o.namespace, objName(i))
		return client.Post().
			NamespaceIfScoped(o.namespace, d.namespaced).
			Resource(d.gvr.Resource).
			Body(obj).
			Do(ctx).Error()
	})
	fmt.Printf("  created  : %d (errors %d) in %s\n", created.ok, created.errs, created.elapsed.Round(time.Millisecond))
	printSampleErrs(created)
	if ctx.Err() != nil {
		return nil
	}

	updated := concurrent(ctx, o.count, o.workers, func(ctx context.Context, i int) error {
		return updateOne(ctx, client, d, o.namespace, objName(i))
	})
	fmt.Printf("  updated  : %d (errors %d) in %s\n", updated.ok, updated.errs, updated.elapsed.Round(time.Millisecond))
	printSampleErrs(updated)
	if ctx.Err() != nil {
		return nil
	}

	deleted := concurrent(ctx, o.count, o.workers, func(ctx context.Context, i int) error {
		return client.Delete().
			NamespaceIfScoped(o.namespace, d.namespaced).
			Resource(d.gvr.Resource).
			Name(objName(i)).
			Do(ctx).Error()
	})
	fmt.Printf("  deleted  : %d (errors %d) in %s\n", deleted.ok, deleted.errs, deleted.elapsed.Round(time.Millisecond))
	printSampleErrs(deleted)
	return nil
}

// updateOne gets the object, applies the spec mutation via a full PUT, then applies the
// status mutation via a PUT to the status subresource — exercising both write paths.
func updateOne(ctx context.Context, client rest.Interface, d kindDescriptor, namespace, name string) error {
	cur := d.newObject(namespace, name)
	if err := client.Get().
		NamespaceIfScoped(namespace, d.namespaced).
		Resource(d.gvr.Resource).
		Name(name).
		Do(ctx).Into(cur); err != nil {
		return fmt.Errorf("get: %w", err)
	}

	d.mutateSpec(cur)
	if err := client.Put().
		NamespaceIfScoped(namespace, d.namespaced).
		Resource(d.gvr.Resource).
		Name(name).
		Body(cur).
		Do(ctx).Into(cur); err != nil {
		return fmt.Errorf("put spec: %w", err)
	}

	d.mutateStatus(cur)
	if err := client.Put().
		NamespaceIfScoped(namespace, d.namespaced).
		Resource(d.gvr.Resource).
		Name(name).
		SubResource("status").
		Body(cur).
		Do(ctx).Error(); err != nil {
		return fmt.Errorf("put status: %w", err)
	}
	return nil
}

type lifecycleResult struct {
	ok         int64
	errs       int64
	elapsed    time.Duration
	sampleErrs []error
}

func printSampleErrs(r lifecycleResult) {
	for i, e := range r.sampleErrs {
		fmt.Printf("    error #%d : %v\n", i+1, e)
	}
}

// concurrent runs op count times across workers goroutines, tracking success/error
// counts and capturing the first few errors. Each op gets a unique index in [0, count).
func concurrent(ctx context.Context, count, workers int, op func(ctx context.Context, i int) error) lifecycleResult {
	var (
		ok    atomic.Int64
		errc  atomic.Int64
		errMu sync.Mutex
		errs  []error
		wg    sync.WaitGroup
	)
	work := make(chan int, workers*2)
	start := time.Now()
	for range workers {
		wg.Go(func() {
			for i := range work {
				if err := op(ctx, i); err != nil {
					errc.Add(1)
					errMu.Lock()
					if len(errs) < 5 {
						errs = append(errs, err)
					}
					errMu.Unlock()
					continue
				}
				ok.Add(1)
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
	return lifecycleResult{ok: ok.Load(), errs: errc.Load(), elapsed: time.Since(start), sampleErrs: errs}
}

// startWatch opens a single List+Watch against the kind and tallies event types until
// the returned stop func is called. It reports observed counts on stop so each kind's
// create/update/delete are confirmed to stream ADDED/MODIFIED/DELETED events.
func startWatch(ctx context.Context, client rest.Interface, d kindDescriptor, namespace string) func() {
	var added, modified, deleted atomic.Int64
	watchCtx, cancel := context.WithCancel(ctx)

	req := client.Get().
		NamespaceIfScoped(namespace, d.namespaced).
		Resource(d.gvr.Resource).
		VersionedParams(&metav1.ListOptions{LabelSelector: loadTestSelector, Watch: true}, metav1.ParameterCodec)

	w, err := req.Watch(watchCtx)
	if err != nil {
		fmt.Printf("  watch    : failed to start (%v)\n", err)
		cancel()
		return func() {}
	}

	done := make(chan struct{})
	go func() {
		defer close(done)
		for ev := range w.ResultChan() {
			switch ev.Type {
			case "ADDED":
				added.Add(1)
			case "MODIFIED":
				modified.Add(1)
			case "DELETED":
				deleted.Add(1)
			}
		}
	}()

	return func() {
		// Let the last events drain before tearing the watch down.
		time.Sleep(500 * time.Millisecond)
		w.Stop()
		cancel()
		<-done
		fmt.Printf("  watch    : added=%d modified=%d deleted=%d\n",
			added.Load(), modified.Load(), deleted.Load())
	}
}

// objName mints deterministic, collision-free names. Explicit names (not generateName)
// so update/delete can address the exact objects created — see ./cmd/loadtest for why
// generateName drops objects at scale in minkapi.
func objName(i int) string { return fmt.Sprintf("grove-load-%09d", i) }
