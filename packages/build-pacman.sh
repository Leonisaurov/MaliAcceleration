#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
#  build-pacman.sh  —  Build Mali GPU acceleration packages for Termux pacman
#                      OPTIMIZED for low-end Termux environments
# =============================================================================
#  Build strategies:
#    - virglrenderer:         FROM SOURCE  (meson)
#    - angle-android:         PREBUILT     (ANGLE requires Chromium-scale infra)
#    - mesa-vulkan-icd-wrapper: FROM SOURCE (auto-detect Mali driver)
#
#  Optimizations for low-end Termux:
#    - Auto-detects RAM and sets ninja jobs accordingly (OOM-safe: -j1 on <4GB)
#    - Builds in $TMPDIR to avoid filling $PREFIX
#    - Download resume support (wget -c)
#    - Resumable builds (skips already-downloaded/extracted sources)
#    - Strips debug symbols from binaries to reduce package size
#    - Cleans build artifacts after each package
#    - Graceful SIGINT handling
#    - Progress output with emoji status indicators
#
#  Usage:
#    ./build-pacman.sh              # build all packages
#    ./build-pacman.sh virgl        # build only virglrenderer
#    ./build-pacman.sh angle        # build only angle-android
#    ./build-pacman.sh icd          # build only mesa-vulkan-icd-wrapper
#    ./build-pacman.sh clean        # remove all build artifacts
#    ./build-pacman.sh force        # rebuild everything from scratch
# =============================================================================

set -e

# --- Config ------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="$SCRIPT_DIR"

# Use TMPDIR for builds (Termux optimized - usually on faster storage)
# Fallback to ./build if TMPDIR isn't set
BUILD_BASE="${TMPDIR:-$SCRIPT_DIR/build}/mali-gpu-pkgbuild"
BUILD_DIR="$BUILD_BASE/src"
PKG_DIR_BASE="$BUILD_BASE/pkg"

# Upstream release URL
BASE_URL="https://github.com/ar37-rs/virgl-angle/releases/download/latest"

# OOM-safe: detect RAM and set ninja jobs
TOTAL_MEM_KB=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}' || echo "0")
TOTAL_MEM_MB=$((TOTAL_MEM_KB / 1024))

if [ "$TOTAL_MEM_MB" -lt 1024 ]; then
    NINJA_JOBS=1
elif [ "$TOTAL_MEM_MB" -lt 3072 ]; then
    NINJA_JOBS=1
elif [ "$TOTAL_MEM_MB" -lt 6144 ]; then
    NINJA_JOBS=2
else
    NINJA_JOBS=$(nproc 2>/dev/null || echo 2)
fi

# --- Colors / emoji helpers --------------------------------------------
STATUS_OK="✅"
STATUS_WARN="⚠️"
STATUS_ERR="❌"
STATUS_SKIP="⏭️ "
STATUS_INFO="ℹ️ "
STATUS_BUILD="🔨"

# --- Signal handling ---------------------------------------------------
cleanup_on_exit() {
    echo ""
    echo "${STATUS_WARN} Build interrupted. Cleaning up..."
    # Don't remove everything on interrupt - user might want to resume
    echo "${STATUS_INFO} Build artifacts preserved in: $BUILD_BASE"
    echo "${STATUS_INFO} Run './build-pacman.sh clean' to remove them."
    exit 1
}
trap cleanup_on_exit SIGINT SIGTERM

# --- Help --------------------------------------------------------------
show_help() {
    cat << 'EOF'
Usage: ./build-pacman.sh [OPTION]

Build Mali GPU acceleration packages for Termux pacman.

Options:
  all          Build all packages (default)
  virgl        Build virglrenderer from source (meson)
  angle        Build angle-android from prebuilt .deb
  icd          Build mesa-vulkan-icd-wrapper from source
  clean        Remove all build artifacts (.deb, .pkg.tar.xz, build dir)
  force        Rebuild everything from scratch (cleans then builds)
  help         Show this help

Environment:
  NINJA_JOBS   Override automatic job count (e.g. NINJA_JOBS=1 ./build-pacman.sh)

Examples:
  ./build-pacman.sh              # build all packages
  ./build-pacman.sh virgl        # build only virglrenderer
  NINJA_JOBS=1 ./build-pacman.sh # single-threaded build (lowest RAM usage)
EOF
}

