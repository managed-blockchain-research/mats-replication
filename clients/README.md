# MATS source patch

- `besu-mats/`: Besu-side scheduler, reconstructed/extended from the
  besu-24.1.1 LAST integration to add the MATS/MATS_RAW EWMA-adaptive
  variants (and PREP/PREP_SCHED, which share this same file — see PREP's
  own `clients/besu-mats/` for the identical copy). Includes the
  `reorderHybridWithWeights` O(n log n) comparator-recompute fix.
- `nethermind-mats/`: the Nethermind CLR port (`LastTxPoolTxSource.cs`),
  identical to the copy under LAST's and PREP's `clients/`.
