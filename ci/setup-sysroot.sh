#!/usr/bin/env bash
# =============================================================================
#  setup-sysroot.sh  —  Download Termux .deb packages for cross-compilation
# =============================================================================
#  Downloads the latest versions of all required Termux .deb packages by
#  resolving their URLs from the Termux repository metadata (Packages.xz).
#
#  Usage:  ./ci/setup-sysroot.sh <sysroot-dir>
#
#  Output: <sysroot-dir>/data/data/com.termux/files/usr/  (extracted sysroot)
# =============================================================================
set -euo pipefail

SYSROOT_DIR="${1:?Usage: $0 <sysroot-dir>}"
mkdir -p "$SYSROOT_DIR"

TERMUX_REPO="https://packages.termux.dev/apt/termux-main"
PACKAGES_URL="$TERMUX_REPO/dists/stable/main/binary-aarch64/Packages.xz"

# Packages needed for virglrenderer cross-compilation
PACKAGES=(
    "libdrm"
    "libepoxy"
    "libglvnd"
    "libx11"
    "mesa"
    "libxcb"
    "xorgproto"
    "libxdmcp"
    "libxau"
    "libxshmfence"
)

echo "=== Setting up Termux sysroot in: $SYSROOT_DIR ==="

# Download and parse Packages.xz to get the correct .deb URLs
echo "Downloading package metadata..."
wget -q -c "$PACKAGES_URL" -O /tmp/termux-packages.xz

echo "Resolving package URLs..."

# Create a temporary directory for .deb downloads
DEB_DIR="$SYSROOT_DIR/.debs"
mkdir -p "$DEB_DIR"

for pkg in "${PACKAGES[@]}"; do
    echo -n "  $pkg ... "
    
    # Skip if already downloaded and extracted
    if [ -f "$SYSROOT_DIR/.${pkg}-done" ]; then
        echo "already done"
        continue
    fi
    
    # Extract the Filename field from Packages.xz for this package
    filename=$(xz -cd /tmp/termux-packages.xz | awk -v pkg="$pkg" '
        $1 == "Package:" && $2 == pkg { found=1; next }
        found && $1 == "Filename:" { print $2; found=0; exit }
    ')
    
    if [ -z "$filename" ]; then
        echo "WARNING: package not found in repo" >&2
        continue
    fi
    
    deb_url="$TERMUX_REPO/$filename"
    deb_name=$(basename "$filename")
    
    # Download
    wget -q --show-progress -c "$deb_url" -O "$DEB_DIR/$deb_name" 2>&1 || {
        echo "FAILED"
        continue
    }
    
    # Extract
    echo -n "extracting... "
    if command -v dpkg-deb >/dev/null 2>&1; then
        dpkg-deb -x "$DEB_DIR/$deb_name" "$SYSROOT_DIR" 2>/dev/null
    else
        ar p "$DEB_DIR/$deb_name" data.tar.xz 2>/dev/null | tar -xJ -C "$SYSROOT_DIR" 2>/dev/null || \
        ar p "$DEB_DIR/$deb_name" data.tar.gz 2>/dev/null | tar -xz -C "$SYSROOT_DIR" 2>/dev/null
    fi
    
    # Mark as done
    touch "$SYSROOT_DIR/.${pkg}-done"
    echo "OK"
done

# Cleanup .deb files
rm -rf "$DEB_DIR" /tmp/termux-packages.xz

# Show what we got
echo ""
echo "=== Sysroot ready ==="
echo "Location: $SYSROOT_DIR"
echo "Pkg-config files:"
find "$SYSROOT_DIR" -name "*.pc" -path "*/pkgconfig/*" 2>/dev/null | head -20
echo ""
echo "Libraries (.so):"
find "$SYSROOT_DIR" -name "*.so" 2>/dev/null | head -20
