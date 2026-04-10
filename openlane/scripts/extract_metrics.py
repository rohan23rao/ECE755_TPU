#!/usr/bin/env python3
"""
extract_metrics.py — Extract key metrics from OpenLane2 run directories.

Usage:
    python3 extract_metrics.py <run_dir> [<run_dir2> ...]
    python3 extract_metrics.py <run_dir> --csv > results.csv

Examples:
    python3 extract_metrics.py ../design2_flat/runs/RUN_2024-01-15_12-00-00
    python3 extract_metrics.py ../design2_flat/runs/RUN_*
    python3 extract_metrics.py ../design2_flat/runs/RUN_* --csv > sweep.csv
"""

import argparse
import json
import os
import sys
from pathlib import Path

# Metrics to extract (key in metrics.json → display name)
METRIC_KEYS = [
    ("design__instance__count",              "Instance Count"),
    ("design__instance__area",               "Cell Area (um^2)"),
    ("design__core__utilization",            "Core Utilization (%)"),
    ("design__die__area",                    "Die Area (um^2)"),
    ("timing__setup__ws",                    "Setup WS (ns)"),
    ("timing__setup__tns",                   "Setup TNS (ns)"),
    ("timing__hold__ws",                     "Hold WS (ns)"),
    ("timing__hold__tns",                    "Hold TNS (ns)"),
    ("route__wirelength",                    "Wirelength (um)"),
    ("route__drc_errors",                    "DRC Errors"),
    ("synthesis__area",                      "Synth Area"),
    ("clock__period",                        "Clock Period (ns)"),
]


def find_metrics_file(run_dir: Path) -> Path | None:
    """Find the metrics.json in a run directory."""
    # OpenLane2 places metrics.json at the run root
    candidates = [
        run_dir / "metrics.json",
        run_dir / "final" / "metrics.json",
    ]
    for c in candidates:
        if c.exists():
            return c
    # Fallback: search for any metrics.json
    for f in run_dir.rglob("metrics.json"):
        return f
    return None


def load_metrics(run_dir: Path) -> dict:
    """Load metrics from a run directory."""
    metrics_file = find_metrics_file(run_dir)
    if metrics_file is None:
        print(f"[WARN] No metrics.json found in {run_dir}", file=sys.stderr)
        return {}
    with open(metrics_file) as f:
        return json.load(f)


def extract(metrics: dict) -> dict:
    """Extract the key metrics we care about."""
    result = {}
    for key, label in METRIC_KEYS:
        val = metrics.get(key, "N/A")
        if isinstance(val, float):
            val = round(val, 4)
        result[label] = val
    return result


def print_table(runs: list[tuple[str, dict]]):
    """Print a formatted table of metrics across runs."""
    if not runs:
        print("No runs to display.")
        return

    labels = [label for _, label in METRIC_KEYS]
    name_width = max(len(name) for name, _ in runs)
    label_width = max(len(l) for l in labels)

    # Header
    header = f"{'Metric':<{label_width}}"
    for name, _ in runs:
        header += f"  {name:>{max(name_width, 18)}}"
    print(header)
    print("-" * len(header))

    # Rows
    for label in labels:
        row = f"{label:<{label_width}}"
        for _, data in runs:
            val = data.get(label, "N/A")
            row += f"  {str(val):>{max(name_width, 18)}}"
        print(row)


def print_csv(runs: list[tuple[str, dict]]):
    """Print CSV output."""
    labels = [label for _, label in METRIC_KEYS]
    # Header
    print("Metric," + ",".join(name for name, _ in runs))
    # Rows
    for label in labels:
        vals = [str(data.get(label, "N/A")) for _, data in runs]
        print(f"{label},{','.join(vals)}")


def main():
    parser = argparse.ArgumentParser(
        description="Extract key metrics from OpenLane2 run directories"
    )
    parser.add_argument("run_dirs", nargs="+", help="Path(s) to OpenLane2 run directories")
    parser.add_argument("--csv", action="store_true", help="Output as CSV")
    args = parser.parse_args()

    runs = []
    for rd in args.run_dirs:
        p = Path(rd)
        if not p.is_dir():
            print(f"[WARN] Not a directory: {rd}", file=sys.stderr)
            continue
        metrics = load_metrics(p)
        extracted = extract(metrics)
        # Use the run directory name as the label
        runs.append((p.name, extracted))

    if args.csv:
        print_csv(runs)
    else:
        print_table(runs)


if __name__ == "__main__":
    main()
