# ECE755_TPU
ECE755 Project TPU — 8x8 Systolic Array GEMM Accelerator

## Repository Structure

```
Design1/src/          Design Review 1 (baseline)
Design2/src/          Design Review 2 (optimized)
DesignDiagrams/       Architecture diagrams
openlane/             OpenLane2 APR configs and scripts
```

## OpenLane2 Setup

### Prerequisites

- Docker (with non-root access: `sudo usermod -aG docker $USER`)
- Python 3.8+
- OpenLane2: `pip install openlane`
- Sky130 PDK: `volare enable --pdk sky130`

### Flow Configurations

| Config | Top Module | Description |
|--------|-----------|-------------|
| `openlane/design2_flat/` | `gemm_top` | Flat flow — full Design2 as one block |
| `openlane/design2_hier/gemm_pe/` | `gemm_pe` | Hierarchical — harden PE as standalone macro |
| `openlane/design2_hier/gemm_top/` | `gemm_top` | Hierarchical — top-level with PE black-boxed |
| `openlane/design1/` | `gemm_top` | Design1 reference (for comparison) |

Please add more as necessary

### Running a Flow

```bash
cd openlane/scripts
./run_flow.sh ../design2_flat -tag baseline_20ns
```

The script copies source files into the config directory, then launches OpenLane2 in Docker. Run outputs go to `runs/` inside each config directory (gitignored).

### Editing Config

Each config directory has:
- `config.json` — main configuration (clock period, utilization, fanout, etc.)
- `constraints/base.sdc` — timing constraints

Key parameters in `config.json`:
```json
{
  "DESIGN_NAME": "gemm_top",
  "CLOCK_PERIOD": 20.0,
  "pdk::sky130A": {
    "FP_CORE_UTIL": 40,
    "PL_TARGET_DENSITY_PCT": 50,
    "MAX_FANOUT_CONSTRAINT": 128
  }
}
```

- `CLOCK_PERIOD` — target clock in ns. Increase if setup violations occur.
- `FP_CORE_UTIL` — core utilization %. Higher = smaller die but harder to route.
- `PL_TARGET_DENSITY_PCT` — placement density. Keep ~10% above `FP_CORE_UTIL`.
- `MAX_FANOUT_CONSTRAINT` — max fanout per net.

### Hierarchical Flow (Black-Boxing)

1. Harden the PE macro first:
   ```bash
   ./run_flow.sh ../design2_hier/gemm_pe -tag pe_v1
   ```
2. Update `design2_hier/gemm_top/config.json` — replace placeholder paths with PE run outputs:
   - `VERILOG_FILES_BLACKBOX` → `runs/<tag>/final/nl/gemm_pe.nl.v`
   - `EXTRA_LEFS` → `runs/<tag>/final/lef/gemm_pe.lef`
   - `EXTRA_GDS_FILES` → `runs/<tag>/final/gds/gemm_pe.gds`
3. Run the top-level:
   ```bash
   ./run_flow.sh ../design2_hier/gemm_top -tag top_v1
   ```

### Viewing Results

**Key report locations** (inside `runs/<tag>/`):
- `final/metrics.csv` — all metrics (area, timing, power, DRC)
- `57-openroad-stapostpnr/summary.rpt` — timing summary across all corners
- `57-openroad-stapostpnr/<corner>/max.rpt` — setup timing paths
- `57-openroad-stapostpnr/<corner>/min.rpt` — hold timing paths
- `57-openroad-stapostpnr/<corner>/power.rpt` — power report
- `final/gds/gemm_top.gds` — layout (open with KLayout)

Note: Step numbers (e.g. `57-`) may vary between runs.

**Extract metrics to terminal:**
```bash
python3 openlane/scripts/extract_metrics.py openlane/design2_flat/runs/<tag>
```

**Compare two runs:**
```bash
python3 openlane/scripts/compare_runs.py openlane/design2_flat/runs/<run_a> openlane/design2_flat/runs/<run_b>
```

**Copy results to Windows Desktop:**
```bash
python3 openlane/scripts/extract_results.py              # all runs
python3 openlane/scripts/extract_results.py design2_flat  # specific design
```

### Opening Layout in KLayout (WSL)

From Windows PowerShell:
```
klayout "\\wsl$\Ubuntu-22.04\home\rohan\ECE755_TPU\openlane\design2_flat\runs\<tag>\final\gds\gemm_top.gds"
```

### What's Gitignored

Run outputs (`openlane/**/runs/`) and copied source files (`openlane/**/src/`) are excluded from git. Only configs, constraints, and scripts are tracked. Clone and run — no large binaries in the repo.
