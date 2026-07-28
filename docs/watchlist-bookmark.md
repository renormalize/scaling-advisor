# WatchList, the `initial-events-end` Bookmark, and why kube-scheduler 1.35 hung against minkapi

## Summary / TL;DR

When we ran a dockerized `kube-scheduler:v1.35.1` against our in-memory API server
`minkapi`, the scheduler failed to schedule a single pod. Every informer hung during
startup, logging repeatedly:

```
reflector.go:1159 "Warning: event bookmark expired" err="k8s.io/client-go/informers/factory.go:161: awaiting required bookmark event for initial events stream, no events received for 4m0s"
"...hasn't received required bookmark event marking the end of initial events stream..."
```

**Root cause:** client-go's `WatchListClient` feature gate flipped from default `false`
to default `true` in Kubernetes/client-go **1.35**. With it enabled, informers initialize
using the streaming *WatchList* protocol instead of the classic list-then-watch. WatchList
requires the API server to terminate the initial-events stream with a special watch
`Bookmark` event carrying the annotation `k8s.io/initial-events-end: "true"`. minkapi
never emits that bookmark (its watch handler ignores `sendInitialEvents`/
`allowWatchBookmarks`), so the reflector's `WaitForCacheSync` never completes, the
scheduler sees zero nodes/pods, and it binds nothing.

**One-line fix (client-side):** force the scheduler onto the classic list-then-watch path
by disabling the gate:

```
--feature-gates=WatchListClient=false
```

After that flag was added, the scheduler bound ~10000 pods to ~10000 nodes immediately.

---

## Background: minkapi and our test

`minkapi` (module `github.com/gardener/scaling-advisor/minkapi`) is an in-memory
Kubernetes API server used for scale-testing the scaling advisor. It implements enough of
the kube-apiserver HTTP contract that a real `kube-scheduler` can talk to it: paged/filtered
LIST, WATCH streaming, pod binding, status patches, etc.

For scale-testing we ran an unmodified `registry.k8s.io/kube-scheduler:v1.35.1` container
pointed at minkapi. Older scheduler images had worked, but `v1.35.1` never scheduled
anything — all informers were stuck "syncing" forever. The logs above pointed straight at
client-go's reflector waiting for a bookmark that minkapi does not send.

---

## What is WatchList (streaming lists)?

**WatchList** is a mechanism (KEP-3157, *Watch-List*) that lets a client obtain the initial
state of a resource collection as a *stream* of watch events instead of as one big LIST
response.

The problem it solves is API-server memory pressure. A large LIST forces the apiserver to
buffer the entire response in memory before sending it — per KEP-3157 the server can
allocate hundreds of megabytes per request (roughly `O(5 * the_response_from_etcd)`
temporary memory), so a handful of concurrent LISTs of a big collection (e.g. all pods in a
large cluster) can OOM the apiserver and even destabilize a co-located kubelet. WatchList
instead streams objects one-by-one out of the watch cache, keeping server memory bounded
(KEP-3157 targets roughly `O(watchers * constant)`, ~2 MB per watcher). It also fixes the
long-standing "stale reads from the watch cache" problem by computing a fresh resource
version from etcd and waiting for the cache to catch up before streaming — i.e. a
consistent read for informer initialization.

There are two matching feature gates:

- **`WatchList`** — server-side (kube-apiserver). Makes the apiserver honor
  `sendInitialEvents=true` on a watch request.
- **`WatchListClient`** — client-side (client-go). Makes informers/reflectors *choose* the
  WatchList path when initializing, instead of classic list-then-watch.

The client-side gate is defined in client-go:

`/Users/i585850/go/pkg/mod/k8s.io/client-go@v0.35.5/features/known_features.go`

```go
// owner: @p0lyn0mial
// beta: v1.30
//
// Allow the client to get a stream of individual items instead of chunking from the server.
WatchListClient Feature = "WatchListClient"
```

At reflector construction, the gate is what decides `UseWatchList`
(`/Users/i585850/go/pkg/mod/k8s.io/client-go@v0.33.7/tools/cache/reflector.go:296-300`,
identical wiring in v0.35.5):

```go
// don't overwrite UseWatchList if already set
// because the higher layers (e.g. storage/cacher) disabled it on purpose
if r.UseWatchList == nil {
    r.UseWatchList = ptr.To(clientfeatures.FeatureGates().Enabled(clientfeatures.WatchListClient))
}
```

