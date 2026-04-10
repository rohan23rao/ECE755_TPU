#!/usr/bin/env python3
"""
extract_results.py — Copy key OpenLane2 results to a flat folder for easy access.

What it does:
  1. Scans all run directories under openlane/
  2. For each run, copies: metrics.csv, STA summary, timing reports (per corner),
     GDS, LEF, synthesized netlist
  3. Outputs to Windows Desktop (via /mnt/c/) organized by design/run_tag/

Usage:
    python3 extract_results.py                    # extract all runs
    python3 extract_results.py design2_flat       # extract only design2_flat runs
    python3 extract_results.py --dst /some/path   # custom output directory
"""

import argparse
import os
import shutil
from pathlib import Path

# ==============================
# CONFIG
# ==============================

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
OPENLANE_BASE = REPO_ROOT / "openlane"
DEFAULT_DST = Path("/mnt/c/Users") / os.getenv("USER", "rohan") / "Desktop/ECE755_TPU_Results"

# Corners to extract timing reports from
CORNERS = {
    "max_ff": "max_ff_n40C_1v95",
    "max_ss": "max_ss_100C_1v60",
    "max_tt": "max_tt_025C_1v80",
    "min_ff": "min_ff_n40C_1v95",
    "min_ss": "min_ss_100C_1v60",
    "min_tt": "min_tt_025C_1v80",
    "nom_ff": "nom_ff_n40C_1v95",
    "nom_ss": "nom_ss_100C_1v60",
    "nom_tt": "nom_tt_025C_1v80",
}

CORNER_REPORTS = ["max.rpt", "min.rpt", "power.rpt"]

# ==============================
# HELPERS
# ==============================

def safe_copy(src: Path, dst: Path):
    if src.exists():
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst)
        print(f"  [+] {dst.name}")
    else:
        print(f"  [-] Missing: {src.name}")


def find_step_dir(run_dir: Path, step_name: str) -> Path | None:
    """Find a step directory by name (step numbers vary between runs)."""
    for d in sorted(run_dir.iterdir()):
        if d.is_dir() and step_name in d.name:
            return d
    return None


def find_all_runs(openlane_base: Path, design_filter: str = None):
    """Find all (design_name, run_dir) pairs under openlane/."""
    results = []
    for runs_dir in sorted(openlane_base.rglob("runs")):
        if not runs_dir.is_dir():
            continue
        # Design name from parent path relative to openlane/
        design_name = str(runs_dir.parent.relative_to(openlane_base))
        if design_filter and design_filter not in design_name:
            continue
        for run_dir in sorted(runs_dir.iterdir()):
            if run_dir.is_dir():
                results.append((design_name, run_dir))
    return results


# ==============================
# MAIN
# ==============================

def extract_run(design_name: str, run_dir: Path, dst_base: Path):
    run_tag = run_dir.name
    design_name_clean = design_name.replace("/", "_")
    dst = dst_base / design_name_clean / run_tag

    # Read design name from config for GDS/LEF filenames
    config_file = run_dir.parent.parent / "config.json"
    top_module = "gemm_top"  # fallback
    if config_file.exists():
        import json
        with open(config_file) as f:
            cfg = json.load(f)
            top_module = cfg.get("DESIGN_NAME", top_module)

    print(f"\n=== {design_name} / {run_tag} (top: {top_module}) ===")

    # Metrics
    safe_copy(run_dir / "final" / "metrics.csv", dst / "metrics.csv")
    safe_copy(run_dir / "final" / "metrics.json", dst / "metrics.json")

    # GDS and LEF
    safe_copy(run_dir / "final" / "gds" / f"{top_module}.gds", dst / f"{top_module}.gds")
    safe_copy(run_dir / "final" / "lef" / f"{top_module}.lef", dst / f"{top_module}.lef")

    # Synthesized netlist
    synth_dir = find_step_dir(run_dir, "yosys-synthesis")
    if synth_dir:
        safe_copy(synth_dir / f"{top_module}.nl.v", dst / f"{top_module}.nl.v")

    # STA post-PNR summary and corner reports
    sta_dir = find_step_dir(run_dir, "openroad-stapostpnr")
    if sta_dir:
        safe_copy(sta_dir / "summary.rpt", dst / "sta_summary.rpt")

        for label, corner_name in CORNERS.items():
            corner_src = sta_dir / corner_name
            corner_dst = dst / "timing" / label
            for rpt in CORNER_REPORTS:
                safe_copy(corner_src / rpt, corner_dst / rpt)


def main():
    parser = argparse.ArgumentParser(description="Extract OpenLane2 results to a flat folder")
    parser.add_argument("design", nargs="?", default=None, help="Filter by design name (e.g. design2_flat)")
    parser.add_argument("--dst", type=Path, default=DEFAULT_DST, help="Output directory")
    args = parser.parse_args()

    runs = find_all_runs(OPENLANE_BASE, args.design)

    if not runs:
        print("No runs found.")
        return

    print(f"Found {len(runs)} run(s). Extracting to: {args.dst}")

    for design_name, run_dir in runs:
        extract_run(design_name, run_dir, args.dst)

    print(f"\n=== Done. Results in: {args.dst} ===")


if __name__ == "__main__":
    main()
