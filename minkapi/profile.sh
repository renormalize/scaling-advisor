#!/usr/bin/env bash
#
# Continuous profiling of a running minkapi (started with --profile) for the
# duration of a load test. Captures:
#   - one CPU profile spanning the whole window   (cpu.pprof)
#   - one execution trace spanning the whole window (trace.out)
#   - heap / allocs / goroutine snapshots every INTERVAL seconds (timestamped)
#
# Also logs OS-level CPU% and resident memory (RSS) of the minkapi process every
# INTERVAL seconds to minkapi-usage.log — the ground-truth consumption numbers that pprof
# cannot report (pprof's CPU profile is proportional, not absolute).
#
# And logs the Go runtime's own memory breakdown (heap / stack / Sys, in MiB) every
# INTERVAL seconds to mem-usage.log, sourced from the heap?debug=1 MemStats footer.
#
# The kube-scheduler's CPU%/RSS is logged to kube-scheduler-usage.log — the SAME filename
# and 3-column format profile-kwok.sh uses, so a minkapi run and a kwok run produce
# directly comparable per-process logs. How the scheduler is sampled depends on how it runs:
#   --sched-container NAME : sample a docker container via `docker stats` (darwin path).
#   --sched-pid PID        : sample a local process via `ps` (linux binary path). In this
#                            mode minkapi and the scheduler are sampled in one loop that
#                            also writes all-usage.log (minkapi + scheduler summed),
#                            mirroring profile-kwok.sh's all-usage.log. There is no
#                            all-usage.log in --sched-container mode (docker stats is a
#                            separate sampler, not summed per-tick).
# Use whichever flag matches how the scheduler runs; if both are given, docker wins.
#
# Usage (all arguments are named flags; order does not matter):
#   ./profile.sh [--duration SECS] [--interval SECS] [--base-url URL] \
#                [--outdir DIR] [--pid PID] [--sched-container NAME] [--sched-pid PID] \
#                [--nodes N] [--pods N] [--workers N]
#
# Defaults:
#   --duration  120
#   --interval  5
#   --base-url  http://localhost:8091/base/debug/pprof
#   --outdir    ./profiles/<name>   (see naming below)
#   --pid       auto-discovered via `pgrep -f 'minkapi.*--profile'`
#   --sched-container   unset (skip docker stats sampling of the scheduler)
#   --nodes / --pods / --workers   unset (only used to label the default --outdir)
#
# Output directory naming (when --outdir is not given explicitly):
#   ./profiles/<os>-minkapi-<timestamp>[-n<NODES>-p<PODS>-w<WORKERS>]
#   e.g. ./profiles/darwin-minkapi-20260730-142530-n50000-p100000-w100
#   <os> is the lowercased `uname -s` (darwin | linux). Field order is fixed: os,
#   minkapi, timestamp, then n<nodes>, p<pods>, w<workers>. Any of the three
#   --nodes/--pods/--workers that are supplied are appended in THAT order; ones omitted
#   are simply left out. This mirrors profile-kwok.sh's <os>-kwok-<timestamp> naming so
#   minkapi and kwok runs sort side by side. An explicit --outdir overrides this entirely.
#
# Note: minkapi must be started with --profile. block/mutex profiles are
# omitted because minkapi does not call SetBlockProfileRate / SetMutexProfileFraction,
# so they would be empty.

set -euo pipefail

# --- named args (order-independent) ---
DURATION=120
INTERVAL=5
BASE_URL="http://localhost:8091/base/debug/pprof"
OUTDIR=""     # empty => build the param-labelled default below
PID=""
SCHED_CONTAINER=""   # kube-scheduler docker container to sample (optional)
SCHED_PID=""         # kube-scheduler process PID to sample (optional; binary-runtime path)
NODES=""; PODS=""; WORKERS=""

