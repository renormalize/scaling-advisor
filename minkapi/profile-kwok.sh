#!/usr/bin/env bash
#
# profile-kwok.sh — sample CPU% and resident memory (RSS) of every process in a
# kwokctl "binary" runtime cluster for the duration of a load test.
#
# A binary-runtime kwok cluster is NOT one process (unlike minkapi): kwokctl starts
# five separate OS processes and records each one's PID in a pid file under
#   ~/.kwok/clusters/<name>/pids/{etcd,kube-apiserver,kube-controller-manager,
#                                 kube-scheduler,kwok-controller}.pid
# This script reads those pid files and samples each process with `ps` every INTERVAL
# seconds, writing one log per component plus a combined total. kwok-controller (the
# fake kubelet emulating all nodes) is the component of primary interest at scale.
#
# These are upstream binaries with no minkapi-style /debug/pprof endpoint, so this
# captures OS-level CPU/RSS only (the ground-truth resource numbers) — no Go heap
# profiles. That is the right signal for "how far can kwok scale."
#
# Usage (named flags, order-independent):
#   ./profile-kwok.sh [--duration SECS] [--interval SECS] [--name CLUSTER] \
#                     [--outdir DIR] [--nodes N] [--pods N] [--workers N]
#
# Defaults:
#   --duration  600
#   --interval  5
#   --name      kwok
#   --outdir    ./profiles/<os>-kwok-<timestamp>[-n<NODES>-p<PODS>-w<WORKERS>]
#   --nodes/--pods/--workers   unset (only used to label the default --outdir)
#
# Output directory naming mirrors profile.sh: an explicit --outdir wins; otherwise
# ./profiles/<os>-kwok-<timestamp> (<os> = lowercased `uname -s`, darwin | linux) with
# -n/-p/-w appended in that fixed order when given.
#
# Per-component logs share the same 3-column format as minkapi's minkapi-usage.log:
#   timestamp  cpu%(of one core, may exceed 100)  rss_MiB(resident RAM)
# so they can be analyzed with the same awk peak-extraction patterns.

set -euo pipefail

# --- named args ---
DURATION=600
INTERVAL=5
NAME="kwok"
OUTDIR=""
NODES=""; PODS=""; WORKERS=""

while [ $# -gt 0 ]; do
  case "$1" in
    --duration) DURATION="$2"; shift 2 ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    --name)     NAME="$2";     shift 2 ;;
    --outdir)   OUTDIR="$2";   shift 2 ;;
    --nodes)    NODES="$2";    shift 2 ;;
    --pods)     PODS="$2";     shift 2 ;;
    --workers)  WORKERS="$2";  shift 2 ;;
    -h|--help)  grep '^#' "$0" | grep -v '^#!' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# Run from the script's directory so ./profiles resolves next to the other scripts.
cd "$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")"

PIDS_DIR="$HOME/.kwok/clusters/${NAME}/pids"
[ -d "$PIDS_DIR" ] || { echo "ERROR: no kwok cluster '$NAME' (missing $PIDS_DIR). Create it with ./run-kwok.sh up --name $NAME" >&2; exit 1; }

# Components we expect (pid file basename = component name). We sample whatever pid
# files actually exist so the script still works if the component set changes.
COMPONENTS="etcd kube-apiserver kube-controller-manager kube-scheduler kwok-controller"

# Build the param-labelled default dir name (fixed field order: os, kwok, ts, nodes, pods, workers).
if [ -z "$OUTDIR" ]; then
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"   # darwin | linux
  default_name="${os}-kwok-$(date +%Y%m%d-%H%M%S)"
  [ -n "$NODES" ]   && default_name="${default_name}-n${NODES}"
  [ -n "$PODS" ]    && default_name="${default_name}-p${PODS}"
  [ -n "$WORKERS" ] && default_name="${default_name}-w${WORKERS}"
  OUTDIR="./profiles/${default_name}"
fi
mkdir -p "$OUTDIR"

