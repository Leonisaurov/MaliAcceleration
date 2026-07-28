#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
#  build-pacman.sh  —  Build Mali GPU acceleration packages for Termux pacman
# =============================================================================
#  Builds .pkg.tar.xz packages from source where possible, and from prebuilt
#  .deb releases where source builds are impractical.
#
#  Build strategies:
#    - virglrenderer:         FROM SOURCE (meson + gitlab.freedesktop.org)
#    - angle-android:         Prebuilt .deb  (ANGLE requires Google depot_tools,
#                              Chromium-scale build infrastructure - impractical
#                              to build on-device in Termux)
#    - mesa-vulkan-icd-wrapper: FROM SOURCE (auto-detects Mali driver, creates
#                              ICD JSON config)
#
#  Usage:
#    ./build-pacman.sh              # build all packages
#    ./build-pacman.sh virgl        # build only virglrenderer (from source)
#    ./build-pacman.sh angle        # build only angle-android (from prebuilt)
#    ./build-pacman.sh icd          # build only mesa-vulkan-icd-wrapper (from source)
#    ./build-pacman.sh clean        # remove all .deb and .pkg.tar.xz
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="$SCRIPT_DIR"
BUILD_DIR="$OUTPUT_DIR/build"

# Upstream release URL for prebuilt components
BASE_URL="https://github.com/ar37-rs/virgl-angle/releases/download/latest"

# --- Check dependencies ------------------------------------------------
check_deps() {
    local missing=0

    # Common deps
    for cmd in wget tar; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "ERROR: '$cmd' not found." >&2
            missing=1
        fi
    done

    echo "==> Checking build dependencies..."
    echo "  meson ...... $(command -v meson 2>/dev/null || echo 'NOT FOUND')"
    echo "  ninja ...... $(command -v ninja 2>/dev/null || echo 'NOT FOUND')"
    echo "  pkg-config . $(command -v pkg-config 2>/dev/null || echo 'NOT FOUND')"
    echo "  dpkg-deb ... $(command -v dpkg-deb 2>/dev/null || echo 'NOT FOUND')"

    # For source builds: meson + ninja + pkg-config + gcc/clang
    if ! command -v meson >/dev/null 2>&1; then
        echo "WARN: 'meson' not found. Source builds will not work." >&2
        echo "  Install: pacman -S meson ninja pkg-config" >&2
    fi
    if ! command -v dpkg-deb >/dev/null 2>&1; then
        echo "WARN: 'dpkg-deb' not found. Binary .deb extraction will not work." >&2
        echo "  Install: pacman -S dpkg" >&2
    fi

    [ "$missing" -eq 1 ] && exit 1
}

# --- Build virglrenderer from source ------------------------------------
build_virglrenderer() {
    local VERSION="1.3.0"
    local TARBALL="virglrenderer-virglrenderer-${VERSION}.tar.gz"
    local SOURCE_URL="https://gitlab.freedesktop.org/virgl/virglrenderer/-/archive/virglrenderer-${VERSION}/${TARBALL}"

    echo ""
    echo "========================================================================"
    echo "  Package: virglrenderer (FROM SOURCE)"
    echo "  Version: $VERSION"
    echo "  Source:  $SOURCE_URL"
    echo "========================================================================"

    # Check build tools
    if ! command -v meson >/dev/null 2>&1; then
        echo "ERROR: 'meson' is required to build virglrenderer from source." >&2
        echo "  Install: pacman -S meson ninja pkg-config" >&2
        echo "  Also need libdrm, libepoxy, libglvnd, libx11, mesa:" >&2
        echo "  pacman -S libdrm libepoxy libglvnd libx11 mesa" >&2
        return 1
    fi

    mkdir -p "$BUILD_DIR"
    cd "$BUILD_DIR"

    # Download source
    if [ ! -f "$TARBALL" ]; then
        echo "==> Downloading source..."
        wget -q --show-progress "$SOURCE_URL" -O "$TARBALL" || {
            echo "ERROR: Failed to download source"
            return 1
        }
    else
        echo "==> Source already downloaded"
    fi

    # Extract
    echo "==> Extracting..."
    rm -rf "virglrenderer-virglrenderer-${VERSION}"
    tar xf "$TARBALL"
    cd "virglrenderer-virglrenderer-${VERSION}"

    # Build
    echo "==> Configuring with meson..."
    CFLAGS+=" -Wno-error=gnu-offsetof-extensions"
    meson setup build \
        -Dplatforms=egl,glx \
        -Dvenus=true \
        --prefix /data/data/com.termux/files/usr || {
        echo "ERROR: meson configure failed"
        return 1
    }

    echo "==> Compiling with ninja..."
    ninja -C build || {
        echo "ERROR: ninja build failed"
        return 1
    }

    # Package
    echo "==> Creating .pkg.tar.xz..."
    local PKGDIR="$BUILD_DIR/pkg-virglrenderer"
    rm -rf "$PKGDIR"
    DESTDIR="$PKGDIR" ninja -C build install || {
        echo "ERROR: install failed"
        return 1
    }

    # Create .PKGINFO
    mkdir -p "$PKGDIR"
    local PKG_SIZE=$(du -sk "$PKGDIR" | awk '{print $1 * 1024}')
    local PKGINFO="$PKGDIR/.PKGINFO"
    cat > "$PKGINFO" << EOF
# Generated by build-pacman.sh (from source)
pkgname = virglrenderer
pkgver = ${VERSION}-1
pkgdesc = VirGL virtual OpenGL renderer. Build from freedesktop.org source.
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

    # Build the .pkg.tar.xz
    local OUTPUT_FILE="$OUTPUT_DIR/virglrenderer-${VERSION}-1-aarch64.pkg.tar.xz"
    cd "$PKGDIR"
    tar -cJf "$OUTPUT_FILE" --owner=0 --group=0 .PKGINFO $(find . -not -name '.PKGINFO' -not -name '.MTREE' | sed 's|^./||')

    echo "✅ Done: $(basename "$OUTPUT_FILE")"
    echo "   Install: pacman -U $(basename "$OUTPUT_FILE")"
    cd "$OUTPUT_DIR"
}