The client's option-building logic lives in
`/Users/i585850/go/pkg/mod/k8s.io/client-go@v0.35.5/util/watchlist/watch_list.go`. It
early-returns (falling back to classic list) when the gate is off:

```go
func PrepareWatchListOptionsFromListOptions(listOptions metav1.ListOptions) (metav1.ListOptions, bool, error) {
    if !clientfeatures.FeatureGates().Enabled(clientfeatures.WatchListClient) {
        return metav1.ListOptions{}, false, nil
    }
    ...
    watchListOptions.ResourceVersionMatch = metav1.ResourceVersionMatchNotOlderThan
    watchListOptions.Watch = true
    watchListOptions.AllowWatchBookmarks = true
    watchListOptions.SendInitialEvents = ptr.To(true)
    ...
}
```

---

## The `initial-events-end` Bookmark

### Ordinary bookmarks

A watch **Bookmark** event is normally a lightweight, periodic event that carries *only* a
`resourceVersion` (no object payload of interest). It exists so a client can advance its
"last seen resourceVersion" without the server having to replay real object changes, which
makes watch restarts cheap. A client opts in by setting `allowWatchBookmarks=true`; a
server that does not support bookmarks simply ignores the field. See the reflector comment
at `/Users/i585850/go/pkg/mod/k8s.io/client-go@v0.35.5/tools/cache/reflector.go:531-534`:

```go
// To reduce load on kube-apiserver on watch restarts, you may enable watch bookmarks.
// Reflector doesn't assume bookmarks are returned at all (if the server do not support
// watch bookmarks, it will ignore this field).
AllowWatchBookmarks: true,
```

### The special terminating bookmark

WatchList overloads the bookmark mechanism with one **special** bookmark: the event whose
object carries the annotation `k8s.io/initial-events-end: "true"`. This marks the end of the
initial-events stream. The constant is defined in apimachinery
(`k8s.io/apimachinery/pkg/apis/meta/v1/types.go:435-442`):

```go
const (
    // InitialEventsAnnotationKey the name of the key
    // under which an annotation marking the end of
    // a watchlist stream is stored.
    //
    // The annotation is added to a "Bookmark" event.
    InitialEventsAnnotationKey = "k8s.io/initial-events-end"
)
```

### The request shape

When WatchList is active, the reflector issues a *watch* request (not a list) with these
options (`.../client-go@v0.35.5/tools/cache/reflector.go:762-768`):

```go
options := metav1.ListOptions{
    ResourceVersion:      lastKnownRV,
    AllowWatchBookmarks:  true,
    SendInitialEvents:    ptr.To(true),
    ResourceVersionMatch: metav1.ResourceVersionMatchNotOlderThan,
    TimeoutSeconds:       &timeoutSeconds,
}
```

On the wire this is roughly:

```
GET /api/v1/pods?watch=true&sendInitialEvents=true&resourceVersionMatch=NotOlderThan&allowWatchBookmarks=true
```

The server is then expected to (per the `watchList` doc comment,
`.../reflector.go:695-711`):

1. begin with synthetic `ADDED` events for every existing object up to the current
   resourceVersion, then
2. end with a synthetic `Bookmark` event carrying that resourceVersion **and** the
   `k8s.io/initial-events-end: "true"` annotation.

```go
// It begins with synthetic "Added" events of all resources up to the most recent ResourceVersion.
// It ends with a synthetic "Bookmark" event containing the most recent ResourceVersion.
// After receiving a "Bookmark" event the reflector is considered to be synchronized.
```

### Why the client blocks until it sees that bookmark

The reflector consumes the stream in `handleAnyWatch`/`handleListWatch`
(`.../reflector.go:869-992`). During WatchList initialization it is called with
`exitOnWatchListBookmarkReceived = true`, and it only sets `watchListBookmarkReceived` when
it sees a `watch.Bookmark` bearing the annotation (`.../reflector.go:962-979`):

```go
case watch.Bookmark:
    // A `Bookmark` means watch has synced here, just update the resourceVersion
    if meta.GetAnnotations()[metav1.InitialEventsAnnotationKey] == "true" {
        watchListBookmarkReceived = true
    }
...
if exitOnWatchListBookmarkReceived && watchListBookmarkReceived {
    ...
    return watchListBookmarkReceived, nil
}
```

`watchList()` loops until that flag is true before it will `Replace` the store and set the
last-sync resourceVersion (`.../reflector.go:791-809`). Until the terminating bookmark
arrives, the informer's cache is never considered synced, so `WaitForCacheSync` blocks —
and the scheduler's informers never become usable.

