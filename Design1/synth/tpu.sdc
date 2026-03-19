# ============================================================
# dnn.sdc — Timing Constraints for DNN (MS2 / Sky130)
#
# READ ME:
# - This SDC defines the timing assumptions used for synthesis,
#   APR, and timing analysis in the Sky130/OpenLane flow.
# - The values here are chosen to closely match the intent of the
#   ASAP7 MS2 (Design Compiler) constraints used earlier.
#
# WHAT YOU MAY CHANGE:
# - The clock period is automatically taken from config.tcl (CLOCK_PERIOD).
#
# WHAT YOU SHOULD NOT CHANGE:
# - Clock uncertainty, transition, I/O delays, or load values,
#   unless you fully understand the timing impact.
#
# NOTE:
# - All values are in nanoseconds (ns).
# - These are simple, project-prep-friendly constraints intended
#   for functional correctness rather than aggressive optimization.
# ============================================================

# ---------- Clock definition ----------
# Main system clock driving the DNN
create_clock -name clk -period $::env(CLOCK_PERIOD) -waveform {0 [expr $::env(CLOCK_PERIOD)/2]} [get_ports clk]
