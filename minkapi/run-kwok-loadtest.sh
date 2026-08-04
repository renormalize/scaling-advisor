#!/usr/bin/env bash
#
# run-kwok-loadtest.sh — orchestrate a full kwok scheduling load test.
#
# Unlike run-loadtest.sh (minkapi + a separate kube-scheduler container), a kwok
# binary-runtime cluster is self-contained: kwokctl runs etcd, kube-apiserver,
# kube-controller-manager, kube-scheduler and kwok-controller as local processes. So
# this script:
#   1. brings the kwok cluster up (./run-kwok.sh up) and waits for it to be ready,
#   2. opens a tmux session with two panes:
#        pane 0: profiler  (./profile-kwok.sh — samples all 5 components' CPU%/RSS)
#        pane 1: loadtest  (go run ./cmd/loadtest --kwok — creates nodes+pods, waits)
#
# The cluster is left running afterwards (nothing is torn down automatically) so you
# can poke at it. Tear down manually when done:
#   tmux kill-session -t <session>
#   ./run-kwok.sh down --name <name>
#
# Usage:
#   ./run-kwok-loadtest.sh [--nodes N] [--pods N] [--workers N] [--duration SECS]
#                          [--sample SECS] [--name CLUSTER] [--keep-cluster]
#
# Defaults match the minkapi orchestrator where they overlap.

set -euo pipefail

# --- tunables ---
NODES=10000
PODS=10000
WORKERS=100
DURATION=600          # profiler window (seconds)
SAMPLE=5              # profiler sample interval (seconds)
NAME="kwok"
REUSE_CLUSTER=0       # if 1, use an already-running cluster instead of creating one

while [ $# -gt 0 ]; do
  case "$1" in
    --nodes)         NODES="$2";    shift 2 ;;
    --pods)          PODS="$2";     shift 2 ;;
    --workers)       WORKERS="$2";  shift 2 ;;
    --duration)      DURATION="$2"; shift 2 ;;
    --sample)        SAMPLE="$2";   shift 2 ;;
    --name)          NAME="$2";     shift 2 ;;
    --keep-cluster)  REUSE_CLUSTER=1; shift ;;
    -h|--help) grep '^#' "$0" | grep -v '^#!' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# Run from the directory this script lives in so ./run-kwok.sh, ./profile-kwok.sh and
# ./cmd/loadtest resolve.
cd "$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")"

# Preflight.
[ -x ./run-kwok.sh ]     || { echo "ERROR: ./run-kwok.sh missing or not executable" >&2; exit 1; }
[ -x ./profile-kwok.sh ] || { echo "ERROR: ./profile-kwok.sh missing or not executable" >&2; exit 1; }
command -v tmux    >/dev/null || { echo "ERROR: tmux not installed" >&2; exit 1; }
command -v kwokctl >/dev/null || { echo "ERROR: kwokctl not installed" >&2; exit 1; }

SESSION="kwok-test-$(date +%Y%m%d-%H%M%S)"
KUBECONFIG_PATH="$(pwd)/kwok-kubeconfig.yaml"

echo "session   : $SESSION"
echo "nodes=$NODES pods=$PODS workers=$WORKERS duration=${DURATION}s sample=${SAMPLE}s cluster=$NAME"
echo

# --- 1. bring the cluster up (foreground, so binary downloads finish before panes) ---
# This blocks until kwokctl reports the cluster ready and writes kwok-kubeconfig.yaml.
# If --keep-cluster and a cluster already exists, skip creation and reuse it.
if [ "$REUSE_CLUSTER" = 1 ] && kwokctl get clusters 2>/dev/null | grep -qx "$NAME"; then
  echo "reusing existing kwok cluster '$NAME'"
  # Make sure the kubeconfig file the loadtest needs is present.
  kwokctl get kubeconfig --name "$NAME" > "$KUBECONFIG_PATH"
else
  echo "creating kwok cluster '$NAME' (this can take a while on first run) ..."
  ./run-kwok.sh up --name "$NAME"
fi

# Sanity: the kubeconfig must exist and the apiserver must answer.
[ -f "$KUBECONFIG_PATH" ] || { echo "ERROR: expected kubeconfig at $KUBECONFIG_PATH" >&2; exit 1; }
echo -n "waiting for kwok apiserver to answer /healthz ..."
for _ in $(seq 1 60); do
  if KUBECONFIG="$KUBECONFIG_PATH" kubectl get --raw /healthz >/dev/null 2>&1; then ok=1; break; fi
  sleep 0.5
done
if [ "${ok:-}" != 1 ]; then
  echo " TIMEOUT"; echo "apiserver not healthy; inspect: kwokctl --name $NAME get components" >&2; exit 1
fi
echo " healthy"

# The two pane commands. `exec $SHELL` keeps each pane open after the command exits so
# its final output stays on screen.
PROFILE_CMD="./profile-kwok.sh --duration ${DURATION} --interval ${SAMPLE} --name ${NAME} --nodes ${NODES} --pods ${PODS} --workers ${WORKERS}; exec \$SHELL"
LOADTEST_CMD="go run ./cmd/loadtest --kubeconfig \"${KUBECONFIG_PATH}\" --kwok --nodes ${NODES} --pods ${PODS} --workers ${WORKERS}; exec \$SHELL"

# --- 2. tmux session: profiler first (so sampling starts before the load lands), then loadtest ---
P_PROF="$(tmux new-session -d -P -F '#{pane_id}' -s "$SESSION" -n kwok-loadtest -c "$(pwd)")"
tmux send-keys -t "$P_PROF" "$PROFILE_CMD" C-m

P_LOAD="$(tmux split-window -t "$P_PROF" -v -P -F '#{pane_id}' -c "$(pwd)")"
tmux send-keys -t "$P_LOAD" "$LOADTEST_CMD" C-m

tmux select-layout -t "$SESSION" even-vertical

cat <<EOF

kwok cluster is up and the load test is running.
  attach : tmux attach -t $SESSION
  panes  : $P_PROF=profiler  $P_LOAD=loadtest
  kubeconfig: $KUBECONFIG_PATH

profiler output lands in ./profiles/<os>-kwok-<timestamp>-n${NODES}-p${PODS}-w${WORKERS}/

teardown when done:
  tmux kill-session -t $SESSION
  ./run-kwok.sh down --name $NAME
EOF