### How this maps to the error we saw

A watchdog ticker (`initialEventsEndBookmarkTicker`) fires while the reflector waits. If no
terminating bookmark has arrived, it emits exactly the warnings we observed
(`.../reflector.go:1157-1181`):

```go
func (t *initialEventsEndBookmarkTicker) warnIfExpired() {
    if err := t.produceWarningIfExpired(); err != nil {
        t.logger.Info("Warning: event bookmark expired", "err", err)
    }
}

func (t *initialEventsEndBookmarkTicker) produceWarningIfExpired() error {
    ...
    if t.lastEventObserveTime.IsZero() {
        return fmt.Errorf("%s: awaiting required bookmark event for initial events stream, no events received for %v", t.name, t.clock.Since(t.watchStart))
    }
    ...
    return fmt.Errorf("%s: hasn't received required bookmark event marking the end of initial events stream, received last event %v ago", t.name, elapsedTime)
}
```

Those two format strings are, verbatim, the messages from the scheduler log:
`awaiting required bookmark event for initial events stream, no events received for 4m0s`
and `hasn't received required bookmark event marking the end of initial events stream`.
The `reflector.go:1159` file:line in the scheduler log corresponds to `warnIfExpired`'s
`t.logger.Info("Warning: event bookmark expired", ...)` call.

---

## The classic list-then-watch path (why it works against minkapi)

Before WatchList, and whenever `WatchListClient` is disabled, informers initialize with
list-then-watch (`ListAndWatchWithContext`,
`.../client-go@v0.35.5/tools/cache/reflector.go:406-414`):

```go
func (r *Reflector) ListAndWatchWithContext(ctx context.Context) error {
    ...
    fallbackToList := !r.useWatchList
    ...
    if r.useWatchList {
        w, err = r.watchList(ctx)
        ...
    }
```

The classic path is:

1. **LIST** the collection (optionally paginated with `limit`/`continue`). The list
   response's `metadata.resourceVersion` gives the snapshot point. The reflector fills its
   store from the list result and treats the list as "synced" — no bookmark required.
2. **WATCH** starting at that resourceVersion (`?watch=true&resourceVersion=<RV>`), applying
   incremental `ADDED`/`MODIFIED`/`DELETED` events from there on.

Crucially, in this path *the LIST response itself* establishes the initial synced state, so
there is no `initial-events-end` bookmark and no dependency on it. minkapi already
implements both halves: a plain LIST handler and a WATCH handler that streams from a
starting resourceVersion. That is exactly why disabling `WatchListClient` makes the 1.35
scheduler work.

---

## Why kube-scheduler 1.35 broke: version history

`WatchListClient` was introduced as Beta but *off by default* in 1.30, and only became
*on by default* in 1.35. This is the change that broke us. Compare the two vendored
definitions:

**client-go v0.33.7** (`.../client-go@v0.33.7/features/known_features.go:83`) — single,
default-`false` entry:

```go
WatchListClient: {Default: false, PreRelease: Beta},
```

**client-go v0.35.5** (`.../client-go@v0.35.5/features/known_features.go:101-104`) —
versioned, flips to default-`true` at 1.35:

```go
WatchListClient: {
    {Version: version.MustParse("1.30"), Default: false, PreRelease: Beta},
    {Version: version.MustParse("1.35"), Default: true, PreRelease: Beta},
},
```

| Component / version | `WatchListClient` default | Informer init path | Works vs minkapi? |
|---------------------|---------------------------|--------------------|-------------------|
| client-go / k8s ≤ 1.29 | (gate not present / alpha) | classic list-then-watch | Yes |
| client-go / k8s 1.30–1.34 | `false` (Beta, opt-in) | classic list-then-watch | Yes |
| client-go / k8s 1.35+ | `true` (Beta, on)         | **WatchList streaming** | **No** (until fixed) |

So a `kube-scheduler:v1.34.x` (or earlier) image talks to minkapi over the classic path and
works; `v1.35.1` defaults into WatchList and hangs. (Related gates in v0.35.5 also moved at
1.35 — e.g. `InformerResourceVersion` GA and `InOrderInformersBatchProcess` Beta — but those
did not cause this failure.)

Per KEP-3157, the server-side `WatchList` gate progressed Alpha → Beta → GA, and the
client-side `WatchListClient` gate went Beta (initially for kube-controller-manager),
through a "beta5" scale-testing milestone, toward GA-default-on across all clients; the
1.35 default-true flip we observed is that rollout reaching the scheduler.

---