while [ $# -gt 0 ]; do
  case "$1" in
    --duration) DURATION="$2"; shift 2 ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    --base-url) BASE_URL="$2"; shift 2 ;;
    --outdir)   OUTDIR="$2";   shift 2 ;;
    --pid)      PID="$2";      shift 2 ;;
    --sched-container) SCHED_CONTAINER="$2"; shift 2 ;;
    --sched-pid)       SCHED_PID="$2";       shift 2 ;;
    --nodes)    NODES="$2";    shift 2 ;;
    --pods)     PODS="$2";     shift 2 ;;
    --workers)  WORKERS="$2";  shift 2 ;;
    -h|--help)  grep '^#' "$0" | grep -v '^#!' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# Build the param-labelled default dir name (fixed field order: os, minkapi, ts, nodes, pods, workers).
if [ -z "$OUTDIR" ]; then
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"   # darwin | linux
  default_name="${os}-minkapi-$(date +%Y%m%d-%H%M%S)"
  [ -n "$NODES" ]   && default_name="${default_name}-n${NODES}"
  [ -n "$PODS" ]    && default_name="${default_name}-p${PODS}"
  [ -n "$WORKERS" ] && default_name="${default_name}-w${WORKERS}"
  OUTDIR="./profiles/${default_name}"
fi

mkdir -p "$OUTDIR"
echo "profiling $BASE_URL for ${DURATION}s (snapshots every ${INTERVAL}s) -> $OUTDIR"

# Fail fast if minkapi isn't reachable / profiling isn't enabled.
if ! curl -fsS "$BASE_URL/" -o /dev/null; then
  echo "ERROR: cannot reach $BASE_URL/ — is minkapi running with --profile?" >&2
  exit 1
fi

# Discover the minkapi PID for OS-level CPU/RSS sampling (skip if we can't find one).
if [ -z "$PID" ]; then
  PID="$(pgrep -f 'minkapi.*--profile' | head -1 || true)"
fi
if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
  echo "sampling OS CPU%/RSS of minkapi pid $PID -> $OUTDIR/minkapi-usage.log"
else
  echo "WARN: no minkapi PID (pass one as arg 5); skipping OS CPU/RSS sampling" >&2
  PID=""
fi

# --- OS-level CPU% + RSS sampling: ps every INTERVAL until the window elapses ---
# Columns (via `ps -o %cpu,rss` on the PID; the whole process, not just Go):
#   timestamp : wall-clock time of the sample (HH:MM:SS)
#   cpu%      : CPU usage normalized to ONE core (100% = 1 core; >100% on multi-core).
#               ps reports an average since the process last ran, so it is spiky.
#   rss_MiB   : Resident Set Size — physical RAM held by the process, in MiB. Includes
#               the Go heap+stack+runtime metadata PLUS binary code/data and mmaps.
#               This is the number that counts toward a container memory limit / OOM.
#
# When the scheduler is a ps-samplable PROCESS (--sched-pid; the linux binary path), we
# sample minkapi AND the scheduler in ONE synchronous loop and also emit a combined
# all-usage.log — exactly mirroring profile-kwok.sh, so the two setups produce identical
# filenames (minkapi-usage.log, kube-scheduler-usage.log, all-usage.log) sampled the same
# way. When the scheduler is a docker container (darwin) it is sampled separately below
# via `docker stats`; there is no all-usage.log in that mode (see header note).
OS_PID=""
if [ -n "$PID" ] && [ -n "$SCHED_PID" ] && [ -z "$SCHED_CONTAINER" ]; then
  # Unified process sampler: minkapi + scheduler + combined total, one tick each.
  echo "sampling OS CPU%/RSS of minkapi pid $PID and kube-scheduler pid $SCHED_PID (+ all-usage.log)"
  {
    hdr_comment='# timestamp=sample time  cpu%=% of one core (may exceed 100)  rss_MiB=resident RAM (whole process)'
    mk_log="$OUTDIR/minkapi-usage.log"; sc_log="$OUTDIR/kube-scheduler-usage.log"; all_log="$OUTDIR/all-usage.log"
    for lf in "$mk_log" "$sc_log" "$all_log"; do
      printf '%s\n' "$hdr_comment" > "$lf"
      printf '%-20s %8s %12s\n' "timestamp" "cpu%" "rss_MiB" >> "$lf"
    done
    sample_one() {  # args: pid logfile ; echoes "cpu rss_mib" (0 0 if dead), appends a row
      local p="$1" lf="$2" cpu rss rss_mib now="$3"
      if kill -0 "$p" 2>/dev/null; then
        read -r cpu rss < <(ps -o %cpu=,rss= -p "$p" 2>/dev/null || echo "0 0")
        cpu="${cpu:-0}"; rss_mib="$(awk "BEGIN{print ${rss:-0}/1024}")"
        printf '%-20s %8s %12.0f\n' "$now" "$cpu" "$rss_mib" >> "$lf"
        echo "$cpu $rss_mib"
      else
        printf '%-20s %8s %12s\n' "$now" "exited" "0" >> "$lf"
        echo ""
      fi
    }
    U_END=$(( $(date +%s) + DURATION ))
    while [ "$(date +%s)" -lt "$U_END" ]; do
      now="$(date +%H:%M:%S)"; tot_cpu=0; tot_rss=0; alive=0
      for r in "$(sample_one "$PID" "$mk_log" "$now")" "$(sample_one "$SCHED_PID" "$sc_log" "$now")"; do
        [ -n "$r" ] || continue
        read -r cpu rss_mib <<<"$r"
        tot_cpu="$(awk "BEGIN{print ${tot_cpu}+${cpu}}")"
        tot_rss="$(awk "BEGIN{print ${tot_rss}+${rss_mib}}")"
        alive=$(( alive + 1 ))
      done
      printf '%-20s %8.1f %12.0f\n' "$now" "$tot_cpu" "$tot_rss" >> "$all_log"
      [ "$alive" -gt 0 ] || { echo "# all processes exited at $now" >> "$all_log"; break; }
      sleep "$INTERVAL"
    done
  } &
  OS_PID=$!
