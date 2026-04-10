#!/usr/bin/env bash
# =============================================================================
# run_all.sh — Run all Design2 modules through OpenLane2 in parallel tiers
#
# Tier 1 (leaf modules, no custom sub-hierarchy):
#   FloatP4x16, FloatP16x4, fp16_adder, gemm_control_unit, gemm_fifo_array
#
# Tier 2 (depend on tier 1 modules):
#   gemm_pe, vector_unit
#
# All lower modules restricted to met1-met3 (RT_MAX_LAYER) to reserve
# met4/met5 for top-level hierarchical routing.
#
# Usage:
#   ./run_all.sh                          # all modules, tiered
#   ./run_all.sh gemm_pe vector_unit      # specific modules only
#   JOBS=4 ./run_all.sh                   # override parallelism
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SRC_DIR="$REPO_ROOT/Design2/src"

RUN_TAG="${RUN_TAG:-$(date +%Y%m%d_%H%M%S)}"
JOBS="${JOBS:-3}"

# Tiered ordering
TIER1=(FloatP4x16 FloatP16x4 fp16_adder gemm_control_unit gemm_fifo_array)
TIER2=(gemm_pe vector_unit)

echo "================================================================"
echo "  Design2 Modules — OpenLane2 (Docker, parallel)"
echo "  Tag:     $RUN_TAG"
echo "  Jobs:    $JOBS"
echo "  Source:  $SRC_DIR"
echo "================================================================"
echo ""

# ── Copy source files into a module's config dir ─────────────────────────────
copy_src() {
    local MODULE_DIR="$1"
    rm -rf "$MODULE_DIR/src"
    mkdir -p "$MODULE_DIR/src"
    cp "$SRC_DIR"/*.sv "$MODULE_DIR/src/" 2>/dev/null || true
    cp "$SRC_DIR"/*.v  "$MODULE_DIR/src/" 2>/dev/null || true
}

# ── Run one module (blocking) ────────────────────────────────────────────────
run_module() {
    local MODULE="$1"
    local MODULE_DIR="$SCRIPT_DIR/$MODULE"

    if [[ ! -f "$MODULE_DIR/config.json" ]]; then
        echo "[SKIP] $MODULE — config.json not found"
        return 0
    fi

    copy_src "$MODULE_DIR"

    mkdir -p "$SCRIPT_DIR/logs"
    local LOGFILE="$SCRIPT_DIR/logs/${MODULE}_${RUN_TAG}.log"
    echo "[START] $MODULE → $LOGFILE"

    python3 -m openlane --dockerized \
        --run-tag "$RUN_TAG" \
        "$MODULE_DIR/config.json" \
        2>&1 | tee "$LOGFILE"

    local RC=${PIPESTATUS[0]}

    if [[ $RC -eq 0 ]]; then
        echo "[DONE]  $MODULE ✓"
    else
        echo "[FAIL]  $MODULE ✗ (exit $RC)"
    fi

    return $RC
}

# ── Run a list of modules in parallel (up to $JOBS at once) ──────────────────
run_tier() {
    local TIER_NAME="$1"; shift
    local MODULES=("$@")
    local PIDS=()
    local NAMES=()
    local FAILED=()

    echo "── Tier $TIER_NAME: ${MODULES[*]} ──"

    local SLOT=0
    for MODULE in "${MODULES[@]}"; do
        # Throttle: wait for a slot if at job limit
        while [[ ${#PIDS[@]} -ge $JOBS ]]; do
            for i in "${!PIDS[@]}"; do
                if ! kill -0 "${PIDS[$i]}" 2>/dev/null; then
                    wait "${PIDS[$i]}" && RC=0 || RC=$?
                    if [[ $RC -ne 0 ]]; then
                        FAILED+=("${NAMES[$i]}")
                    fi
                    unset 'PIDS[$i]'
                    unset 'NAMES[$i]'
                    PIDS=("${PIDS[@]}")
                    NAMES=("${NAMES[@]}")
                    break
                fi
            done
            sleep 2
        done

        run_module "$MODULE" &
        PIDS+=($!)
        NAMES+=("$MODULE")
    done

    # Wait for remaining
    for i in "${!PIDS[@]}"; do
        wait "${PIDS[$i]}" && RC=0 || RC=$?
        if [[ $RC -ne 0 ]]; then
            FAILED+=("${NAMES[$i]}")
        fi
    done

    if [[ ${#FAILED[@]} -gt 0 ]]; then
        echo ""
        echo "[TIER $TIER_NAME FAILED] ${FAILED[*]}"
        return 1
    fi

    echo "[TIER $TIER_NAME PASSED]"
    echo ""
    return 0
}

# ── Specific modules mode (args provided) ────────────────────────────────────
if [[ $# -gt 0 ]]; then
    run_tier "custom" "$@"
    EXIT=$?
    echo "================================================================"
    echo "  Run tag: $RUN_TAG"
    [[ $EXIT -eq 0 ]] && echo "  All modules completed." || echo "  Some modules FAILED."
    echo "================================================================"
    exit $EXIT
fi

# ── Full tiered run ──────────────────────────────────────────────────────────
run_tier 1 "${TIER1[@]}" || { echo "Aborting — fix Tier 1 failures before Tier 2."; exit 1; }
run_tier 2 "${TIER2[@]}" || { echo "Aborting — Tier 2 failed."; exit 1; }

echo "================================================================"
echo "  Run tag: $RUN_TAG"
echo "  All tiers completed successfully."
echo "================================================================"
