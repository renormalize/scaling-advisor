#!/usr/bin/env bash
#
# run-kwok.sh — bring up a local kwok cluster (binary runtime, no Docker) so you can
# point the loadtest tool at it and run the same scheduling exercise you run against
# minkapi: create N fake nodes, create N pending pods, let the bundled kube-scheduler
# bind them.
#
# Unlike the minkapi setup (minkapi + a SEPARATE kube-scheduler you profile), kwokctl
# bundles its own etcd, kube-apiserver, kube-controller-manager, kube-scheduler and
# kwok-controller and runs them all as local OS processes (--runtime binary). This
# script only stands the cluster up and hands you a kubeconfig; it does not run the
# load test itself (run the loadtest tool separately once this prints "cluster ready").
#
# IMPORTANT — the loadtest tool must add kwok-specific fields or nothing will schedule:
#   * each fake Node needs annotation  kwok.x-k8s.io/node: fake   (so kwok manages it)
#     and kwok puts a taint  kwok.x-k8s.io/node=fake:NoSchedule  on managed nodes.
#   * each Pod needs a matching toleration:
#         tolerations:
#         - key: "kwok.x-k8s.io/node"
#           operator: "Exists"
#           effect: "NoSchedule"
#   Without the toleration pods stay Pending forever. (This script does not modify the
#   loadtest tool — adapt cmd/loadtest yourself, e.g. behind a --kwok flag.)
#
# Usage:
#   ./run-kwok.sh [up|down|status|kubeconfig] [--name NAME] [--kube-version VER]
#                 [--scheduler-config PATH] [--no-scheduler-config]
#
#   up          create the cluster (default if no subcommand given)
#   down        delete the cluster
#   status      show component status
#   kubeconfig  print the path to the written kubeconfig
#
# After `up` it writes a standalone kubeconfig to ./kwok-kubeconfig.yaml and prints the
# exact loadtest command to run next.
#
# First `up` downloads the component binaries (etcd, kube-apiserver, ...) into ~/.kwok;
# subsequent runs are fast.

set -euo pipefail

# --- tunables ---
NAME="kwok"
KUBE_VERSION=""        # empty => kwokctl default (matches its bundled binaries)
SCHED_CONFIG="kwok-bin-packing-scheduler-config.yaml"
USE_SCHED_CONFIG=1
KUBECONFIG_OUT=""      # set after we know the module dir

# Run from the directory this script lives in so relative config paths resolve.
cd "$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")"
KUBECONFIG_OUT="$(pwd)/kwok-kubeconfig.yaml"

SUBCMD="up"
case "${1:-}" in
  up|down|status|kubeconfig) SUBCMD="$1"; shift ;;
esac

while [ $# -gt 0 ]; do
  case "$1" in
    --name)             NAME="$2"; shift 2 ;;
    --kube-version)     KUBE_VERSION="$2"; shift 2 ;;
    --scheduler-config) SCHED_CONFIG="$2"; shift 2 ;;
    --no-scheduler-config) USE_SCHED_CONFIG=0; shift ;;
    -h|--help) grep '^#' "$0" | grep -v '^#!' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

command -v kwokctl >/dev/null || { echo "ERROR: kwokctl not on PATH" >&2; exit 1; }

do_status() {
  echo "=== clusters ==="; kwokctl get clusters 2>/dev/null || true
  echo "=== components (name=$NAME) ==="; kwokctl --name "$NAME" get components 2>/dev/null || true
}

do_kubeconfig() {
  if [ -f "$KUBECONFIG_OUT" ]; then
    echo "$KUBECONFIG_OUT"
  else
    echo "no kubeconfig at $KUBECONFIG_OUT — run '$0 up' first" >&2; exit 1
  fi
}

do_down() {
  echo "deleting kwok cluster '$NAME' ..."
  kwokctl delete cluster --name "$NAME"
  rm -f "$KUBECONFIG_OUT"
  echo "deleted."
}

do_up() {
  # Refuse to silently talk to a stale cluster of the same name.
  if kwokctl get clusters 2>/dev/null | grep -qx "$NAME"; then
    echo "cluster '$NAME' already exists. Delete it first with: $0 down --name $NAME" >&2
    echo "(or pass a different --name)" >&2
    exit 1
  fi

  # Build the create args.
  #   --runtime binary          run all components as local processes (no Docker).
  #   --disable-qps-limits      lift the apiserver/controller/scheduler client QPS caps
  #                             so 100k+ creates are not throttled to a crawl.
  #   --wait                    block until the cluster reports ready.
  local -a args=(create cluster --name "$NAME" --runtime binary --disable-qps-limits --wait 300s)

  if [ -n "$KUBE_VERSION" ]; then
    args+=(--kube-version "$KUBE_VERSION")
  fi

  if [ "$USE_SCHED_CONFIG" = 1 ]; then
    [ -f "$SCHED_CONFIG" ] || { echo "ERROR: scheduler config '$SCHED_CONFIG' not found" >&2; exit 1; }
    args+=(--kube-scheduler-config "$(pwd)/$SCHED_CONFIG")
    echo "using scheduler config: $(pwd)/$SCHED_CONFIG"
  else
    echo "using kwok's default scheduler (no custom config)"
  fi

  echo "creating kwok cluster '$NAME' (binary runtime) ..."
  echo "  (first run downloads component binaries into ~/.kwok — this can take a while)"
  kwokctl "${args[@]}"

  # Export a standalone kubeconfig for the loadtest tool. 127.0.0.1 is the default host
  # kwokctl serves the apiserver on for the binary runtime.
  kwokctl get kubeconfig --name "$NAME" > "$KUBECONFIG_OUT"
  echo "wrote kubeconfig -> $KUBECONFIG_OUT"

  echo ""
  echo "cluster ready. components:"
  kwokctl --name "$NAME" get components 2>/dev/null || true

  cat <<EOF

=============================================
kwok cluster '$NAME' is up (binary runtime).
kubeconfig: $KUBECONFIG_OUT

Sanity check:
  kwokctl --name $NAME kubectl get nodes
  KUBECONFIG=$KUBECONFIG_OUT kubectl get --raw /healthz

Run the scheduling load test (loadtest tool must add the kwok node annotation/taint
and pod toleration — see the header of this script):
  go run ./cmd/loadtest --kubeconfig "$KUBECONFIG_OUT" --nodes 10000 --pods 10000 --workers 100

Tear down when done:
  $0 down --name $NAME
=============================================
EOF
}

case "$SUBCMD" in
  up)         do_up ;;
  down)       do_down ;;
  status)     do_status ;;
  kubeconfig) do_kubeconfig ;;
esac
