# ============================================================
# Sky130 / OpenLane config for DNN (MS2-friendly)
#
# READ ME FIRST:
# - This config is written to closely match the intent of the ASAP7 MS2
#   (Design Compiler) synthesis flow used earlier in the project.
# - All timing constraints (create_clock, delays, uncertainty, loads) are defined only in dnn.sdc.
#   This file must remain the single source of truth for timing.
#
# WHAT YOU ARE EXPECTED TO CHANGE:
# - CLK_PERIOD_NS only.
#   If you see setup violations after synthesis or APR, increase this
#   value (e.g., 20ns). Do NOT change CLOCK_PORT or CLOCK_PERIOD directly.
# - If the design fails timing at the typical corner, increase
#   CLK_PERIOD_NS gradually (e.g., +2ns steps).
#
# WHAT YOU SHOULD NOT CHANGE:
# - DESIGN_NAME, VERILOG_FILES, SDC_FILE path
# - Fanout settings (these are chosen to match DC-style behavior)
#
# FANOUT NOTE:
# - MAX_FANOUT_CONSTRAINT is set to a relaxed value (128), similar to
#   ASAP7/DC defaults. This avoids unnecessary fanout warnings in
#   OpenLane and keeps the focus on functionality rather than aggressive
#   optimization.
#
# ============================================================

# ---------- Design ----------
set ::env(DESIGN_NAME) gemm_pe
set ::env(VERILOG_FILES) [glob \
  $::env(DESIGN_DIR)/src/*.sv \
  $::env(DESIGN_DIR)/src/*.v \
]

# ---------- Clock (EDIT ONLY HERE) ----------
# ASAP7 versions often use ~2.0ns. Sky130 is slower, so we relax the clock.
# If post-route STA shows setup violations, increase this value gradually (e.g., 18ns, 20ns, 22ns).
set CLK_PORT       "clk"
set CLK_PERIOD_NS  20.0

# OpenLane still expects CLOCK_PORT/CLOCK_PERIOD for CTS + internal flow settings.
# Do NOT edit these directly; change CLK_PERIOD_NS above.
set ::env(CLOCK_PORT)   $CLK_PORT
set ::env(CLOCK_PERIOD) $CLK_PERIOD_NS

# ---------- Constraints ----------
set sdc_path "$::env(DESIGN_DIR)/dnn.sdc"
set ::env(SDC_FILE) $sdc_path

# ---------- Fanout control ----------
set ::env(MAX_FANOUT_CONSTRAINT) 128

# ---------- Tool settings ----------
set ::env(OPENROAD_NUM_THREADS) 8