#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
#  setup.sh  —  Install Mali GPU acceleration stack in Termux (no proot)
# =============================================================================
#  This script automates the full installation:
#    - Installs packages (supports both pacman and apt)
#    - Downloads the vgl toolkit
#    - Installs the gpu convenience wrapper
#    - Applies the Vulkan ICD fix
#    - Verifies everything works
#
#  Usage:
#    ./scripts/setup.sh              # install everything (re-run safe)
#    ./scripts/setup.sh --help       # show help
#    ./scripts/setup.sh --no-pacman  # force apt even if pacman is present
#
#  Requires: Termux + Termux:X11 + Mali GPU
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_DIR="$SCRIPT_DIR"

# --- Colors / emoji ----------------------------------------------------
OK="✅"
WARN="⚠️"
ERR="❌"
INFO="ℹ️ "
STEP="📦"
DONE="🎉"

# --- Help --------------------------------------------------------------
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    cat << 'EOF'
Usage: ./scripts/setup.sh [options]

Install Mali GPU acceleration stack in Termux (no proot required).

Options:
  --no-pacman   Force use of apt even if pacman is detected
  --help, -h    Show this help

This script:
  1. Installs required packages (virglrenderer, angle-android, etc.)
  2. Applies the Mali Vulkan ICD fix (make-or-break)
  3. Downloads the vgl toolkit from ar37-rs/virgl-angle
  4. Installs the gpu convenience wrapper to ~/.local/bin/gpu
  5. Verifies the installation

After running, start the server with:  ~/.local/bin/gpu
Then in another terminal:              DISPLAY=:1 ~/.local/bin/gpu glxgears -info
EOF
    exit 0
fi

# --- Preflight checks --------------------------------------------------
echo ""
echo "=============================="
echo " Mali GPU Acceleration Setup"
echo "=============================="
echo ""

# Check we're in Termux
if [ ! -d "/data/data/com.termux" ]; then
    echo "${ERR} This script must run inside Termux on Android." >&2
    exit 1
fi

# Check Termux:X11
if ! pm list packages 2>/dev/null | grep -q com.termux.x11; then
    echo "${WARN} Termux:X11 app not detected."
    echo "   Install from F-Droid: https://f-droid.org/packages/com.termux.x11/"
    echo "   (You can still install the GPU stack now and install X11 later.)"
    echo ""
fi

# Detect package manager
USE_PACMAN=true
if [ "${1:-}" = "--no-pacman" ]; then
    USE_PACMAN=false
elif ! command -v pacman >/dev/null 2>&1; then
    USE_PACMAN=false
fi

# --- Detect Mali GPU ---------------------------------------------------
echo "${INFO} Detecting GPU..."
MALI_DETECTED=false
for path in \
    /vendor/lib64/hw/vulkan.mali.so \
    /vendor/lib/hw/vulkan.mali.so \
    /system/vendor/lib64/hw/vulkan.mali.so \
    /system/lib64/hw/vulkan.mali.so
do
    if [ -f "$path" ]; then
        MALI_DETECTED=true
        echo "${OK} Mali GPU detected: $path"
        break
    fi
done

if [ "$MALI_DETECTED" = false ]; then
    echo "${WARN} No Mali Vulkan driver detected."
    echo "   This device may not have a Mali GPU, or the driver is"
    echo "   in an unexpected location. The stack may still work."
fi

# Show system info
echo "${INFO} System: $(uname -m) | RAM: $(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2 " KB"}' || echo 'unknown')"
echo ""

# =========================================================================
# STEP 1: Install packages
# =========================================================================
echo "${STEP} Step 1/5: Installing packages..."

