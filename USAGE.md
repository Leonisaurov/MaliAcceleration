# Usage

How to use the Mali GPU acceleration stack — both the **Termux-native** path
(single GL/WebGL apps, no proot) and the **Termux + proot** path (full XFCE
desktop). For installation steps, see the [README](README.md) and
[docs/TERMUX-ONLY.md](docs/TERMUX-ONLY.md).

## What you're driving

The render chain, in both modes:

```
app (Termux or proot) -> Mesa virpipe -> socket -> virgl_test_server -> ANGLE -> Vulkan -> Mali
```

Only the last hop is the real GPU — everything above it is translation.

Two wrappers exist:

- **`config/gpu`** — the main wrapper, installed on the **Termux host** as
  `~/.local/bin/gpu`. Self-contained: starts/stops the virgl server, switches
  GL profiles and ANGLE backends, updates packages from CI, and runs apps with
  acceleration.
- **`config/gpu.alias`** — a shell *alias* used **inside a proot distro** for
  per-app acceleration. It only sets the env vars; the server always runs on
  the Termux host.

---

## Requirements

### Hardware

- **ARM Mali GPU** (Midgard / Bifrost / Valhall, roughly G52–G715).
- Tested on: **Xiaomi Redmi Pad 2** (MediaTek Helio G100-Ultra, **Mali-G57 MC2**),
  Android 15 / HyperOS 2, **no root**.
- **Not for Adreno:** Qualcomm Adreno GPUs expose `/dev/kgsl` and should use
  **Turnip / Zink** instead — see
  [docs/GPU-COMPATIBILITY.md](docs/GPU-COMPATIBILITY.md).

### Software on the Termux host

| Package / app | Why |
|---|---|
| Termux from **F-Droid** | the Play Store build is too old / unsupported |
| **Termux:X11** (F-Droid) | X server + display app |
| `virglrenderer`, `virglrenderer-android` | the virgl server (ANGLE-modified build) |
| `angle-android` | ANGLE libraries (Vulkan backend) |
| `vulkan-loader-generic` | generic Vulkan loader (part of the ICD fix) |
| `wget`, `which`, `openssl`, `dpkg` | tooling + installing the ICD wrapper .deb |
| `mesa-vulkan-icd-wrapper_25.0.0-1_aarch64.deb` | the Mali Vulkan ICD wrapper — **make-or-break**, downloaded separately |

### For the proot method (XFCE desktop)

- A proot distro: **udroid** (`jammy:xfce4`) or `proot-distro`.
- **XFCE4** desktop inside the distro.
- The `gpu` alias (`config/gpu.alias`) added to the distro's shell rc
  (`~/.bashrc` or `~/.zshrc`).

### Permissions

- Grant **storage access** to Termux — required for the `/storage/emulated/0`
  bind mount in `scripts/start-ubuntu.sh`:

  ```bash
  termux-setup-storage
  ```

---

## Installation (Termux native)

All commands run in **Termux** (the host).

### Manual install

```bash
# 0. Get this repo
pkg install git
git clone https://github.com/Theguilherm3/termux-mali-gpu-acceleration ~/termux-mali-gpu-acceleration
cd ~/termux-mali-gpu-acceleration

# 1. Install the virgl/ANGLE toolkit
pkg install wget which virglrenderer virglrenderer-android angle-android

# 2. Download the vgl toolkit (Termux-native script)
cd && rm -f ~/vgl && \
  wget https://github.com/ar37-rs/virgl-angle/raw/refs/heads/main/vgl && \
  chmod +x ~/vgl

# 3. The Mali Vulkan ICD fix (make-or-break) — see note below
pkg remove *icd-swrast && pkg install vulkan-loader-generic wget openssl && \
  cd && rm -f ~/mesa-vulkan-icd-wrapper_25.0.0-1_aarch64.deb && \
  wget https://github.com/ar37-rs/virgl-angle/releases/download/latest/mesa-vulkan-icd-wrapper_25.0.0-1_aarch64.deb && \
  dpkg -i ~/mesa-vulkan-icd-wrapper_25.0.0-1_aarch64.deb

# 4. Install the gpu wrapper
mkdir -p ~/.local/bin
cp ~/termux-mali-gpu-acceleration/config/gpu ~/.local/bin/gpu && chmod +x ~/.local/bin/gpu
```