## How we diagnosed it

Two log lines told the whole story:

1. **Scheduler side (client-go reflector):**

   ```
   reflector.go:1159 "Warning: event bookmark expired" err="k8s.io/client-go/informers/factory.go:161: awaiting required bookmark event for initial events stream, no events received for 4m0s"
   ```

   This is `initialEventsEndBookmarkTicker.warnIfExpired()` — proof the reflector was in
   WatchList mode and waiting for the `initial-events-end` bookmark.

2. **minkapi side:** minkapi logs `"WatchBookmarks is unimplemented"` whenever a client
   sets `AllowWatchBookmarks`. From
   `/Users/i585850/go/src/github.com/gardener/scaling-advisor/minkapi/view/inmclient/access/genericaccess.go:168-175`:

   ```go
   func logUnimplementedOptionalListOptions(log logr.Logger, listOptions metav1.ListOptions) {
       if listOptions.AllowWatchBookmarks {
           log.V(4).Info("WatchBookmarks is unimplemented")
       }
       if listOptions.Limit > 0 {
           log.V(4).Info("Limit is unimplemented", "limit", listOptions.Limit)
       }
   }
   ```

The scheduler was asking for bookmarks (and `sendInitialEvents`); minkapi acknowledged the
option only to say it was unimplemented and then streamed no terminating bookmark. Match
confirmed.

---

## Fix (client-side): disable the feature gate

The fix that worked was to force the scheduler back onto classic list-then-watch by
disabling the client gate:

```
--feature-gates=WatchListClient=false
```

Corrected `docker run` invocation (illustrative — keep your existing config/mount/network
flags, just add the feature gate):

```bash
docker run --rm \
  --network host \
  -v /private/tmp/minkapi-bin-packing-scheduler-config-docker.yaml:/etc/kubernetes/scheduler-config.yaml:ro \
  registry.k8s.io/kube-scheduler:v1.35.1 \
  kube-scheduler \
    --config=/etc/kubernetes/scheduler-config.yaml \
    --feature-gates=WatchListClient=false \
    -v=4
```

Notes and caveats:

- **`KubeSchedulerConfiguration` has no `featureGates` field.** Feature gates for the
  scheduler are set only via the `--feature-gates` command-line flag, so you cannot express
  this inside the scheduler config YAML — the CLI flag is the only lever.
- **Other clients disable it differently.** Any client-go-based component defaults into this
  behavior once built against client-go ≥ 1.35:
  - kube-controller-manager / kube-apiserver / kubelet: `--feature-gates=WatchListClient=false`.
  - controller-runtime / custom controllers: client-go reads gates from the
    `KUBE_FEATURE_WatchListClient=false` environment variable (client-go's
    `envVarFeatureGates`), or the component can call
    `clientfeatures.FeatureGates().Set(...)` / disable per-lister via
    `Reflector.UseWatchList`. There is no single universal flag — it depends on how each
    binary wires client-go feature gates.
- This is a **workaround**, not a fix in minkapi. It merely avoids the code path minkapi
  does not implement.

---

## Making minkapi natively WatchList-compatible (server-side, not implemented)

To support WatchList natively (so clients need no flag), minkapi's watch handling must
recognize the WatchList request and emit the terminating bookmark. Two files are involved.

### 1. HTTP watch handler — `minkapi/server/server.go`

`handleListOrWatch` currently only branches on `watch=true` vs list
(`server.go:462-481`), and `handleWatch` (`server.go:547-588`) streams incremental events
from `startVersion` but never inspects `sendInitialEvents`, never replays current objects as
`ADDED`, and never sends a bookmark:

```go
func handleWatch(d typeinfo.Descriptor, view minkapi.View, labelSelector labels.Selector) http.HandlerFunc {
    return func(w http.ResponseWriter, r *http.Request) {
        ...
        startVersion, ok = getParseResourceVersion(w, r)
        ...
        err := view.WatchObjects(r.Context(), d.GVK, startVersion, namespace, labelSelector, func(event watch.Event) error {
            ...
            _, _ = fmt.Fprintln(w, eventJson)
            flusher.Flush()
            return nil
        })
        ...
    }
}
```

Required changes:

- Parse `sendInitialEvents` and `resourceVersionMatch` from the query string (alongside the
  existing `watch` parse).
