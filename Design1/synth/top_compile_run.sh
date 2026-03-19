#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Sky130 Gate-Level Simulation (Post-Synthesis / MS2 Equivalent)
#
# PURPOSE:
# - This script performs gate-level simulation (GLS) of the synthesized
#   DNN netlist produced by OpenLane.
# - It is the Sky130/OpenLane equivalent of the QuestaSim-based
#   post-synthesis simulation used in the ASAP7 MS2 reference flow.
#
# WHAT THIS MATCHES IN ASAP7:
# - ASAP7 MS2: simulate top.vg using standard-cell Verilog + testbench
# - Sky130 MS2-style: simulate results/synthesis/top.v using Icarus Verilog
#
# IMPORTANT:
# - This script is intended for FUNCTIONAL VERIFICATION ONLY.
# - Timing is NOT back-annotated (no SDF), just like ASAP7 MS2.
#
# WHEN TO USE THIS:
# - After synthesis (MS2-style check)
# - Before APR (to confirm correctness is preserved)
#
# WHEN NOT TO USE THIS:
# - For post-route timing validation (that is done via STA, not simulation)
#
###############################################################################

# -------------------------------
# Default inputs (override if needed)
# -------------------------------
# NETLIST:
#   - Should point to the synthesized netlist from OpenLane
#   - Example:
#     NETLIST=/openlane/designs/dnn/runs/<run_tag>/results/synthesis/top.v
#
# TB:
#   - Provided project testbench (same one used for RTL simulation)
#
NETLIST="${NETLIST:-./top.v}"
TB="${TB:-./top_tb_v1.sv}"

# -------------------------------
# Sky130 PDK discovery
# -------------------------------
# Priority:
# 1) User-provided PDK_ROOT
# 2) OpenLane default locations
# 3) CIEL-managed PDKs (used in CAE / course setup)
#
PDK_ROOT="${PDK_ROOT:-}"

if [[ -z "$PDK_ROOT" ]]; then
  if [[ -d "/openlane/pdks/sky130A" ]]; then
    PDK_ROOT="/openlane/pdks/sky130A"
  else
    FOUND_PRIM="$(find / -path '*sky130A/libs.ref/sky130_fd_sc_hd/verilog/primitives.v' 2>/dev/null | head -n 1 || true)"
    if [[ -n "$FOUND_PRIM" ]]; then
      PDK_ROOT="${FOUND_PRIM%/libs.ref/sky130_fd_sc_hd/verilog/primitives.v}"
    fi
  fi
fi

PRIMITIVES="$PDK_ROOT/libs.ref/sky130_fd_sc_hd/verilog/primitives.v"
STDCELLS="$PDK_ROOT/libs.ref/sky130_fd_sc_hd/verilog/sky130_fd_sc_hd.v"

# -------------------------------
# Waveform settings
# -------------------------------
# A VCD waveform will be generated ONLY if the testbench includes:
#   $dumpfile("wave.vcd");
#   $dumpvars(...);
#
WAVE="wave.vcd"
OPEN_WAVE=0

usage() {
  echo "Usage:"
  echo "  $0                 # compile + run"
  echo "  $0 -w              # compile + run, then open gtkwave (if $WAVE exists)"
  echo "  NETLIST=<path> TB=<path> $0"
  exit 1
}

while getopts ":wh" opt; do
  case $opt in
    w) OPEN_WAVE=1 ;;
    h) usage ;;
    \?) echo "Invalid option: -$OPTARG" >&2; usage ;;
  esac
done

# -------------------------------
# Sanity checks
# -------------------------------
if [[ ! -f "$NETLIST" ]]; then
  echo "[ERROR] Netlist not found: $NETLIST"
  echo "        Tip: use NETLIST=/openlane/designs/dnn/runs/<run_tag>/results/synthesis/top.v"
  exit 2
fi

if [[ ! -f "$TB" ]]; then
  echo "[ERROR] Testbench not found: $TB"
  exit 2
fi

if [[ ! -f "$PRIMITIVES" ]]; then
  echo "[ERROR] Sky130 primitives not found: $PRIMITIVES"
  echo "        Are you inside the OpenLane container (or is PDK set correctly)?"
  exit 2
fi

if [[ -z "$PDK_ROOT" ]]; then
  echo "[ERROR] Could not locate Sky130 PDK automatically."
  echo "        Please set PDK_ROOT manually."
  exit 2
fi

if [[ ! -f "$STDCELLS" ]]; then
  echo "[ERROR] Sky130 stdcell model not found: $STDCELLS"
  echo "        Are you inside the OpenLane container (or is PDK set correctly)?"
  exit 2
fi

# -------------------------------
# Clean previous build artifacts
# -------------------------------
rm -f simv *.vcd vvp.log 2>/dev/null || true

echo "[INFO] NETLIST  = $NETLIST"
echo "[INFO] TB       = $TB"
echo "[INFO] PDK_ROOT = $PDK_ROOT"

# -------------------------------
# Compile (gate-level)
# -------------------------------
# - Includes Sky130 primitives and standard-cell functional models
# - Uses SystemVerilog support (-g2012)
#
iverilog -g2012 -D FUNCTIONAL -o simv \
  "$PRIMITIVES" \
  "$STDCELLS" \
  "$NETLIST" \
  "$TB"

# -------------------------------
# Run simulation
# -------------------------------
vvp simv | tee vvp.log

# -------------------------------
# Optional waveform viewing
# -------------------------------
if [[ $OPEN_WAVE -eq 1 ]]; then
  if [[ -f "$WAVE" ]]; then
    echo "[INFO] Opening $WAVE in gtkwave..."
    gtkwave "$WAVE" >/dev/null 2>&1 &
  else
    echo "[WARNING] $WAVE not found."
    echo "          Make sure your testbench includes \$dumpfile/\$dumpvars."
  fi
fi

echo "[DONE] GLS finished. Log: vvp.log"