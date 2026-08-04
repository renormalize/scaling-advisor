#!/usr/bin/env bash
#
# run-loadtest-sweep.sh — run run-loadtest.sh across a sweep of (nodes, pods) pairs,
# one after another, tearing each run down fully before starting the next.
#
# Why serial (never concurrent): run-loadtest.sh always binds minkapi on the fixed
# :8091 (the committed docker kubeconfig hardcodes it), so two runs cannot coexist.
# run-loadtest.sh also returns immediately — it leaves the tmux session and the
# kube-scheduler container running. This wrapper therefore:
#   1. launches one run,
#   2. captures its tmux session + scheduler container name from run-loadtest.sh's output,
#   3. sleeps that run's --duration plus a settle buffer,
#   4. tears the run down (tmux kill-session + docker stop),
#   5. moves to the next pair.
#
# Duration per run scales linearly with node count, anchored on measured points:
#   50k -> 600s, 100k -> 1220s, 200k -> 2400s  (~0.012 s/node).
# Small runs are floored so the profiler window isn't trivially short. See DURATION() below.
#
# Usage:
#   ./run-loadtest-sweep.sh [--workers N] [--sample SECS] [--buffer SECS]
#                           [--image IMG] [--dry-run]
#
#   --workers   loadtest worker count passed through to every run   (default 100)
#   --sample    profiler sample interval passed through             (default 5)
#   --buffer    extra seconds to wait after --duration before teardown, to let the
#               loadtest ramp up and the profiler flush its artifacts (default 120)
#   --image     kube-scheduler image passed through                 (default: run-loadtest.sh's)
#   --dry-run   print the plan (pairs + durations) and exit without running anything
#
# The (nodes, pods) pairs are fixed in PAIRS below; nodes == pods for every entry.

set -euo pipefail

WORKERS=100
SAMPLE=5
BUFFER=120
IMAGE=""          # empty => let run-loadtest.sh use its own default
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --workers) WORKERS="$2"; shift 2 ;;
    --sample)  SAMPLE="$2";  shift 2 ;;
    --buffer)  BUFFER="$2";  shift 2 ;;
    --image)   IMAGE="$2";   shift 2 ;;
    --dry-run) DRY_RUN=1;    shift ;;
    -h|--help) grep '^#' "$0" | grep -v '^#!' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# Run from this script's directory so ./run-loadtest.sh resolves.
cd "$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")"

[ -x ./run-loadtest.sh ] || { echo "ERROR: ./run-loadtest.sh missing or not executable" >&2; exit 1; }
command -v tmux   >/dev/null || { echo "ERROR: tmux not installed" >&2; exit 1; }
command -v docker >/dev/null || { echo "ERROR: docker not installed" >&2; exit 1; }

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
echo "sweep plan (workers=$WORKERS sample=${SAMPLE}s buffer=${BUFFER}s):"
printf '  %-8s %-8s %-10s %-10s\n' "nodes" "pods" "duration" "wall(+buf)"
TOTAL=0
for pair in "${PAIRS[@]}"; do
  read -r n p <<<"$pair"
  d="$(DURATION "$n")"
  wall=$(( d + BUFFER ))
  TOTAL=$(( TOTAL + wall ))
  printf '  %-8s %-8s %-10s %-10s\n' "$n" "$p" "${d}s" "${wall}s"
done
printf '  %-8s %-8s %-10s %-10s\n' "" "" "" "-----"
printf '  estimated total wall time: %ss (~%s min)\n\n' "$TOTAL" "$(( TOTAL / 60 ))"

if [ "$DRY_RUN" = 1 ]; then
  echo "dry run — nothing launched."
  exit 0
fi

