#!/usr/bin/env bash
#
# run-kwok-loadtest-sweep.sh — run run-kwok-loadtest.sh across a sweep of (nodes, pods)
# pairs, one after another, tearing each kwok cluster down fully before the next.
#
# The kwok analogue of run-loadtest-sweep.sh. Differences from the minkapi sweep:
#   * kwok is self-contained (kwokctl runs etcd/apiserver/scheduler/etc. as local
#     processes) — there is no fixed :8091 to gate on. Instead, run-kwok.sh's `up`
#     REFUSES to start if a cluster of the same --name already exists, so the "next run
#     may start" condition is simply "the cluster of that name no longer exists".
#   * To keep runs from colliding even if a teardown is slow, each run gets its OWN
#     cluster name (kwok-sweep-<nodes>), created and deleted within that iteration.
#   * There is no docker and no downloaded scheduler binary; teardown is
#     `tmux kill-session` + `./run-kwok.sh down --name <name>`.
#
# run-kwok-loadtest.sh returns immediately (it leaves the cluster + a 2-pane tmux
# session running), so this wrapper:
#   1. launches one run with a unique --name,
#   2. captures the tmux session from run-kwok-loadtest.sh's output,
#   3. sleeps that run's --duration plus a settle buffer,
#   4. tears the run down (tmux kill-session + run-kwok.sh down + straggler pkill),
#   5. HARD-GATES on the cluster actually being gone before the next run.
#
# Duration per run scales linearly with node count, anchored on the minkapi measurements
# (50k -> 600s, 100k -> 1220s, 200k -> 2400s ~= 0.012 s/node), floored at 120s. kwok's
# bundled scheduler is not the same code path as the minkapi kube-scheduler, so treat
# these windows as a starting point and widen --buffer if large runs don't finish.
#
# Usage:
#   ./run-kwok-loadtest-sweep.sh [--workers N] [--sample SECS] [--buffer SECS]
#                                [--name-prefix PFX] [--dry-run]
#
#   --workers      loadtest worker count passed through to every run   (default 100)
#   --sample       profiler sample interval passed through             (default 5)
#   --buffer       extra seconds to wait after --duration before teardown, to let the
#                  loadtest finish binding and the profiler flush artifacts (default 120)
#   --name-prefix  cluster name prefix; each run is <prefix>-<nodes>     (default kwok-sweep)
#   --dry-run      print the plan (pairs + durations) and exit without running anything
#
# The (nodes, pods) pairs are fixed in PAIRS below; nodes == pods for every entry.

set -euo pipefail

WORKERS=100
SAMPLE=5
BUFFER=120
NAME_PREFIX="kwok-sweep"
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --workers)     WORKERS="$2";     shift 2 ;;
    --sample)      SAMPLE="$2";      shift 2 ;;
    --buffer)      BUFFER="$2";      shift 2 ;;
    --name-prefix) NAME_PREFIX="$2"; shift 2 ;;
    --dry-run)     DRY_RUN=1;        shift ;;
    -h|--help) grep '^#' "$0" | grep -v '^#!' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# Run from this script's directory so ./run-kwok-loadtest.sh and ./run-kwok.sh resolve.
cd "$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")"

[ -x ./run-kwok-loadtest.sh ] || { echo "ERROR: ./run-kwok-loadtest.sh missing or not executable" >&2; exit 1; }
[ -x ./run-kwok.sh ]          || { echo "ERROR: ./run-kwok.sh missing or not executable" >&2; exit 1; }
command -v tmux    >/dev/null || { echo "ERROR: tmux not installed" >&2; exit 1; }
command -v kwokctl >/dev/null || { echo "ERROR: kwokctl not installed" >&2; exit 1; }

# The sweep: nodes == pods for each pair.
PAIRS=(
  "1000 1000"
  "5000 5000"
  "10000 10000"
  "25000 25000"
  "50000 50000"
  "100000 100000"
  "150000 150000"
  "200000 200000"
  "250000 250000"
)

# Profiler window (seconds) for a given node count. Linear at ~0.012 s/node
# (anchored: 50k->600, 100k->1220, 200k->2400), floored at 120s so small runs still
# capture a meaningful window. Rounded to the nearest 10s.
DURATION() {
  local nodes="$1"
  awk -v n="$nodes" 'BEGIN{
    d = n * 0.012;
    if (d < 120) d = 120;          # floor for the tiny runs
    d = int((d + 5) / 10) * 10;    # round to nearest 10s
    print d;
  }'
}

# Print the plan up front so a dry-run (or the log header) shows every run's duration.
echo "kwok sweep plan (workers=$WORKERS sample=${SAMPLE}s buffer=${BUFFER}s name-prefix=$NAME_PREFIX):"
printf '  %-8s %-8s %-10s %-10s %-18s\n' "nodes" "pods" "duration" "wall(+buf)" "cluster"
TOTAL=0
for pair in "${PAIRS[@]}"; do
  read -r n p <<<"$pair"
  d="$(DURATION "$n")"
  wall=$(( d + BUFFER ))
  TOTAL=$(( TOTAL + wall ))
  printf '  %-8s %-8s %-10s %-10s %-18s\n' "$n" "$p" "${d}s" "${wall}s" "${NAME_PREFIX}-${n}"
