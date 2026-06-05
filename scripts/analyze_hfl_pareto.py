#!/usr/bin/env python3
"""
Analyze HFL Pareto sweep results.
Reads gc_total.txt and revenue.json from each run_dir,
computes mean ± std per variant, prints Pareto table.

Usage:
    python3 scripts/analyze_hfl_pareto.py <results_dir>
"""

import json
import os
import sys
import statistics

results_dir = sys.argv[1]

VARIANT_ORDER = ['disabled', 'al', 'hfl_0.1', 'hfl_0.3', 'hfl_0.5', 'hfl_0.7', 'hfl_0.9']

def label_to_variant(label):
    """'hfl_0.9_2' → 'hfl_0.9', 'disabled_1' → 'disabled'"""
    parts = label.rsplit('_', 1)
    return parts[0] if len(parts) == 2 and parts[1].isdigit() else label

def read_float(path):
    try:
        return float(open(path).read().strip())
    except Exception:
        return None

# Collect per-variant lists
gc_by_variant      = {}
scattered_by_variant = {}
total_fee_by_variant = {}

for entry in sorted(os.listdir(results_dir)):
    run_dir = os.path.join(results_dir, entry)
    if not os.path.isdir(run_dir):
        continue
    if os.path.exists(os.path.join(run_dir, 'FAILED')):
        continue

    variant = label_to_variant(entry)

    gc_val = read_float(os.path.join(run_dir, 'gc_total.txt'))
    if gc_val is not None:
        gc_by_variant.setdefault(variant, []).append(gc_val)

    rev_path = os.path.join(run_dir, 'revenue.json')
    if os.path.exists(rev_path):
        with open(rev_path) as f:
            rev = json.load(f)
        sf = rev.get('scattered_fee_share', None)
        tf = rev.get('total_fee_wei', None)
        if sf is not None:
            scattered_by_variant.setdefault(variant, []).append(sf)
        if tf is not None:
            total_fee_by_variant.setdefault(variant, []).append(tf)

def mean_std(vals):
    if not vals:
        return None, None
    m = statistics.mean(vals)
    s = statistics.stdev(vals) if len(vals) > 1 else 0.0
    return m, s

# Baseline reference (DISABLED = pure fee, best revenue)
disabled_gc_mean, _ = mean_std(gc_by_variant.get('disabled', []))
disabled_sf_mean, _ = mean_std(scattered_by_variant.get('disabled', []))

print("=" * 72)
print("HFL PARETO RESULTS")
print("=" * 72)
print(f"{'Variant':<14} {'GC Total (ms)':>16} {'GC vs Disabled':>16} {'Scattered Fee%':>16} {'Revenue vs Dis':>16}")
print("-" * 72)

for v in VARIANT_ORDER:
    gc_vals = gc_by_variant.get(v, [])
    sf_vals = scattered_by_variant.get(v, [])

    gc_m, gc_s = mean_std(gc_vals)
    sf_m, sf_s = mean_std(sf_vals)

    gc_str = f"{gc_m:.0f} ± {gc_s:.0f}" if gc_m is not None else "N/A"
    sf_str = f"{sf_m:.1%}"                if sf_m is not None else "N/A"

    if disabled_gc_mean and gc_m is not None:
        gc_rel = f"{(gc_m - disabled_gc_mean) / disabled_gc_mean * 100:+.1f}%"
    else:
        gc_rel = "N/A"

    if disabled_sf_mean and sf_m is not None:
        sf_rel = f"{(sf_m - disabled_sf_mean) / disabled_sf_mean * 100:+.1f}pp"
    else:
        sf_rel = "N/A"

    n = len(gc_vals)
    print(f"{v:<14} {gc_str:>16} {gc_rel:>16} {sf_str:>16} {sf_rel:>16}   (n={n})")

print("=" * 72)
print()
print("PARETO CSV (for figure)")
print("variant,alpha,gc_mean_ms,gc_std_ms,gc_reduction_pct,scattered_fee_share,n")
alpha_map = {
    'disabled': 1.0, 'al': 0.0,
    'hfl_0.1': 0.1, 'hfl_0.3': 0.3, 'hfl_0.5': 0.5,
    'hfl_0.7': 0.7, 'hfl_0.9': 0.9,
}
for v in VARIANT_ORDER:
    gc_m, gc_s = mean_std(gc_by_variant.get(v, []))
    sf_m, _    = mean_std(scattered_by_variant.get(v, []))
    if gc_m is None:
        continue
    gc_red = (disabled_gc_mean - gc_m) / disabled_gc_mean * 100 if disabled_gc_mean else 0
    alpha  = alpha_map.get(v, '')
    n      = len(gc_by_variant.get(v, []))
    print(f"{v},{alpha},{gc_m:.1f},{gc_s:.1f},{gc_red:.1f},{sf_m:.4f if sf_m else 'N/A'},{n}")