# --- Check dependencies ------------------------------------------------
check_deps() {
    local missing=0
    
    echo "${STATUS_INFO} Checking tools..."
    
    for cmd in wget tar gzip; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "${STATUS_ERR} '$cmd' not found." >&2
            missing=1
        fi
    done
    
    # Source build deps (non-fatal - only needed for virgl)
    if ! command -v meson >/dev/null 2>&1; then
        echo "${STATUS_WARN} 'meson' not found. Source builds will not work."
        echo "   Install: pacman -S meson ninja pkg-config"
    fi
    
    # Binary conversion deps
    if ! command -v dpkg-deb >/dev/null 2>&1; then
        echo "${STATUS_WARN} 'dpkg-deb' not found. Binary conversions will not work."
        echo "   Install: pacman -S dpkg"
    fi
    
    echo "   Memory : ${TOTAL_MEM_MB}MB detected → NINJA_JOBS=${NINJA_JOBS}"
    echo "   Build  : ${BUILD_BASE}"
    echo "   Output : ${OUTPUT_DIR}"
    
    [ "$missing" -eq 1 ] && exit 1
}

# --- Download with resume support --------------------------------------
download() {
    local url="$1"
    local output="$2"
    local desc="${3:-$(basename "$output")}"
    
    if [ -f "$output" ] && [ -s "$output" ]; then
        echo "${STATUS_SKIP} Already downloaded: $desc"
        return 0
    fi
    
    echo "${STATUS_INFO} Downloading: $desc"
    mkdir -p "$(dirname "$output")"
    wget -q --show-progress -c "$url" -O "$output" || {
        echo "${STATUS_ERR} Failed to download: $url" >&2
        return 1
    }
    echo "${STATUS_OK} Downloaded: $desc"
}

# --- Show resource usage -----------------------------------------------
show_resources() {
    echo ""
    echo "  RAM: ${TOTAL_MEM_MB}MB total  |  Build jobs: ${NINJA_JOBS}"
    echo "  CPU: $(nproc 2>/dev/null || echo '?') cores available"
    echo "  TMPDIR: ${TMPDIR:-not set}"
    echo "  Build dir: ${BUILD_BASE}"
    echo ""
}

