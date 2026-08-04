#!/usr/bin/env bash
#
# run-loadtest.sh — orchestrate a full minkapi scheduling load test in one tmux session.
#
# Launches four panes, strictly in order, each gated on the previous being ready:
#   pane 0: minkapi           (waits until it serves /base/api/v1)
#   pane 1: kube-scheduler    (waits until it is running — see per-OS note below)
#   pane 2: profiler          (./profile.sh)
#   pane 3: loadtest          (launched immediately after the profiler)
#
# How the kube-scheduler runs depends on the host OS:
#   linux : a kube-scheduler BINARY downloaded from https://dl.k8s.io/<ver>/bin/linux/<arch>/
#           and run as a local process (reaches minkapi on localhost directly). Cached
#           under ./bin/kube-scheduler-<ver>-<arch> and reused across runs.
#   darwin: a kube-scheduler DOCKER CONTAINER (no darwin binary is published upstream);
#           reaches minkapi via host.docker.internal.
# The version is taken from the --image tag (registry.k8s.io/kube-scheduler:vX -> vX),
# so a single flag drives both paths.
#
# Prints the tmux session name and returns. Nothing is torn down — minkapi keeps
# serving, the scheduler keeps running, and the profiler finishes on its own timer.
# Tear down manually when done:
#   tmux kill-session -t <session>
#   (darwin) docker stop <scheduler-container>   (linux) kill <scheduler-pid>
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
IMAGE="registry.k8s.io/kube-scheduler:v1.36.1"

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

# How does the kube-scheduler run on this host? linux -> downloaded binary process,
# darwin -> docker container (no darwin binary is published upstream).
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"   # linux | darwin
case "$OS" in
  linux)  SCHED_MODE="binary" ;;
  darwin) SCHED_MODE="docker" ;;
  *) echo "ERROR: unsupported OS '$OS' (expected linux or darwin)" >&2; exit 1 ;;
esac

# Preflight: fail early with a clear message rather than deep inside a pane.
[ -x ./bin/minkapi ] || { echo "ERROR: ./bin/minkapi not built (run: go build -o bin/minkapi .)" >&2; exit 1; }
[ -x ./profile.sh ]  || { echo "ERROR: ./profile.sh missing or not executable" >&2; exit 1; }
command -v tmux >/dev/null || { echo "ERROR: tmux not installed" >&2; exit 1; }
if [ "$SCHED_MODE" = docker ]; then
  command -v docker >/dev/null || { echo "ERROR: docker not installed" >&2; exit 1; }
else
  command -v curl >/dev/null || { echo "ERROR: curl not installed (needed to download kube-scheduler)" >&2; exit 1; }
fi

SESSION="minkapi-test-$(date +%Y%m%d-%H%M%S)"
KUBECONFIG_PATH="$(pwd)/minkapi-kubeconfig.yaml"
BASE_URL="http://localhost:${PORT}/base/debug/pprof"
READY_URL="http://localhost:${PORT}/base/api/v1"
SCHED_NAME="minkapi-sched-$(date +%s)"

# kube-scheduler version comes from the --image tag (…/kube-scheduler:vX.Y.Z -> vX.Y.Z),
# so darwin (docker) and linux (binary) always run the same version.
SCHED_VERSION="${IMAGE##*:}"
case "$SCHED_VERSION" in
  v*) : ;;
  *) echo "ERROR: could not derive a version tag from --image '$IMAGE' (expected …:vX.Y.Z)" >&2; exit 1 ;;
esac

# Map host arch to the k8s release path (amd64/arm64), used only for the linux binary.
case "$(uname -m)" in
  x86_64|amd64) SCHED_ARCH="amd64" ;;
  aarch64|arm64) SCHED_ARCH="arm64" ;;
  *) SCHED_ARCH="" ;;  # only fatal on linux; validated in the binary branch below
esac
SCHED_BIN="$(pwd)/bin/kube-scheduler-${SCHED_VERSION}-${SCHED_ARCH}"

echo "session   : $SESSION"
echo "scheduler : $SCHED_MODE ($SCHED_VERSION)"
echo "nodes=$NODES pods=$PODS workers=$WORKERS duration=${DURATION}s sample=${SAMPLE}s port=$PORT (fixed)"
echo

