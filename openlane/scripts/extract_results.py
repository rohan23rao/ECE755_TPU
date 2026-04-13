#!/usr/bin/env python3
"""
extract_results.py — Copy key OpenLane2 results to a flat folder for easy access.

What it does:
  1. Scans all run directories under openlane/
  2. For each run, copies: metrics, STA reports (per corner), GDS, LEF, DRC reports,
     synthesized netlist, IR drop report
  3. Falls back to step-level outputs when final/ doesn't exist (deferred DRC errors)
  4. Outputs to /mnt/c/ (Windows) organized by design/run_tag/

Usage:
    python3 extract_results.py                          # extract all runs
    python3 extract_results.py design2_pe_hier          # filter by design name
    python3 extract_results.py --run hier_top_v4_68pins # filter by run tag
    python3 extract_results.py --dst /some/path         # custom output directory
    python3 extract_results.py --latest                 # only the latest run per design
"""

import argparse
import json
import os
import shutil
from pathlib import Path

# ==============================
# CONFIG
# ==============================

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
OPENLANE_BASE = REPO_ROOT / "openlane"
path = "development/masters/ece755/results"
DEFAULT_DST = Path("/mnt/c/Users") / os.getenv("USER", "rohan") /  path

STA_CORNERS = [
    "max_ff_n40C_1v95",
    "min_ss_100C_1v60",
    "nom_tt_025C_1v80",
]

CORNER_REPORTS = ["max.rpt", "min.rpt", "power.rpt"]

# ==============================
# HELPERS
# ==============================

def safe_copy(src: Path, dst: Path):
    if src.exists():
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst)
        return True
    return False


def find_step_dir(run_dir: Path, step_name: str) -> Path | None:
    """Find a step directory by name (step numbers vary between runs)."""
    for d in sorted(run_dir.iterdir()):
        if d.is_dir() and step_name in d.name:
            return d
    return None


def find_all_runs(openlane_base: Path, design_filter: str = None, run_filter: str = None):
    """Find all (design_name, run_dir) pairs under openlane/."""
    results = []
    for runs_dir in sorted(openlane_base.rglob("runs")):
        if not runs_dir.is_dir():
            continue
        design_name = str(runs_dir.parent.relative_to(openlane_base))
        if design_filter and design_filter not in design_name:
            continue
        for run_dir in sorted(runs_dir.iterdir()):
            if run_dir.is_dir():
                if run_filter and run_filter not in run_dir.name:
                    continue
                results.append((design_name, run_dir))
    return results


# ==============================
# EXTRACTION
# ==============================