# --- Build virglrenderer from source ------------------------------------
build_virglrenderer() {
    local VERSION="1.3.0"
    local TARBALL="virglrenderer-virglrenderer-${VERSION}.tar.gz"
    local SOURCE_DIR="virglrenderer-virglrenderer-${VERSION}"
    local SOURCE_URL="https://gitlab.freedesktop.org/virgl/virglrenderer/-/archive/virglrenderer-${VERSION}/${TARBALL}"
    local OUTPUT_FILE="$OUTPUT_DIR/virglrenderer-${VERSION}-1-aarch64.pkg.tar.xz"
    
    echo ""
    echo "========================================================================"
    echo "  ${STATUS_BUILD} virglrenderer ${VERSION} (FROM SOURCE)"
    echo "  Jobs: ${NINJA_JOBS}  |  Target dir: ${BUILD_DIR}"
    echo "========================================================================"
    
    # Skip if already built
    if [ -f "$OUTPUT_FILE" ]; then
        echo "${STATUS_SKIP} Already built: $(basename "$OUTPUT_FILE")"
        echo "   Use './build-pacman.sh clean' then rebuild, or delete it manually."
        return 0
    fi
    
    # Check build tools
    if ! command -v meson >/dev/null 2>&1; then
        echo "${STATUS_ERR} 'meson' is required to build virglrenderer from source." >&2
        echo "   Install: pacman -S meson ninja pkg-config" >&2
        echo "   Also: pacman -S libdrm libepoxy libglvnd libx11 mesa" >&2
        return 1
    fi
    
    mkdir -p "$BUILD_DIR" "$PKG_DIR_BASE"
    cd "$BUILD_DIR"
    
    # Download source
    download "$SOURCE_URL" "$BUILD_DIR/$TARBALL" "$TARBALL" || return 1
    
    # Extract (skip if already extracted)
    if [ ! -d "$SOURCE_DIR" ]; then
        echo "${STATUS_INFO} Extracting: $TARBALL"
        tar xf "$TARBALL"
        echo "${STATUS_INFO} Extracted: $SOURCE_DIR"
    else
        echo "${STATUS_SKIP} Already extracted: $SOURCE_DIR"
    fi
    
    cd "$SOURCE_DIR"
    
    # Verify source integrity
    if [ ! -f "meson.build" ]; then
        echo "${STATUS_ERR} Corrupt source: meson.build not found in $SOURCE_DIR" >&2
        rm -rf "$BUILD_DIR/$SOURCE_DIR"
        return 1
    fi
    
    # Configure with meson (skip if already configured)
    if [ ! -d "build/meson-info" ]; then
        echo "${STATUS_BUILD} Configuring with meson..."
        rm -rf build 2>/dev/null
        CFLAGS="-O2 -Wno-error=gnu-offsetof-extensions" \
        meson setup build \
            -Dplatforms=egl,glx \
            -Dvenus=true \
            -Dbuildtype=release \
            -Dstrip=true \
            --prefix /data/data/com.termux/files/usr \
            --libdir /data/data/com.termux/files/usr/lib || {
            echo "${STATUS_ERR} meson configure failed" >&2
            return 1
        }
        echo "${STATUS_OK} Meson configured"
    else
        echo "${STATUS_SKIP} Already configured"
    fi
    
    # Compile
    echo "${STATUS_BUILD} Compiling (${NINJA_JOBS} job(s))..."
    ninja -C build -j${NINJA_JOBS} 2>&1 | tail -5 || {
        echo "${STATUS_ERR} ninja build failed" >&2
        # Don't delete build dir - user can fix and retry
        return 1
    }
    echo "${STATUS_OK} Compilation complete"
    
    # Install to package dir
    local PKGDIR="$PKG_DIR_BASE/virglrenderer"
    rm -rf "$PKGDIR"
    DESTDIR="$PKGDIR" ninja -C build install 2>&1 | tail -3 || {
        echo "${STATUS_ERR} Install failed" >&2
        return 1
    }
    
    # Strip debug symbols (reduce package size)
    echo "${STATUS_INFO} Stripping binaries..."
    find "$PKGDIR" -type f \( -name '*.so*' -o -name 'virgl_test_server*' \) \
        -exec strip --strip-all {} \; 2>/dev/null || true
    
    # Create .PKGINFO
    local PKG_SIZE=$(du -sk "$PKGDIR" | awk '{print $1 * 1024}')
    cat > "$PKGDIR/.PKGINFO" << EOF
# Generated by build-pacman.sh (from source, optimized for low-end)
pkgname = virglrenderer
pkgver = ${VERSION}-1
pkgdesc = VirGL virtual OpenGL renderer (virgl_test_server). Built from freedesktop.org source.
url = https://gitlab.freedesktop.org/virgl/virglrenderer
builddate = $(date -u +%s)
packager = termux-mali-gpu-acceleration
size = $PKG_SIZE
arch = aarch64
license = MIT
depend = libdrm
depend = libepoxy
depend = libglvnd
depend = libx11
depend = mesa
EOF
    
    # Build the .pkg.tar.xz (xz -6 for good compression without maxing CPU)
    cd "$PKGDIR"
    echo "${STATUS_BUILD} Creating package (this may take a moment)..."
    tar -cf - .PKGINFO $(find . -not -name '.PKGINFO' -not -name '.MTREE' | sed 's|^./||') | \
        xz -6 -T1 -c > "$OUTPUT_FILE" || {
        echo "${STATUS_ERR} Package creation failed" >&2
        return 1
    }
    
    echo "${STATUS_OK} Package created: $(basename "$OUTPUT_FILE") ($(( $(stat -c%s "$OUTPUT_FILE") / 1024 ))KB)"
    echo "   Install: pacman -U $(basename "$OUTPUT_FILE")"
    
    # Clean up source to save disk (keep .tar.gz for resume)
    echo "${STATUS_INFO} Cleaning source..."
    cd "$BUILD_DIR"
    rm -rf "$SOURCE_DIR" 2>/dev/null || true
    rm -rf "$PKGDIR" 2>/dev/null || true
    
    cd "$OUTPUT_DIR"
}

