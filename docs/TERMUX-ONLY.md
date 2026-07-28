# Termux-Only GPU Acceleration (no proot)

The full virgl → ANGLE → Vulkan → Mali acceleration stack works **directly in
Termux**, no proot distro required. This document covers the native Termux path.

The repo's main [README](../README.md) targets Termux + proot + XFCE for people
who want a full Linux desktop. But if you just want to run individual GL or
WebGL apps (e.g. `glxgears`, a WebGL browser, an OpenGL game) natively in
Termux, this is the simpler way: no distro setup, no bind mounts, no session
manager tricks.

The render chain is the same:

```
app (Termux) -> Mesa virpipe -> socket -> virgl_test_server -> ANGLE -> Vulkan -> Mali
```

Only the last hop is the real GPU — everything above it is translation.

---

## When to use this vs. the proot method

| You want… | Use this |
|-----------|----------|
| A single GL app or WebGL browser, no desktop | **Termux-native** (this page) |
| A full XFCE Linux desktop inside Termux | [Proot method](../README.md) |
| KDE, GNOME, or another heavy DE | Proot method (but you're on your own) |
| To test if acceleration works at all | **Termux-native** (minimal setup) |

---

## Prerequisites

- Termux — install from **F-Droid** or [GitHub Releases](https://github.com/termux/termux-app/releases)
  (the Play Store build is unsupported, too old).
- The [**Termux:X11**](https://github.com/termux/termux-x11) companion app.
- A **Mali GPU** (see [GPU-COMPATIBILITY.md](GPU-COMPATIBILITY.md) — Adreno
  devices should use Turnip/Zink instead).

---

## Installation

All commands run in **Termux** (no proot involved).

> **Package manager note:** These steps use `pkg` (Termux's apt frontend). If you use
> **pacman** instead, see the [Pacman alternative](#pacman-alternative) at the end of
> this section for the equivalent commands. The `vgl` script and the rest of the
> guide work identically regardless of package manager.

### 0. (Optional) Clone this repo

```bash
pkg install git
git clone https://github.com/Theguilherm3/termux-mali-gpu-acceleration ~/termux-mali-gpu-acceleration
```

You can also just follow the steps below without cloning — only a few commands
are needed.

### 1. Install the virgl/ANGLE toolkit

```bash
pkg install wget which virglrenderer virglrenderer-android angle-android
```

### 2. Get the `vgl` script

```bash
cd && rm -f ~/vgl && \
  wget https://github.com/ar37-rs/virgl-angle/raw/refs/heads/main/vgl && \
  chmod +x ~/vgl
```

The `vgl` script is the one-stop tool for starting the virgl server and
launching GPU-accelerated apps. It is a **Termux-native** script (shebang
`#!/data/data/com.termux/files/usr/bin/bash`) and all its paths reference
Termux's filesystem.

### 3. The Mali Vulkan ICD fix (make-or-break)

Without this step, ANGLE cannot find Mali's Vulkan driver and silently falls
back to Mali's broken OpenGL — the exact cause of the `texImage2D 0x0502` /
`EGL_BAD_ACCESS` errors. You only need this once per Termux installation:

```bash
pkg remove *icd-swrast && pkg install vulkan-loader-generic wget openssl && \
  cd && rm -f ~/mesa-vulkan-icd-wrapper_25.0.0-1_aarch64.deb && \
  wget https://github.com/ar37-rs/virgl-angle/releases/download/latest/mesa-vulkan-icd-wrapper_25.0.0-1_aarch64.deb && \
  dpkg -i ~/mesa-vulkan-icd-wrapper_25.0.0-1_aarch64.deb
```

> **Note:** `pkg remove *icd-swrast` relies on the shell passing the unmatched
> glob through to `apt`. If your shell sets `failglob` or `nullglob` differently
> from Termux's default, quote it: `pkg remove '*icd-swrast'`.

### Pacman alternative

If you use **pacman** instead of `pkg`/`apt`, the package names are the same but
some packages are only distributed as `.deb` from the upstream
[ar37-rs/virgl-angle](https://github.com/ar37-rs/virgl-angle) releases.

```bash
# 1. Base dependencies from pacman
pacman -S dpkg wget which vulkan-loader-generic openssl

# 2. virglrenderer (modified for ANGLE) — only available as .deb from upstream
cd && wget https://github.com/ar37-rs/virgl-angle/releases/download/latest/virglrenderer_1.1.1-latest_aarch64.deb && \
  dpkg -i virglrenderer_1.1.1-latest_aarch64.deb

# 3. angle-android — only available as .deb from upstream
wget https://github.com/ar37-rs/virgl-angle/releases/download/latest/angle-android_2.1.2-latest.deb && \
  dpkg -i angle-android_2.1.2-latest.deb

# 4. mesa-vulkan-icd-wrapper — only available as .deb from upstream
wget https://github.com/ar37-rs/virgl-angle/releases/download/latest/mesa-vulkan-icd-wrapper_25.0.0-1_aarch64.deb && \
  dpkg -i mesa-vulkan-icd-wrapper_25.0.0-1_aarch64.deb
```

> **Note:** The `vgl` script's `~/vgl i` command uses `pkg` internally and will
> not work with pacman. Install everything manually as shown above, or use
> `./packages/build-pacman.sh` to build native .pkg.tar.xz packages. All other
> `~/vgl` commands (`angle=vulkan`, `q`, launching apps, etc.) are
> package-manager-agnostic.

> **About dpkg + pacman coexistence:** `dpkg` and `pacman` have separate
> databases in Termux and can coexist safely. Use pacman for system packages and
> `dpkg -i` only for these three `.deb` files from upstream. Do not mix both
> package managers for the same package.

> **Even easier: use `packages/build-pacman.sh`** — this repo's
> [`packages/`](../packages/README.md) directory contains a build script that
> automates downloading the upstream .deb files and converting them to .pkg.tar.xz
> for pacman. Run `./packages/build-pacman.sh` then `pacman -U packages/*.pkg.tar.xz`.

---

## Usage

### 1. Start the virgl server (with ANGLE → Vulkan)

```bash
~/vgl angle=vulkan
```

This starts `virgl_test_server` with the ANGLE Vulkan backend. The server
creates the socket at `$PREFIX/tmp/.virgl_test` (set by a Termux-specific patch
in the `virglrenderer` package).

You should see:

```
using virgl angle=vulkan.
(OpenGL 4.1COMPAT profile)
```

> **Note:** The `vgl` script also creates symlinks for ANGLE libraries on first
> run (`libEGL.so.1`, `libGLESv1_CM.so.1`, `libGLESv2.so.2`) inside the ANGLE
> backend directory. If you see ANGLE init errors, check that these symlinks
> exist under `$PREFIX/opt/angle-android/vulkan/`.

Keep this terminal open — the server must stay running.

### 2. Launch Termux:X11

```bash
termux-x11 :1 -ac -dpi 192 &
sleep 3
am start --user 0 -n com.termux.x11/.MainActivity
```

> **Never** pass `-legacy-drawing` to `termux-x11`. Combined with virgl it
> produces `X_GetImage BadMatch` and a blank screen.

### 3. Run a GL app

Open a **second Termux terminal** (the first is holding the server) and run:

```bash
export DISPLAY=:1
~/vgl glxgears -info
```

The `~/vgl` wrapper sets all the required environment variables:

- `GALLIUM_DRIVER=virpipe` — route GL calls to the virgl server
- `LIBGL_ALWAYS_SOFTWARE=1` — keeps Mesa in a compatible path (virpipe is
  treated as a software driver internally, so this flag doesn't block it)
- `MESA_GL_VERSION_OVERRIDE=4.1COMPAT` / `MESA_GLSL_VERSION_OVERRIDE=410` —
  expose a modern GL version to apps
- `MESA_BACK_BUFFER=pixmap` — compatible back-buffer mode for Termux:X11
- `MESA_NO_ERROR=1` — performance optimization, skips GL error checking

#### Without the `~/vgl` wrapper

You can skip the wrapper and set the env vars manually:

```bash
DISPLAY=:1 GALLIUM_DRIVER=virpipe \
  MESA_GL_VERSION_OVERRIDE=4.1COMPAT \
  MESA_GLSL_VERSION_OVERRIDE=410 \
  glxgears -info
```

Or define a simple alias in your `~/.bashrc`:

```bash
alias gpu='DISPLAY=:1 GALLIUM_DRIVER=virpipe MESA_GL_VERSION_OVERRIDE=4.1COMPAT MESA_GLSL_VERSION_OVERRIDE=410'
```

Then:

```bash
gpu glxgears -info
```

---

## Verification

Inside Termux:X11, run:

```bash
DISPLAY=:1 ~/vgl glxgears -info
```

Look at the first line of output:

- **Working:** `GL_RENDERER = virgl (ANGLE (ARM, Vulkan 1.3.303 (Mali-...)))`
- **Not working:** `GL_RENDERER = virgl (Mesa X11)` or `llvmpipe` — the ANGLE
  → Vulkan hop is missing (ICD fix not applied or server started wrong).

> `glxinfo` may throw `X_GetImage BadMatch` — that is a cosmetic probing quirk
> under virgl, not a real failure. `glxgears` and WebGL render fine.

---

## Comparison: Termux-native vs. proot method

| Aspect | Termux-native (this page) | Proot + XFCE ([README](../README.md)) |
|---|---|---|
| **Setup complexity** | 3 `pkg` commands + 1 script download | Same packages + proot distro + XFCE + launch scripts |
| **Use case** | Individual GL/WebGL apps | Full XFCE Linux desktop |
| **virgl socket path** | `$PREFIX/tmp/.virgl_test` (Termux native) | `/tmp/.virgl_test` via `--bind "$TMPDIR":/tmp` |
| **Mesa variant** | Termux's `mesa` (bionic libc) | Distro's Mesa (glibc) |
| **GPU wrapper** | `~/vgl <app>` or `GALLIUM_DRIVER=virpipe <app>` | `gpu <app>` alias: `env -u LIBGL_ALWAYS_SOFTWARE GALLIUM_DRIVER=virpipe MESA_GL_VERSION_OVERRIDE=4.1COMPAT MESA_GLSL_VERSION_OVERRIDE=410` |
| **Desktop shell** | None — apps run directly | XFCE4 (panel, WM, desktop — all in software/llvmpipe) |
| **X server** | Manual `termux-x11` | Managed by `start-ubuntu.sh` |
| **Server management** | Manual `~/vgl angle=vulkan` | Automatic via `start-ubuntu.sh` |
| **Pros** | Minimal setup, no distro, no bind mounts, no session-manager issues, fast to start | Full desktop experience, per-app GPU via `gpu` alias, desktop stays in software automatically |
| **Cons** | Must manage server and X manually, no desktop environment, no convenient per-app wrapper by default | Heavier setup, proot overhead, ICE/gremlin risks from session manager, `/tmp` bind mount is required |

---

## Caveats

The same limitations from the proot method apply:

- **No video decode acceleration.** No VA-API through virgl. YouTube will
  stutter regardless. Mitigate with lower resolution or `yt-dlp` + `mpv`.
- **~10% of native GPU throughput.** The bottleneck is the virgl ↔ ANGLE ↔
  Vulkan bridge, not the GPU.
- **No Firefox WebRender.** Set `gfx.webrender.all = false` in `about:config`
  (true makes the UI buggy under virgl).
- **OpenGL 2.1 effective ceiling for complex apps.** While `MESA_GL_VERSION_OVERRIDE=4.1COMPAT` is set, some apps may hit virgl's limited feature set. Drop to `2.1COMPAT` if you see rendering glitches.
- **`virgl_fence_set_fd: failed err=-9`** in logs — known virgl fence limitation, harmless.

### Safe-to-ignore log noise

Same as the proot method:

- `glxinfo` → `X_GetImage BadMatch` — cosmetic probing quirk
- `virgl_fence_set_fd: failed err=-9` — known limitation
- Firefox `glxtest` → "No GPUs detected via PCI" — cosmetic
- `Xlib: extension "DPMS" missing` — Termux:X11 has no DPMS
- `Failed to connect to session manager` — expected, no session manager running

---

## vgl advanced usage

The `~/vgl` script supports several configuration options. These are controlled
by **sentinel files** in `~/.vgl-*` — touching or removing them switches modes
persistently.

### ANGLE backend

| Command | Sentinel file | Backend |
|---|---|---|
| `~/vgl angle=vulkan` | `~/.vgl-angle-vulkan` | ANGLE → Vulkan (recommended for Mali) |
| `~/vgl angle=gl` | `~/.vgl-angle-gl` | ANGLE → OpenGL (broken on Mali, for testing) |
| `~/vgl angle=vulkan-null` | *(neither sentinel)* | Vulkan with null surface |
| `~/vgl use-android` | `~/.vgl-android` | Hardware-native virgl (fallback for GPUs where ANGLE doesn't work) |

Use `angle=vulkan` for Mali. `use-android` is a fallback for GPUs where ANGLE's
Vulkan backend doesn't work — it runs virgl against the system's native GLES
driver instead. The other ANGLE modes exist for debugging or GPUs with working
OpenGL paths.

### GL version override

| Command | Sentinel file | GL version exposed |
|---|---|---|
| `~/vgl 4.1COMPAT` | *(default, no sentinel)* | OpenGL 4.1 |
| `~/vgl 4.3COMPAT` | `~/.vgl-gl43` | OpenGL 4.3 |
| `~/vgl 3.3COMPAT` | `~/.vgl-gl33` | OpenGL 3.3 |
| `~/vgl 3.2COMPAT` | `~/.vgl-gl32` | OpenGL 3.2 |
| `~/vgl 2.1COMPAT` | `~/.vgl-gl21` | OpenGL 2.1 |

Use a lower version if apps report missing extensions or crash.

### Config profile

| Command | Sentinel file | Effect |
|---|---|---|
| `~/vgl config=gl` | *(no sentinel, default)* | Default OpenGL/ES configuration |
| `~/vgl config=d3d` | `~/.vgl-d3d` | Direct3D-style config (alters extension overrides) |

### Manage the server

| Command | Effect |
|---|---|
| `~/vgl q` | Kill the running virgl server |
| `~/vgl -Q ...` | Verbose/debug mode (`set -x`) for any command |
| `~/vgl update-angle` | Download and install the latest ANGLE build (Android 10+) |
| `~/vgl update-virgl` | Download and install the latest virglrenderer build (recommended for stability, Android 10+) |

> Changing backends (`angle=vulkan` → `angle=gl`, etc.) automatically kills the
> running server and restarts it with the new mode.

---

## Quick-start one-liner

If you already have Termux and Termux:X11 installed, and only need to verify
the stack works:

```bash
# --- Install everything ---
pkg install wget which virglrenderer virglrenderer-android angle-android \
  vulkan-loader-generic openssl && \
cd && rm -f ~/vgl && \
wget https://github.com/ar37-rs/virgl-angle/raw/refs/heads/main/vgl && \
chmod +x ~/vgl && \
pkg remove '*icd-swrast' && \
wget https://github.com/ar37-rs/virgl-angle/releases/download/latest/mesa-vulkan-icd-wrapper_25.0.0-1_aarch64.deb && \
dpkg -i ~/mesa-vulkan-icd-wrapper_25.0.0-1_aarch64.deb

# --- Start the server ---
~/vgl angle=vulkan

# --- (in another Termux session) Start X and run a test ---
termux-x11 :1 -ac -dpi 192 &
sleep 3
am start --user 0 -n com.termux.x11/.MainActivity
DISPLAY=:1 ~/vgl glxgears -info
```

If you see `virgl (ANGLE (ARM, Vulkan ...))` in the renderer string,
acceleration is working.

#### Pacman quick-start

```bash
# --- Install everything (pacman) ---
pacman -S dpkg wget which vulkan-loader-generic openssl && \
cd && rm -f ~/vgl && \
wget https://github.com/ar37-rs/virgl-angle/raw/refs/heads/main/vgl && \
chmod +x ~/vgl && \
wget https://github.com/ar37-rs/virgl-angle/releases/download/latest/virglrenderer_1.1.1-latest_aarch64.deb && \
dpkg -i virglrenderer_1.1.1-latest_aarch64.deb && \
wget https://github.com/ar37-rs/virgl-angle/releases/download/latest/angle-android_2.1.2-latest.deb && \
dpkg -i angle-android_2.1.2-latest.deb && \
wget https://github.com/ar37-rs/virgl-angle/releases/download/latest/mesa-vulkan-icd-wrapper_25.0.0-1_aarch64.deb && \
dpkg -i mesa-vulkan-icd-wrapper_25.0.0-1_aarch64.deb

# --- Start the server ---
~/vgl angle=vulkan

# --- (in another Termux session) Start X and run a test ---
termux-x11 :1 -ac -dpi 192 &
sleep 3
am start --user 0 -n com.termux.x11/.MainActivity
DISPLAY=:1 ~/vgl glxgears -info
```

---

## Troubleshooting

For common errors (`texImage2D 0x0502`, blank screen, etc.) refer to the
project's [TROUBLESHOOTING.md](TROUBLESHOOTING.md) — the same root causes apply.

Key things to check:

- **Server started correctly** — `~/vgl angle=vulkan`, not `virgl_test_server_android --angle-vulkan`
- **ICD fix applied** — `dpkg -i mesa-vulkan-icd-wrapper_25.0.0-1_aarch64.deb` was run
- **No `-legacy-drawing`** flag on `termux-x11`
- **`$DISPLAY=:1`** is set when running the app
- **Socket reachable** — `ls -la $PREFIX/tmp/.virgl_test` should exist when the server is running
