#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
#  repo-add.sh  —  Create a local pacman repo from built .pkg.tar.xz files
# =============================================================================
#  After running build-pacman.sh, run this to create a local repository
#  that pacman can use. This allows:
#    pacman -S virglrenderer angle-android mesa-vulkan-icd-wrapper
#  instead of:
#    pacman -U *.pkg.tar.xz
#
#  Usage:
#    ./repo-add.sh                    # add all .pkg.tar.xz in current dir
#    ./repo-add.sh /path/to/packages  # add from specific directory
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PKG_DIR="${1:-$SCRIPT_DIR}"
REPO_NAME="mali-gpu"
REPO_FILE="$PKG_DIR/$REPO_NAME.db.tar.xz"

# --- Check deps ---------------------------------------------------------
if ! command -v repo-add >/dev/null 2>&1; then
    echo "ERROR: 'repo-add' not found." >&2
    echo "  Install with: pacman -S pacman (should be included)" >&2
    exit 1
fi

echo "==> Creating local repo: $REPO_NAME"
echo "==> Package dir: $PKG_DIR"

# Find all .pkg.tar.xz files
PKG_FILES=("$PKG_DIR"/*.pkg.tar.xz)
if [ ${#PKG_FILES[@]} -eq 0 ] || [ ! -f "${PKG_FILES[0]}" ]; then
    echo "ERROR: No .pkg.tar.xz files found in $PKG_DIR" >&2
    echo "  Run build-pacman.sh first to build packages." >&2
    exit 1
fi

# Remove old repo files
rm -f "$PKG_DIR/$REPO_NAME.db" "$PKG_DIR/$REPO_NAME.db.tar.xz" 2>/dev/null
rm -f "$PKG_DIR/$REPO_NAME.files" "$PKG_DIR/$REPO_NAME.files.tar.xz" 2>/dev/null

# Add all packages to the repo
cd "$PKG_DIR"
for pkg in *.pkg.tar.xz; do
    [ -f "$pkg" ] || continue
    echo "  Adding: $pkg"
    repo-add "$REPO_FILE" "$pkg"
done

echo ""
echo "✅ Local repo created: $REPO_FILE"
echo ""
echo "To use this repo, add to /data/data/com.termux/files/usr/etc/pacman.conf:"
echo ""
echo "  [mali-gpu]"
echo "  SigLevel = Optional TrustAll"
echo "  Server = file://$PKG_DIR"
echo ""
echo "Then: pacman -Sy && pacman -S virglrenderer angle-android mesa-vulkan-icd-wrapper"