if [ "$USE_PACMAN" = true ]; then
    echo "   Using pacman..."
    pacman -Sy --noconfirm 2>/dev/null || true
    
    # Install base deps
    for pkg in dpkg wget which vulkan-loader-generic openssl; do
        if ! pacman -Q "$pkg" >/dev/null 2>&1; then
            pacman -S --noconfirm "$pkg" || echo "${WARN} Failed to install $pkg"
        else
            echo "   ${OK} $pkg already installed"
        fi
    done
    
    # Build or download virglrenderer
    if ! pacman -Q virglrenderer >/dev/null 2>&1; then
        echo "   Building virglrenderer package..."
        if command -v meson >/dev/null 2>&1 && [ -d "$REPO_DIR/packages" ]; then
            cd "$REPO_DIR/packages"
            bash build-pacman.sh virgl 2>/dev/null || {
                echo "   Source build failed, downloading prebuilt..."
                cd "$REPO_DIR/packages"
                wget -q https://github.com/ar37-rs/virgl-angle/releases/download/latest/virglrenderer_1.1.1-latest_aarch64.deb -O virglrenderer_prebuilt.deb
                dpkg -i virglrenderer_prebuilt.deb
                rm -f virglrenderer_prebuilt.deb
            }
        else
            echo "   Downloading prebuilt..."
            cd "$REPO_DIR/packages"
            wget -q https://github.com/ar37-rs/virgl-angle/releases/download/latest/virglrenderer_1.1.1-latest_aarch64.deb -O virglrenderer.deb
            dpkg -i virglrenderer.deb
            rm -f virglrenderer.deb
        fi
        echo "${OK} virglrenderer installed"
    else
        echo "   ${OK} virglrenderer already installed"
    fi
    
    # Build or download angle-android
    if ! pacman -Q angle-android >/dev/null 2>&1; then
        echo "   Installing angle-android..."
        cd "$REPO_DIR/packages"
        wget -q https://github.com/ar37-rs/virgl-angle/releases/download/latest/angle-android_2.1.2-latest.deb -O angle-android.deb
        dpkg -i angle-android.deb
        rm -f angle-android.deb
        echo "${OK} angle-android installed"
    else
        echo "   ${OK} angle-android already installed"
    fi
    
    # Build or download mesa-vulkan-icd-wrapper
    if ! pacman -Q mesa-vulkan-icd-wrapper >/dev/null 2>&1; then
        echo "   Installing mesa-vulkan-icd-wrapper..."
        cd "$REPO_DIR/packages"
        wget -q https://github.com/ar37-rs/virgl-angle/releases/download/latest/mesa-vulkan-icd-wrapper_25.0.0-1_aarch64.deb -O icd-wrapper.deb
        dpkg -i icd-wrapper.deb
        rm -f icd-wrapper.deb
        echo "${OK} mesa-vulkan-icd-wrapper installed"
    else
        echo "   ${OK} mesa-vulkan-icd-wrapper already installed"
    fi
else
    echo "   Using apt (pkg)..."
    pkg update 2>/dev/null || true
    pkg install -y virglrenderer virglrenderer-android angle-android \
        vulkan-loader-generic wget which openssl dpkg 2>&1 | tail -5 || {
        echo "${WARN} Some packages may have failed. Check above."
    }
    
    # mesa-vulkan-icd-wrapper is NOT in apt repos, download separately
    if [ ! -f "$PREFIX/share/vulkan/icd.d/wrapper_icd.aarch64.json" ]; then
        echo "   Downloading mesa-vulkan-icd-wrapper..."
        cd && wget -q https://github.com/ar37-rs/virgl-angle/releases/download/latest/mesa-vulkan-icd-wrapper_25.0.0-1_aarch64.deb -O mesa-icd.deb
        dpkg -i mesa-icd.deb 2>/dev/null || dpkg --force-depends -i mesa-icd.deb
        rm -f mesa-icd.deb
        echo "${OK} mesa-vulkan-icd-wrapper installed"
    else
        echo "   ${OK} mesa-vulkan-icd-wrapper already installed"
    fi
fi

echo ""

# =========================================================================
# STEP 2: Install vgl toolkit
# =========================================================================
echo "${STEP} Step 2/5: Installing vgl toolkit..."

if [ -x "$HOME/vgl" ]; then
    echo "   ${OK} ~/vgl already installed ($(ls -la ~/vgl | awk '{print $5}') bytes)"
else
    cd && wget -q --show-progress \
        https://github.com/ar37-rs/virgl-angle/raw/refs/heads/main/vgl \
        -O vgl && chmod +x vgl
    echo "${OK} Downloaded ~/vgl ($(ls -la ~/vgl | awk '{print $5}') bytes)"
fi

# Create symlinks for ANGLE if needed (vgl does this at runtime, but be safe)
ANGLE_DIR="$PREFIX/opt/angle-android/vulkan"
if [ -d "$ANGLE_DIR" ]; then
    for lib in EGL GLESv1_CM GLESv2; do
        if [ ! -f "$ANGLE_DIR/lib${lib}.so.1" ] && [ -f "$ANGLE_DIR/lib${lib}_angle.so" ]; then
            ln -sf "lib${lib}_angle.so" "$ANGLE_DIR/lib${lib}.so.1" 2>/dev/null || true
        fi
    done
