#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
#  build-pacman.sh  —  Download and build pacman .pkg.tar.xz packages for the
#                      Mali GPU acceleration stack
# =============================================================================
#  This script downloads the latest .deb packages from
#  ar37-rs/virgl-angle releases and converts them to .pkg.tar.xz
#  for use with Termux's pacman.
#
#  Usage:
#    ./build-pacman.sh            # build all packages
#    ./build-pacman.sh virgl      # build only virglrenderer
#    ./build-pacman.sh angle      # build only angle-android
#    ./build-pacman.sh icd        # build only mesa-vulkan-icd-wrapper
#    ./build-pacman.sh clean      # remove all .deb and .pkg.tar.xz
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="$SCRIPT_DIR"

# Upstream release URLs
BASE_URL="https://github.com/ar37-rs/virgl-angle/releases/download/latest"

PKGS=(
    "virglrenderer:virglrenderer_1.1.1-latest_aarch64.deb:$BASE_URL/virglrenderer_1.1.1-latest_aarch64.deb"
    "angle-android:angle-android_2.1.2-latest.deb:$BASE_URL/angle-android_2.1.2-latest.deb"
    "mesa-vulkan-icd-wrapper:mesa-vulkan-icd-wrapper_25.0.0-1_aarch64.deb:$BASE_URL/mesa-vulkan-icd-wrapper_25.0.0-1_aarch64.deb"
)

# --- Check dependencies ------------------------------------------------
check_deps() {
    local missing=0
    for cmd in wget dpkg-deb tar; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "ERROR: '$cmd' not found." >&2
            echo "  Install with: pacman -S dpkg wget" >&2
            missing=1
        fi
    done
    [ "$missing" -eq 1 ] && exit 1
}

# --- Build a single package from .deb -----------------------------------
build_pkg() {
    local name="$1"
    local deb_file="$2"
    local url="$3"
    
    echo ""
    echo "========================================================================"
    echo "  Package: $name"
    echo "  Source:  $(basename "$deb_file")"
    echo "========================================================================"
    
    # Download if not present
    if [ ! -f "$OUTPUT_DIR/$deb_file" ]; then
        echo "==> Downloading: $url"
        wget -q --show-progress "$url" -O "$OUTPUT_DIR/$deb_file" || {
            echo "ERROR: Failed to download $url" >&2
            return 1
        }
    else
        echo "==> Already downloaded: $deb_file"
    fi
    
    # Convert to .pkg.tar.xz
    echo "==> Converting to pacman package..."
    "$SCRIPT_DIR/deb2pkg.sh" "$OUTPUT_DIR/$deb_file"
}

# --- Clean --------------------------------------------------------------
clean() {
    echo "==> Cleaning..."
    rm -f "$OUTPUT_DIR"/*.deb 2>/dev/null
    rm -f "$OUTPUT_DIR"/*.pkg.tar.xz 2>/dev/null
    echo "✅ Cleaned all .deb and .pkg.tar.xz files"
    exit 0
}

# --- Main ---------------------------------------------------------------
echo ""
echo "  ╔══════════════════════════════════════════════════════════════╗"
    echo "  ║     Mali GPU Acceleration — Pacman Package Builder        ║"
echo "  ║     for Termux (ar37-rs/virgl-angle upstream)              ║"
echo "  ╚══════════════════════════════════════════════════════════════╝"
echo ""

check_deps

# Handle commands
case "${1:-all}" in
    clean)
        clean
        ;;
    virgl|virglrenderer)
        for pkg_info in "${PKGS[@]}"; do
            IFS=':' read -r name deb url <<< "$pkg_info"
            [ "$name" = "virglrenderer" ] && build_pkg "$name" "$deb" "$url"
        done
        ;;
    angle|angle-android)
        for pkg_info in "${PKGS[@]}"; do
            IFS=':' read -r name deb url <<< "$pkg_info"
            [ "$name" = "angle-android" ] && build_pkg "$name" "$deb" "$url"
        done
        ;;
    icd|vulkan|mesa-vulkan-icd-wrapper)
        for pkg_info in "${PKGS[@]}"; do
            IFS=':' read -r name deb url <<< "$pkg_info"
            [ "$name" = "mesa-vulkan-icd-wrapper" ] && build_pkg "$name" "$deb" "$url"
        done
        ;;
    all|"")
        for pkg_info in "${PKGS[@]}"; do
            IFS=':' read -r name deb url <<< "$pkg_info"
            build_pkg "$name" "$deb" "$url"
        done
        ;;
    *)
        echo "Usage: $0 [all|virgl|angle|icd|clean]" >&2
        exit 1
        ;;
esac

echo ""
echo "  ╔══════════════════════════════════════════════════════════════╗"
echo "  ║  All packages built!                                        ║"
echo "  ║                                                            ║"
echo "  ║  Install with:                                             ║"
echo "  ║    cd packages && pacman -U *.pkg.tar.xz                   ║"
echo "  ╚══════════════════════════════════════════════════════════════╝"
echo ""