# --- Build angle-android from prebuilt .deb -----------------------------
build_angle() {
    local DEB_FILE="angle-android_2.1.2-latest.deb"
    local URL="$BASE_URL/$DEB_FILE"

    echo ""
    echo "========================================================================"
    echo "  Package: angle-android (FROM PREBUILT BINARY)"
    echo "  Source:  $URL"
    echo "========================================================================"
    echo "  NOTE: ANGLE requires Google's depot_tools and Chromium-scale"
    echo "  build infrastructure. Building from source in Termux is not"
    echo "  practical. Using pre-built binaries from upstream."
    echo "========================================================================"

    if [ ! -f "$OUTPUT_DIR/$DEB_FILE" ]; then
        echo "==> Downloading..."
        wget -q --show-progress "$URL" -O "$OUTPUT_DIR/$DEB_FILE"
    else
        echo "==> Already downloaded"
    fi

    # Convert using deb2pkg
    echo "==> Converting to pacman package..."
    "$SCRIPT_DIR/deb2pkg.sh" "$OUTPUT_DIR/$DEB_FILE"
}

# --- Build mesa-vulkan-icd-wrapper from source --------------------------
build_icd() {
    echo ""
    echo "========================================================================"
    echo "  Package: mesa-vulkan-icd-wrapper (FROM SOURCE)"
    echo "========================================================================"

    local PKGDIR="$BUILD_DIR/pkg-mesa-vulkan-icd-wrapper"
    rm -rf "$PKGDIR"
    mkdir -p "$PKGDIR/data/data/com.termux/files/usr/share/vulkan/icd.d"

    # Try to detect Mali Vulkan driver on THIS device
    local MALI_DRIVER=""
    for path in \
        /vendor/lib64/hw/vulkan.mali.so \
        /vendor/lib/hw/vulkan.mali.so \
        /system/vendor/lib64/hw/vulkan.mali.so \
        /system/lib64/hw/vulkan.mali.so; do
        if [ -f "$path" ] && [ -r "$path" ]; then
            MALI_DRIVER="$path"
            break
        fi
    done

    # Create install script that runs on the TARGET device
    mkdir -p "$PKGDIR/.INSTALL"

    if [ -n "$MALI_DRIVER" ]; then
        echo "==> Mali Vulkan driver detected at: $MALI_DRIVER"
        echo "==> Creating ICD JSON..."
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
        echo "==> Mali driver not detected on build device."
        echo "==> Creating runtime-detection post-install script..."

        # Create a post-install script that detects at install time
        cat > "$PKGDIR/.INSTALL" << 'POSTINST'
post_install() {
    ICD_DIR="$PREFIX/share/vulkan/icd.d"
    ICD_FILE="$ICD_DIR/mali.json"

    for path in \
        /vendor/lib64/hw/vulkan.mali.so \
        /vendor/lib/hw/vulkan.mali.so \
        /system/vendor/lib64/hw/vulkan.mali.so \
        /system/lib64/hw/vulkan.mali.so; do
        if [ -f "$path" ]; then
            mkdir -p "$ICD_DIR"
            cat > "$ICD_FILE" << 'EOF'
{
    "file_format_version": "1.0.0",
    "ICD": {
        "library_path": "__MALI_PATH__",
        "api_version": "1.3"
    }
}
EOF
            sed -i "s|__MALI_PATH__|$path|" "$ICD_FILE"
            echo "Mali ICD configured: $path"
            return 0
        fi
    done

    echo "WARNING: Could not find Mali Vulkan driver!"
    echo "Try: pacman -S mesa-vulkan-icd-wrapper (prebuilt version)"
    return 1
}

post_upgrade() {
    post_install
}
POSTINST
        chmod +x "$PKGDIR/.INSTALL"

        # Also create a placeholder ICD so the package isn't empty
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

    # Calculate size
    local PKG_SIZE=$(du -sk "$PKGDIR" | awk '{print $1 * 1024}')

    # Create .PKGINFO
    cat > "$PKGDIR/.PKGINFO" << EOF
# Generated by build-pacman.sh (from source)
pkgname = mesa-vulkan-icd-wrapper
pkgver = 25.0.0-1
pkgdesc = Vulkan ICD wrapper for Mali GPUs. Auto-detects Mali Vulkan driver.
url = https://github.com/ar37-rs/virgl-angle
builddate = $(date -u +%s)
packager = termux-mali-gpu-acceleration
size = $PKG_SIZE
arch = aarch64
license = MIT
depend = vulkan-loader-generic
EOF

    # Build the .pkg.tar.xz
    local OUTPUT_FILE="$OUTPUT_DIR/mesa-vulkan-icd-wrapper-25.0.0-1-aarch64.pkg.tar.xz"
    cd "$PKGDIR"
    # Include .INSTALL if present
    local EXTRA_FILES=""
    [ -f ".INSTALL" ] && EXTRA_FILES=".INSTALL"
    tar -cJf "$OUTPUT_FILE" --owner=0 --group=0 .PKGINFO $EXTRA_FILES $(find . -not -name '.PKGINFO' -not -name '.MTREE' -not -name '.INSTALL' -not -path './.INSTALL/*' | sed 's|^./||')

    echo "✅ Done: $(basename "$OUTPUT_FILE")"
    echo "   Install: pacman -U $(basename "$OUTPUT_FILE")"
    echo ""
    if [ -z "$MALI_DRIVER" ]; then
        echo "   ⚠️  Mali driver was NOT detected on this build device."
        echo "   The package includes a post-install script that will"
        echo "   auto-detect it when installed on a Mali device."
    fi
    cd "$OUTPUT_DIR"
}

