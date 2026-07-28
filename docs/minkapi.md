# MinKAPI

> Status: exploratory notes. Written to help integrate `minkapi` into other projects (e.g. [grove](https://github.com/ai-dynamo/grove)) for scale testing.

## What is MinKAPI?

`minkapi` (**Min**imal **K**ubernetes **API**) is a lightweight, **in-memory Kubernetes API server**. It speaks enough of the real `kube-apiserver` HTTP contract that standard Kubernetes clients — `client-go`, `kubectl`, informers, and even an embedded `kube-scheduler` — can talk to it, but it holds all objects in memory with no etcd, no admission control, no authentication, and no real reconciliation.

It exists inside the `scaling-advisor` repo as the module `github.com/gardener/scaling-advisor/minkapi`. The scaling advisor uses it as a **simulation engine**: it loads a snapshot of a real cluster's objects (nodes, pods, PVCs, etc.) into minkapi, then runs scheduling simulations against isolated *sandbox views* to decide how to scale node pools.

### Why it's useful for scale testing

- **No real cluster required.** You get a working API endpoint that accepts creates/lists/watches for the standard resource types.
- **Fast and cheap.** Everything is in-memory. You can create thousands of pods/nodes without kubelets, container runtimes, or etcd.
- **Standard clients work unchanged.** Your controller/operator can point its `client-go` clientset or dynamic client at minkapi's generated kubeconfig and behave as if it's talking to a real cluster.
- **Sandbox views** let you fork the cluster state cheaply: a sandbox overlays a base view, so reads see base + local changes while writes stay private to the sandbox.
- **In-process embedding.** You can `import` minkapi and get a `kubernetes.Interface` / `dynamic.Interface` directly, bypassing the network entirely (`ClientAccessModeInMemory`).

### What it is NOT

- Not a conformant apiserver. There is **no OpenAPI/schema endpoint**, so `kubectl` client-side validation must be disabled (`--validate=false`).
- **No admission, no defaulting, no field validation, no RBAC/auth** (served over plain HTTP, `insecure-skip-tls-verify`).
- No controllers/reconcilers — objects don't get controller-manager side effects (no ReplicaSet -> Pod creation, no PVC binding controller, etc.). Objects just sit in the store as you write them.
- `PUT` (update) handling is explicitly marked incomplete in the code.
- `fieldSelector` on watches is not supported (only `labelSelector`).

## Supported resources

Registered in `api/minkapi/typeinfo/typeinfo.go` (`SupportedDescriptors`). Core group (`v1`): Namespace, ServiceAccount, ConfigMap, Node, Pod, Service, PersistentVolume, PersistentVolumeClaim, ReplicationController, Event. Plus: `apps/v1` Deployment, ReplicaSet, StatefulSet; `coordination.k8s.io/v1` Lease; `events.k8s.io/v1` Event; `rbac.authorization.k8s.io/v1` Role; `scheduling.k8s.io/v1` PriorityClass; `policy/v1` PodDisruptionBudget; `storage.k8s.io/v1` StorageClass, CSIDriver, CSIStorageCapacity, CSINode, VolumeAttachment, VolumeAttributesClass; `node.k8s.io/v1` RuntimeClass; `resource.k8s.io/v1` (DRA) ResourceSlice, ResourceClaim, DeviceClass.

## Architecture

```
                 minkapi.Server (HTTP)  ── api/apis discovery, per-resource CRUD/watch
                        │
                        ▼
                 minkapi.ViewAccess
                        │
          ┌─────────────┴───────────────┐
          ▼                             ▼
     base View                    sandbox View(s)
   (ViewTypeBase)                (ViewTypeSandbox)
          │                             │ overlays a delegate view
          ▼                             ▼
   per-GVK ResourceStore          private per-GVK ResourceStore + EventSink
   (in-memory, versioned)
```

Key interfaces (all in `api/minkapi/types.go`):

- **`Server`** = `common.Service` (Start/Stop) + `ViewAccess`. Serves the base view at `http://<host>:<port>/<basePrefix>` (default prefix `base`) and each sandbox at `http://<host>:<port>/<sandboxName>`.
- **`ViewAccess`** — `GetBaseView()`, `GetSandboxView(ctx, name)`, `GetSandboxViewOverDelegate(ctx, name, delegateView)`.
- **`View`** — the object repository facade. Create/Get/Update/Patch/Delete/List/Watch objects by GVK, plus conveniences `ListNodes`, `ListPods`, `ListEvents`, `UpdatePodNodeBinding`. Also `GetClientFacades(ctx, accessMode)` to get client-go clients wired to the view, and `GetResourceStore(gvk)`.
- **`ResourceStore`** — per-GVK in-memory store with a monotonic resource-version counter and watch support.
- **`EventSink`** — collects k8s Events.

### Views: base vs sandbox

- The **base view** is the authoritative in-memory cluster state. This is what you load your snapshot into.
- A **sandbox view** is created *over a delegate view* (usually the base). It has its own private per-GVK stores and event sink. Reads fall through to the delegate for objects the sandbox hasn't touched; writes are captured privately in the sandbox and do **not** propagate back to the base. This is how the scaling advisor runs an embedded `kube-scheduler` against speculative node additions without mutating the real snapshot.
- Verified behavior: after creating objects in base then `POST /views/sim1`, listing `sim1` returns the base objects (overlay read-through). Writes into `sim1` would stay isolated.

### Client access modes (`commontypes.ClientAccessMode`)

`View.GetClientFacades(ctx, mode)` returns a `commontypes.ClientFacades` bundle: `{ Client kubernetes.Interface, DynClient dynamic.Interface, InformerFactory, DynInformerFactory, Mode }`.

- **`ClientAccessModeNetwork`** — clients issue real HTTP calls to the minkapi server (uses the generated kubeconfig). Use this when the code under test is a separate process, or you specifically want to exercise the HTTP path.
- **`ClientAccessModeInMemory`** — clients call directly into the in-memory stores, skipping serialization and the network. Fastest; only usable when you embed minkapi in-process.

## The CLI

Source: `minkapi/main.go` -> `minkapi/cli/cli.go` -> `minkapi/server`.

### Build

```sh
cd minkapi
go build -o bin/minkapi .
# (the module Makefile `build` target has a stale var; building the package directly is simplest)
```

### Flags

| Flag | Default | Meaning |
|------|---------|---------|
| `-k, --kubeconfig` | `/tmp/minkapi.yaml` | Path where the **base** kubeconfig is generated (falls back to `$KUBECONFIG`). Sandbox kubeconfigs are written next to it as `minkapi-<name>.yaml`. |
| `--bind-address` | `:8091` | `host:port` to listen on. |
| `-b, --base-prefix` | `base` | Path prefix for the base view. Base served at `/<prefix>`. |
| `-s, --watch-queue-size` | `100` | Max queued events per watcher. |
| `-t, --watch-timeout` | `5m` | Watch idle timeout before the server closes the connection. |
| `--profile` | `false` | Register `/debug/pprof/*` and `/trigger-gc`. |
| `--shutdown-timeout` | `10s` | Graceful shutdown timeout. |
| `-v, --v` | | klog verbosity (higher = more logs; try `-v 3` or `-v 4`). |

Default port `8091` = `commonconstants.DefaultMinKAPIPort`.

### Run

```sh
./bin/minkapi --bind-address ":8091" -k /tmp/minkapi.yaml -v 3
```

On start it:
1. Listens on the bind address.
2. Generates the base kubeconfig at `-k` (server URL `http://<bind>/base`, `insecure-skip-tls-verify: true`, no auth).
3. Generates a sample `kube-scheduler` config at `/tmp/minkapi-bin-packing-scheduler-config.yaml` (QPS 100, Burst 50) pointed at that kubeconfig.
4. Serves discovery (`/api`, `/apis`, `/api/v1/...`) and per-resource routes.

It handles SIGINT/SIGTERM for graceful shutdown.

### Talking to it with kubectl

```sh
export KUBECONFIG=/tmp/minkapi.yaml
kubectl api-resources                       # discovery works
kubectl get nodes
# client-side validation must be OFF (no OpenAPI endpoint):
kubectl create --validate=false -f node.json
kubectl create --validate=false -f pod.json
```

Gotchas confirmed during exploration:
- `kubectl create namespace foo` **fails** — it relies on an apiserver behavior minkapi doesn't implement. Create the Namespace from a manifest with `--validate=false` instead.
- `kubectl apply` fails for objects using `generateName` ("cannot use generate name with apply"); use `kubectl create` for those.
- Always pass `--validate=false` (no schema/OpenAPI served).

### Creating a sandbox view over HTTP

```sh
curl -X POST http://localhost:8091/views/sim1
# -> {"kind":"Status","status":"Success","code":201,...}
# now addressable at http://localhost:8091/sim1 and a kubeconfig /tmp/minkapi-sim1.yaml is generated
kubectl --server=http://localhost:8091/sim1 --insecure-skip-tls-verify get pods -A
```

## Endpoints (per view, mounted under the view's path prefix)

- `GET /api`, `GET /apis` — discovery (versions, groups).
- `GET /api/v1/` and `GET /apis/<group>/v1/` — API resource lists.
- Core, namespaced: `POST|GET /api/v1/namespaces/{ns}/{resource}`, `GET|PATCH|PUT|DELETE .../{name}`, `PUT .../{name}/status`, `PATCH .../{name}/status`.
- Core, cluster-scoped: same under `/api/v1/{resource}`.
- Grouped resources: under `/apis/<group>/v1/...`.
- Pod binding (used by the scheduler): `POST /api/v1/namespaces/{ns}/pods/{name}/binding` — sets `pod.Spec.NodeName`.
- Watch: add `?watch=true` to a list URL (chunked streaming of `metav1.WatchEvent`). Supports `?resourceVersion=` and `?labelSelector=`. `fieldSelector` is not supported.
- Server-level: `POST /views/{name}` — create a sandbox view.
- If `--profile`: `/debug/pprof/*`, `/trigger-gc`.

Patch content types: `application/merge-patch+json` and `application/strategic-merge-patch+json` (status patch requires strategic-merge).

## Embedding minkapi in Go (in-process)

Two ways.

### A) Launch the full server via the CLI helpers

```go
import (
    "context"
    "github.com/gardener/scaling-advisor/minkapi/cli"
    commontypes "github.com/gardener/scaling-advisor/api/common/types"
)

app, exitCode, err := cli.LaunchApp(ctx) // parses os.Args, starts HTTP server in a goroutine
// app.Server is a minkapi.Server; app.Ctx / app.Cancel manage lifecycle
facades, err := app.Server.GetBaseView().GetClientFacades(ctx, commontypes.ClientAccessModeNetwork)
// facades.Client is a kubernetes.Interface pointed at the running server
...
cli.ShutdownApp(&app)
```

### B) Construct the server directly (more control, no os.Args)

```go
import (
    "github.com/gardener/scaling-advisor/minkapi/server"
    "github.com/gardener/scaling-advisor/api/minkapi"
    commontypes "github.com/gardener/scaling-advisor/api/common/types"
)

cfg := minkapi.Config{
    BasePrefix: minkapi.DefaultBasePrefix,
    ServerConfig: commontypes.ServerConfig{
        KubeConfigPath: "/tmp/minkapi.yaml",
        BindAddress:    ":8091",
    },
    WatchConfig: minkapi.WatchConfig{QueueSize: 100, Timeout: 5 * time.Minute},
}
srv, err := server.New(ctx, cfg)
go srv.Start(ctx)           // blocks serving; run in goroutine
defer srv.Stop(ctx)

// In-memory clients (no network):
facades, err := srv.GetBaseView().GetClientFacades(ctx, commontypes.ClientAccessModeInMemory)
sandbox, err := srv.GetSandboxView(ctx, "sim1")
```

You can also skip the HTTP server entirely and use `view.NewAccess(...)` + `GetClientFacades(ClientAccessModeInMemory)` if you only need in-process client behavior — but the server route is the documented path.

## Notes / caveats for integrators

- **No controllers run.** If your test relies on Deployment→ReplicaSet→Pod expansion or PVC binding, minkapi won't do it. You either create the leaf objects (Pods) directly, or run the relevant controller/scheduler yourself against minkapi's kubeconfig.
- Generated kubeconfigs use plain HTTP + `insecure-skip-tls-verify`. Fine for local scale testing, not for anything exposed.
- Resource versions are a global monotonic counter shared across stores (per view).
- For scheduling simulations, minkapi ships a sample scheduler config; you can point a real `kube-scheduler` binary at `/tmp/minkapi-*-bin-packing-scheduler-config.yaml`.

## Integration with grove (scale testing)

Target: [grove](https://github.com/ai-dynamo/grove) at `/Users/i585850/go/src/github.com/ai-dynamo/grove`. Grove is a controller-runtime **operator** for AI-inference workloads. It defines CRDs and reconciles them into native + custom objects.

### What grove is (relevant facts)

- Modules: `operator/` (controller-manager, the thing under test), `operator/api` (CRD Go types), `scheduler/api` (PodGang type), `cli-plugin/`. Standard `sigs.k8s.io/controller-runtime`.
- CRDs:
  - `grove.io/v1alpha1`: **PodCliqueSet**, **PodClique**, **PodCliqueScalingGroup**, **ClusterTopologyBinding**
  - `scheduler.grove.io/v1alpha1`: **PodGang**
- The manager is built in `operator/internal/controller/manager.go` via `ctrl.NewManager(getRestConfig(...), ...)`, and `getRestConfig` uses `ctrl.GetConfigOrDie()` — i.e. it reads the standard `KUBECONFIG` / in-cluster config. **This is the seam**: point it at a kubeconfig and it will talk to whatever apiserver that config names.
- Reconcilers create/patch: **Pods**, **Services**, **ServiceAccounts**, **Roles/RoleBindings** (native), plus **HorizontalPodAutoscaler** (`autoscaling/v2`), plus the grove/scheduler **CRs** and their status subresources.
- CRDs are installed separately (embedded YAML + `operator/cmd/install-crds`, or Helm `operator/charts/crds/`), not auto-registered by the manager.
- Existing test infra: controller-runtime **`envtest`** in unit tests; a **fake client** (`operator/test/utils/setup.go`, `fake.NewClientBuilder()`); and **e2e scale tests** under `operator/e2e/tests/scale/` (`scale_up_test.go`, `soak_test.go`, etc.) that run against real **k3d** clusters at ~1000+ PodCliqueSets.

### The blocker: minkapi does not support CRDs

**minkapi cannot host grove's controllers as-is.** minkapi's type registry is a fixed, hardcoded set of built-in Kubernetes types (see `SupportedScheme` / `SupportedDescriptors` in `api/minkapi/typeinfo/typeinfo.go`) — assembled from `corev1.AddToScheme`, `appsv1.AddToScheme`, etc. There is **no apiextensions / CustomResourceDefinition support and no way to register an arbitrary GVK at runtime**. Concretely, minkapi would reject or 404:

- `grove.io/v1alpha1` and `scheduler.grove.io/v1alpha1` resources (grove's core objects) — not in the scheme, no routes registered, not in discovery.
- `autoscaling/v2` HorizontalPodAutoscaler — also not among the supported groups.

Since grove's reconcilers spend their time reading/writing exactly those CR types, standing up grove against a stock minkapi will fail at discovery/CRUD for its own resources. The parts minkapi *could* host (Pods, Services, ServiceAccounts, RBAC) are the downstream leaf objects, not the CRs that drive the controllers.

Two further mismatches to keep in mind even for the native subset:
- minkapi is **JSON-only**; controller-runtime defaults can negotiate protobuf. Grove exposes `ClientConnection.{AcceptContentTypes,ContentType}` in its operator config, so force JSON there if you go down this path.
- **No controllers/side-effects** in minkapi: creating a PodCliqueSet would not cascade to PodCliques/Pods — grove's own controller is what does that, so you need grove running against the store, which brings us back to the CRD requirement.

### Options for scale testing grove

Ranked by effort/return:

1. **Extend the fake-client / envtest path grove already has (recommended, lowest risk).** Grove already scale-tests controller logic with `fake.NewClientBuilder()` and uses `envtest` in unit tests. `envtest` runs a *real* `kube-apiserver` + etcd locally and *does* support installing grove's CRDs — this is the supported way to exercise reconcilers without nodes/kubelets. For pure controller throughput/scale, this is the intended tool, not minkapi. minkapi adds little here.

2. **Teach minkapi to serve grove's CRDs (medium/large effort, if you specifically want minkapi's speed + sandbox model).** minkapi's type handling is data-driven off `Descriptor`s and a `runtime.Scheme`. You would need to:
   - Register grove's schemes (`grovev1alpha1.AddToScheme`, `schedulerv1alpha1.AddToScheme`, `autoscalingv2.AddToScheme`) into a scheme minkapi uses.
   - Add `Descriptor`s for each Kind (GVK/GVR/list kind/namespaced/plural) and include them in `SupportedDescriptors` (or a pluggable equivalent) so routes + discovery get generated.
   - This requires code changes in `api/minkapi/typeinfo` and possibly the discovery/list-building logic. There is no public extension hook today — it's a fork/patch, not configuration.
   - Even then, minkapi runs **no controllers**, so you must run grove's controller-manager against it (pointing `KUBECONFIG` at minkapi's generated kubeconfig) to get the CR→Pod cascade. Grove's manager `getRestConfig` makes this a config change, not a code change on grove's side.

3. **Hybrid: real apiserver for CRs, minkapi for the pod/node fan-out (speculative).** Not directly supported; only worth it if the pod/node population is the scale bottleneck and you can decouple it. Likely more complex than option 1.

**Bottom line:** for scale-testing grove's controllers, the CRD requirement makes stock minkapi a poor drop-in — grove's own `envtest`/fake-client scale harness is the path of least resistance. minkapi becomes attractive only if you (a) invest in adding grove's GVKs to minkapi's registry and (b) run grove's controller-manager against it, in exchange for minkapi's in-memory speed and sandbox/fork semantics for large pod/node populations.

### If you pursue option 2, the wiring on grove's side is trivial

Grove reads a standard kubeconfig via `ctrl.GetConfigOrDie()`. Run minkapi, then start grove's operator with `KUBECONFIG=/tmp/minkapi.yaml` (and CRDs "installed" — which in a patched minkapi means the GVKs are registered). Set grove's operator config `ContentType: application/json` to avoid protobuf negotiation. No grove code changes needed beyond config.

