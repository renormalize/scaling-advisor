# Running minkapi with a dockerized kube-scheduler

How to point an external `kube-scheduler` (run as a Docker container) at a
locally-running `minkapi`, so it schedules minkapi's pending pods onto minkapi's
nodes.

## Why the extra config files

`minkapi` generates a kubeconfig and a sample scheduler config on startup. With `-k
./minkapi-kubeconfig.yaml` they persist in the `minkapi/` directory
(`minkapi/minkapi-kubeconfig.yaml` and
`minkapi/minkapi-base-bin-packing-scheduler-config.yaml`). Both are written for
**host-local** use, though:

- The kubeconfig's server URL is `http://:8091/base` — an empty host that resolves to
  *localhost*. Inside a container, localhost is the container itself, not your host.
- The scheduler config's `kubeconfig:` points at an **absolute host path** that does
  not exist inside the container.

So we keep the generated files untouched and make two **docker-variant copies** with
container-appropriate values. They live in the `minkapi/` directory:

| File | Purpose | Key difference from the generated file |
|------|---------|----------------------------------------|
| `minkapi/minkapi-kubeconfig-docker.yaml` | kubeconfig the scheduler uses | `server: http://host.docker.internal:8091/base` |
| `minkapi/minkapi-base-bin-packing-scheduler-config-docker.yaml` | scheduler config | `kubeconfig: /etc/minkapi/minkapi-kubeconfig-docker.yaml` (the in-container mount path) |

`host.docker.internal` is the alias for the host machine as seen from inside a
container (enabled via `--add-host host.docker.internal:host-gateway`).

## Prerequisites

- `minkapi` built (`cd minkapi && go build -o bin/minkapi .`).
- Docker running.
- The two docker-variant config files above (already committed under `minkapi/`).

## Step 1 — Start minkapi on the host

Bind to all interfaces so the container's bridge network can reach it, and write the
kubeconfig into the `minkapi/` directory (so it lives alongside the other configs):

```sh
cd minkapi
./bin/minkapi --bind-address "0.0.0.0:8091" -k "$(pwd)/minkapi-kubeconfig.yaml" -v 3
```

`:8091` also works in practice, but `0.0.0.0:8091` is the safe choice for
reachability from the container. minkapi keeps running in this terminal.

## Step 2 — Start kube-scheduler as a container

In a second terminal, from the `minkapi/` directory:

```sh
docker run \
  --add-host host.docker.internal:host-gateway \
  -v "$PWD/minkapi-base-bin-packing-scheduler-config-docker.yaml:/etc/minkapi/scheduler-config.yaml:ro" \
  -v "$PWD/minkapi-kubeconfig-docker.yaml:/etc/minkapi/minkapi-kubeconfig-docker.yaml:ro" \
  registry.k8s.io/kube-scheduler:v1.35.1 \
  kube-scheduler \
    --config=/etc/minkapi/scheduler-config.yaml \
    --feature-gates=WatchListClient=false \
    -v=2
```

Three things must be right, and each was a real failure we hit:

1. **`--add-host host.docker.internal:host-gateway`** — lets the container dial the
   host. The kubeconfig's `server` uses this alias.
2. **Bind-mount real *files*, not missing paths.** If a `-v` source path does not
   exist on the host, Docker silently creates it as an **empty directory** and mounts
   it as such; the scheduler then fails with
   `read .../scheduler-config.yaml: is a directory`. Always mount files that exist.
   (Using `$PWD/...` from `minkapi/` guarantees they exist.)
3. **`--feature-gates=WatchListClient=false`** — REQUIRED for scheduler images >= 1.35.
   Client-go's `WatchListClient` gate defaults to `true` as of 1.35, which makes the
   scheduler use the streaming WatchList informer protocol. That protocol waits for a
   terminating "initial-events-end" bookmark that minkapi does not emit, so every
   informer hangs and nothing is scheduled. Disabling the gate forces the classic
   list-then-watch path, which minkapi supports. See
   [`docs/watchlist-bookmark.md`](./watchlist-bookmark.md) for the full analysis.

### The in-container paths

The `-v` targets and the scheduler flags must agree:

- The scheduler config is mounted at `/etc/minkapi/scheduler-config.yaml`, which is
  what `--config=` points at.
- Inside that config, `kubeconfig: /etc/minkapi/minkapi-kubeconfig-docker.yaml` must
  match the second `-v` target exactly.

## Step 3 — Create nodes + pending pods and watch them bind

With both running, use the loadtest in `--external` mode to drive the already-running
minkapi (do NOT let it start its own in-process server):

```sh
cd minkapi
go run ./cmd/loadtest --external --schedule \
  --kubeconfig "$(pwd)/minkapi-kubeconfig.yaml" \
  --nodes 10000 --pods 10000
```

It creates the nodes and pending pods, then polls and prints `bound : N / M` until
every pod is scheduled or you Ctrl-C. The scheduler binds them onto the nodes.

> Note: `--kubeconfig` here is the **host** kubeconfig (`minkapi/minkapi-kubeconfig.yaml`),
> because the loadtest runs on the host, not in a container.

## Verifying manually

```sh
export KUBECONFIG="$(pwd)/minkapi-kubeconfig.yaml"
kubectl --insecure-skip-tls-verify get pods -n default \
  -o custom-columns='POD:.metadata.name,NODE:.spec.nodeName'
```

Pods with a non-empty `NODE` column are bound.

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `read .../config.yaml: is a directory` | `-v` source path didn't exist; Docker made it a dir | Mount a real file (use `$PWD/<file>` from `minkapi/`) |
| Informers log `awaiting required bookmark event for initial events stream` and nothing binds | Scheduler 1.35 uses WatchList; minkapi has no initial-events bookmark | Add `--feature-gates=WatchListClient=false` |
| Connection refused from container | minkapi bound to a loopback the bridge can't reach | Start minkapi with `--bind-address "0.0.0.0:8091"` |
| Pods stay pending, `schedulerName` mismatch | Pod `spec.schedulerName` not served by the config | Use `default-scheduler` (empty defaults to it) or a profile in the config |

## Counts land slightly below the requested number

At scale (e.g. 10000), the final node/pod counts come out a few short (e.g. 9996 /
9995). This is a minkapi `generateName` limitation: its 5-char suffix (~14.3M space)
collides under the birthday problem and the store silently upserts on duplicate keys.
The loadtest counts *distinct* objects, so its "all bound" target accounts for this.
