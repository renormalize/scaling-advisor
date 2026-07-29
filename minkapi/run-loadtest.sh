#!/usr/bin/env bash
#
# run-loadtest.sh — orchestrate a full minkapi scheduling load test in one tmux session.
#
# Launches four panes, strictly in order, each gated on the previous being ready:
#   pane 0: minkapi           (waits until it serves /base/api/v1)
#   pane 1: kube-scheduler    (docker; waits until the container is running)
#   pane 2: profiler          (./profile.sh)
#   pane 3: loadtest          (launched immediately after the profiler)
#
# Prints the tmux session name and returns. Nothing is torn down — minkapi keeps
# serving, the scheduler container keeps running, and the profiler finishes on its
# own timer. Tear down manually when done:
#   tmux kill-session -t <session>   &&   docker stop <scheduler-container>
#
# Usage:
#   ./run-loadtest.sh [--nodes N] [--pods N] [--workers N] [--duration SECS] [--sample SECS]
#                     [--image IMG]
#
# minkapi always binds :8091 — the committed docker kubeconfig the scheduler mounts
# (minkapi-kubeconfig-docker.yaml) points at host.docker.internal:8091, so the port
# is not configurable.
#
# Defaults match the manual commands we run today.

set -euo pipefail

# --- tunables ---
NODES=50000
PODS=100000
WORKERS=100
DURATION=600          # profiler window (seconds)
SAMPLE=5              # profiler sample interval (seconds)
PORT=8091             # fixed: the committed docker kubeconfig hardcodes this
IMAGE="registry.k8s.io/kube-scheduler:v1.35.7"

while [ $# -gt 0 ]; do
  case "$1" in
    --nodes)    NODES="$2";    shift 2 ;;
    --pods)     PODS="$2";     shift 2 ;;
    --workers)  WORKERS="$2";  shift 2 ;;
    --duration) DURATION="$2"; shift 2 ;;
    --sample)   SAMPLE="$2";   shift 2 ;;
    --image)    IMAGE="$2";    shift 2 ;;
    -h|--help)
      grep '^#' "$0" | grep -v '^#!' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# Run from the minkapi module directory (where this script lives) so all the
# relative paths (bin/minkapi, ./cmd/loadtest, the -docker.yaml configs) resolve.
cd "$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")"

# Preflight: fail early with a clear message rather than deep inside a pane.
[ -x ./bin/minkapi ] || { echo "ERROR: ./bin/minkapi not built (run: go build -o bin/minkapi .)" >&2; exit 1; }
[ -x ./profile.sh ]  || { echo "ERROR: ./profile.sh missing or not executable" >&2; exit 1; }
command -v tmux   >/dev/null || { echo "ERROR: tmux not installed" >&2; exit 1; }
command -v docker >/dev/null || { echo "ERROR: docker not installed" >&2; exit 1; }
SESSION="minkapi-test-$(date +%Y%m%d-%H%M%S)"
KUBECONFIG_PATH="$(pwd)/minkapi-kubeconfig.yaml"
BASE_URL="http://localhost:${PORT}/base/debug/pprof"
READY_URL="http://localhost:${PORT}/base/api/v1"
SCHED_NAME="minkapi-sched-$(date +%s)"

echo "session   : $SESSION"
echo "nodes=$NODES pods=$PODS workers=$WORKERS duration=${DURATION}s sample=${SAMPLE}s port=$PORT (fixed)"
echo

# The four commands, run verbatim in their panes. `exec` so the pane's shell IS the
# process (clean signals); `; exec $SHELL` keeps the pane open after exit so you can
# read the final output.
MINKAPI_CMD="./bin/minkapi --bind-address \"0.0.0.0:${PORT}\" -k \"${KUBECONFIG_PATH}\" --profile -v 3; exec \$SHELL"

SCHED_CMD="docker run --rm --name ${SCHED_NAME} \
  --add-host host.docker.internal:host-gateway \
  -v \"\$PWD/minkapi-base-bin-packing-scheduler-config-docker.yaml:/etc/minkapi/scheduler-config.yaml:ro\" \
  -v \"\$PWD/minkapi-kubeconfig-docker.yaml:/etc/minkapi/minkapi-kubeconfig-docker.yaml:ro\" \
  ${IMAGE} \
  kube-scheduler --config=/etc/minkapi/scheduler-config.yaml \
    --feature-gates=WatchListClient=false -v=2; exec \$SHELL"

PROFILE_CMD="./profile.sh --duration ${DURATION} --interval ${SAMPLE} --base-url \"${BASE_URL}\" --sched-container ${SCHED_NAME} --nodes ${NODES} --pods ${PODS} --workers ${WORKERS}; exec \$SHELL"

LOADTEST_CMD="go run ./cmd/loadtest \
  --kubeconfig \"${KUBECONFIG_PATH}\" \
  --nodes ${NODES} --pods ${PODS} --workers ${WORKERS}; exec \$SHELL"

