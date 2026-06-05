#!/usr/bin/env python3
"""
MATS Evaluation Analyzer

Usage:
    python3 scripts/analyze_mats.py <RESULTS_DIR>

Reads per-run artifacts from run_mats_eval.sh and produces:
  - Markdown summary table (5 metrics × 5 variants)
  - MATS α/β time-series stats (mean, std, min, max)
  - Saved to <RESULTS_DIR>/mats_analysis.md
"""
import sys
import os
import csv
import re
import statistics
from pathlib import Path


VARIANTS = ["baseline", "last_wsa", "last_hfl", "mats", "mats_raw"]
REPS = 5


def parse_gc_summary(path: Path) -> dict:
    """Parse gc_summary.txt from NettraceGcParser."""
    result = {}
    if not path.exists():
        return result
    for line in path.read_text().splitlines():
        if "=" in line:
            k, _, v = line.partition("=")
            try:
                result[k.strip()] = float(v.strip())
            except ValueError:
                pass
    return result


def parse_last_metrics(path: Path) -> dict:
    """Parse last_metrics.csv; returns aggregate stats."""
    if not path.exists():
        return {}
    rows = []
    with open(path, newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            rows.append(row)
    if not rows:
        return {}

    block_count = len(rows)
    total_alloc = sum(float(r["alloc_mb"]) for r in rows)
    total_g0 = sum(int(r["g0"]) for r in rows)
    total_g1 = sum(int(r.get("g1", 0)) for r in rows)
    total_g2 = sum(int(r.get("g2", 0)) for r in rows)
    total_tx = sum(int(r["tx_count"]) for r in rows)
    total_warm = sum(int(r["warm_hits"]) for r in rows)
    warm_ratio = total_warm / total_tx if total_tx > 0 else 0.0

    result = {
        "block_count": block_count,
        "alloc_mb_total": total_alloc,
        "alloc_mb_per_block": total_alloc / block_count if block_count else 0,
        "g0_total": total_g0,
        "g1_total": total_g1,
        "g2_total": total_g2,
        "gc_count_total": total_g0 + total_g1 + total_g2,
        "warm_ratio": warm_ratio,
    }

    # MATS-specific columns
    if "mats_alpha" in rows[0]:
        alphas = [float(r["mats_alpha"]) for r in rows if r.get("mats_alpha", "-1") != "-1"]
        betas  = [float(r["mats_beta"])  for r in rows if r.get("mats_beta",  "-1") != "-1"]
        pressures_ewma = [float(r["mats_ewma_pressure"]) for r in rows
                          if r.get("mats_ewma_pressure", "-1") != "-1"]
        pressures_raw  = [float(r["mats_raw_pressure"])  for r in rows
                          if r.get("mats_raw_pressure",  "-1") != "-1"]
        if alphas:
            result["mats_alpha_mean"] = statistics.mean(alphas)
            result["mats_alpha_std"]  = statistics.stdev(alphas) if len(alphas) > 1 else 0
            result["mats_alpha_min"]  = min(alphas)
            result["mats_alpha_max"]  = max(alphas)
        if pressures_ewma:
            result["mats_ewma_mean"] = statistics.mean(pressures_ewma)
            result["mats_raw_mean"]  = statistics.mean(pressures_raw) if pressures_raw else 0

    return result


def parse_caliper_p99(caliper_log: Path) -> float:
    """Extract P99 latency from caliper_console.log measure round."""
    if not caliper_log.exists():
        return -1.0
    content = caliper_log.read_text()
    # Look for table row with "| measure " and extract Max or P99
    for line in content.splitlines():
        if "| measure " in line:
            # Format: | measure | N | N | min | max | avg | p50 | p99 | throughput |
            parts = [p.strip() for p in line.split("|")]
            parts = [p for p in parts if p]
            # Try to find a numeric p99 column (typically 8th non-empty field)
            if len(parts) >= 8:
                try:
                    return float(parts[7])
                except (ValueError, IndexError):
                    pass
    return -1.0


def collect_run(results_dir: Path, variant: str, rep: int) -> dict:
    run_dir = results_dir / f"{variant}_{rep}"
    result = {"variant": variant, "rep": rep, "failed": False}

    if (run_dir / "FAILED").exists():
        result["failed"] = True
        return result

    gc = parse_gc_summary(run_dir / "gc_summary.txt")
    result.update(gc)

    lm = parse_last_metrics(run_dir / "last_metrics.csv")
    result.update(lm)

    result["p99_latency"] = parse_caliper_p99(run_dir / "caliper_console.log")

    return result


def aggregate_variant(runs: list) -> dict:
    """Aggregate valid reps for a variant."""
    valid = [r for r in runs if not r.get("failed")]
    if not valid:
        return {"n_valid": 0}

    def mean_field(field):
        vals = [r[field] for r in valid if field in r and r[field] >= 0]
        return statistics.mean(vals) if vals else None

    def stdev_field(field):
        vals = [r[field] for r in valid if field in r and r[field] >= 0]
        return statistics.stdev(vals) if len(vals) > 1 else 0.0

    agg = {"n_valid": len(valid)}
    for field in ["total_pause_ms", "alloc_mb_total", "alloc_mb_per_block",
                  "gc_count_total", "g0_total", "g2_total",
                  "warm_ratio", "p99_latency",
                  "mats_alpha_mean", "mats_ewma_mean"]:
        m = mean_field(field)
        if m is not None:
            agg[field + "_mean"] = m
            agg[field + "_std"]  = stdev_field(field)

    return agg


def pct_vs_baseline(val, baseline):
    if val is None or baseline is None or baseline == 0:
        return "N/A"
    pct = (val - baseline) / baseline * 100
    sign = "+" if pct >= 0 else ""
    return f"{sign}{pct:.1f}%"


def fmt(val, decimals=1):
    if val is None:
        return "—"
    return f"{val:.{decimals}f}"


def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <RESULTS_DIR>", file=sys.stderr)
        sys.exit(1)

    results_dir = Path(sys.argv[1])
    if not results_dir.exists():
        print(f"ERROR: {results_dir} not found", file=sys.stderr)
        sys.exit(1)

    # Collect all run data
    all_runs = {}
    for variant in VARIANTS:
        runs = []
        for rep in range(1, REPS + 1):
            runs.append(collect_run(results_dir, variant, rep))
        all_runs[variant] = runs

    # Aggregate
    agg = {v: aggregate_variant(all_runs[v]) for v in VARIANTS}
    baseline = agg["baseline"]

    lines = []
    lines.append(f"# MATS Evaluation Results")
    lines.append(f"")
    lines.append(f"Run ID: `{results_dir.name}`")
    lines.append(f"")

    # ── Per-run table ──────────────────────────────────────────────────────────
    lines.append("## Per-Run GC Summary")
    lines.append("")
    lines.append("| Run | total_pause_ms | alloc_mb | g0 | g2 | warm_ratio | P99 (ms) |")
    lines.append("|-----|----------------|----------|----|----|------------|----------|")
    for variant in VARIANTS:
        for run in all_runs[variant]:
            label = f"{variant}_{run['rep']}"
            if run.get("failed"):
                lines.append(f"| {label} | FAILED | — | — | — | — | — |")
                continue
            lines.append(
                f"| {label} "
                f"| {fmt(run.get('total_pause_ms'))} "
                f"| {fmt(run.get('alloc_mb_total'))} "
                f"| {int(run.get('g0_total', 0))} "
                f"| {int(run.get('g2_total', 0))} "
                f"| {fmt(run.get('warm_ratio', 0), 3)} "
                f"| {fmt(run.get('p99_latency'))} |"
            )

    # ── Aggregate table ────────────────────────────────────────────────────────
    lines.append("")
    lines.append("## Aggregate (mean ± std, n=5 valid reps)")
    lines.append("")
    lines.append("| Variant | n | GC pause (ms) | Alloc MB | g0 | g2 | Warm ratio | P99 (ms) | vs baseline |")
    lines.append("|---------|---|---------------|----------|----|----|------------|----------|-------------|")

    b_gc   = baseline.get("total_pause_ms_mean")
    b_alloc = baseline.get("alloc_mb_total_mean")

    for variant in VARIANTS:
        a = agg[variant]
        n = a.get("n_valid", 0)
        gc_m  = a.get("total_pause_ms_mean")
        gc_s  = a.get("total_pause_ms_std", 0)
        al_m  = a.get("alloc_mb_total_mean")
        g0    = a.get("g0_total_mean")
        g2    = a.get("g2_total_mean")
        wr    = a.get("warm_ratio_mean")
        p99   = a.get("p99_latency_mean")
        vs    = pct_vs_baseline(gc_m, b_gc)

        gc_str = f"{fmt(gc_m)} ± {fmt(gc_s)}" if gc_m is not None else "—"
        lines.append(
            f"| **{variant}** | {n} | {gc_str} | {fmt(al_m)} | {fmt(g0, 0)} | {fmt(g2, 0)}"
            f" | {fmt(wr, 3)} | {fmt(p99)} | {vs} |"
        )

    # ── MATS α/β time-series ───────────────────────────────────────────────────
    mats_runs = [r for r in all_runs["mats"] if not r.get("failed")]
    mats_raw_runs = [r for r in all_runs["mats_raw"] if not r.get("failed")]

    if any("mats_alpha_mean" in r for r in mats_runs + mats_raw_runs):
        lines.append("")
        lines.append("## MATS α/β Adaptation (mean per run)")
        lines.append("")
        lines.append("| Run | α mean | α std | α min | α max | EWMA pressure mean |")
        lines.append("|-----|--------|-------|-------|-------|--------------------|")
        for variant_label, runs in [("mats", mats_runs), ("mats_raw", mats_raw_runs)]:
            for r in runs:
                if "mats_alpha_mean" in r:
                    lines.append(
                        f"| {variant_label}_{r['rep']} "
                        f"| {fmt(r.get('mats_alpha_mean'), 4)} "
                        f"| {fmt(r.get('mats_alpha_std', 0), 4)} "
                        f"| {fmt(r.get('mats_alpha_min'), 4)} "
                        f"| {fmt(r.get('mats_alpha_max'), 4)} "
                        f"| {fmt(r.get('mats_ewma_mean', r.get('mats_raw_mean', 0)), 4)} |"
                    )

    # ── Key findings ───────────────────────────────────────────────────────────
    lines.append("")
    lines.append("## Key Findings")
    lines.append("")
    if b_gc and agg["mats"].get("total_pause_ms_mean"):
        lines.append(f"- MATS vs baseline GC pause: {pct_vs_baseline(agg['mats']['total_pause_ms_mean'], b_gc)}")
    if b_gc and agg["last_hfl"].get("total_pause_ms_mean"):
        lines.append(f"- MATS vs LAST-HFL GC pause: {pct_vs_baseline(agg['mats'].get('total_pause_ms_mean'), agg['last_hfl']['total_pause_ms_mean'])}")
    if agg["mats"].get("mats_alpha_mean_mean"):
        lines.append(f"- MATS mean α (fee weight): {fmt(agg['mats']['mats_alpha_mean_mean'], 3)} (static HFL_5_5 = 0.500)")
    lines.append("")
    lines.append("_Generated by scripts/analyze_mats.py_")

    # Write output
    report_path = results_dir / "mats_analysis.md"
    report_path.write_text("\n".join(lines) + "\n")
    print(f"Report written: {report_path}")

    # Also print to stdout
    print("\n".join(lines))


if __name__ == "__main__":
    main()
