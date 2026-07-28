# AGENTS.md — termux-mali-gpu-acceleration

This repo is a **documentation + shell-scripts** project for getting hardware-accelerated GL/WebGL (via virgl -> ANGLE -> Vulkan -> Mali) working on unrooted Mali-GPU Android devices, inside either Termux directly or Termux + proot. There is nothing to build, compile, or test. See `docs/TERMUX-ONLY.md` for the Termux-native (no proot) variant.

## No build system — this is not a code project

- No CI, no tests, no linter, no package.json, no Cargo.toml, no Makefile.
- Every file is either markdown or a shell script. Edits are straightforward.
- If you want to verify a change works, the only way is to run the full desktop flow on an actual Mali device inside Termux — there is no unit-test or CI gate.

## Repo layout

```
config/
  firefox-gpu      Wrapper script to launch Firefox with GPU acceleration
  gpu.alias        Shell alias definition for per-app GPU wrapper
docs/
  GPU-COMPATIBILITY.md   Explains which GPUs this repo applies to vs Adreno
  TROUBLESHOOTING.md     Known errors and their fixes
  TERMUX-ONLY.md       Guide for using acceleration directly in Termux without proot
  screenshots/           Proof-of-concept images
scripts/
  start-ubuntu.sh   Termux-host launcher (editing required)
  start-xfce.sh     proot-guest desktop launcher (drop-session-manager pattern)
```

## Critical gotchas an agent WILL miss

### The `gpu` alias is the whole point

Add `config/gpu.alias` to the distro's shell rc. It unsets `LIBGL_ALWAYS_SOFTWARE` (the desktop sets it to 1) and forces `GALLIUM_DRIVER=virpipe`:

```bash
alias gpu='env -u LIBGL_ALWAYS_SOFTWARE GALLIUM_DRIVER=virpipe MESA_GL_VERSION_OVERRIDE=4.1COMPAT MESA_GLSL_VERSION_OVERRIDE=410'
```

Desktop shell stays in software; GPU is applied **per app** via `gpu <app>`.

### `~/vgl angle=vulkan` — not `virgl_test_server_android --angle-vulkan`

The virgl server MUST be started with `~/vgl angle=vulkan`. The `virgl_test_server_android --angle-vulkan` variant silently falls back to Mali's broken OpenGL path. This is the single most common mistake (documented in TROUBLESHOOTING.md).

### The Vulkan ICD fix is make-or-break

If ANGLE can't find Mali's Vulkan, it falls back to OpenGL, producing `texImage2D 0x0502` / `EGL_BAD_ACCESS`. The fix (step 2 in README):

```bash
pkg remove '*icd-swrast'          # remove software ICD
pkg install vulkan-loader-generic # install generic loader
dpkg -i mesa-vulkan-icd-wrapper_25.0.0-1_aarch64.deb  # Mali ICD wrapper
```

The `*icd-swrast` glob may need quoting depending on shell options.

### Editing `start-ubuntu.sh` is required

Two variables at the top **must** be edited before running:
- `USER_NAME` — your username inside the proot distro
- `UDROID_DISTRO` — your udroid distro tag (e.g. jammy:xfce4)

If using `proot-distro` instead of `udroid`, replace the final login line.

### The `/tmp` bind mount is required

`start-ubuntu.sh` does `--bind "$TMPDIR":/tmp` so the proot guest can reach the virgl socket created on the host. Without it, the guest Mesa can't find the server.

### No session manager — intentional

`start-xfce.sh` skips `xfce4-session` and launches XFCE components by hand under `dbus-run-session`. This stops ICE socket flakiness on bind-mounted `/tmp` and ghost-WM-from-disk issues. Trade-off: no graphical logout button (close via Termux:X11 app or Ctrl+C).

### `-legacy-drawing` + virgl = blank screen

Never pass `-legacy-drawing` to `termux-x11`. Combined with virgl, it produces `X_GetImage BadMatch` and a blank desktop.

### Safe-to-ignore log noise

- `glxinfo` → `X_GetImage BadMatch` — cosmetic probing quirk, apps render fine
- `virgl_fence_set_fd: failed err=-9` — known virgl fence limitation, harmless
- Firefox `glxtest` → "No GPUs detected via PCI" — cosmetic
- `Xlib: extension "DPMS" missing` — Termux:X11 has no DPMS
- `Failed to connect to session manager` — expected, no session manager
- `fuse`, `pipewire`, `colord`, system-bus warnings — normal proot noise

## Termux-native (no proot)

The `~/vgl` toolkit from ar37-rs/virgl-angle is **primarily a Termux-native tool** — its shebang is `#!/data/data/com.termux/files/usr/bin/bash` and it references Termux paths. The full virgl → ANGLE → Vulkan → Mali stack works directly in Termux without a proot distro.

**When to use each:**

| Situation | Use |
|---|---|
| Run a single GL app (glmark2, glxgears, a game) | Termux-native — simpler, no proot overhead |
| Run a full Linux desktop (XFCE, panel, file manager) | Proot method — this repo's default |
| Run Firefox with WebGL | Either — both work the same under the hood |

**Key differences from proot method:**

- **No proot distro needed** — no `start-ubuntu.sh`, no `start-xfce.sh`, no bind mounts
- **No `gpu` alias needed** — just set `GALLIUM_DRIVER=virpipe` directly (Termux doesn't set `LIBGL_ALWAYS_SOFTWARE` by default)
- **Socket path**: Termux's virpipe looks for `$PREFIX/tmp/.virgl_test` (not `/tmp/`) — handled by a Termux-specific Mesa patch
- **Usage pattern**: `~/vgl angle=vulkan` to start server, then `DISPLAY=:1 GALLIUM_DRIVER=virpipe glxgears -info` to run apps
- **The `vgl` script** already sets `GALLIUM_DRIVER=virpipe` internally — you can also use `DISPLAY=:1 ~/vgl glxgears -info`
- **All caveats apply** — same limitations, same ICD fix, same log noise, same `-legacy-drawing` prohibition

See `docs/TERMUX-ONLY.md` for the complete step-by-step guide.

## Verification

Inside the desktop terminal:

```bash
gpu glxgears -info
```

`GL_RENDERER` should read `virgl (ANGLE (ARM, Vulkan 1.3.303 (Mali-...)))`. If it says `Mesa X11` or `llvmpipe`, acceleration is not working.

## Key limitations

- **No video decode acceleration** — no VA-API through virgl. YouTube will stutter regardless.
- **~10% of native GPU throughput** — bottleneck is the virgl bridge, not the chip.
- **Mali only** — Adreno GPUs should use Turnip/Zink instead (see GPU-COMPATIBILITY.md).
- **No Firefox WebRender** — set `gfx.webrender.all = false` in about:config (true makes UI buggy under virgl).

## How this repo is tested

The only test environment is a real device: Xiaomi Redmi Pad 2 (Mali-G57 MC2), Termux + udroid Ubuntu 22.04, Android 15 / HyperOS 2, no root. Changes to scripts cannot be verified without physical access to a Mali-GPU Android device running Termux.
