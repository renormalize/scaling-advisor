# minkapi load-test scaling analysis — 25k → 200k (List+Watch loadtest)

Consolidated analysis of four load-test runs after the loadtest was changed to track
progress via a single List+Watch informer (instead of re-Listing every 2s). Each run
creates N Ready nodes, then N pending pods, then waits for an external kube-scheduler
to bind them all. One pod requests a node's full allocatable CPU, so the scheduler
places exactly one pod per node.

| Run dir | nodes | pods | workers |
|---|---|---|---|
| `20260730-201203-n25000-p25000-w100`  | 25k  | 25k  | 100 |
| `20260730-204341-n50000-p50000-w100`  | 50k  | 50k  | 100 |
| `20260730-210154-n100000-p100000-w100`| 100k | 100k | 100 |
| `20260731-012325-n200000-p200000-w100`| 200k | 200k | 100 |

> Note: an earlier doc, `loadtest-analysis-n50000-p100000-w100.md`, covers a *different,
> pre-fix* workload (2s full-List polling, 50k nodes / 100k pods). It is not comparable
> row-for-row with the runs here; it is the "before" picture that motivated the fix.

## Ground-truth resource consumption

Numbers below are peaks pulled from each run's `os-usage.log` (minkapi process
cpu%/RSS), `mem-usage.log` (Go runtime), and `sched-usage.log` (the separate
kube-scheduler process). CPU% is percent of one core (may exceed 100).

| Metric | 25k | 50k | 100k | 200k |
|---|---|---|---|---|
| minkapi peak CPU (% of 1 core) | 17% | 335% | 340% | 328% |
| minkapi peak RSS (MiB) | 427 | 901 | 1483 | 2703 |
| Go peak HeapInuse (MiB) | 363 | 842 | 1415 | 2659 |
| Go peak Sys (MiB) | 420 | 893 | 1482 | 2760 |
| steady-state goroutines | ~200 | ~210 | ~197 | ~200 |
| CPU profile duration (s) | 420 | 600 | 1220 | 2400 |
| CPU total samples (% of 1 core over window) | 5.8% | 9.4% | 9.8% | 8.7% |
| alloc churn over run (GiB) | 1.8 | 3.5 | 7.8 | 16.3 |
| scheduler peak CPU (% of 1 core) | 881% | 941% | 1210% | 975% |
| scheduler peak mem (MiB) | 1025 | 1850 | 2691 | 3457 |

### What scales and what doesn't

- **Memory scales linearly with object count.** RSS, HeapInuse and alloc churn all roughly
  double from 100k → 200k (1483 → 2703 MiB RSS; 7.8 → 16.3 GiB churn). There is no
  super-linear blowup and no off-heap bloat — RSS tracks Go `Sys` almost exactly at every
  scale. minkapi holds ~2.7 GiB resident for 400k total objects, which is unremarkable.
- **Peak CPU is essentially flat from 50k onward (~330%, ~3.3 cores).** It is *not*
  proportional to object count. The jump is between 25k (17%) and 50k (335%): below ~50k
  the scheduler binds fast enough that minkapi's per-event watch fan-out never bursts;
  at and above 50k the bind storm saturates the watch-encode path to the same ~3.3-core
  ceiling regardless of whether there are 50k or 200k pods.
- **Goroutines are flat and healthy (~200 steady-state)** at every scale — no leak, no
  connection pile-up. The 100k run shows a single-sample spike to 33,778 goroutines at
  21:02:05, which is the node/pod create burst (100 client workers × in-flight HTTP
  handlers). It collapses back to ~210 on the very next sample. Transient, not a leak.
- **The external kube-scheduler is the real CPU hog**, burning 9–12 cores at peak while
  minkapi sits at ~3.3. minkapi is not the bottleneck in this workload.

## Where minkapi's CPU goes — the watch write path, not List

The CPU profiles at 100k and 200k are nearly identical in shape, and both differ
fundamentally from the pre-fix picture (which was >50% in `handleList` / `json.Encode`).
After the loadtest fix, the scheduler drives one persistent Watch, so the cost moved to
streaming watch events out:

```
200k CPU (cum):
  56.4%  net/http.(*conn).serve            (all request handling)
   40.1%  internal/poll.(*FD).Write         ← writing watch events to sockets
     35.9%  bufio.Writer.Flush
   16.4%  handleWatch → WatchObjects → Store.Watch   ← building/encoding events
  48.7%  syscall.rawsyscalln  (flat)         ← the socket writes, at the syscall level
```

- **~40% of CPU is socket `Write`/`Flush`** — pushing serialized watch events to every
  connected watcher. `syscall.rawsyscalln` is 48.7% flat: that *is* the write syscalls.
- **~16% is the watch build/encode path** (`handleWatch` → `WatchObjects` →
  `Store.Watch` → `buildWatchEventJson`). This is the per-event JSON marshal, one event
  per bind, fanned out to watchers.
- **`json.Encode` / reflection is now a minor CPU cost** (`structEncoder.encode` ~2%),
  a large drop from the pre-fix List-heavy profiles where it was ~46%. The fix worked:
  the dominant cost is no longer re-marshalling full object lists on every poll.

Both 100k and 200k CPU profiles were captured with execution tracing on (`trace.out`
present; `runtime.traceAdvance` visible in the flat profile), which adds some overhead —
treat the absolute CPU-in-runtime numbers as slightly inflated.

## Where the allocations go — watch fan-out + per-read DeepCopy

Allocation churn (`alloc_space`, cumulative over the run) at 200k:

```
39.3%  handleWatch → WatchObjects → Store.Watch     (watch event stream)
  24.3%  Store.buildPendingWatchEvents
    23.9%  objutil.CloneRuntimeObjects
      20.7%  v1.(*Node).DeepCopy                     ← store deep-copies objects out
  15.3%  encoding/json.Encode                        (event serialization)
16.3%  net/http/pprof  (self-profiling artifact of the snapshot, ignore)
```

- The watch path is the allocation firehose: **~39% of all churn**. Each watch event
  clones the object out of the store (`CloneRuntimeObjects` → `DeepCopy`) and then
  JSON-encodes it. At 200k this is 6.4 GiB churned through the watch path alone.
- **`DeepCopy` on read is ~20%** — the store hands out deep copies so watchers can't
  mutate stored objects. Correct, but it means every watch event pays a full object copy.
- Live heap (`inuse_space`) is small and dominated by the *create* path, not watch:
  ~1.3 GiB at 200k, ~40% of it `json.Unmarshal` in `readBodyIntoObj` (decoding incoming
  create/binding request bodies). This is transient load-in cost, GC'd afterward.

## Bottom line

The loadtest fix (List+Watch instead of 2s full-List polling) fundamentally changed
minkapi's cost profile: the old >50%-CPU `handleList`/`json.Encode` hotspot is gone.
minkapi now scales cleanly to 200k nodes + 200k pods — linear memory (~2.7 GiB RSS),
flat ~3.3-core peak CPU, stable ~200 goroutines, no leaks, healthy GC.

The remaining cost concentrates in the **watch write path**: ~40% CPU streaming events
to sockets and ~39% alloc churn building/cloning/encoding one JSON event per bind, fanned
out to watchers, with a full `DeepCopy` per event. That is the next lever if further
scale is needed:

1. **Reduce per-event allocation** — avoid a full `DeepCopy` when the event object is
   immediately serialized and discarded (serialize directly, or copy only mutated fields).
2. **Cache/reuse event serialization** — the same bind event is re-encoded per watcher;
   encode once and write the shared buffer to all watchers.
3. **Batch/coalesce watch writes** — during a bind storm the socket `Write`/`Flush` cost
   dominates; larger buffered flushes reduce syscall count.

None of these are correctness problems — minkapi behaves well at 200k. They are the
headroom levers for pushing beyond it. And the true CPU ceiling in this workload is the
external kube-scheduler (9–12 cores), not minkapi (~3.3).