# Resolve component -> pid up front; warn (don't fail) on any that are missing.
declare -a NAMES=() PIDLIST=()
for c in $COMPONENTS; do
  f="$PIDS_DIR/${c}.pid"
  if [ -f "$f" ]; then
    p="$(tr -dc '0-9' < "$f")"
    if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then
      NAMES+=("$c"); PIDLIST+=("$p")
    else
      echo "WARN: $c pid ($p) not alive; skipping" >&2
    fi
  else
    echo "WARN: no pid file for $c; skipping" >&2
  fi
done
[ "${#PIDLIST[@]}" -gt 0 ] || { echo "ERROR: no live kwok component processes found" >&2; exit 1; }

echo "profiling ${#PIDLIST[@]} kwok components of cluster '$NAME' for ${DURATION}s (every ${INTERVAL}s) -> $OUTDIR"
for i in "${!NAMES[@]}"; do echo "  ${NAMES[$i]} = pid ${PIDLIST[$i]}"; done

# Header written to every per-component log and the combined total log. Columns match
# minkapi's minkapi-usage.log so the same analysis awk works.
write_header() {
  printf '# timestamp=sample time  cpu%%=%% of one core (may exceed 100)  rss_MiB=resident RAM\n' > "$1"
  printf '%-20s %8s %12s\n' "timestamp" "cpu%" "rss_MiB" >> "$1"
}

# One log per component + one combined total.
declare -a LOGS=()
for c in "${NAMES[@]}"; do
  lf="$OUTDIR/${c}-usage.log"; write_header "$lf"; LOGS+=("$lf")
done
TOTAL_LOG="$OUTDIR/all-usage.log"; write_header "$TOTAL_LOG"

# Sample all components each tick. ps %cpu is normalized to one core (>100% on
# multi-core); rss is KiB -> convert to MiB. The combined total sums every live
# component so you can see the whole cluster's footprint at a glance.
END=$(( $(date +%s) + DURATION ))
while [ "$(date +%s)" -lt "$END" ]; do
  now="$(date +%H:%M:%S)"
  tot_cpu=0; tot_rss_mib=0; alive=0
  for i in "${!PIDLIST[@]}"; do
    p="${PIDLIST[$i]}"
    if kill -0 "$p" 2>/dev/null; then
      read -r cpu rss < <(ps -o %cpu=,rss= -p "$p" 2>/dev/null || echo "0 0")
      cpu="${cpu:-0}"; rss="${rss:-0}"
      rss_mib="$(awk "BEGIN{print ${rss}/1024}")"
      printf '%-20s %8s %12.0f\n' "$now" "$cpu" "$rss_mib" >> "${LOGS[$i]}"
      tot_cpu="$(awk "BEGIN{print ${tot_cpu}+${cpu}}")"
      tot_rss_mib="$(awk "BEGIN{print ${tot_rss_mib}+${rss_mib}}")"
      alive=$(( alive + 1 ))
    else
      printf '%-20s %8s %12s\n' "$now" "exited" "0" >> "${LOGS[$i]}"
    fi
  done
  printf '%-20s %8.1f %12.0f\n' "$now" "$tot_cpu" "$tot_rss_mib" >> "$TOTAL_LOG"
  [ "$alive" -gt 0 ] || { echo "# all components exited at $now" >> "$TOTAL_LOG"; break; }
  sleep "$INTERVAL"
done

echo "done. artifacts in $OUTDIR:"
ls -1 "$OUTDIR"
cat <<EOF

Inspect (peaks per component; columns: timestamp cpu% rss_MiB):
  for f in $OUTDIR/*-usage.log; do
    echo "== \$f =="
    awk 'NR>2 && \$2!="exited"{if(\$2>c)c=\$2; if(\$3>r)r=\$3} END{print "peak_cpu%="c" peak_rss_MiB="r}' "\$f"
  done
  cat $OUTDIR/all-usage.log     # whole-cluster CPU%/RSS over the run
EOF
