#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# run_flow.sh — Run OpenLane2 Docker flow for a given config
#
# Usage:
#   ./run_flow.sh <config_dir>              # auto-tagged with timestamp
#   ./run_flow.sh <config_dir> -tag my_run  # named run
#
# Examples:
#   ./run_flow.sh ../design2_flat
#   ./run_flow.sh ../design2_flat -tag baseline_20ns
#   ./run_flow.sh ../design2_hier/gemm_pe -tag pe_macro
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <config_dir> [-tag <run_tag>]"
    echo ""
    echo "Config directories:"
    echo "  design2_flat          Full Design2 (gemm_top, flat)"
    echo "  design2_hier/gemm_pe  Harden PE macro"
    echo "  design2_hier/gemm_top Top-level with PE macros"
    echo "  design1               Design1 reference"
    exit 1
fi

CONFIG_DIR="$(cd "$1" && pwd)"
shift

# Parse optional -tag
TAG_ARGS=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -tag)
            TAG_ARGS="--run-tag $2"
            shift 2
            ;;
        *)
            echo "Unknown argument: $1"
            exit 1
            ;;
    esac
done

CONFIG_FILE="$CONFIG_DIR/config.json"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "[ERROR] config.json not found in: $CONFIG_DIR"
    exit 2
fi

# Determine source directory from config dir name
CONFIG_NAME="$(basename "$CONFIG_DIR")"
CONFIG_PARENT="$(basename "$(dirname "$CONFIG_DIR")")"

if [[ "$CONFIG_NAME" == "design1" ]]; then
    SRC_DIR="$REPO_ROOT/Design1/src"
else
    SRC_DIR="$REPO_ROOT/Design2/src"
fi

if [[ ! -d "$SRC_DIR" ]]; then
    echo "[ERROR] Source directory not found: $SRC_DIR"
    exit 2
fi

# Copy source files into config dir so dir:: paths resolve inside Docker
echo "[INFO] Copying source files from $SRC_DIR ..."
rm -rf "$CONFIG_DIR/src"
mkdir -p "$CONFIG_DIR/src"
cp "$SRC_DIR"/*.sv "$CONFIG_DIR/src/" 2>/dev/null || true
cp "$SRC_DIR"/*.v  "$CONFIG_DIR/src/" 2>/dev/null || true

echo "============================================"
echo " OpenLane2 Docker Flow"
echo "============================================"
echo " Config dir : $CONFIG_DIR"
echo " Config file: $CONFIG_FILE"
echo " Source from: $SRC_DIR"
echo " Repo root  : $REPO_ROOT"
echo " Tag        : ${TAG_ARGS:-<auto>}"
echo "============================================"

python3 -m openlane --dockerized \
    $TAG_ARGS \
    "$CONFIG_FILE"