# The four commands, run verbatim in their panes. `exec` so the pane's shell IS the
# process (clean signals); `; exec $SHELL` keeps the pane open after exit so you can
# read the final output.
MINKAPI_CMD="./bin/minkapi --bind-address \"0.0.0.0:${PORT}\" -k \"${KUBECONFIG_PATH}\" --profile -v 3; exec \$SHELL"

# SCHED_CMD is built later (after minkapi writes its configs), because it differs by
# mode and the docker path needs the derived -docker.yaml files.

# Base profiler command. In docker mode we pass --sched-container now (the container
# name is already known). In binary mode we cannot pass --sched-pid yet — the scheduler
# process does not exist until it is launched below — so this is a placeholder that the
# binary branch overwrites with --sched-pid once the PID is known.
if [ "$SCHED_MODE" = docker ]; then
  PROFILE_CMD="./profile.sh --duration ${DURATION} --interval ${SAMPLE} --base-url \"${BASE_URL}\" --sched-container ${SCHED_NAME} --nodes ${NODES} --pods ${PODS} --workers ${WORKERS}; exec \$SHELL"
else
  PROFILE_CMD="./profile.sh --duration ${DURATION} --interval ${SAMPLE} --base-url \"${BASE_URL}\" --nodes ${NODES} --pods ${PODS} --workers ${WORKERS}; exec \$SHELL"
fi

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

# --- prepare the scheduler's configs from what minkapi just wrote ---
# On Start, minkapi generates two files next to the -k path:
#   minkapi-kubeconfig.yaml                         (server: http://<bind>/base)
#   minkapi-base-bin-packing-scheduler-config.yaml  (kubeconfig: <abs local path>)
SCHED_CFG_SRC="$(pwd)/minkapi-base-bin-packing-scheduler-config.yaml"
for f in "$KUBECONFIG_PATH" "$SCHED_CFG_SRC"; do
  [ -f "$f" ] || { echo "ERROR: expected minkapi to generate $f but it is missing" >&2; \
    echo "inspect: tmux attach -t $SESSION" >&2; exit 1; }
done

if [ "$SCHED_MODE" = docker ]; then
  # The kube-scheduler container can't use minkapi's files as-is: it reaches minkapi via
  # host.docker.internal (not the bind host), and its kubeconfig path must be the
  # in-container mount path. Produce docker copies by rewriting exactly those two lines.
  KUBECONFIG_DOCKER="$(pwd)/minkapi-kubeconfig-docker.yaml"
  SCHED_CFG_DOCKER="$(pwd)/minkapi-base-bin-packing-scheduler-config-docker.yaml"
  CONTAINER_KUBECONFIG="/etc/minkapi/minkapi-kubeconfig-docker.yaml"

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

  SCHED_CMD="docker run --rm --name ${SCHED_NAME} \
    --add-host host.docker.internal:host-gateway \
    -v \"\$PWD/minkapi-base-bin-packing-scheduler-config-docker.yaml:/etc/minkapi/scheduler-config.yaml:ro\" \
    -v \"\$PWD/minkapi-kubeconfig-docker.yaml:/etc/minkapi/minkapi-kubeconfig-docker.yaml:ro\" \
    ${IMAGE} \
    kube-scheduler --config=/etc/minkapi/scheduler-config.yaml \
      --feature-gates=WatchListClient=false -v=2; exec \$SHELL"
else
  # linux binary: the scheduler runs on the same host as minkapi, so it uses minkapi's
  # generated configs verbatim — the kubeconfig's bind host is reachable locally and the
  # scheduler-config already points 'kubeconfig:' at the local absolute path. No rewrite.
  [ -n "$SCHED_ARCH" ] || { echo "ERROR: unsupported arch '$(uname -m)' for the linux kube-scheduler binary" >&2; exit 1; }
  if [ ! -x "$SCHED_BIN" ]; then
    SCHED_URL="https://dl.k8s.io/${SCHED_VERSION}/bin/linux/${SCHED_ARCH}/kube-scheduler"
    echo -n "downloading kube-scheduler ${SCHED_VERSION} (${SCHED_ARCH}) -> $SCHED_BIN ..."
    mkdir -p "$(dirname "$SCHED_BIN")"
    if ! curl -fsSL "$SCHED_URL" -o "$SCHED_BIN.tmp"; then
      echo " FAILED"; echo "ERROR: could not download $SCHED_URL" >&2; rm -f "$SCHED_BIN.tmp"; exit 1
    fi
    chmod +x "$SCHED_BIN.tmp" && mv "$SCHED_BIN.tmp" "$SCHED_BIN"
    echo " done"
  else
    echo "using cached kube-scheduler binary $SCHED_BIN"
  fi

  SCHED_CMD="exec \"${SCHED_BIN}\" --config=\"${SCHED_CFG_SRC}\" \
    --feature-gates=WatchListClient=false -v=2; exec \$SHELL"
