#!/usr/bin/env bash
# =============================================================================
#  build-virglrenderer.sh  —  Cross-compile virglrenderer for Termux aarch64
# =============================================================================
#  Intended for GitHub Actions CI. Uses Android NDK for cross-compilation.
#
#  Env vars:
#    NDK_DIR     - Path to Android NDK (default: /opt/android-ndk)
#    SYSROOT_DIR - Path to extracted Termux sysroot (default: ./sysroot)
#    VERSION     - virglrenderer version (default: 1.3.0)
#    NINJA_JOBS  - Parallel build jobs (default: $(nproc))
#
#  Usage:  ./ci/build-virglrenderer.sh
#  Output: packages/virglrenderer-<VERSION>-1-aarch64.pkg.tar.xz
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
OUTPUT_DIR="$REPO_DIR/packages"

# --- Defaults ----------------------------------------------------------
NDK_DIR="${NDK_DIR:-/opt/android-ndk}"
SYSROOT_DIR="${SYSROOT_DIR:-$REPO_DIR/.build/sysroot}"
VERSION="${VERSION:-1.3.0}"
NINJA_JOBS="${NINJA_JOBS:-$(nproc 2>/dev/null || echo 2)}"

TARBALL="virglrenderer-virglrenderer-${VERSION}.tar.gz"
SOURCE_URL="https://gitlab.freedesktop.org/virgl/virglrenderer/-/archive/virglrenderer-${VERSION}/${TARBALL}"
SOURCE_DIR="virglrenderer-virglrenderer-${VERSION}"
OUTPUT_FILE="$OUTPUT_DIR/virglrenderer-${VERSION}-1-aarch64.pkg.tar.xz"

BUILD_BASE="$REPO_DIR/.build/virglrenderer"
CROSS_FILE="$REPO_DIR/ci/aarch64-linux-android-cross.ini"

mkdir -p "$BUILD_BASE" "$OUTPUT_DIR"

echo "=== virglrenderer ${VERSION} cross-build ==="
echo "NDK:       $NDK_DIR"
echo "Sysroot:   $SYSROOT_DIR"
echo "Jobs:      $NINJA_JOBS"
echo "Output:    $OUTPUT_FILE"
echo ""

# --- Check requirements -------------------------------------------------
if [ ! -d "$NDK_DIR" ]; then
    echo "ERROR: NDK not found at $NDK_DIR" >&2
    exit 1
fi

if ! command -v meson >/dev/null 2>&1; then
    echo "ERROR: meson not found. Install: pip install meson ninja" >&2
    exit 1
fi

# --- Download source ----------------------------------------------------
if [ ! -f "$BUILD_BASE/$TARBALL" ]; then
    echo "Downloading virglrenderer ${VERSION}..."
    wget -q --show-progress -c "$SOURCE_URL" -O "$BUILD_BASE/$TARBALL"
fi

# --- Extract -----------------------------------------------------------
cd "$BUILD_BASE"
if [ ! -d "$SOURCE_DIR" ]; then
    echo "Extracting..."
    tar xf "$TARBALL"
fi

cd "$SOURCE_DIR"

# --- Debug: check sysroot contents --------------------------------------
echo "=== Debug: Sysroot pkg-config files ==="
find "$SYSROOT_DIR" -name "*.pc" 2>/dev/null | head -30 | sort || true
echo ""

echo "=== Debug: Checking for epoxy.pc ==="
if [ -f "$SYSROOT_DIR/data/data/com.termux/files/usr/lib/pkgconfig/epoxy.pc" ]; then
    echo "  epoxy.pc FOUND"
    cat "$SYSROOT_DIR/data/data/com.termux/files/usr/lib/pkgconfig/epoxy.pc" | head -10
else
    echo "  epoxy.pc NOT FOUND at expected path"
    # Search for it anywhere in sysroot
    find "$SYSROOT_DIR" -name "epoxy*" 2>/dev/null | head -10 || true
fi
echo ""

echo "=== Debug: Checking for gl.pc (from mesa) ==="
find "$SYSROOT_DIR" -name "gl.pc" 2>/dev/null | head -5 || true
echo ""