def extract_run(design_name: str, run_dir: Path, dst_base: Path):
    run_tag = run_dir.name
    design_name_clean = design_name.replace("/", "_").replace("\\", "_")
    dst = dst_base / design_name_clean / run_tag

    # Read design name from config
    config_file = run_dir.parent.parent / "config.json"
    top_module = "gemm_top"
    if config_file.exists():
        with open(config_file) as f:
            cfg = json.load(f)
            top_module = cfg.get("DESIGN_NAME", top_module)

    has_final = (run_dir / "final").is_dir()
    copied = []
    missing = []

    print(f"\n{'='*60}")
    print(f"  {design_name} / {run_tag}  (module: {top_module})")
    print(f"  final/ exists: {has_final}")
    print(f"{'='*60}")

    # --- Metrics ---
    if has_final:
        for f in ["metrics.csv", "metrics.json"]:
            if safe_copy(run_dir / "final" / f, dst / f):
                copied.append(f)
            else:
                missing.append(f)

    # --- GDS ---
    gds_copied = False
    if has_final:
        gds_copied = safe_copy(
            run_dir / "final" / "gds" / f"{top_module}.gds",
            dst / f"{top_module}.gds"
        )
    if not gds_copied:
        # Fallback: magic-streamout step
        magic_dir = find_step_dir(run_dir, "magic-streamout")
        if magic_dir:
            gds_copied = safe_copy(
                magic_dir / f"{top_module}.gds",
                dst / f"{top_module}.gds"
            )
    if gds_copied:
        copied.append("GDS")
    else:
        missing.append("GDS")

    # --- LEF ---
    lef_copied = False
    if has_final:
        lef_copied = safe_copy(
            run_dir / "final" / "lef" / f"{top_module}.lef",
            dst / f"{top_module}.lef"
        )
    if not lef_copied:
        lef_dir = find_step_dir(run_dir, "magic-writelef")
        if lef_dir:
            lef_copied = safe_copy(
                lef_dir / f"{top_module}.lef",
                dst / f"{top_module}.lef"
            )
    if lef_copied:
        copied.append("LEF")
    else:
        missing.append("LEF")

    # --- Liberty files (for sub-module runs) ---
    if has_final:
        lib_dir = run_dir / "final" / "lib"
        if lib_dir.is_dir():
            lib_dst = dst / "lib"
            for lib_file in sorted(lib_dir.rglob("*.lib")):
                rel = lib_file.relative_to(lib_dir)
                safe_copy(lib_file, lib_dst / rel)
            copied.append("Liberty")

    # --- Synthesized netlist ---
    synth_dir = find_step_dir(run_dir, "yosys-synthesis")
    if synth_dir:
        if safe_copy(synth_dir / f"{top_module}.nl.v", dst / f"{top_module}.nl.v"):
            copied.append("netlist")

    # --- STA post-PNR reports ---
    sta_dir = find_step_dir(run_dir, "openroad-stapostpnr")
    if sta_dir:
        safe_copy(sta_dir / "summary.rpt", dst / "sta_summary.rpt")
        copied.append("STA summary")

        for corner_name in STA_CORNERS:
            corner_src = sta_dir / corner_name
            short = corner_name.split("_")[0] + "_" + corner_name.split("_")[1]
            corner_dst = dst / "timing" / short
            for rpt in CORNER_REPORTS:
                safe_copy(corner_src / rpt, corner_dst / rpt)

    # --- DRC reports ---
    magic_drc_dir = find_step_dir(run_dir, "magic-drc")
    if magic_drc_dir:
        rpt = magic_drc_dir / "reports" / "drc_violations.magic.rpt"
        if safe_copy(rpt, dst / "drc_magic.rpt"):
            copied.append("Magic DRC report")

    klayout_drc_dir = find_step_dir(run_dir, "klayout-drc")
    if klayout_drc_dir:
        for rpt in klayout_drc_dir.glob("*.xml"):
            safe_copy(rpt, dst / "drc_klayout.xml")
            copied.append("KLayout DRC report")
            break

    # --- IR drop report ---
    ir_dir = find_step_dir(run_dir, "openroad-irdropreport")
    if ir_dir:
        for rpt in ir_dir.glob("*.rpt"):
            if safe_copy(rpt, dst / "ir_drop.rpt"):
                copied.append("IR drop")
                break

    # --- LVS report ---
    lvs_dir = find_step_dir(run_dir, "netgen-lvs")
    if lvs_dir:
        for rpt in sorted(lvs_dir.glob("*.rpt")):
            if safe_copy(rpt, dst / "lvs.rpt"):
                copied.append("LVS report")
                break

    # --- Summary metrics printout ---
    metrics_path = dst / "metrics.json"
    if not metrics_path.exists() and has_final:
        metrics_path = run_dir / "final" / "metrics.json"
    if metrics_path.exists():
        with open(metrics_path) as f:
            m = json.load(f)
        print(f"  Instances:    {m.get('design__instance__count', 'N/A')}")
        print(f"  Cell Area:    {m.get('design__instance__area', 'N/A')} um2")
        print(f"  Die Area:     {m.get('design__die__area', 'N/A')} um2")
        wl = m.get('route__wirelength', 'N/A')
        print(f"  Wirelength:   {wl} um")
        wns = m.get('timing__setup__wns', 'N/A')
        print(f"  Setup WNS:    {wns} ns")
        hwns = m.get('timing__hold__wns', 'N/A')
        print(f"  Hold WNS:     {hwns} ns")
        drc = m.get('magic__drc_error__count', 'N/A')
        print(f"  Magic DRC:    {drc}")
        lvs = m.get('design__lvs_error__count', 'N/A')
        print(f"  LVS Errors:   {lvs}")

    print(f"\n  Copied: {', '.join(copied) if copied else 'nothing'}")
    if missing:
        print(f"  Missing: {', '.join(missing)}")


def main():
    parser = argparse.ArgumentParser(description="Extract OpenLane2 results to a flat folder")
    parser.add_argument("design", nargs="?", default=None, help="Filter by design name")
    parser.add_argument("--run", default=None, help="Filter by run tag")
    parser.add_argument("--dst", type=Path, default=DEFAULT_DST, help="Output directory")
    parser.add_argument("--latest", action="store_true", help="Only extract the latest run per design")
    args = parser.parse_args()

    runs = find_all_runs(OPENLANE_BASE, args.design, args.run)

    if args.latest:
        # Keep only the latest run per design
        latest = {}
        for design_name, run_dir in runs:
            if design_name not in latest or run_dir.name > latest[design_name].name:
                latest[design_name] = run_dir
        runs = [(d, r) for d, r in latest.items()]

    if not runs:
        print("No runs found.")
        return

    print(f"Found {len(runs)} run(s). Extracting to: {args.dst}")

    for design_name, run_dir in runs:
        extract_run(design_name, run_dir, args.dst)

    print(f"\n{'='*60}")
    print(f"Done. Results in: {args.dst}")
    print(f"{'='*60}")


if __name__ == "__main__":
    main()