elif [ -n "$PID" ]; then
  # minkapi-only sampler (docker-scheduler mode, or no scheduler pid given).
  {
    printf '# timestamp=sample time  cpu%%=%% of one core (may exceed 100)  rss_MiB=resident RAM (whole process)\n'
    printf '%-20s %8s %12s\n' "timestamp" "cpu%" "rss_MiB"
    OS_END=$(( $(date +%s) + DURATION ))
    while [ "$(date +%s)" -lt "$OS_END" ]; do
      kill -0 "$PID" 2>/dev/null || { echo "# pid $PID exited"; break; }
      # ps %cpu is normalized to one core (can exceed 100% on multi-core); rss is KiB.
      read -r cpu rss < <(ps -o %cpu=,rss= -p "$PID" 2>/dev/null || echo "0 0")
      printf '%-20s %8s %12.0f\n' "$(date +%H:%M:%S)" "${cpu:-0}" "$(awk "BEGIN{print ${rss:-0}/1024}")"
      sleep "$INTERVAL"
    done
  } > "$OUTDIR/minkapi-usage.log" &
  OS_PID=$!
fi

# --- Go runtime memory sampling: MemStats footer from heap?debug=1 every INTERVAL ---
# Reports the Go runtime's own view of memory (from runtime.MemStats) rather than
# whole-process RSS. Fields are bytes in the profile; we convert to MiB.
# Columns:
#   timestamp    : wall-clock time of the sample (HH:MM:SS)
#   heapMiB      : HeapInuse — live heap actually in use (reachable Go objects).
#                  Sawtooths as GC frees garbage between samples.
#   heapSysMiB   : HeapSys — heap memory obtained from the OS (high-water reservation;
#                  only grows/holds). Always >= heapMiB; the gap is idle heap kept for reuse.
#   stackMiB     : Stack (in-use) — memory used by goroutine stacks right now.
#   stackSysMiB  : Stack (sys) — stack memory reserved from the OS.
#   sysMiB       : Sys — TOTAL memory the Go runtime got from the OS (heap + stack + GC
#                  metadata + MSpan/MCache + ...). The runtime's full footprint.
#   numGoroutine : count of live goroutines at sample time (from the goroutine profile header).
{
  printf '# timestamp=sample time  heapMiB=HeapInuse(live)  heapSysMiB=HeapSys(from OS)  stackMiB/stackSysMiB=goroutine stacks  sysMiB=Sys(total from OS)  numGoroutine=live goroutines\n'
  printf '%-20s %10s %10s %10s %10s %10s %10s\n' \
    "timestamp" "heapMiB" "heapSysMiB" "stackMiB" "stackSysMiB" "sysMiB" "numGoroutine"
  MEM_END=$(( $(date +%s) + DURATION ))
  while [ "$(date +%s)" -lt "$MEM_END" ]; do
    footer="$(curl -fsS "$BASE_URL/heap?debug=1" 2>/dev/null | grep -E '^# (HeapInuse|HeapSys|Stack|Sys) =' || true)"
    if [ -z "$footer" ]; then
      echo "# heap?debug=1 unreachable at $(date +%H:%M:%S)"
    else
      # goroutine count comes from the goroutine profile header ("N total").
      ng="$(curl -fsS "$BASE_URL/goroutine?debug=1" 2>/dev/null | head -1 | grep -oE '[0-9]+' | head -1 || echo 0)"
      # Note: the heap footer reports stack as "# Stack = <inuse> / <sys>" (bytes,
      # slash-separated), NOT as separate StackInuse/StackSys fields.
      printf '%-20s %10.1f %10.1f %10.1f %10.1f %10.1f %10s\n' "$(date +%H:%M:%S)" \
        "$(awk -v x="$(echo "$footer" | awk '/HeapInuse/{print $4}')" 'BEGIN{print x/1048576}')" \
        "$(awk -v x="$(echo "$footer" | awk '/HeapSys/{print $4}')"   'BEGIN{print x/1048576}')" \
        "$(awk -v x="$(echo "$footer" | awk '/^# Stack =/{print $4}')" 'BEGIN{print x/1048576}')" \
        "$(awk -v x="$(echo "$footer" | awk '/^# Stack =/{print $6}')" 'BEGIN{print x/1048576}')" \
        "$(awk -v x="$(echo "$footer" | awk '/^# Sys/{print $4}')"     'BEGIN{print x/1048576}')" \
        "${ng:-0}"
    fi
    sleep "$INTERVAL"
  done
} > "$OUTDIR/mem-usage.log" &
MEM_PID=$!

