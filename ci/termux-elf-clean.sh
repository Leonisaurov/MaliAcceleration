#!/usr/bin/env bash
# =============================================================================
#  termux-elf-clean.sh  —  Apply Termux ELF cleaning to a package staging dir
# =============================================================================
#  Downloads termux-elf-cleaner (cached) and runs it with --api-level 24 over
#  all ELF files under the Termux-prefix paths embedded in the staging dir
#  (data/data/com.termux/files/usr/{bin,lib,lib32,libexec,opt}/).
#  This is part of the official Termux packaging format: it removes DT_RPATH,
#  fixes TLS segment alignment, and cleans DT_FLAGS_1.
#
#  Usage:  ./ci/termux-elf-clean.sh <pkgdir>
# =============================================================================
set -euo pipefail

PKGDIR="${1:?Usage: $0 <pkgdir>}"
CACHE_DIR="${TMPDIR:-/tmp}/termux-elf-cleaner-cache"
mkdir -p "$CACHE_DIR"

ELF_CLEANER="$CACHE_DIR/termux-elf-cleaner"
ELF_CLEANER_VERSION="3.0.1"
ELF_CLEANER_SHA256="59645fb25b84d11f108436e83d9df5e874ba4eb76ab62948869a23a3ee692fa7"

# --- Download if not cached -------------------------------------------
if [ ! -x "$ELF_CLEANER" ]; then
    echo "Downloading termux-elf-cleaner v${ELF_CLEANER_VERSION}..."
    wget -q -O "$ELF_CLEANER" \
        "https://github.com/termux/termux-elf-cleaner/releases/download/v${ELF_CLEANER_VERSION}/termux-elf-cleaner"
    echo "$ELF_CLEANER_SHA256  $ELF_CLEANER" | sha256sum -c - >/dev/null 2>&1 || {
        echo "ERROR: termux-elf-cleaner checksum mismatch" >&2
        rm -f "$ELF_CLEANER"
        exit 1
    }
    chmod +x "$ELF_CLEANER"
fi

# --- Apply to ELFs in standard package paths --------------------------
echo "Running termux-elf-cleaner --api-level 24 on: $PKGDIR"
cd "$PKGDIR"
# Collect ELF files only (termux-packages filters with `file` too, so a
# stray non-ELF under lib/ (e.g. a .pc) never reaches the cleaner).
# pipefail is disabled for this pipeline: `grep` exits 1 when no ELF is
# found, which would abort the script under `set -o pipefail`; with it off
# the pipe simply yields no input and `xargs -r` runs nothing.
set +o pipefail
find . \( -path "./data/data/com.termux/files/usr/bin/*" \
         -o -path "./data/data/com.termux/files/usr/lib/*" \
         -o -path "./data/data/com.termux/files/usr/lib32/*" \
         -o -path "./data/data/com.termux/files/usr/libexec/*" \
         -o -path "./data/data/com.termux/files/usr/opt/*" \) -type f -print0 | \
    xargs -0 -r file | \
    grep "ELF" | \
    cut -d: -f1 | \
    xargs -r "$ELF_CLEANER" --api-level 24
set -o pipefail
echo "termux-elf-cleaner done."