done
printf '  %-8s %-8s %-10s %-10s\n' "" "" "" "-----"
printf '  estimated total wall time: %ss (~%s min), excluding per-run cluster create/delete\n\n' "$TOTAL" "$(( TOTAL / 60 ))"

if [ "$DRY_RUN" = 1 ]; then
  echo "dry run — nothing launched."
  exit 0
fi

# True if a kwok cluster with the given name currently exists.
cluster_exists() {
  kwokctl get clusters 2>/dev/null | grep -qx "$1"
}

run_one() {
  local nodes="$1" pods="$2" duration="$3" name="$4"
  echo "=================================================================="
  echo ">>> starting kwok run: nodes=$nodes pods=$pods duration=${duration}s cluster=$name  ($(date '+%Y-%m-%d %H:%M:%S'))"
  echo "=================================================================="

  # Defensive: if a cluster of this name lingers from a previous aborted sweep, delete it
  # first — run-kwok.sh's `up` would otherwise refuse to start.
  if cluster_exists "$name"; then
    echo ">>> pre-existing cluster '$name' found; deleting before this run ..."
    ./run-kwok.sh down --name "$name" >/dev/null 2>&1 || true
  fi

  # Launch the run, capturing stdout so we can extract the tmux session name.
  local out
  if ! out="$(./run-kwok-loadtest.sh --nodes "$nodes" --pods "$pods" --workers "$WORKERS" \
              --duration "$duration" --sample "$SAMPLE" --name "$name" 2>&1)"; then
    echo "$out"
    echo "ERROR: run-kwok-loadtest.sh failed for nodes=$nodes pods=$pods; tearing down and skipping." >&2
    ./run-kwok.sh down --name "$name" >/dev/null 2>&1 || true
    return 1
  fi
  echo "$out"

  # run-kwok-loadtest.sh prints:  "session   : kwok-test-<ts>"
  local session
  session="$(printf '%s\n' "$out" | sed -n 's/^session *: *//p' | head -1)"
  if [ -z "$session" ]; then
    echo "WARN: could not parse tmux session from run-kwok-loadtest.sh output; teardown relies on the cluster gate." >&2
  fi

  local wall=$(( duration + BUFFER ))
  echo ">>> run launched (session=$session cluster=$name). waiting ${wall}s (duration ${duration}s + buffer ${BUFFER}s) ..."
  sleep "$wall"

  echo ">>> tearing down kwok run: nodes=$nodes pods=$pods cluster=$name  ($(date '+%Y-%m-%d %H:%M:%S'))"
  # 1. kill the tmux session (stops the profiler + loadtest panes).
  [ -n "$session" ] && tmux kill-session -t "$session" 2>/dev/null || true
  # 2. reap the compiled loadtest child that `go run ./cmd/loadtest` spawns (a grandchild
  #    of the pane shell, so kill-session does not always reap it).
  pkill -f 'exe/loadtest' 2>/dev/null || true
  pkill -f 'cmd/loadtest' 2>/dev/null || true
  # 3. delete the kwok cluster (stops etcd/apiserver/scheduler/kwok-controller processes).
  ./run-kwok.sh down --name "$name" >/dev/null 2>&1 || true

  # 4. HARD GATE: the cluster must be gone before the next run, or the next `up` (which
  #    reuses names deterministically) could collide. run-kwok.sh's `up` refuses to start
  #    over an existing cluster, so a lingering one would break the next run.
  echo -n ">>> waiting for cluster '$name' to be deleted ..."
  for _ in $(seq 1 60); do
    if ! cluster_exists "$name"; then
      echo " gone"; return 0
    fi
    sleep 1
  done
  echo " STILL PRESENT"
  echo "FATAL: kwok cluster '$name' still exists 60s after teardown of the nodes=$nodes run." >&2
  echo "       Aborting the sweep. Inspect / clean up with:" >&2
  echo "         kwokctl get clusters ; ./run-kwok.sh down --name $name" >&2
  return 2
}

for pair in "${PAIRS[@]}"; do
  read -r n p <<<"$pair"
  d="$(DURATION "$n")"
  name="${NAME_PREFIX}-${n}"
  # Capture run_one's exit code without tripping `set -e`. rc==2 => hard cluster-gate
  # failure (abort the sweep); any other non-zero => single-run failure (already logged,
  # cluster already torn down) => skip to next pair.
  rc=0
  run_one "$n" "$p" "$d" "$name" || rc=$?
  if [ "$rc" = 2 ]; then
    echo "sweep aborted after nodes=$n run (cluster '$name' not deleted)." >&2
    exit 1
  fi
  echo
done

echo "kwok sweep complete. per-run profiler artifacts are under ./profiles/<os>-kwok-<timestamp>-n<nodes>-p<pods>-w${WORKERS}/"
