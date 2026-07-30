# minkapi load test analysis — 50k nodes, 100k pods, 100 workers

Profiles: `minkapi/profiles/20260730-105213-n50000-p100000-w100/`
Run window: ~17 min (10:52–11:09), scheduler active throughout.

## Resource consumption (ground truth)

- **RSS: plateaued at ~2.7–3.1 GiB.** Ramped 36 MiB → ~2.3 GiB in the first ~90s (object load-in), drifted up to ~3.1 GiB by the end. Tracks Go `Sys` almost exactly (3103 MiB `sysMiB` vs 3102 MiB RSS at the end) — no native/off-heap bloat.
- **CPU: bursty, never saturated.** Total samples were only **27.6% of one core over the whole window** (281s of samples across 1020s). Peaks hit ~1.3 cores (140%) during scheduler List bursts; idle baseline ~5–10%. Nowhere near CPU-bound.
- **Goroutines: flat and healthy.** ~200 during the create/load phase, settling to a steady **78** for the rest of the run. No goroutine leak, no connection pile-up (contrast an earlier `--workers 1000` EOF run, which spiked to ~1800).
- **Stacks: negligible** — ~3 MiB the entire run.
- **Heap: sawtooths 0.9–2.4 GiB** (GC working normally), with `HeapSys` growing 1.8 → 3.06 GiB as the object set grew.

## Where the CPU goes — JSON serialization dominates

The CPU profile is unambiguous: **~56% of all CPU is in `handleList`**, and **~46% is `json.Encode` alone**:

```
56.0%  handleList  (serving LIST/WATCH)
 46.0%  json.Encode
   41.8%  structEncoder / sliceEncoder / arrayEncoder   ← encoding []Pod
 18.8%  syscall.rawsyscalln  (writing responses to socket)
```

The scheduler repeatedly LISTs pods/nodes; minkapi re-marshals the full typed object list to JSON on **every** List. Reflection-based `json` encoding (`structEncoder.encode` 5.8% flat, `appendString`, `reflect.Value.Field`) is the single biggest cost. There is no response caching — each List pays full marshal cost.

## Where the memory/allocations go — List buffers + DeepCopy

- **Live heap (final):** `bytes.growSlice` **52%** (704 MiB) — growing byte buffers for JSON List responses. `Pod.DeepCopy` + `ResourceRequirements/PodSpec/ObjectMeta.DeepCopyInto` ≈ **25%** — the store deep-copies objects out on read.
- **Cumulative allocations over the run: 116 GiB churned** (all GC'd, not resident). `reflect.unsafe_NewArray` 45% + `bytes.growSlice` 31% — JSON List encoding is the allocation firehose.
- **Growth diff (early→late):** live heap essentially flat aside from `bytes.growSlice` (+336 MiB) and DeepCopy buffers. Some allocations went *negative*, confirming **no leak** — steady-state churn from repeated Lists, not accumulation.

## Bottom line

minkapi handled 50k nodes + 100k pods comfortably: ~3 GiB steady RSS, well under 1.5 cores at peak, stable goroutines, healthy GC, no leaks. The dominant cost — **>50% CPU and >50% live heap — is JSON-marshaling full object lists on every scheduler List request**, plus per-read DeepCopy.

To push scale further, that's the lever: response caching / incremental encoding for List, or reducing List frequency (the WATCH path / partial responses).