fi

# --- pane 1: kube-scheduler ---
P_SCHED="$(tmux split-window -t "$P_MINKAPI" -v -P -F '#{pane_id}' -c "$(pwd)")"
tmux send-keys -t "$P_SCHED" "$SCHED_CMD" C-m

if [ "$SCHED_MODE" = docker ]; then
  echo -n "waiting for scheduler container ${SCHED_NAME} to be running ..."
  for _ in $(seq 1 60); do
    state="$(docker inspect -f '{{.State.Running}}' "$SCHED_NAME" 2>/dev/null || true)"
    if [ "$state" = "true" ]; then sok=1; break; fi
    sleep 0.5
  done
else
  # The binary runs as a process; treat "listening on the healthz port :10259" as running.
  echo -n "waiting for kube-scheduler binary to answer :10259/healthz ..."
  for _ in $(seq 1 60); do
    if curl -fsSk "https://localhost:10259/healthz" -o /dev/null 2>/dev/null \
       || curl -fsS "http://localhost:10259/healthz" -o /dev/null 2>/dev/null; then
      sok=1; break
    fi
    sleep 0.5
  done
fi
if [ "${sok:-}" != 1 ]; then
  echo " TIMEOUT"; echo "scheduler not running; inspect: tmux attach -t $SESSION" >&2; exit 1
fi
echo " running"

# In binary mode, find the scheduler PID so the profiler can sample its CPU%/RSS. The
# pane exec's the cached binary, so its command line is exactly "$SCHED_BIN --config=…".
if [ "$SCHED_MODE" = binary ]; then
  SCHED_PROC_PID="$(pgrep -f "$SCHED_BIN" | head -1 || true)"
  if [ -n "$SCHED_PROC_PID" ]; then
    echo "kube-scheduler pid $SCHED_PROC_PID (profiler will sample its CPU%/RSS)"
    PROFILE_CMD="./profile.sh --duration ${DURATION} --interval ${SAMPLE} --base-url \"${BASE_URL}\" --sched-pid ${SCHED_PROC_PID} --nodes ${NODES} --pods ${PODS} --workers ${WORKERS}; exec \$SHELL"
  else
    echo "WARN: could not find kube-scheduler pid; scheduler CPU/RSS will not be sampled" >&2
  fi
fi

# --- pane 2: profiler ---
P_PROF="$(tmux split-window -t "$P_SCHED" -v -P -F '#{pane_id}' -c "$(pwd)")"
tmux send-keys -t "$P_PROF" "$PROFILE_CMD" C-m

# --- pane 3: loadtest (immediately after the profiler) ---
P_LOAD="$(tmux split-window -t "$P_PROF" -v -P -F '#{pane_id}' -c "$(pwd)")"
tmux send-keys -t "$P_LOAD" "$LOADTEST_CMD" C-m

tmux select-layout -t "$SESSION" even-vertical

if [ "$SCHED_MODE" = docker ]; then
  SCHED_TEARDOWN="docker stop $SCHED_NAME 2>/dev/null || true"
else
  # Killing the tmux session kills the pane's exec'd scheduler binary; no extra step.
  SCHED_TEARDOWN="# scheduler binary runs in the tmux session; kill-session stops it"
fi

cat <<EOF

all four panes launched in order.
  attach : tmux attach -t $SESSION
  panes  : $P_MINKAPI=minkapi  $P_SCHED=kube-scheduler  $P_PROF=profiler  $P_LOAD=loadtest

teardown when done:
  tmux kill-session -t $SESSION
  $SCHED_TEARDOWN
EOF