# --- Meson cross-compile ------------------------------------------------
if [ ! -d "build/meson-info" ]; then
    echo "Configuring with meson (cross-compile)..."
    rm -rf build 2>/dev/null
    
    # Set up pkg-config for cross
    export PKG_CONFIG_LIBDIR="$SYSROOT_DIR/data/data/com.termux/files/usr/lib/pkgconfig"
    export PKG_CONFIG_SYSROOT_DIR="$SYSROOT_DIR"
    export PKG_CONFIG_PATH=""
    # Ensure meson uses our cross pkg-config
    export PKG_CONFIG="pkg-config"
    
    echo "  PKG_CONFIG_LIBDIR=$PKG_CONFIG_LIBDIR"
    echo "  PKG_CONFIG_SYSROOT_DIR=$PKG_CONFIG_SYSROOT_DIR"
    echo ""
    
    # Test pkg-config can find epoxy
    if ! pkg-config --exists epoxy; then
        echo "WARNING: pkg-config cannot find epoxy. Check sysroot."
        pkg-config --variable=pcfiledir epoxy 2>&1 || true
        echo "  Available epoxy-related .pc files:"
        find "$PKG_CONFIG_LIBDIR" -name "*epoxy*" -o -name "*gl*" 2>/dev/null | head -10 || true
    else
        echo "  pkg-config epoxy: OK ($(pkg-config --modversion epoxy))"
    fi
    
    # NDK sysroot for Android native headers (log/log.h, etc.)
    NDK_SYSROOT="$NDK_DIR/toolchains/llvm/prebuilt/linux-x86_64/sysroot"
    
    CFLAGS="--sysroot=$SYSROOT_DIR -isystem $NDK_SYSROOT/usr/include -O2 -Wno-error=gnu-offsetof-extensions" \
    LDFLAGS="--sysroot=$SYSROOT_DIR" \
    PKG_CONFIG_LIBDIR="$PKG_CONFIG_LIBDIR" \
    PKG_CONFIG_SYSROOT_DIR="$PKG_CONFIG_SYSROOT_DIR" \
    meson setup build \
        --cross-file "$CROSS_FILE" \
        -Dplatforms=egl,glx \
        -Dvenus=true \
        -Dbuildtype=release \
        -Dstrip=true \
        --prefix /data/data/com.termux/files/usr \
        --libdir /data/data/com.termux/files/usr/lib \
        2>&1
fi

# --- Compile -----------------------------------------------------------
echo "Compiling (${NINJA_JOBS} jobs)..."
ninja -C build -j${NINJA_JOBS} 2>&1

echo "Compilation successful."

# --- Install to pkgdir -------------------------------------------------
PKGDIR="$BUILD_BASE/pkg"
rm -rf "$PKGDIR"
DESTDIR="$PKGDIR" ninja -C build install 2>&1

# Verify
if [ -z "$(ls -A "$PKGDIR" 2>/dev/null)" ]; then
    echo "ERROR: Install produced no files" >&2
    exit 1
fi

# --- Strip binaries ----------------------------------------------------
echo "Stripping..."
find "$PKGDIR" -type f \( -name '*.so*' -o -name 'virgl_test_server*' \) \
    -exec "$NDK_DIR/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip" --strip-all {} \; 2>/dev/null || true

# --- Generate .PKGINFO -------------------------------------------------
PKG_SIZE=$(du -sk "$PKGDIR" | awk '{print $1 * 1024}')
cat > "$PKGDIR/.PKGINFO" << EOF
pkgname = virglrenderer
pkgver = ${VERSION}-1
pkgdesc = VirGL virtual OpenGL renderer (virgl_test_server). Cross-compiled for Termux.
url = https://gitlab.freedesktop.org/virgl/virglrenderer
builddate = $(date -u +%s)
packager = termux-mali-gpu-acceleration CI
size = $PKG_SIZE
arch = aarch64
license = MIT
depend = libdrm
depend = libepoxy
depend = libglvnd
depend = libx11
depend = mesa
EOF

# --- Package as .pkg.tar.xz --------------------------------------------
echo "Creating package..."
cd "$PKGDIR"
tar -cf - .PKGINFO $(find . -not -name '.PKGINFO' -not -name '.MTREE' | sed 's|^./||') | \
    xz -6 -T1 -c > "$OUTPUT_FILE"

echo ""
echo "Done: $(basename "$OUTPUT_FILE") ($(( $(stat -c%s "$OUTPUT_FILE" 2>/dev/null || echo 0) / 1024 ))KB)"
echo "Install: pacman -U $(basename "$OUTPUT_FILE")"

# --- Cleanup -----------------------------------------------------------
cd "$REPO_DIR"
rm -rf "$BUILD_BASE" 2>/dev/null || true