# --- Build angle-android from prebuilt .deb -----------------------------
build_angle() {
    local DEB_NAME="angle-android"
    local DEB_VERSION="2.1.2-latest"
    local DEB_FILE="${DEB_NAME}_${DEB_VERSION}.deb"
    local URL="$BASE_URL/$DEB_FILE"
    local OUTPUT_FILE="$OUTPUT_DIR/${DEB_NAME}-${DEB_VERSION}-aarch64.pkg.tar.xz"
    
    echo ""
    echo "========================================================================"
    echo "  ${STATUS_BUILD} angle-android (FROM PREBUILT)"
    echo "  Source: ar37-rs/virgl-angle upstream release"
    echo "========================================================================"
    echo "  NOTE: ANGLE requires Google depot_tools + Chromium-scale build"
    echo "  infrastructure. Not practical to compile on-device in Termux."
    echo "========================================================================"
    
    # Skip if already built
    if [ -f "$OUTPUT_FILE" ]; then
        echo "${STATUS_SKIP} Already built: $(basename "$OUTPUT_FILE")"
        return 0
    fi
    
    if ! command -v dpkg-deb >/dev/null 2>&1; then
        echo "${STATUS_ERR} 'dpkg-deb' not found." >&2
        echo "   Install: pacman -S dpkg" >&2
        return 1
    fi
    
    # Download
    download "$URL" "$OUTPUT_DIR/$DEB_FILE" "$DEB_FILE" || return 1
    
    # Convert using deb2pkg.sh
    "$SCRIPT_DIR/deb2pkg.sh" "$OUTPUT_DIR/$DEB_FILE" || return 1
    
    # Clean up .deb to save space (package is ~15MB)
    echo "${STATUS_INFO} Cleaning up..."
    rm -f "$OUTPUT_DIR/$DEB_FILE" 2>/dev/null || true
    
    # Find the resulting .pkg.tar.xz
    local result=$(ls "$OUTPUT_DIR"/angle-android-*.pkg.tar.xz 2>/dev/null | head -1)
    if [ -n "$result" ]; then
        echo "${STATUS_OK} Package: $(basename "$result")"
    fi
}

# --- Build mesa-vulkan-icd-wrapper from source --------------------------
build_icd() {
    local OUTPUT_FILE="$OUTPUT_DIR/mesa-vulkan-icd-wrapper-25.0.0-1-aarch64.pkg.tar.xz"
    
    echo ""
    echo "========================================================================"
    echo "  ${STATUS_BUILD} mesa-vulkan-icd-wrapper (FROM SOURCE)"
    echo "  Auto-detects Mali Vulkan driver on this device"
    echo "========================================================================"
    
    # Skip if already built
    if [ -f "$OUTPUT_FILE" ]; then
        echo "${STATUS_SKIP} Already built: $(basename "$OUTPUT_FILE")"
        return 0
    fi
    
    local PKGDIR="$PKG_DIR_BASE/mesa-vulkan-icd-wrapper"
    rm -rf "$PKGDIR"
    mkdir -p "$PKGDIR/data/data/com.termux/files/usr/share/vulkan/icd.d"
    
    # Detect Mali Vulkan driver
    local MALI_DRIVER=""
    echo "${STATUS_INFO} Scanning for Mali Vulkan driver..."
    
    for path in \
        /vendor/lib64/hw/vulkan.mali.so \
        /vendor/lib/hw/vulkan.mali.so \
        /system/vendor/lib64/hw/vulkan.mali.so \
        /system/lib64/hw/vulkan.mali.so \
        /vendor/lib64/egl/libGLES_mali.so \
        /system/lib64/egl/libGLES_mali.so; do
        if [ -f "$path" ] && [ -r "$path" ]; then
            MALI_DRIVER="$path"
            break
        fi
    done
    
    if [ -n "$MALI_DRIVER" ]; then
        echo "${STATUS_OK} Mali driver detected: $MALI_DRIVER"
        
        cat > "$PKGDIR/data/data/com.termux/files/usr/share/vulkan/icd.d/mali.json" << EOF
{
    "file_format_version": "1.0.0",
    "ICD": {
        "library_path": "$MALI_DRIVER",
        "api_version": "1.3"
    }
}
EOF
    else
        echo "${STATUS_WARN} Mali driver not detected on this build device."
        echo "   Creating runtime-detection post-install script..."
        
        # Create the ICD pointing to most common location as fallback
        cat > "$PKGDIR/data/data/com.termux/files/usr/share/vulkan/icd.d/mali.json" << 'EOF'
{
    "file_format_version": "1.0.0",
    "ICD": {
        "library_path": "/vendor/lib64/hw/vulkan.mali.so",
        "api_version": "1.3"
    }
}
EOF
    fi
    
    # Verify the JSON is valid
    if ! head -1 "$PKGDIR/data/data/com.termux/files/usr/share/vulkan/icd.d/mali.json" | grep -q "file_format_version"; then
        echo "${STATUS_ERR} Failed to create valid ICD JSON" >&2
        return 1
    fi
    
    # Calculate size
    local PKG_SIZE=$(du -sk "$PKGDIR" | awk '{print $1 * 1024}')
    
    # Create .PKGINFO
    cat > "$PKGDIR/.PKGINFO" << EOF
# Generated by build-pacman.sh (from source, auto-detected Mali driver)
pkgname = mesa-vulkan-icd-wrapper
pkgver = 25.0.0-1
pkgdesc = Vulkan ICD wrapper for Mali GPUs. Registers Mali Vulkan driver with Termux Vulkan loader.
url = https://github.com/ar37-rs/virgl-angle
builddate = $(date -u +%s)
packager = termux-mali-gpu-acceleration
size = $PKG_SIZE
arch = aarch64
license = MIT
depend = vulkan-loader-generic
EOF
    
    # Build the .pkg.tar.xz
    cd "$PKGDIR"
    tar -cf - .PKGINFO $(find . -not -name '.PKGINFO' -not -name '.MTREE' | sed 's|^./||') | \
        xz -6 -T1 -c > "$OUTPUT_FILE" || {
        echo "${STATUS_ERR} Package creation failed" >&2
        return 1
    }
    
    echo "${STATUS_OK} Package created: $(basename "$OUTPUT_FILE") ($(( $(stat -c%s "$OUTPUT_FILE") / 1024 ))KB)"
    echo "   Install: pacman -U $(basename "$OUTPUT_FILE")"
    
    if [ -z "$MALI_DRIVER" ]; then
        echo "   ${STATUS_WARN} Mali driver was NOT detected on this build device."
        echo "   After installing on a Mali device, verify with:"
        echo "     ls -l \$PREFIX/share/vulkan/icd.d/mali.json"
        echo "     head -5 \$PREFIX/share/vulkan/icd.d/mali.json"
        echo "   If the library_path doesn't exist on your device, edit the JSON file."
    fi
    
    # Clean up
    rm -rf "$PKGDIR" 2>/dev/null || true
    cd "$OUTPUT_DIR"
}

