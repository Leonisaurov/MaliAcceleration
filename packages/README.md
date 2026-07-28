# Pacman packages for Mali GPU acceleration

This directory provides tooling to build native Termux pacman packages
(.pkg.tar.xz) for the Mali GPU acceleration stack.

## Build strategies

| Package | Strategy | How |
|---------|----------|-----|
| `virglrenderer` | **From source** | Downloads source from [freedesktop.org](https://gitlab.freedesktop.org/virgl/virglrenderer), compiles with meson+ninja |
| `angle-android` | Prebuilt binary | ANGLE requires Google's depot_tools + Chromium-scale build — impractical for on-device builds. Uses binaries from upstream releases |
| `mesa-vulkan-icd-wrapper` | **From source** | Auto-detects Mali's Vulkan driver on the device; generates ICD JSON configuration |

## Quick start

```bash
# Build all packages
cd packages
./build-pacman.sh

# Install them
pacman -U *.pkg.tar.xz
```

## Manual build per package

```bash
# Build only virglrenderer from source
./build-pacman.sh virgl

# Build only angle-android (prebuilt)
./build-pacman.sh angle

# Build only mesa-vulkan-icd-wrapper (from source)
./build-pacman.sh icd

# Clean all build artifacts
./build-pacman.sh clean
```

## Scripts

| Script | Purpose |
|---|---|
| `build-pacman.sh` | Master build script: builds all packages with optimal strategy |
| `deb2pkg.sh` | Local utility: convert any .deb → .pkg.tar.xz (for local .deb files) |
| `repo-add.sh` | Create a local pacman repository from built .pkg.tar.xz files |

## Build dependencies

Required for source builds:
```bash
pacman -S meson ninja pkg-config
pacman -S libdrm libepoxy libglvnd libx11 mesa
```

Required for prebuilt binary conversion:
```bash
pacman -S dpkg
```

## PKGBUILD files

The `PKGBUILD.*` files are provided for integration with `makepkg` on systems
that support it. In Termux, use `build-pacman.sh` instead.

## About ANGLE source builds

[ANGLE](https://chromium.googlesource.com/angle/angle) (Almost Native Graphics
Layer Engine) is a large C++ project that shares infrastructure with Chromium.
Building it requires:

- Google's [depot_tools](https://chromium.googlesource.com/chromium/tools/depot_tools/)
- GN meta-build system
- Android NDK
- Several gigabytes of source code
- Multiple compilations (one per backend: gl, vulkan, vulkan-null)

This is not practical to do on-device in Termux. Termux's own
[angle-android package](https://github.com/termux/termux-packages/tree/master/packages/angle-android)
also uses pre-built binaries.

## About mesa-vulkan-icd-wrapper

This package creates a Vulkan ICD JSON file that tells Termux's
`vulkan-loader-generic` where to find Mali's system Vulkan driver. It is
built from source (not a .deb conversion) and auto-detects the Mali driver
at build time when possible, or at install time via a post-install script.
