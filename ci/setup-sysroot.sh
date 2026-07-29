#!/usr/bin/env bash
# =============================================================================
#  setup-sysroot.sh  —  Download Termux .deb packages for cross-compilation
# =============================================================================
#  Downloads the latest versions of all required Termux .deb packages by
#  resolving their URLs from the Termux repository metadata (Packages.gz).
#
#  Usage:  ./ci/setup-sysroot.sh <sysroot-dir>
#
#  Output: <sysroot-dir>/data/data/com.termux/files/usr/  (extracted sysroot)
#
#  Note: This script is designed for GitHub Actions CI (ubuntu-latest).
#  In that context, /tmp is available and correct.
# =============================================================================
set -euo pipefail

SYSROOT_DIR="${1:?Usage: $0 <sysroot-dir>}"
mkdir -p "$SYSROOT_DIR"

TERMUX_REPO="https://packages.termux.dev/apt/termux-main"
PACKAGES_URL="$TERMUX_REPO/dists/stable/main/binary-aarch64/Packages.gz"

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

# --- Download Packages metadata ---
METADATA_FILE="/tmp/termux-packages.gz"
echo "Downloading package metadata from Termux repo..."
wget -q -c "$PACKAGES_URL" -O "$METADATA_FILE" || {
    echo "ERROR: Failed to download Termux package metadata" >&2
    echo "URL: $PACKAGES_URL" >&2
    exit 1
}
echo "Metadata downloaded ($(stat -c%s "$METADATA_FILE" 2>/dev/null || echo "?") bytes)"

# --- Download and extract each package ---
DEB_DIR="$SYSROOT_DIR/.debs"
mkdir -p "$DEB_DIR"

for pkg in "${PACKAGES[@]}"; do
    echo -n "  $pkg ... "
    
    # Skip if already extracted
    if [ -f "$SYSROOT_DIR/.${pkg}-done" ]; then
        echo "already done"
        continue
    fi
    
    # Extract the Filename field from Packages.gz for this package
    # Note: awk's `exit` causes SIGPIPE to zcat; temporarily disable pipefail.
    set +o pipefail
    filename=$(zcat "$METADATA_FILE" | awk -v pkg="$pkg" '
        $1 == "Package:" && $2 == pkg { found=1; next }
        found && $1 == "Filename:" { print $2; found=0; exit }
    ')
    set -o pipefail
    
    if [ -z "$filename" ]; then
        echo "WARNING: package '$pkg' not found in Termux repo" >&2
        continue
    fi
    
    deb_url="$TERMUX_REPO/$filename"
    deb_name=$(basename "$filename")
    
    # Download .deb
    if ! wget -q --show-progress -c "$deb_url" -O "$DEB_DIR/$deb_name" 2>&1; then
        echo "FAILED (download error)"
        continue
    fi
    
    # Extract .deb
    echo -n "extracting... "
    if command -v dpkg-deb >/dev/null 2>&1; then
        dpkg-deb -x "$DEB_DIR/$deb_name" "$SYSROOT_DIR" 2>/dev/null || {
            echo "FAILED (dpkg-deb)"
            continue
        }
    else
        ar p "$DEB_DIR/$deb_name" data.tar.xz 2>/dev/null | tar -xJ -C "$SYSROOT_DIR" 2>/dev/null || \
        ar p "$DEB_DIR/$deb_name" data.tar.gz 2>/dev/null | tar -xz -C "$SYSROOT_DIR" 2>/dev/null || {
            echo "FAILED (ar+tar)"
            continue
        }
    fi
    
    # Mark as done
    touch "$SYSROOT_DIR/.${pkg}-done"
    echo "OK"
done

# --- Cleanup ---
rm -rf "$DEB_DIR" "$METADATA_FILE"

# --- Summary ---
echo ""
echo "=== Sysroot ready ==="
echo "Location: $SYSROOT_DIR"
echo ""
echo "Pkg-config files (*.pc):"
find "$SYSROOT_DIR" -name "*.pc" -path "*/pkgconfig/*" 2>/dev/null | head -20 | sed 's|.*/data|  /data|'
echo ""
echo "Libraries (*.so):"
find "$SYSROOT_DIR" -name "*.so" 2>/dev/null | head -10 | sed 's|.*/data|  /data|'
