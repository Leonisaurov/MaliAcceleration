# Pacman packages for Mali GPU acceleration

This directory contains tooling to build native Termux pacman packages
(.pkg.tar.xz) for the Mali GPU acceleration stack.

The packages are built from pre-compiled `.deb` binaries published by
[ar37-rs/virgl-angle](https://github.com/ar37-rs/virgl-angle) releases.

## Quick start

```bash
# Build all packages (downloads .deb from upstream, converts to .pkg.tar.xz)
cd packages
./build-pacman.sh

# Install them
pacman -U *.pkg.tar.xz
```

## Available packages

| Package | Contents | Source |
|---|---|---|
| `virglrenderer` | `virgl_test_server` binary (modified for ANGLE) | ar37-rs/virgl-angle |
| `angle-android` | ANGLE libraries (Vulkan/GL backends) | ar37-rs/virgl-angle |
| `mesa-vulkan-icd-wrapper` | Mali Vulkan ICD wrapper (required fix) | ar37-rs/virgl-angle |

## Scripts

| Script | Purpose |
|---|---|
| `build-pacman.sh` | Master build script: download + convert all packages |
| `deb2pkg.sh` | Core converter: any .deb → .pkg.tar.xz |
| `repo-add.sh` | Create a local pacman repo from .pkg.tar.xz files |

## Manual conversion

```bash
# Convert any single .deb to .pkg.tar.xz
./deb2pkg.sh angle-android_2.1.2-latest.deb
# Output: angle-android-2.1.2-1-aarch64.pkg.tar.xz

# Install with pacman
pacman -U angle-android-2.1.2-1-aarch64.pkg.tar.xz
```

## Local pacman repo

If you want to use `pacman -S` instead of `pacman -U`:

```bash
./build-pacman.sh
./repo-add.sh
```

Then add to `/data/data/com.termux/files/usr/etc/pacman.conf`:

```ini
[mali-gpu]
SigLevel = Optional TrustAll
Server = file:///data/data/com.termux/files/home/termux-mali-gpu-acceleration/packages
```

Then:

```bash
pacman -Sy
pacman -S virglrenderer angle-android mesa-vulkan-icd-wrapper
```

## PKGBUILD files

The `PKGBUILD.*` files are provided as reference for those who want to
integrate with `makepkg`. They download the upstream `.deb` and extract it.
For day-to-day use, `deb2pkg.sh` is simpler.

## Notes

- `dpkg` and `pacman` coexist safely in Termux (separate databases).
- These packages are binary repackages of the upstream .deb files, not
  builds from source.
- The version numbers match the upstream ar37-rs/virgl-angle releases.
