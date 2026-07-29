#!/usr/bin/env bash
# =============================================================================
#  build-icd.sh  —  Generate mesa-vulkan-icd-wrapper for Mali GPU
# =============================================================================
#  Generates the Vulkan ICD JSON that tells the Vulkan loader where to find
#  Mali's Vulkan driver. This is needed for ANGLE to use Vulkan on Mali.
#
#  Usage:  ./ci/build-icd.sh
#  Output: packages/mesa-vulkan-icd-wrapper-25.0.0-1-aarch64.pkg.tar.xz
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
OUTPUT_DIR="$REPO_DIR/packages"

VERSION="25.0.0-1"
OUTPUT_FILE="$OUTPUT_DIR/mesa-vulkan-icd-wrapper-${VERSION}-aarch64.pkg.tar.xz"

mkdir -p "$OUTPUT_DIR"

echo "=== mesa-vulkan-icd-wrapper ${VERSION} ==="

# --- Find Mali Vulkan driver -------------------------------------------
# Common paths for Mali Vulkan driver on Android devices
MALI_PATHS=(
    "/vendor/lib64/hw/vulkan.mali.so"
    "/vendor/lib/hw/vulkan.mali.so"
    "/system/vendor/lib64/hw/vulkan.mali.so"
    "/system/lib64/hw/vulkan.mali.so"
    "/vendor/lib64/egl/libGLES_mali.so"
    "/system/lib64/egl/libGLES_mali.so"
)

MALI_DRIVER=""
for path in "${MALI_PATHS[@]}"; do
    if [ -f "$path" ]; then
        MALI_DRIVER="$path"
        echo "Found Mali driver: $MALI_DRIVER"
        break
    fi
done

if [ -z "$MALI_DRIVER" ]; then
    echo "WARNING: No Mali driver found on this system."
    echo "Using default path: /vendor/lib64/hw/vulkan.mali.so"
    MALI_DRIVER="/vendor/lib64/hw/vulkan.mali.so"
fi

# --- Create PKGDIR -----------------------------------------------------
PKGDIR=$(mktemp -p "${TMPDIR:-/tmp}" -d)
trap "rm -rf '$PKGDIR'" EXIT

ICD_DIR="$PKGDIR/data/data/com.termux/files/usr/share/vulkan/icd.d"
mkdir -p "$ICD_DIR"

# Generate ICD JSON
cat > "$ICD_DIR/mali.json" << JSONEOF
{
    "file_format_version": "1.0.0",
    "ICD": {
        "library_path": "$MALI_DRIVER",
        "api_version": "1.3"
    }
}
JSONEOF

echo "ICD JSON generated: $ICD_DIR/mali.json"
cat "$ICD_DIR/mali.json"

# --- Generate .PKGINFO -------------------------------------------------
PKG_SIZE=$(du -sk "$PKGDIR" | awk '{print $1 * 1024}')
cat > "$PKGDIR/.PKGINFO" << EOF
pkgname = mesa-vulkan-icd-wrapper
pkgver = ${VERSION}
pkgdesc = Mesa Vulkan ICD wrapper for Mali GPU (auto-detected)
url = https://github.com/$(git remote get-url origin 2>/dev/null | sed 's|.*github.com/||; s|\.git||' || echo "termux-mali-gpu-acceleration")
builddate = $(date -u +%s)
packager = termux-mali-gpu-acceleration CI
size = $PKG_SIZE
arch = aarch64
license = custom
depend = vulkan-loader-generic
EOF

# --- Package as .pkg.tar.xz --------------------------------------------
cd "$PKGDIR"
tar -cf - .PKGINFO $(find . -not -name '.PKGINFO' -not -name '.MTREE' | sed 's|^./||') | \
    xz -6 -T1 -c > "$OUTPUT_FILE"

echo ""
echo "Done: $(basename "$OUTPUT_FILE")"
echo "Install: pacman -U $(basename "$OUTPUT_FILE")"

rm -rf "$PKGDIR"