- When `sendInitialEvents=true` (and `resourceVersionMatch=NotOlderThan`):
  1. LIST the current matching objects and write each as a `watch.Event{Type: Added}` to the
     stream, capturing the collection's current resourceVersion `RV`.
  2. After the initial `ADDED` batch, write one `watch.Event{Type: Bookmark, Object: obj}`
     where `obj` is an (empty) object of the resource's kind whose
     `metadata.resourceVersion == RV` and whose
     `metadata.annotations["k8s.io/initial-events-end"] == "true"`
     (use the constant `metav1.InitialEventsAnnotationKey`).
  3. Then continue streaming live events from `RV` as it already does.

`buildWatchEventJson` (`server.go:678`) can encode the bookmark event as long as its
`Object` is a real typed object with the annotation set.

### 2. List-options plumbing — `minkapi/view/inmclient/access/genericaccess.go`

The in-memory client access layer currently *acknowledges but ignores* the relevant option
(`genericaccess.go:168-175`, the `AllowWatchBookmarks` branch shown above). To support
WatchList this branch should stop being a no-op and instead thread `AllowWatchBookmarks` /
`SendInitialEvents` / `ResourceVersionMatch` through `GetWatcher`
(`genericaccess.go:122-129`) into `view.GetWatcher` / `view.WatchObjects`, so the view can
produce the initial `ADDED` replay + terminating bookmark described above.

Both layers must agree: the HTTP handler needs the options parsed off the request, and the
in-memory `View`/`GetWatcher` path needs them for the in-process client used by minkapi's
own components.

This document only describes the change; **no code was modified.**

---

## References

Source files read (paths and line numbers as of the versions vendored in this repo):

- minkapi watch HTTP handler:
  `/Users/i585850/go/src/github.com/gardener/scaling-advisor/minkapi/server/server.go`
  — `handleListOrWatch` (462-481), `handleList` (483-493), `handleWatch` (547-588),
  `buildWatchEventJson` (678).
- minkapi list-option handling / "unimplemented" log:
  `/Users/i585850/go/src/github.com/gardener/scaling-advisor/minkapi/view/inmclient/access/genericaccess.go`
  — `GetWatcher` (122-129), `checkLogListOptions` (162-166),
  `logUnimplementedOptionalListOptions` (168-175).
- client-go feature gate (default flip):
  `/Users/i585850/go/pkg/mod/k8s.io/client-go@v0.35.5/features/known_features.go`
  — `WatchListClient` const (72-76), versioned defaults (101-104).
  Contrast: `/Users/i585850/go/pkg/mod/k8s.io/client-go@v0.33.7/features/known_features.go:83`
  (`{Default: false, PreRelease: Beta}`).
- client-go reflector (WatchList vs classic, bookmark handling, warnings):
  `/Users/i585850/go/pkg/mod/k8s.io/client-go@v0.35.5/tools/cache/reflector.go`
  — gate→`UseWatchList` (v0.33.7:296-300), `ListAndWatchWithContext` (406-431),
  `watchList` doc + body (695-812), watch-list request options (762-768),
  bookmark handling in handler (962-979), warning ticker (1105-1181).
- WatchList client option builder:
  `/Users/i585850/go/pkg/mod/k8s.io/client-go@v0.35.5/util/watchlist/watch_list.go`
  — `PrepareWatchListOptionsFromListOptions` (40-82).
- `initial-events-end` annotation constant:
  `k8s.io/apimachinery/pkg/apis/meta/v1/types.go`
  — `InitialEventsAnnotationKey = "k8s.io/initial-events-end"` (435-442);
  `SendInitialEvents` field + defaulting comment (~428-432).

External:

- KEP-3157 (Watch-List), SIG API Machinery:
  <https://github.com/kubernetes/enhancements/tree/master/keps/sig-api-machinery/3157-watch-list>
  (fetched and verified: memory-spike motivation `O(5*response)` → `O(watchers*constant)`,
  `sendInitialEvents=true` + `resourceVersionMatch=NotOlderThan` request shape, the
  `k8s.io/initial-events-end: "true"` terminating bookmark, and the Alpha/Beta/GA milestones
  for the server-side `WatchList` and client-side `WatchListClient` gates).
- Kubernetes API concepts — "Streaming lists" and watch bookmarks:
  <https://kubernetes.io/docs/reference/using-api/api-concepts/> (not re-fetched in this
  session; consistent with the vendored source above).

> Note: `WebSearch` was unavailable for this session's model, so the KEP milestone wording
> comes from a single `WebFetch` of the KEP directory plus the vendored client-go/apimachinery
> source. All feature-gate defaults, constants, request options, and log strings quoted above
> were verified directly against the vendored source in this repo's module cache.
