#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
#  check-acceleration.sh — Verifica que la aceleración GPU esté funcionando
# =============================================================================
#  Usage:  ./check-acceleration.sh
#  Output: Diagnóstico completo del stack virgl → ANGLE → Vulkan → Mali
# =============================================================================

set -euo pipefail

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   Mali GPU Acceleration - Diagnostic Check                 ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# Check 1: virgl_test_server
echo "🔍 [1/6] virgl_test_server..."
if pgrep -f virgl_test_server >/dev/null 2>&1; then
    echo "   ✅ Server running (PID: $(pgrep -f virgl_test_server | head -1))"
else
    echo "   ❌ Server NOT running. Start with: ~/.local/bin/gpu"
fi

# Check 2: vgl script
echo "🔍 [2/6] vgl toolkit..."
if [ -x "$HOME/vgl" ]; then
    echo "   ✅ ~/vgl found ($(ls -la ~/vgl | awk '{print $5}') bytes)"
else
    echo "   ❌ ~/vgl not found. Install: cd && wget ... && chmod +x"
fi

# Check 3: gpu wrapper
echo "🔍 [3/6] gpu wrapper..."
if [ -x "$HOME/.local/bin/gpu" ]; then
    echo "   ✅ ~/.local/bin/gpu found"
else
    echo "   ⚠️  ~/.local/bin/gpu not found (optional)"
fi

# Check 4: virgl renderer binary
echo "🔍 [4/6] virglrenderer package..."
if command -v virgl_test_server >/dev/null 2>&1; then
    echo "   ✅ virgl_test_server in PATH"
else
    echo "   ❌ virgl_test_server not found. Install virglrenderer package."
fi

# Check 5: ANGLE backends
echo "🔍 [5/6] ANGLE libraries..."
ANGLE_DIR="$PREFIX/opt/angle-android"
if [ -d "$ANGLE_DIR/vulkan" ]; then
    echo "   ✅ ANGLE vulkan backend: $(ls $ANGLE_DIR/vulkan/libEGL_angle.so 2>/dev/null || echo 'libEGL_angle.so found')"
else
    echo "   ❌ ANGLE vulkan backend missing. Install angle-android package."
fi
if [ -d "$ANGLE_DIR/gl" ]; then
    echo "   ✅ ANGLE gl backend present"
else
    echo "   ⚠️  ANGLE gl backend missing"
fi

# Check 6: Vulkan ICD
echo "🔍 [6/6] Vulkan ICD..."
ICD_DIR="$PREFIX/share/vulkan/icd.d"
if [ -d "$ICD_DIR" ]; then
    ICD_FILES=$(ls "$ICD_DIR"/*.json 2>/dev/null || true)
    if [ -n "$ICD_FILES" ]; then
        echo "   ✅ ICD files found:"
        for f in $ICD_FILES; do
            echo "      - $(basename "$f")"
            head -3 "$f" 2>/dev/null | sed 's/^/        /'
        done
    else
        echo "   ❌ No ICD JSON files in $ICD_DIR"
    fi
else
    echo "   ❌ ICD directory missing: $ICD_DIR"
fi

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"

# Final summary
if command -v virgl_test_server >/dev/null 2>&1 && [ -d "$ANGLE_DIR/vulkan" ]; then
    echo "║   ✅ Stack appears functional                               ║"
    echo "║   Start server: ~/.local/bin/gpu                           ║"
    echo "║   Test with:    DISPLAY=:1 ~/.local/bin/gpu glxgears -info ║"
else
    echo "║   ❌ Stack is incomplete - fix issues above                 ║"
fi
echo "╚══════════════════════════════════════════════════════════════╝"
