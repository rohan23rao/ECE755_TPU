#!/usr/bin/env bash
# =============================================================================
# run_hier.sh — Two-step hierarchical flow for design2_hier
#
# Usage:
#   ./run_hier.sh              # run both steps
#   ./run_hier.sh pe           # step 1 only: harden PE
#   ./run_hier.sh top          # step 2 only: integrate (PE must be hardened)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SRC_DIR="$REPO_ROOT/Design2/src"

PDK_ROOT="${PDK_ROOT:-$HOME/.volare}"
PDK="sky130A"
OL_IMAGE="${OL_IMAGE:-ghcr.io/efabless/openlane2:2.3.10}"
RUN_TAG="${RUN_TAG:-$(date +%Y%m%d_%H%M%S)}"

copy_src() {
    local DIR="$1"
    rm -rf "$DIR/src"
    mkdir -p "$DIR/src"
    cp "$SRC_DIR"/*.sv "$DIR/src/" 2>/dev/null || true
    cp "$SRC_DIR"/*.v  "$DIR/src/" 2>/dev/null || true
    # Add black-box stub for top-level
    cp "$SCRIPT_DIR/gemm_pe_bbox.v" "$DIR/src/" 2>/dev/null || true
}

run_module() {
    local MODULE_DIR="$1"
    local NAME="$(basename "$MODULE_DIR")"

    copy_src "$MODULE_DIR"

    echo "============================================"
    echo " Running: $NAME"
    echo " Tag:     $RUN_TAG"
    echo "============================================"

    docker run --rm \
        -v "$PDK_ROOT:$PDK_ROOT" \
        -v "$REPO_ROOT:$REPO_ROOT" \
        -w "$MODULE_DIR" \
        "$OL_IMAGE" \
        python3 -m openlane \
            --pdk-root "$PDK_ROOT" \
            --pdk "$PDK" \
            --run-tag "$RUN_TAG" \
            config.json
}

# ── Step 1: Harden PE ────────────────────────────────────────────────────────
run_pe() {
    run_module "$SCRIPT_DIR/gemm_pe"
    echo ""
    echo "[PE DONE] Outputs at: gemm_pe/runs/$RUN_TAG/final/"
    echo "  LEF: gemm_pe/runs/$RUN_TAG/final/lef/gemm_pe.lef"
    echo "  GDS: gemm_pe/runs/$RUN_TAG/final/gds/gemm_pe.gds"
}

# ── Step 2: Integrate PE into top ─────────────────────────────────────────────
run_top() {
    # Find latest PE run
    local PE_RUN
    PE_RUN="$(ls -td "$SCRIPT_DIR/gemm_pe/runs/"*/ 2>/dev/null | head -1)"
    if [[ -z "$PE_RUN" ]]; then
        echo "[ERROR] No PE run found. Run './run_hier.sh pe' first."
        exit 1
    fi

    local PE_LEF="$PE_RUN/final/lef/gemm_pe.lef"
    local PE_GDS="$PE_RUN/final/gds/gemm_pe.gds"
    local PE_LIB_DIR="$PE_RUN/final/lib"

    if [[ ! -f "$PE_LEF" || ! -f "$PE_GDS" ]]; then
        echo "[ERROR] PE outputs not found at: $PE_RUN/final/"
        exit 1
    fi

    echo "[INFO] Using PE macro from: $(basename "$(dirname "$PE_RUN")")/$(basename "$PE_RUN")"

    # Patch config.json with actual PE paths (LEF, GDS, Liberty)
    local TOP_DIR="$SCRIPT_DIR/gemm_top"
    copy_src "$TOP_DIR"

    local CONFIG="$TOP_DIR/config.json"
    python3 -c "
import json, glob, os
with open('$CONFIG') as f:
    cfg = json.load(f)
cfg['EXTRA_LEFS'] = ['$PE_LEF']
cfg['EXTRA_GDS_FILES'] = ['$PE_GDS']
# Collect all Liberty files for STA corners
libs = sorted(glob.glob('$PE_LIB_DIR/*/*.lib'))
if libs:
    cfg['EXTRA_LIBS'] = libs
    print(f'Found {len(libs)} Liberty files')
with open('$CONFIG', 'w') as f:
    json.dump(cfg, f, indent=2)
print('Patched EXTRA_LEFS, EXTRA_GDS_FILES, and EXTRA_LIBS')
"

    run_module "$TOP_DIR"
}

# ── Main ──────────────────────────────────────────────────────────────────────
case "${1:-all}" in
    pe)  run_pe ;;
    top) run_top ;;
    all) run_pe && run_top ;;
    *)   echo "Usage: $0 [pe|top|all]"; exit 1 ;;
esac