# --- kube-scheduler container CPU%/mem sampling: docker stats every INTERVAL ---
# The scheduler runs as a docker container, so its resource usage is invisible to the
# minkapi (ps) and Go-runtime samplers above. Sample it via `docker stats --no-stream`
# so a run captures BOTH sides of the load test. Skipped if --sched-container is unset
# or the container isn't found.
# Columns:
#   timestamp : wall-clock time of the sample (HH:MM:SS)
#   cpu%      : container CPU usage as reported by docker (normalized to one core;
#               100% = 1 core, may exceed 100% on multi-core). Spiky, like ps.
#   mem_MiB   : container resident memory (docker stats MemUsage, converted to MiB).
SCHED_STATS_PID=""
if [ -n "$SCHED_CONTAINER" ]; then
  if docker inspect "$SCHED_CONTAINER" >/dev/null 2>&1; then
    echo "sampling docker stats of scheduler container $SCHED_CONTAINER -> $OUTDIR/kube-scheduler-usage.log"
    {
      printf '# timestamp=sample time  cpu%%=%% of one core (may exceed 100)  mem_MiB=container resident memory\n'
      printf '%-20s %8s %12s\n' "timestamp" "cpu%" "mem_MiB"
      SCHED_END=$(( $(date +%s) + DURATION ))
      while [ "$(date +%s)" -lt "$SCHED_END" ]; do
        # --no-stream: one sample and exit. Format: "<cpu%> <memusage>" e.g. "12.34% 45.6MiB / 7.6GiB".
        line="$(docker stats --no-stream --format '{{.CPUPerc}} {{.MemUsage}}' "$SCHED_CONTAINER" 2>/dev/null || true)"
        if [ -z "$line" ]; then
          echo "# container $SCHED_CONTAINER unavailable at $(date +%H:%M:%S)"; break
        fi
        # cpu is the leading token with a trailing %; mem usage is the 2nd token (before " / ").
        cpu="$(printf '%s' "$line" | awk '{gsub(/%/,"",$1); print $1}')"
        memraw="$(printf '%s' "$line" | awk '{print $2}')"   # e.g. 45.6MiB, 512KiB, 1.2GiB
        mem_mib="$(awk -v s="$memraw" 'BEGIN{
          v=s+0;                         # numeric prefix
          if (s ~ /GiB/) v*=1024;
          else if (s ~ /KiB/) v/=1024;
          else if (s ~ /B$/ && s !~ /iB/) v/=1048576;  # bare bytes
          printf "%.1f", v }')"
        printf '%-20s %8s %12s\n' "$(date +%H:%M:%S)" "${cpu:-0}" "${mem_mib:-0}"
        sleep "$INTERVAL"
      done
    } > "$OUTDIR/kube-scheduler-usage.log" &
    SCHED_STATS_PID=$!
  else
    echo "WARN: scheduler container $SCHED_CONTAINER not found; skipping docker stats sampling" >&2
  fi
