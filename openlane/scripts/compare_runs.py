#!/usr/bin/env python3
"""
compare_runs.py — Side-by-side comparison of two OpenLane2 runs.

Usage:
    python3 compare_runs.py <run_a> <run_b>

Examples:
    python3 compare_runs.py ../design1/runs/RUN_base ../design2_flat/runs/RUN_base
    python3 compare_runs.py ../design2_flat/runs/RUN_20ns ../design2_flat/runs/RUN_15ns
"""

import argparse
import json
import sys
from pathlib import Path

METRIC_KEYS = [
    ("design__instance__count",    "Instance Count"),
    ("design__instance__area",     "Cell Area (um^2)"),
    ("design__core__utilization",  "Core Utilization (%)"),
    ("design__die__area",          "Die Area (um^2)"),
    ("timing__setup__ws",          "Setup WS (ns)"),
    ("timing__setup__tns",         "Setup TNS (ns)"),
    ("timing__hold__ws",           "Hold WS (ns)"),
    ("timing__hold__tns",          "Hold TNS (ns)"),
    ("route__wirelength",          "Wirelength (um)"),
    ("route__drc_errors",          "DRC Errors"),
    ("clock__period",              "Clock Period (ns)"),
]


def find_metrics(run_dir: Path) -> dict:
    """Load metrics.json from a run directory."""
    for candidate in [
        run_dir / "metrics.json",
        run_dir / "final" / "metrics.json",
    ]:
        if candidate.exists():
            with open(candidate) as f:
                return json.load(f)
    # Fallback search
    for f in run_dir.rglob("metrics.json"):
        with open(f) as fh:
            return json.load(fh)
    print(f"[ERROR] No metrics.json found in {run_dir}", file=sys.stderr)
    return {}


def delta_str(a, b) -> str:
    """Compute delta between two numeric values."""
    if not isinstance(a, (int, float)) or not isinstance(b, (int, float)):
        return ""
    diff = b - a
    if a == 0:
        return f"{diff:+.4f}"
    pct = (diff / abs(a)) * 100
    return f"{diff:+.4f} ({pct:+.1f}%)"


def main():
    parser = argparse.ArgumentParser(
        description="Compare metrics from two OpenLane2 runs side-by-side"
    )
    parser.add_argument("run_a", help="Path to first run directory (baseline)")
    parser.add_argument("run_b", help="Path to second run directory (comparison)")
    args = parser.parse_args()

    path_a = Path(args.run_a)
    path_b = Path(args.run_b)

    if not path_a.is_dir():
        print(f"[ERROR] Not a directory: {args.run_a}", file=sys.stderr)
        sys.exit(1)
    if not path_b.is_dir():
        print(f"[ERROR] Not a directory: {args.run_b}", file=sys.stderr)
        sys.exit(1)

    metrics_a = find_metrics(path_a)
    metrics_b = find_metrics(path_b)

    if not metrics_a or not metrics_b:
        sys.exit(1)

    name_a = path_a.name
    name_b = path_b.name
    col_w = 20
    label_w = max(len(label) for _, label in METRIC_KEYS)

    # Header
    print(f"\n{'Metric':<{label_w}}  {name_a:>{col_w}}  {name_b:>{col_w}}  {'Delta':>{col_w + 8}}")
    print("-" * (label_w + 2 + col_w + 2 + col_w + 2 + col_w + 8))

    # Rows
    for key, label in METRIC_KEYS:
        val_a = metrics_a.get(key, "N/A")
        val_b = metrics_b.get(key, "N/A")

        # Format values
        str_a = f"{val_a:.4f}" if isinstance(val_a, float) else str(val_a)
        str_b = f"{val_b:.4f}" if isinstance(val_b, float) else str(val_b)
        d = delta_str(val_a, val_b)

        print(f"{label:<{label_w}}  {str_a:>{col_w}}  {str_b:>{col_w}}  {d:>{col_w + 8}}")

    print()


if __name__ == "__main__":
    main()