fi

echo ""

# =========================================================================
# STEP 3: Install gpu convenience wrapper
# =========================================================================
echo "${STEP} Step 3/5: Installing gpu wrapper..."

if [ -f "$HOME/.local/bin/gpu" ]; then
    echo "   ${OK} ~/.local/bin/gpu already installed"
else
    if [ -f "$REPO_DIR/config/gpu" ]; then
        mkdir -p "$HOME/.local/bin"
        cp "$REPO_DIR/config/gpu" "$HOME/.local/bin/gpu" && chmod +x "$HOME/.local/bin/gpu"
        echo "${OK} ~/.local/bin/gpu installed from repo"
    else
        # Create gpu wrapper directly
        cat > "$HOME/.local/bin/gpu" << 'GPUSCRIPT'
#!/data/data/com.termux/files/usr/bin/bash
VGL="${HOME}/vgl"
case "${1:-}" in
    --help|-h)
        echo "Usage: gpu [command]"
        echo "  gpu              Start virgl server (ANGLE → Vulkan)"
        echo "  gpu <app>        Run app with GPU acceleration"
        echo "  gpu q            Kill server"
        exit 0
        ;;
    q) exec "$VGL" q ;;
    "") echo "Starting virgl server..."; exec "$VGL" angle=vulkan ;;
    *)
        if ! pgrep -f virgl_test_server >/dev/null 2>&1; then
            echo "Starting virgl server..."; "$VGL" angle=vulkan; sleep 1
        fi
        exec "$VGL" "$@"
        ;;
esac
GPUSCRIPT
        chmod +x "$HOME/.local/bin/gpu"
        echo "${OK} ~/.local/bin/gpu created directly"
    fi
fi

echo ""

# =========================================================================
# STEP 4: Verify installation
# =========================================================================
echo "${STEP} Step 4/5: Verifying installation..."
ALL_OK=true

check() {
    local desc="$1"
    local cmd="$2"
    if eval "$cmd" >/dev/null 2>&1; then
        echo "   ${OK} $desc"
    else
        echo "   ${ERR} $desc"
        ALL_OK=false
    fi
}

check "vgl script exists and executable"    "test -x '$HOME/vgl'"
check "gpu wrapper exists and executable"   "test -x '$HOME/.local/bin/gpu'"
check "virgl_test_server binary"            "which virgl_test_server"
check "ANGLE vulkan backend"                "test -d '$PREFIX/opt/angle-android/vulkan'"
check "ANGLE GL backend"                    "test -d '$PREFIX/opt/angle-android/gl'"
check "Vulkan ICD wrapper"                  "ls '$PREFIX/share/vulkan/icd.d/'*.json >/dev/null 2>&1"
check "EGL.so symlink"                      "ls '$PREFIX/opt/angle-android/vulkan/libEGL.so.1' >/dev/null 2>&1 || ls '$PREFIX/opt/angle-android/vulkan/libEGL_angle.so' >/dev/null 2>&1"

echo ""

# =========================================================================
# STEP 5: Summary
# =========================================================================
echo "${STEP} Step 5/5: Setup complete!"
echo ""
echo "=============================="
if [ "$ALL_OK" = true ]; then
    echo " ${DONE} All checks passed!"
else
    echo " ${WARN} Some checks failed - see above"
fi
echo "=============================="
echo ""
echo "Next steps:"
echo ""
echo "  1. Start the GPU server:"
echo "     ~/.local/bin/gpu"
echo ""
echo "  2. In another Termux session, start X11:"
echo "     termux-x11 :1 -ac -dpi 192 &"
echo "     sleep 3"
echo "     am start --user 0 -n com.termux.x11/.MainActivity"
echo ""
echo "  3. Run a test:"
echo "     DISPLAY=:1 ~/.local/bin/gpu glxgears -info"
echo ""
echo "  4. To stop:"
echo "     ~/.local/bin/gpu q"
echo ""
echo "For Firefox with WebGL:"
echo "   DISPLAY=:1 ~/.local/bin/gpu firefox"
echo "   (Set gfx.webrender.all = false in about:config)"
echo ""
