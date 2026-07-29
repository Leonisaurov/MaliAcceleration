#!/usr/bin/env bash
# =============================================================================
#  build-angle.sh  —  Cross-compile ANGLE for Termux aarch64 in CI
# =============================================================================
#  Compiles Google ANGLE from source with GN/Ninja targeting Android aarch64.
#  Produces a .pkg.tar.xz for two backends: vulkan, vulkan-null (gl excluded:
#  broken on Mali + bug in NDK r27 ARM32).
#
#  Usage:  ./ci/build-angle.sh
#
#  Env vars:
#    NDK_DIR    - Android NDK path (default: $ANDROID_NDK_ROOT)
#    NINJA_JOBS - Parallel jobs (default: $(nproc))
#
#  Requires: depot_tools in PATH (gclient, gn, ninja)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
OUTPUT_DIR="$REPO_DIR/packages"
mkdir -p "$OUTPUT_DIR"

NDK_DIR="${NDK_DIR:-${ANDROID_NDK_ROOT:-}}"
NINJA_JOBS="${NINJA_JOBS:-$(nproc 2>/dev/null || echo 2)}"
API_LEVEL=24
ARCH="arm64"

# --- Check prerequisites -----------------------------------------------
if [ -z "$NDK_DIR" ] || [ ! -d "$NDK_DIR" ]; then
    echo "ERROR: NDK_DIR not set or not found. Set ANDROID_NDK_ROOT or NDK_DIR." >&2
    exit 1
fi

if ! command -v gn >/dev/null 2>&1; then
    echo "ERROR: 'gn' not found. Install depot_tools and add to PATH." >&2
    exit 1
fi

if ! command -v ninja >/dev/null 2>&1; then
    echo "ERROR: 'ninja' not found." >&2
    exit 1
fi

echo "=== Building ANGLE for Termux aarch64 ==="
echo "NDK:       $NDK_DIR"
echo "Jobs:      $NINJA_JOBS"
echo ""

BUILD_BASE="${TMPDIR:-/tmp}/angle-build"
mkdir -p "$BUILD_BASE"

# --- Determine version from ANGLE source --------------------------------
# If we're in a pre-fetched source, get the commit position
ANGLE_SRC="${ANGLE_SRC_DIR:-$BUILD_BASE/angle-source/angle}"
if [ -d "$ANGLE_SRC" ]; then
    cd "$ANGLE_SRC"
    COMMIT_HASH=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
    COMMIT_POSITION=$(git rev-list HEAD --count 2>/dev/null || echo "0")
else
    COMMIT_HASH="unknown"
    COMMIT_POSITION="0"
fi

VERSION="2.1.${COMMIT_POSITION}-${COMMIT_HASH}"
OUTPUT_FILE="$OUTPUT_DIR/angle-android-${VERSION}-aarch64.pkg.tar.xz"

echo "Version: $VERSION"
echo "Output:  $OUTPUT_FILE"
echo ""

# --- Patch NDK r27 hardware_buffer.h (1UL << 32 bug on ARM32) ---------
HWBUF="$NDK_DIR/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/include/android/hardware_buffer.h"
if [ -f "$HWBUF" ] && grep -q "1UL << 32" "$HWBUF" 2>/dev/null; then
    echo "Patching NDK hardware_buffer.h (1UL -> 1ULL for ARM32 compat)..."
    sed -i 's/1UL << 32/1ULL << 32/g' "$HWBUF"
    echo "  Patched: $(grep -c "1ULL << 32" "$HWBUF") occurrence(s)"
fi

# --- Detect Android NDK path for GN ------------------------------------
# GN needs android_ndk_root pointing to the NDK
# The NDK directory from setup-ndk action is typically:
# /usr/local/lib/android/sdk/ndk/<version>/
echo "Using NDK at: $NDK_DIR"

# --- Build configurations ----------------------------------------------
declare -A CONFIGS
CONFIGS["vulkan"]="angle_enable_gl=false angle_enable_vulkan=true angle_use_vulkan_null_display=false"
CONFIGS["vulkan-null"]="angle_enable_gl=false angle_enable_vulkan=true angle_use_vulkan_null_display=true"
# gl backend disabled: broken on Mali GPUs, also fails in NDK r27 (ARM32 bug)
# CONFIGS["gl"]="angle_enable_gl=true angle_enable_vulkan=false angle_use_vulkan_null_display=false"

# --- PKG_DIR for staging installation ----------------------------------
PKG_DIR="$BUILD_BASE/pkg"
rm -rf "$PKG_DIR"