> **The ICD fix is make-or-break.** Without it, ANGLE can't find Mali's Vulkan
> driver and silently falls back to Mali's broken OpenGL — the exact
> `texImage2D 0x0502` / `EGL_BAD_ACCESS` errors. The fix removes the software
> ICD, installs the generic Vulkan loader, and adds the Mesa ICD wrapper:
> `pkg remove '*icd-swrast'` → `pkg install vulkan-loader-generic` →
> `dpkg -i ~/mesa-vulkan-icd-wrapper_25.0.0-1_aarch64.deb`. You only need it
> once per Termux installation.
>
> `pkg remove *icd-swrast` relies on the shell passing the unmatched glob
> through to `apt`, which then matches the package name. If your shell sets
> `failglob` or `nullglob` differently from Termux's default, quote it:
> `pkg remove '*icd-swrast'`.

### Automated install

The repo's installer does all of the above (packages, `vgl`, the `gpu` wrapper,
the ICD fix, and verification checks):

```bash
./scripts/setup.sh              # install everything (re-run safe)
./scripts/setup.sh --no-pacman  # force apt even if pacman is present
./scripts/setup.sh --help       # show help
```

### Pacman alternative

If you use **pacman** instead of `pkg`/`apt`: install the base dependencies from
pacman, then `dpkg -i` the three upstream `.deb` packages (virglrenderer,
angle-android, mesa-vulkan-icd-wrapper) from
[ar37-rs/virgl-angle releases](https://github.com/ar37-rs/virgl-angle/releases)
— or build native .pkg.tar.xz with this repo's tooling:

```bash
cd packages
./build-pacman.sh       # downloads upstream .deb -> converts to .pkg.tar.xz
pacman -U *.pkg.tar.xz  # install them
```

> **Note:** `~/vgl i` uses `pkg` internally and will **not** work with pacman.
> Install everything manually (or via `build-pacman.sh`); all other `~/vgl`
> commands and the `gpu` wrapper are package-manager-agnostic.

---

## Usage in Termux native (no proot)

### 1. Start the virgl server

In one Termux terminal:

```bash
~/.local/bin/gpu
```

(Equivalent: `~/vgl angle=vulkan`.) The server creates the socket at
`$PREFIX/tmp/.virgl_test` and prints something like:

```
using virgl angle=vulkan.
(OpenGL 4.1COMPAT profile)
```

Keep this terminal open — the server must stay running.

> **Never start the server with `virgl_test_server_android --angle-vulkan`.**
> That variant silently falls back to Mali's broken OpenGL path. The `angle=vulkan`
> mode (via the `gpu` wrapper or `~/vgl`) is the one that gives working
> acceleration.

### 2. Launch Termux:X11

In another terminal:

```bash
termux-x11 :1 -ac -dpi 192 &
sleep 3
am start --user 0 -n com.termux.x11/.MainActivity
```

> **Never pass `-legacy-drawing` to `termux-x11`.** Combined with virgl it
> produces `X_GetImage BadMatch` and a blank screen.

### 3. Run a GL app

```bash
DISPLAY=:1 ~/.local/bin/gpu glxgears -info
```

The wrapper auto-starts the server if it isn't running, then launches the app
with acceleration.

### The `gpu` wrapper subcommands

| Command | Effect |
|---|---|
| `gpu` | Start virgl server (current profile) |
| `gpu <app> [args]` | Start server (if needed) + run app accelerated |
| `gpu q` | Kill the virgl server |
| `gpu info` | Full diagnostic output (server, backend, profile, renderer, extensions) |
| `gpu --help` / `-h` | Show help |
| `gpu angle=vulkan` | ANGLE → Vulkan backend (default, recommended for Mali) |
| `gpu angle=vulkan-null` | ANGLE → Vulkan with null surface |
| `gpu angle=gl` | ANGLE → OpenGL (debug only — broken on Mali) |
| `gpu use-android` | Native virgl, no ANGLE (fallback) |
| `gpu use-angle` | Switch back to ANGLE |
| `gpu <profile>` | Set GL profile (see below) |
| `gpu config=d3d` / `cfg=d3d` | Enable Direct3D compat mode |
| `gpu config=gl` / `cfg=gl` | Disable Direct3D mode (default) |
| `gpu update-angle` | Update ANGLE from CI (pacman pkg) |
| `gpu update-renderer` / `update-virgl` | Update virglrenderer from CI (pacman pkg) |
| `gpu update-icd` | Update mesa-vulkan-icd-wrapper from CI (pacman pkg) |
| `gpu update-all` | Update all GPU packages from CI |

**Profiles:** `2.1COMPAT` `3.2COMPAT` `3.3COMPAT` `4.1COMPAT` (default)
`4.3COMPAT` `4.5COMPAT` `4.6COMPAT` `3.2CORE` `3.3CORE` `4.1CORE` `4.3CORE`
`4.5CORE` `4.6CORE`. Drop to a lower one (e.g. `2.1COMPAT`) if an app reports
missing extensions or crashes.

```bash
DISPLAY=:1 ~/.local/bin/gpu 4.3COMPAT   # expose compute shaders
DISPLAY=:1 ~/.local/bin/gpu info        # check everything
```

### Environment variables the wrapper sets

- `GALLIUM_DRIVER=virpipe` — route GL calls to the virgl server (the whole point)
- `MESA_NO_ERROR=1` — performance: skip GL error checking
- `MESA_BACK_BUFFER=pixmap` — compatible back-buffer mode for Termux:X11
- `MESA_GL_VERSION_OVERRIDE` / `MESA_GLSL_VERSION_OVERRIDE` — set per profile
- `MESA_DISK_CACHE_SINGLE_FILE=1`, `MESA_DISK_CACHE_DIR=~/.cache/mesa_shader_cache`,
  `MESA_DISK_CACHE_MAX_SIZE=67108864` — persistent shader cache (avoids
  1st-run stutter)
- `LIBGL_ALWAYS_SOFTWARE=1` — set by the wrapper; virpipe is treated as a
  software driver internally, so this flag doesn't block it

---

## Usage in proot (XFCE desktop)

### 1. Edit `scripts/start-ubuntu.sh` (mandatory)

Two variables at the top **must** be edited before running:

- `USER_NAME` — your username inside the proot distro
- `UDROID_DISTRO` — your udroid distro tag (e.g. `jammy:xfce4`)

If you use `proot-distro` instead of `udroid`, replace the final login line
with the equivalent `proot-distro login ... --shared-tmp -- /home/$USER_NAME/start-xfce.sh`.

### 2. Install the launchers

```bash
# On the Termux host:
cp scripts/start-ubuntu.sh ~/ && chmod +x ~/start-ubuntu.sh
```

`scripts/start-xfce.sh` goes **inside the distro** — copy it to
`/home/<you>/start-xfce.sh` and `chmod +x` it there.

> **The `/tmp` bind mount is required.** `start-ubuntu.sh` does
> `--bind "$TMPDIR":/tmp` so the proot guest can reach the virgl socket
> (`/tmp/.virgl_test`) created by the server on the host. With `proot-distro`,
> `--shared-tmp` does the same job. Without it, the guest Mesa can't find the
> server.

### 3. Add the `gpu` alias to the distro's shell rc

The alias (`config/gpu.alias`) unsets `LIBGL_ALWAYS_SOFTWARE` (the desktop sets
it to 1) and forces `GALLIUM_DRIVER=virpipe`, plus a persistent Mesa shader
cache. Guarded so re-running doesn't duplicate the line:

```bash
grep -q "alias gpu=" ~/.bashrc 2>/dev/null || \
  echo "alias gpu='env -u LIBGL_ALWAYS_SOFTWARE GALLIUM_DRIVER=virpipe MESA_GL_VERSION_OVERRIDE=4.1COMPAT MESA_GLSL_VERSION_OVERRIDE=410 MESA_DISK_CACHE_SINGLE_FILE=1 MESA_DISK_CACHE_DIR=\$HOME/.cache/mesa_shader_cache MESA_DISK_CACHE_MAX_SIZE=67108864'" >> ~/.bashrc
source ~/.bashrc
```

(Replace `~/.bashrc` with `~/.zshrc` if you use zsh.) The alias expands to:

```bash
env -u LIBGL_ALWAYS_SOFTWARE GALLIUM_DRIVER=virpipe MESA_GL_VERSION_OVERRIDE=4.1COMPAT MESA_GLSL_VERSION_OVERRIDE=410 MESA_DISK_CACHE_SINGLE_FILE=1 MESA_DISK_CACHE_DIR=$HOME/.cache/mesa_shader_cache MESA_DISK_CACHE_MAX_SIZE=67108864
```

### 4. Run it

From Termux:

```bash
./start-ubuntu.sh
```

This kills stale X/virgl state, starts the virgl server in ANGLE → Vulkan mode
on the host, brings up Termux:X11, and logs into the distro to launch the
desktop.

**How the desktop is structured** (`scripts/start-xfce.sh`): the desktop shell
(panel, WM, wallpaper) runs in **software** (`LIBGL_ALWAYS_SOFTWARE=1`,
`GALLIUM_DRIVER=llvmpipe`) for stability, and the GPU is applied **per app**
via the `gpu` alias. There is **no session manager** — components are launched
by hand under `dbus-run-session` to avoid ICE-socket flakiness on the
bind-mounted `/tmp` (trade-off: no graphical logout button; close via the
Termux:X11 app or Ctrl+C).

### 5. Inside the desktop

```bash
gpu glxgears       # accelerated
gpu blender        # accelerated
firefox-gpu        # Firefox with accelerated WebGL (config/firefox-gpu)
```

For Firefox WebGL, set `webgl.force-enabled = true` and `gfx.webrender.all = false`
in `about:config` (true makes the UI buggy under virgl).

> **`vgl` does not exist inside the distro — that's normal.** `vgl` lives in
> Termux; the server is already running on the host (started by
> `start-ubuntu.sh`). Inside the distro just use the `gpu` alias.

---

## Verification

**Termux-native:**

```bash
DISPLAY=:1 ~/.local/bin/gpu glxgears -info
```

**Proot (inside the desktop terminal):**

```bash
gpu glxgears -info
```

Look at the first line of output:

- **Working:** `GL_RENDERER = virgl (ANGLE (ARM, Vulkan 1.3.303 (Mali-...)))`
- **Not working:** `GL_RENDERER = virgl (Mesa X11)` or `llvmpipe` — the
  ANGLE → Vulkan hop is missing (ICD fix not applied, or server started wrong).

For a full diagnostic dump (server status, backend, profile, ANGLE symlinks,
renderer, extensions), run:

```bash
~/.local/bin/gpu info          # native
gpu info                       # proot (install mesa-utils for renderer info)
```

> `glxinfo` may throw `X_GetImage BadMatch` — that is a cosmetic probing quirk
> under virgl, not a real failure. `glxgears` and WebGL render fine.

---

## Updating packages

| Method | Command |
|---|---|
| CI builds (pacman, from [Leonisaurov/MaliAcceleration](https://github.com/Leonisaurov/MaliAcceleration/releases)) | `gpu update-angle`, `gpu update-renderer` (alias `update-virgl`), `gpu update-icd`, `gpu update-all` |
| Upstream `vgl` (ar37-rs/virgl-angle) | `~/vgl update-angle`, `~/vgl update-virgl` |
| Manual (upstream .deb) | download the .deb from ar37-rs/virgl-angle releases, `dpkg -i` it |

The `gpu update-*` commands download `.pkg.tar.xz` from the CI releases and
install them with `pacman -U`, so they require the pacman package manager on
the Termux host.

---

## Quick troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `texImage2D ... 0x0502` + `EGL_BAD_ACCESS` | ANGLE on the broken OpenGL path | Start the server with `~/vgl angle=vulkan` (not `virgl_test_server_android --angle-vulkan`) **and** make sure the ICD fix was applied (`dpkg -i ~/mesa-vulkan-icd-wrapper_25.0.0-1_aarch64.deb`) |
| Blank screen; `X_GetImage BadMatch` | Desktop forced through virgl, or `-legacy-drawing` used | Run the shell in software (`LIBGL_ALWAYS_SOFTWARE=1`, `GALLIUM_DRIVER=llvmpipe`) + GPU per app; **never** pass `-legacy-drawing` to `termux-x11` |
| `GL_RENDERER = llvmpipe` / `virgl (Mesa X11)` | ANGLE → Vulkan hop missing | Apply the ICD fix; restart the server with `angle=vulkan` |
| `vgl: command not found` inside the distro | `vgl` is host-only | Normal — server runs on the Termux host; use the `gpu` alias instead |
| Alacritty shader error `output location 0 >= GL_MAX_DUAL_SOURCE_DRAW_BUFFERS` | dual-source blending reported but unsupported by virgl/ANGLE | Set `renderer = "Gles2Pure"` in `~/.config/alacritty/alacritty.toml`, or run with `MESA_EXTENSION_OVERRIDE="-GL_EXT_blend_func_extended"`, or use another terminal (xfce4-terminal, foot) |

### Safe-to-ignore log noise

- `glxinfo` → `X_GetImage BadMatch` — cosmetic probing quirk, apps render fine
- `virgl_fence_set_fd: failed err=-9` — known virgl fence limitation, harmless
- Firefox `glxtest` → "No GPUs detected via PCI" — cosmetic
- `Xlib: extension "DPMS" missing` — Termux:X11 has no DPMS
- `Failed to connect to session manager` — expected, no session manager running
- `fuse`, `pipewire`, `colord`, system-bus warnings — normal proot noise

For the full list of known walls and fixes, see
[docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).
