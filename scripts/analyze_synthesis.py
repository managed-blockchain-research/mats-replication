#!/usr/bin/env python3
"""
Phase 3 Synthesis: Besu E-Spill vs Nethermind GC Control
Combines final_besu_sensitivity_1GB.md and final_nethermind_evaluation_1GB.md
into a cross-client comparison: final_synthesis_1GB.md

Usage:
    python3 analyze_synthesis.py \
        --besu-sensitivity <besu_sensitivity_dir> \
        --besu-baseline <ctrl_lass75_dir> \
        --nm-results <nm_sensitivity_dir>
"""
import sys
import os
import re
import csv
import math
import argparse
from pathlib import Path
from datetime import datetime


def mean(vals):
    return sum(vals) / len(vals) if vals else None


def stdev(vals):
    if len(vals) < 2:
        return 0.0
    m = mean(vals)
    return math.sqrt(sum((v - m) ** 2 for v in vals) / (len(vals) - 1))


def pct_delta(base, cmp):
    if base is None or cmp is None or base == 0:
        return None
    return (cmp - base) / base * 100


def fmt_pct(pct):
    if pct is None:
        return "N/A"
    arrow = "↑" if pct > 0 else "↓"
    return f"{arrow} {abs(pct):.1f}%"


# ── Besu GC log parser (same as analyze_besu_sensitivity.py) ─────────────────

def parse_besu_gc(gc_log_path):
    gc_pauses = []
    full_gc_pauses = []
    mixed_gc = 0
    if not os.path.exists(gc_log_path):
        return 0, 0.0, 0.0, 0, 0
    with open(gc_log_path) as f:
        for line in f:
            m = re.search(r'GC\(\d+\)\s+Pause\s+(Full|Young|Mixed|Cleanup).*\s+([\d.]+)ms\s*$', line)
            if not m:
                continue
            gc_type = m.group(1)
            try:
                ms = float(m.group(2))
            except ValueError:
                continue
            if gc_type == 'Full':
                full_gc_pauses.append(ms)
            elif gc_type == 'Mixed':
                mixed_gc += 1
                gc_pauses.append(ms)
            else:
                gc_pauses.append(ms)
    all_p = gc_pauses + full_gc_pauses
    return len(all_p), max(all_p) if all_p else 0.0, sum(all_p), len(full_gc_pauses), mixed_gc


def load_besu_variant(results_dir, prefix):
    rows = []
    p = Path(results_dir)
    for entry in sorted(p.iterdir()):
        if not entry.is_dir() or not entry.name.startswith(prefix + '_'):
            continue
        gc_count, max_gc, total_gc, full_gc, mixed = parse_besu_gc(str(entry / 'gc.log'))
        rows.append({'gc_count': gc_count, 'max_gc_ms': max_gc, 'total_gc_ms': total_gc,
                     'full_gc': full_gc, 'mixed_gc': mixed})
    return rows


# ── Nethermind counters parser ────────────────────────────────────────────────

def parse_nm_counters(csv_path):
    gen0 = gen1 = gen2 = 0
    time_gc = []
    heap = []
    if not os.path.exists(csv_path):
        return {'gc_count': 0, 'gen2_count': 0, 'max_time_in_gc': 0.0, 'avg_time_in_gc': 0.0, 'peak_heap_mb': 0.0}
    try:
        with open(csv_path, newline='') as f:
            reader = csv.DictReader(f)
            fld = [h.lower().strip() for h in (reader.fieldnames or [])]
            name_col = next((reader.fieldnames[i] for i, h in enumerate(fld) if 'counter' in h or 'name' in h), None)
            val_col  = next((reader.fieldnames[i] for i, h in enumerate(fld) if 'value' in h or 'mean' in h or 'increment' in h), None)
            if not name_col or not val_col:
                return {'gc_count': 0, 'gen2_count': 0, 'max_time_in_gc': 0.0, 'avg_time_in_gc': 0.0, 'peak_heap_mb': 0.0}
            g0s = g1s = g2s = []
            g0s, g1s, g2s = [], [], []
            for row in reader:
                cn = str(row.get(name_col, '')).lower().strip()
                try:
                    v = float(row.get(val_col, 0) or 0)
                except ValueError:
                    continue
                if 'gen-0-gc-count' in cn: g0s.append(v)
                elif 'gen-1-gc-count' in cn: g1s.append(v)
                elif 'gen-2-gc-count' in cn: g2s.append(v)
                elif 'time-in-gc' in cn: time_gc.append(v)
                elif 'gc-heap-size' in cn: heap.append(v / (1024*1024))
        gen0 = int(max(g0s)) if g0s else 0
        gen1 = int(max(g1s)) if g1s else 0
        gen2 = int(max(g2s)) if g2s else 0
    except Exception:
        pass
    return {
        'gc_count': gen0 + gen1 + gen2,
        'gen2_count': gen2,
        'max_time_in_gc': max(time_gc) if time_gc else 0.0,
        'avg_time_in_gc': sum(time_gc) / len(time_gc) if time_gc else 0.0,
        'peak_heap_mb': max(heap) if heap else 0.0,
    }