fi

# Note: when the scheduler is a ps-samplable PID (--sched-pid), it is sampled together
# with minkapi in the unified loop near the top (which also writes all-usage.log), so
# there is no separate scheduler-pid sampler here.

# --- duration profiles: one file each, spanning the whole window (background) ---
curl -fsS "$BASE_URL/profile?seconds=${DURATION}" -o "$OUTDIR/cpu.pprof" &
CPU_PID=$!
curl -fsS "$BASE_URL/trace?seconds=${DURATION}" -o "$OUTDIR/trace.out" &
TRACE_PID=$!

# --- snapshot profiles: poll on an interval until the window elapses ---
END=$(( $(date +%s) + DURATION ))
i=0
while [ "$(date +%s)" -lt "$END" ]; do
  ts=$(printf '%03d' "$i")
  curl -fsS "$BASE_URL/heap"      -o "$OUTDIR/heap-${ts}.pprof"      || true
  curl -fsS "$BASE_URL/allocs"    -o "$OUTDIR/allocs-${ts}.pprof"    || true
  curl -fsS "$BASE_URL/goroutine" -o "$OUTDIR/goroutine-${ts}.pprof" || true
  i=$(( i + 1 ))
  sleep "$INTERVAL"
done

# Wait for the long CPU profile + trace (and the samplers) to finish writing.
wait "$CPU_PID" "$TRACE_PID"
[ -n "$OS_PID" ] && wait "$OS_PID" 2>/dev/null || true
wait "$MEM_PID" 2>/dev/null || true
[ -n "${SCHED_STATS_PID:-}" ] && wait "$SCHED_STATS_PID" 2>/dev/null || true

echo "done. artifacts in $OUTDIR:"
ls -1 "$OUTDIR"
cat <<EOF

Inspect with:
  go tool pprof $OUTDIR/cpu.pprof
  go tool pprof $OUTDIR/heap-000.pprof
  go tool pprof -http=:9000 $OUTDIR/cpu.pprof
  go tool pprof -base $OUTDIR/heap-000.pprof $OUTDIR/heap-$(printf '%03d' $((i-1))).pprof   # heap growth across the run
  go tool trace $OUTDIR/trace.out
  cat $OUTDIR/minkapi-usage.log         # minkapi process CPU% and RSS over the run
  cat $OUTDIR/mem-usage.log             # Go runtime heap/stack/Sys (MiB) over the run
  cat $OUTDIR/kube-scheduler-usage.log  # kube-scheduler CPU% and mem (docker or pid)
  cat $OUTDIR/all-usage.log             # minkapi + scheduler summed (linux/binary mode only)
EOF