# --- Clean --------------------------------------------------------------
clean() {
    echo "==> Cleaning..."
    rm -f "$OUTPUT_DIR"/*.deb 2>/dev/null
    rm -f "$OUTPUT_DIR"/*.pkg.tar.xz 2>/dev/null
    rm -rf "$BUILD_DIR" 2>/dev/null
    echo "✅ Cleaned all build artifacts"
    exit 0
}

# --- Main ---------------------------------------------------------------
echo ""
echo "  ╔══════════════════════════════════════════════════════════════╗"
echo "  ║     Mali GPU Acceleration — Pacman Package Builder          ║"
echo "  ║     Builds from source where possible                      ║"
echo "  ╚══════════════════════════════════════════════════════════════╝"
echo ""

check_deps

case "${1:-all}" in
    clean)
        clean
        ;;
    virgl|virglrenderer)
        build_virglrenderer
        ;;
    angle|angle-android)
        build_angle
        ;;
    icd|vulkan|mesa-vulkan-icd-wrapper)
        build_icd
        ;;
    all|"")
        build_virglrenderer || echo "WARN: virglrenderer build failed"
        build_angle
        build_icd
        ;;
    *)
        echo "Usage: $0 [all|virgl|angle|icd|clean]" >&2
        echo "" >&2
        echo "  all     Build all packages (default)" >&2
        echo "  virgl   Build virglrenderer from source (meson)" >&2
        echo "  angle   Build angle-android from prebuilt .deb" >&2
        echo "  icd     Build mesa-vulkan-icd-wrapper from source" >&2
        echo "  clean   Remove all build artifacts" >&2
        exit 1
        ;;
esac

echo ""
echo "  ╔══════════════════════════════════════════════════════════════╗"
echo "  ║  All packages built!                                        ║"
echo "  ║                                                            ║"
echo "  ║  Install with:                                             ║"
echo "  ║    pacman -U packages/*.pkg.tar.xz                         ║"
echo "  ╚══════════════════════════════════════════════════════════════╝"
echo ""