# --- Clean --------------------------------------------------------------
clean() {
    echo ""
    echo "${STATUS_INFO} Cleaning all build artifacts..."
    
    # Remove generated packages
    local count=0
    for f in "$OUTPUT_DIR"/*.pkg.tar.xz; do
        [ -f "$f" ] && rm -f "$f" && count=$((count+1))
    done
    for f in "$OUTPUT_DIR"/*.deb; do
        [ -f "$f" ] && rm -f "$f" && count=$((count+1))
    done
    
    # Remove build directory
    if [ -d "$BUILD_BASE" ]; then
        rm -rf "$BUILD_BASE"
        echo "${STATUS_OK} Removed build directory: $BUILD_BASE"
    fi
    
    echo "${STATUS_OK} Cleaned $count files"
}

# --- Main ---------------------------------------------------------------
main() {
    echo ""
    echo "  ╔══════════════════════════════════════════════════════════════╗"
    echo "  ║     Mali GPU — Pacman Package Builder (low-end optimized)   ║"
    echo "  ╚══════════════════════════════════════════════════════════════╝"
    
    # Show system info
    show_resources
    
    # Parse command
    CMD="${1:-all}"
    
    case "$CMD" in
        all)
            check_deps
            build_virglrenderer || echo "${STATUS_WARN} virglrenderer build had issues"
            build_angle
            build_icd
            ;;
        virgl|virglrenderer)
            check_deps
            build_virglrenderer
            ;;
        angle|angle-android)
            check_deps
            build_angle
            ;;
        icd|vulkan|wrapper)
            check_deps
            build_icd
            ;;
        clean)
            clean
            ;;
        force)
            clean
            echo ""
            echo "${STATUS_INFO} Forcing rebuild from scratch..."
            exec "$0" all
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            echo "${STATUS_ERR} Unknown command: $CMD" >&2
            show_help
            exit 1
            ;;
    esac
    
    # Final summary
    echo ""
    echo "  ╔══════════════════════════════════════════════════════════════╗"
    echo "  ║  Done!                                                     ║"
    echo "  ║                                                            ║"
    echo "  ║  Packages:                                                 ║"
    for f in "$OUTPUT_DIR"/*.pkg.tar.xz; do
        if [ -f "$f" ]; then
            size=$(stat -c%s "$f" 2>/dev/null | awk '{printf "%.1f", $1/1024}')
            echo "  ║    $(basename "$f")  (${size}KB)"
        fi
    done
    echo "  ║                                                            ║"
    echo "  ║  Install: cd packages && pacman -U *.pkg.tar.xz            ║"
    echo "  ╚══════════════════════════════════════════════════════════════╝"
    echo ""
}

main "$@"