run_one() {
  local nodes="$1" pods="$2" duration="$3"
  echo "=================================================================="
  echo ">>> starting run: nodes=$nodes pods=$pods duration=${duration}s  ($(date '+%Y-%m-%d %H:%M:%S'))"
  echo "=================================================================="

  # Launch the run, capturing its stdout so we can extract the tmux session and the
  # scheduler container name (run-loadtest.sh prints both, then returns immediately).
  local out
  local args=(--nodes "$nodes" --pods "$pods" --workers "$WORKERS"
              --duration "$duration" --sample "$SAMPLE")
  [ -n "$IMAGE" ] && args+=(--image "$IMAGE")

  if ! out="$(./run-loadtest.sh "${args[@]}" 2>&1)"; then
    echo "$out"
    echo "ERROR: run-loadtest.sh failed for nodes=$nodes pods=$pods; skipping to next." >&2
    return 1
  fi
  echo "$out"

  # run-loadtest.sh prints:  "session   : minkapi-test-<ts>"
  # On darwin it also prints:  "docker stop minkapi-sched-<epoch>"  (teardown block).
  # On linux the scheduler is a binary inside the tmux session (no container to stop).
  local session sched
  session="$(printf '%s\n' "$out" | sed -n 's/^session *: *//p' | head -1)"
  sched="$(printf '%s\n' "$out" | grep -oE 'minkapi-sched-[0-9]+' | head -1)"

  if [ -z "$session" ]; then
    echo "WARN: could not parse tmux session from run-loadtest.sh output; teardown relies on pkill + port gate." >&2
  fi

  local wall=$(( duration + BUFFER ))
  echo ">>> run launched (session=$session sched=${sched:-<binary>}). waiting ${wall}s (duration ${duration}s + buffer ${BUFFER}s) ..."
  sleep "$wall"

  echo ">>> tearing down run: nodes=$nodes pods=$pods  ($(date '+%Y-%m-%d %H:%M:%S'))"
  # 1. stop the scheduler container if this run used one (darwin/docker mode).
  [ -n "$sched" ] && docker stop "$sched" >/dev/null 2>&1 || true
  # 2. kill the tmux session — this stops minkapi, the profiler, the loadtest pane, and
  #    (on linux) the exec'd scheduler binary in the pane.
  [ -n "$session" ] && tmux kill-session -t "$session" 2>/dev/null || true
  # 3. explicitly reap stragglers the pane kill may leave behind:
  #    - minkapi (started with --profile)
  #    - the compiled loadtest child that `go run ./cmd/loadtest` spawns (a grandchild of
  #      the pane shell, so kill-session does not always reap it)
  #    - a leftover kube-scheduler binary process (linux), matched by our cached path
  pkill -f 'bin/minkapi .*--profile'      2>/dev/null || true
  pkill -f 'exe/loadtest'                 2>/dev/null || true
  pkill -f 'cmd/loadtest'                 2>/dev/null || true
  pkill -f 'bin/kube-scheduler-'          2>/dev/null || true

  # 4. HARD GATE: :8091 must be free before the next run, or minkapi cannot bind. If it
  #    is still answering after teardown, abort the whole sweep rather than launch a run
  #    that will collide with the previous one's leftovers.
  echo -n ">>> waiting for :8091 to free ..."
  for _ in $(seq 1 60); do
    if ! curl -fsS "http://localhost:8091/base/api/v1" -o /dev/null 2>/dev/null; then
      echo " free"; return 0
    fi
    sleep 1
  done
  echo " STILL BOUND"
  echo "FATAL: :8091 still answering 60s after teardown of the nodes=$nodes run." >&2
  echo "       A leftover minkapi is holding the port; aborting the sweep to avoid a collided run." >&2
  echo "       Inspect with: lsof -i :8091 ; pgrep -fa 'bin/minkapi'" >&2
  return 2
}

for pair in "${PAIRS[@]}"; do
  read -r n p <<<"$pair"
  d="$(DURATION "$n")"
  # Capture run_one's exit code without tripping `set -e` (|| true) and without the
  # `if !` negation masking it. rc==2 => hard port-gate failure (abort the sweep);
  # any other non-zero => single-run launch failure (already logged) => skip to next.
  rc=0
  run_one "$n" "$p" "$d" || rc=$?
  if [ "$rc" = 2 ]; then
    echo "sweep aborted after nodes=$n run (port :8091 not freed)." >&2
    exit 1
  fi
  echo
done

echo "sweep complete. per-run profiler artifacts are under ./profiles/<os>-<timestamp>-n<nodes>-p<pods>-w${WORKERS}/"