def load_nm_variant(results_dir, prefix):
    rows = []
    p = Path(results_dir)
    for entry in sorted(p.iterdir()):
        if not entry.is_dir() or not entry.name.startswith(prefix + '_'):
            continue
        rows.append(parse_nm_counters(str(entry / 'dotnet_counters.csv')))
    return rows


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--besu-baseline', required=True, help='Dir with ctrl_* and lass75_*')
    parser.add_argument('--besu-sensitivity', required=True, help='Dir with lass60_* and lass90_*')
    parser.add_argument('--nm-results', required=True, help='Dir with NM ctrl_*, lass60_*, lass75_*, lass90_*')
    args = parser.parse_args()

    # Load Besu data
    b_ctrl   = load_besu_variant(args.besu_baseline,   'ctrl')
    b_lass60 = load_besu_variant(args.besu_sensitivity, 'lass60')
    b_lass75 = load_besu_variant(args.besu_baseline,   'lass75')
    b_lass90 = load_besu_variant(args.besu_sensitivity, 'lass90')

    # Load Nethermind data
    n_ctrl   = load_nm_variant(args.nm_results, 'ctrl')
    n_lass60 = load_nm_variant(args.nm_results, 'lass60')
    n_lass75 = load_nm_variant(args.nm_results, 'lass75')
    n_lass90 = load_nm_variant(args.nm_results, 'lass90')

    lines = []
    lines.append("# Synthesis Report: Besu E-Spill vs Nethermind GC Control @ 1GB Heap")
    lines.append("")
    lines.append(f"**Generated:** {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    lines.append("")
    lines.append("## Setup Summary")
    lines.append("")
    lines.append("| | Besu (JVM/G1GC) | Nethermind (.NET CLR) |")
    lines.append("|---|---|---|")
    lines.append("| Heap constraint | Xms1g Xmx1g | DOTNET_GCHeapHardLimit=1GB |")
    lines.append("| LASS mechanism | E-Spill to RocksDB | CLR GCHighMemPercent |")
    lines.append("| LASS-60 | activation=0.60, deact=0.45 | GCHighMemPercent=60 |")
    lines.append("| LASS-75 | activation=0.75, deact=0.60 | GCHighMemPercent=75 |")
    lines.append("| LASS-90 | activation=0.90, deact=0.75 | GCHighMemPercent=90 |")
    lines.append("| GC metric | G1GC log (pause ms) | dotnet-counters (Gen counts, time-in-GC%) |")
    lines.append("| Caliper load | fixed-rate 1500 TPS, 600s, 30 workers |")
    lines.append("")

    # Besu GC reduction table
    lines.append("## Besu: GC Event Reduction vs Ctrl")
    lines.append("")
    lines.append("| Threshold | GC Count | Δ vs ctrl | Full GC | Δ vs ctrl | Max GC (ms) | Δ vs ctrl |")
    lines.append("|-----------|----------|-----------|---------|-----------|-------------|-----------|")

    def besu_row(rows):
        if not rows:
            return None, None, None, None, None, None
        return (mean([r['gc_count'] for r in rows]), stdev([r['gc_count'] for r in rows]),
                mean([r['full_gc'] for r in rows]), stdev([r['full_gc'] for r in rows]),
                mean([r['max_gc_ms'] for r in rows]), stdev([r['max_gc_ms'] for r in rows]))

    bc_gc, bc_gc_s, bc_fg, bc_fg_s, bc_mg, bc_mg_s = besu_row(b_ctrl)

    for label, rows in [('ctrl', b_ctrl), ('LASS-60', b_lass60), ('LASS-75', b_lass75), ('LASS-90', b_lass90)]:
        gc_m, gc_s, fg_m, fg_s, mg_m, mg_s = besu_row(rows)
        if gc_m is None:
            lines.append(f"| {label} | N/A | — | N/A | — | N/A | — |")
            continue
        d_gc = fmt_pct(pct_delta(bc_gc, gc_m)) if label != 'ctrl' else "—"
        d_fg = fmt_pct(pct_delta(bc_fg, fg_m)) if label != 'ctrl' else "—"
        d_mg = fmt_pct(pct_delta(bc_mg, mg_m)) if label != 'ctrl' else "—"
        lines.append(f"| {label} | {gc_m:.0f} ± {gc_s:.0f} | {d_gc} "
                     f"| {fg_m:.0f} ± {fg_s:.0f} | {d_fg} "
                     f"| {mg_m:.1f} ± {mg_s:.1f} | {d_mg} |")
    lines.append("")

    # Nethermind GC reduction table
    lines.append("## Nethermind: GC Event Reduction vs Ctrl")
    lines.append("")
    lines.append("| Threshold | Total GC | Δ vs ctrl | Gen2 GC | Δ vs ctrl | Max time-in-GC% | Δ vs ctrl |")
    lines.append("|-----------|----------|-----------|---------|-----------|-----------------|-----------|")

    def nm_row(rows):
        if not rows:
            return None, None, None, None, None, None
        return (mean([r['gc_count'] for r in rows]), stdev([r['gc_count'] for r in rows]),
                mean([r['gen2_count'] for r in rows]), stdev([r['gen2_count'] for r in rows]),
                mean([r['max_time_in_gc'] for r in rows]), stdev([r['max_time_in_gc'] for r in rows]))

    nc_gc, nc_gc_s, nc_g2, nc_g2_s, nc_mt, nc_mt_s = nm_row(n_ctrl)

    for label, rows in [('ctrl', n_ctrl), ('LASS-60', n_lass60), ('LASS-75', n_lass75), ('LASS-90', n_lass90)]:
        gc_m, gc_s, g2_m, g2_s, mt_m, mt_s = nm_row(rows)
        if gc_m is None:
            lines.append(f"| {label} | N/A | — | N/A | — | N/A | — |")
            continue
        d_gc = fmt_pct(pct_delta(nc_gc, gc_m)) if label != 'ctrl' else "—"
        d_g2 = fmt_pct(pct_delta(nc_g2, g2_m)) if label != 'ctrl' else "—"
        d_mt = fmt_pct(pct_delta(nc_mt, mt_m)) if label != 'ctrl' else "—"
        lines.append(f"| {label} | {gc_m:.0f} ± {gc_s:.0f} | {d_gc} "
                     f"| {g2_m:.0f} ± {g2_s:.0f} | {d_g2} "
                     f"| {mt_m:.1f} ± {mt_s:.1f} | {d_mt} |")
    lines.append("")

    lines.append("## Cross-Client Comparison: Full GC / Gen2 Reduction")
    lines.append("")
    lines.append("| Threshold | Besu Full GC Δ | NM Gen2 GC Δ |")
    lines.append("|-----------|----------------|--------------|")
    for label, b_rows, n_rows in [
        ('LASS-60', b_lass60, n_lass60),
        ('LASS-75', b_lass75, n_lass75),
        ('LASS-90', b_lass90, n_lass90),
    ]:
        b_fg_m, _, b_fg2_m, _, _, _ = besu_row(b_rows)
        n_gc_m, _, n_g2_m, _, _, _ = nm_row(n_rows)
        d_b = fmt_pct(pct_delta(bc_fg, b_fg2_m)) if b_fg_m is not None else "N/A"
        d_n = fmt_pct(pct_delta(nc_g2, n_g2_m)) if n_gc_m is not None else "N/A"
        lines.append(f"| {label} | {d_b} | {d_n} |")
    lines.append("")

    lines.append("## Key Findings")
    lines.append("")
    lines.append("### Besu (E-Spill mechanism)")
    for label, b_rows in [('LASS-60', b_lass60), ('LASS-75', b_lass75), ('LASS-90', b_lass90)]:
        if not b_rows or not b_ctrl:
            continue
        gc_red = pct_delta(bc_gc, mean([r['gc_count'] for r in b_rows]))
        fg_red = pct_delta(bc_fg, mean([r['full_gc'] for r in b_rows]))
        mg_chg = pct_delta(bc_mg, mean([r['max_gc_ms'] for r in b_rows]))
        lines.append(f"- **{label}**: GC count {fmt_pct(gc_red)}, "
                     f"Full GC {fmt_pct(fg_red)}, Max GC pause {fmt_pct(mg_chg)}")

    lines.append("")
    lines.append("### Nethermind (CLR GCHighMemPercent mechanism)")
    for label, n_rows in [('LASS-60', n_lass60), ('LASS-75', n_lass75), ('LASS-90', n_lass90)]:
        if not n_rows or not n_ctrl:
            continue
        gc_red = pct_delta(nc_gc, mean([r['gc_count'] for r in n_rows]))
        g2_red = pct_delta(nc_g2, mean([r['gen2_count'] for r in n_rows]))
        mt_chg = pct_delta(nc_mt, mean([r['max_time_in_gc'] for r in n_rows]))
        lines.append(f"- **{label}**: GC count {fmt_pct(gc_red)}, "
                     f"Gen2 GC {fmt_pct(g2_red)}, Max time-in-GC {fmt_pct(mt_chg)}")

    lines.append("")
    lines.append("---")
    lines.append("*Report generated by analyze_synthesis.py*")

    report_text = "\n".join(lines)
    out_path = Path("/home/yeochan.yoon/caliper-stress-test/final_synthesis_1GB.md")
    with open(out_path, 'w') as f:
        f.write(report_text)
    print(report_text)
    print(f"\nReport: {out_path}")


if __name__ == '__main__':
    main()