# --- pane 0: minkapi ---
# Track panes by their stable pane-id (%N) rather than index, since a user's
# tmux base-index / pane-base-index config may not start at 0.
P_MINKAPI="$(tmux new-session -d -P -F '#{pane_id}' -s "$SESSION" -n loadtest -c "$(pwd)")"
tmux send-keys -t "$P_MINKAPI" "$MINKAPI_CMD" C-m

echo -n "waiting for minkapi to serve ${READY_URL} ..."
for _ in $(seq 1 60); do
  if curl -fsS "$READY_URL" -o /dev/null 2>/dev/null; then ok=1; break; fi
  sleep 0.5
done
if [ "${ok:-}" != 1 ]; then
  echo " TIMEOUT"; echo "minkapi did not come up; inspect: tmux attach -t $SESSION" >&2; exit 1
fi
echo " up"

# --- derive the scheduler container's configs from what minkapi just wrote ---
# On Start, minkapi generates two files next to the -k path:
#   minkapi-kubeconfig.yaml                         (server: http://<bind>/base)
#   minkapi-base-bin-packing-scheduler-config.yaml  (kubeconfig: <abs local path>)
# The kube-scheduler container can't use either as-is: it reaches minkapi via
# host.docker.internal (not the bind host), and its kubeconfig path must be the
# in-container mount path. Produce docker copies by rewriting exactly those two lines.
SCHED_CFG_SRC="$(pwd)/minkapi-base-bin-packing-scheduler-config.yaml"
KUBECONFIG_DOCKER="$(pwd)/minkapi-kubeconfig-docker.yaml"
SCHED_CFG_DOCKER="$(pwd)/minkapi-base-bin-packing-scheduler-config-docker.yaml"
CONTAINER_KUBECONFIG="/etc/minkapi/minkapi-kubeconfig-docker.yaml"

for f in "$KUBECONFIG_PATH" "$SCHED_CFG_SRC"; do
  [ -f "$f" ] || { echo "ERROR: expected minkapi to generate $f but it is missing" >&2; \
    echo "inspect: tmux attach -t $SESSION" >&2; exit 1; }
done

# kubeconfig: point the scheduler at the docker-gateway host instead of the bind host.
sed -e "s#server: http://0.0.0.0:${PORT}/#server: http://host.docker.internal:${PORT}/#" \
    -e "s#server: http://127.0.0.1:${PORT}/#server: http://host.docker.internal:${PORT}/#" \
    -e "s#server: http://localhost:${PORT}/#server: http://host.docker.internal:${PORT}/#" \
    "$KUBECONFIG_PATH" > "$KUBECONFIG_DOCKER"
echo "derived $KUBECONFIG_DOCKER (host -> host.docker.internal)"

# scheduler config: repoint kubeconfig at the in-container mount path.
sed -e "s#^\( *kubeconfig:\).*#\1 ${CONTAINER_KUBECONFIG}#" \
    "$SCHED_CFG_SRC" > "$SCHED_CFG_DOCKER"
echo "derived $SCHED_CFG_DOCKER (kubeconfig -> ${CONTAINER_KUBECONFIG})"

# --- pane 1: kube-scheduler ---
P_SCHED="$(tmux split-window -t "$P_MINKAPI" -v -P -F '#{pane_id}' -c "$(pwd)")"
tmux send-keys -t "$P_SCHED" "$SCHED_CMD" C-m

echo -n "waiting for scheduler container ${SCHED_NAME} to be running ..."
for _ in $(seq 1 60); do
  state="$(docker inspect -f '{{.State.Running}}' "$SCHED_NAME" 2>/dev/null || true)"
  if [ "$state" = "true" ]; then sok=1; break; fi
  sleep 0.5
done
if [ "${sok:-}" != 1 ]; then
  echo " TIMEOUT"; echo "scheduler container not running; inspect: tmux attach -t $SESSION" >&2; exit 1
fi
echo " running"

# --- pane 2: profiler ---
P_PROF="$(tmux split-window -t "$P_SCHED" -v -P -F '#{pane_id}' -c "$(pwd)")"
tmux send-keys -t "$P_PROF" "$PROFILE_CMD" C-m

# --- pane 3: loadtest (immediately after the profiler) ---
P_LOAD="$(tmux split-window -t "$P_PROF" -v -P -F '#{pane_id}' -c "$(pwd)")"
tmux send-keys -t "$P_LOAD" "$LOADTEST_CMD" C-m

tmux select-layout -t "$SESSION" even-vertical

cat <<EOF

all four panes launched in order.
  attach : tmux attach -t $SESSION
  panes  : $P_MINKAPI=minkapi  $P_SCHED=kube-scheduler  $P_PROF=profiler  $P_LOAD=loadtest

teardown when done:
  tmux kill-session -t $SESSION
  docker stop $SCHED_NAME 2>/dev/null || true
EOF
