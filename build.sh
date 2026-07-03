#!/bin/bash
# Exit immediately if any command fails
set -e

# Resolve absolute paths based on the script's location
ZICRO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE_DIR="$(cd "$ZICRO_DIR/../zicro-wgpu-bridge" && pwd)"

echo "=========================================="
echo " Building Bridge (Rust cdylib)"
echo "=========================================="
cd "$BRIDGE_DIR"
cargo build --release

# Set dynamic linker path to locate the shared library (.so)
export LD_LIBRARY_PATH="$BRIDGE_DIR/target/release:$LD_LIBRARY_PATH"

echo ""
echo "=========================================="
echo " Building Zicro (Zig)"
echo "=========================================="
cd "$ZICRO_DIR"
zig build "$@"

echo ""
echo "=========================================="
echo " Build Completed Successfully!"
echo "=========================================="