for variant in vulkan vulkan-null; do
    echo ""
    echo "========================================================================"
    echo "  Building ANGLE backend: $variant"
    echo "========================================================================"
    
    BUILD_DIR="$BUILD_BASE/out/$variant"
    
    GN_ARGS="
        target_os = \"android\"
        target_cpu = \"${ARCH}\"
        is_component_build = false
        is_debug = false
        angle_assert_always_on = false
        ${CONFIGS[$variant]}
        android64_ndk_api_level = ${API_LEVEL}
        android_ndk_root = \"${NDK_DIR}\"
        angle_build_tests = false
        angle_expose_non_conformant_extensions_and_versions = true
    "
    
    # --- GN gen ----------------------------------------------------------------
    echo "  GN gen..."
    rm -rf "$BUILD_DIR"
    cd "$ANGLE_SRC"
    gn gen "$BUILD_DIR" --args="$GN_ARGS" 2>&1 || {
        echo "ERROR: GN gen failed for $variant" >&2
        exit 1
    }
    
    # --- Ninja build -----------------------------------------------------------
    echo "  Ninja build (${NINJA_JOBS} jobs)..."
    ninja -C "$BUILD_DIR" -j"${NINJA_JOBS}" 2>&1 | tail -20 || {
        echo "ERROR: Ninja build failed for $variant" >&2
        exit 1
    }
    
    # --- Extract .so files from AngleLibraries.apk -----------------------------
    echo "  Extracting .so files..."
    APK_PATH="$BUILD_DIR/apks/AngleLibraries.apk"
    
    if [ ! -f "$APK_PATH" ]; then
        echo "WARNING: AngleLibraries.apk not found, looking for .so files directly..."
        # Some ANGLE versions output .so files directly
        find "$BUILD_DIR" -name "*.so" -path "*/lib/*" 2>/dev/null | head -10
        # Try direct lib output
        SO_DIR="$BUILD_DIR"
        find "$SO_DIR" -name "libEGL*" -o -name "libGLES*" -o -name "libVk*" 2>/dev/null | head -10
        
        # Fallback: look for .so in common locations
        SO_FILES=$(find "$BUILD_DIR" -name "libEGL_angle.so" -o -name "libGLESv2_angle.so" -o -name "libGLESv1_CM_angle.so" 2>/dev/null)
        if [ -n "$SO_FILES" ]; then
            echo "  Found .so files directly!"
            INSTALL_DIR="$PKG_DIR/data/data/com.termux/files/usr/opt/angle-android/$variant"
            mkdir -p "$INSTALL_DIR"
            echo "$SO_FILES" | while read -r so; do
                cp -v "$so" "$INSTALL_DIR/"
            done
        else
            echo "ERROR: No .so files found for $variant" >&2
            exit 1
        fi
    else
        # Extract from APK
        echo "  Extracting from APK..."
        EXTRACT_DIR="$BUILD_BASE/apk-extract/$variant"
        mkdir -p "$EXTRACT_DIR"
        cd "$EXTRACT_DIR"
        unzip -q -o "$APK_PATH" 2>/dev/null || {
            echo "ERROR: Failed to extract APK" >&2
            exit 1
        }
        
        # Find and copy .so files for our architecture
        INSTALL_DIR="$PKG_DIR/data/data/com.termux/files/usr/opt/angle-android/$variant"
        mkdir -p "$INSTALL_DIR"
        
        # Files are typically in lib/arm64-v8a/
        if [ -d "lib/arm64-v8a" ]; then
            cp -v lib/arm64-v8a/*.so "$INSTALL_DIR/" 2>/dev/null || true
        fi
        # Also try lib/aarch64/
        if [ -d "lib/aarch64" ]; then
            cp -v lib/aarch64/*.so "$INSTALL_DIR/" 2>/dev/null || true
        fi
        
        # Verify we got something
        if [ -z "$(ls -A "$INSTALL_DIR" 2>/dev/null)" ]; then
            echo "ERROR: No .so files found in extracted APK for $variant" >&2
            echo "Contents of extract dir:"
            find "$EXTRACT_DIR" -name "*.so" 2>/dev/null | head -20
            exit 1
        fi
    fi
    
    echo "  $variant: $(ls -1 "$INSTALL_DIR" 2>/dev/null | wc -l) .so files"
done

echo ""
echo "=== Creating .PKGINFO and packaging ==="

# --- Generate .PKGINFO -------------------------------------------------
PKG_SIZE=$(du -sk "$PKG_DIR" | awk '{print $1 * 1024}')
cat > "$PKG_DIR/.PKGINFO" << EOF
pkgname = angle-android
pkgver = ${VERSION}
pkgdesc = Google ANGLE for Termux (GLES to Vulkan translator). Cross-compiled.
url = https://chromium.googlesource.com/angle/angle
builddate = $(date -u +%s)
packager = termux-mali-gpu-acceleration CI
size = $PKG_SIZE
arch = aarch64
license = BSD-3-Clause, Apache-2.0
depend = vulkan-loader-generic
EOF

# --- Package as .pkg.tar.xz --------------------------------------------
cd "$PKG_DIR"
tar -cf - .PKGINFO $(find . -not -name '.PKGINFO' -not -name '.MTREE' | sed 's|^./||') | \
    xz -6 -T1 -c > "$OUTPUT_FILE"

echo ""
echo "Done: $(basename "$OUTPUT_FILE") ($(( $(stat -c%s "$OUTPUT_FILE" 2>/dev/null || echo 0) / 1024 ))KB)"
echo "Install: pacman -U $(basename "$OUTPUT_FILE")"

# --- Verify package contents --------------------------------------------
echo ""
echo "=== Package contents ==="
tar -tJf "$OUTPUT_FILE" | grep -E "\.so$" | head -20
echo "... ($(tar -tJf "$OUTPUT_FILE" | grep -c "\.so$") .so files total)"
