# Referencias Técnicas: Aceleración GPU Mali en Termux

## URLs clave

| Recurso | URL |
|---|---|
| Toolkit vgl (upstream) | https://github.com/ar37-rs/virgl-angle |
| vgl script directo | https://github.com/ar37-rs/virgl-angle/raw/refs/heads/main/vgl |
| Mesa virgl driver docs | https://docs.mesa3d.org/drivers/virgl.html |
| Mesa Zink driver docs | https://docs.mesa3d.org/drivers/zink.html |
| Mesa Venus docs | https://docs.mesa3d.org/drivers/venus.html |
| Mesa llvmpipe docs | https://docs.mesa3d.org/gallium/drivers/llvmpipe.html |
| Google ANGLE project | https://chromium.googlesource.com/angle/angle |
| Termux packages (github) | https://github.com/termux/termux-packages |
| Termux packages (pacman) | https://github.com/termux-pacman/termux-packages |
| Benchmarks LinuxDroidMaster | https://github.com/LinuxDroidMaster/Termux-Desktops |
| WebGL Aquarium test | https://webglsamples.org/aquarium/aquarium.html |
| WebGL Report | https://webglreport.com |
| Este repo | https://github.com/Theguilherm3/termux-mali-gpu-acceleration |

## Releases de ar37-rs (archivos .deb)

| Paquete | URL |
|---|---|
| virglrenderer (modificado) | https://github.com/ar37-rs/virgl-angle/releases/download/latest/virglrenderer_1.1.1-latest_aarch64.deb |
| angle-android (completo) | https://github.com/ar37-rs/virgl-angle/releases/download/latest/angle-android_2.1.2-latest.deb |
| angle-android (minimal) | https://github.com/ar37-rs/virgl-angle/releases/download/latest/angle-android_2.1.24570_minimal.deb |
| mesa-vulkan-icd-wrapper | https://github.com/ar37-rs/virgl-angle/releases/download/latest/mesa-vulkan-icd-wrapper_25.0.0-1_aarch64.deb |

## Issues y PRs relevantes

| Issue/PR | Descripción | URL |
|---|---|---|
| issue #1 | Vulkan ICD fix (crítico) | https://github.com/ar37-rs/virgl-angle/issues/1 |
| termux #23042 | Bug ANGLE+GL en Mali | https://github.com/termux/termux-packages/issues/23042 |
| termux PR #23104 | Venus interface para Termux | https://github.com/termux/termux-packages/pull/23104 |
| termux PR #22598 | termux-wsi-layer (Wayland) | https://github.com/termux/termux-packages/pull/22598 |
| termux #17579 | Overhead de virgl | https://github.com/termux/termux-packages/issues/17579 |
| Reddit post original Mali | Primer post Mali+virgl+ANGLE | https://old.reddit.com/r/termux/comments/1tklbnb/ |

## Paquetes Termux necesarios

### Con apt/pkg
```
virglrenderer virglrenderer-android angle-android
vulkan-loader-generic wget which openssl dpkg
mesa-vulkan-icd-wrapper (desde .deb de ar37-rs)
```

### Con pacman
```
dpkg wget which vulkan-loader-generic openssl
meson ninja pkg-config libdrm libepoxy libglvnd libx11 mesa
```
Más los .deb de ar37-rs convertidos a .pkg.tar.xz

## Arquitectura de archivos del stack

```
$PREFIX/opt/angle-android/
├── gl/              # Backend GL
│   ├── libEGL_angle.so
│   └── libGLESv2_angle.so
├── vulkan/          # Backend Vulkan (default)
│   ├── libEGL_angle.so
│   └── libGLESv2_angle.so
└── vulkan-null/     # Backend Vulkan null surface
    ├── libEGL_angle.so
    └── libGLESv2_angle.so

$PREFIX/bin/
├── virgl_test_server   # De virglrenderer
└── virgl-angle         # De virglrenderer-android (alias)

$PREFIX/share/vulkan/icd.d/
└── wrapper_icd.aarch64.json   # ICD wrapper para Mali

~/.vgl-*               # Sentinel files (config persistente)
  .vgl-angle-vulkan    # ANGLE backend = vulkan
  .vgl-angle-gl        # ANGLE backend = gl
  .vgl-android         # Usar virgl nativo (sin ANGLE)
  .vgl-gl21 / gl32 / gl33 / gl43  # Perfil GL
  .vgl-d3d             # Config D3D
```

## Variables de entorno clave

| Variable | Valor típico | Propósito |
|---|---|---|
| `GALLIUM_DRIVER` | `virpipe` | Fuerza driver Gallium virgl |
| `LIBGL_ALWAYS_SOFTWARE` | `1` | Software fallback (se unsetea para apps GPU) |
| `MESA_GL_VERSION_OVERRIDE` | `4.1COMPAT` | Versión GL expuesta |
| `MESA_GLSL_VERSION_OVERRIDE` | `410` | Versión GLSL expuesta |
| `MESA_BACK_BUFFER` | `pixmap` | Modo backbuffer para termux-x11 |
| `MESA_NO_ERROR` | `1` | Saltea chequeo de errores GL |
| `DISPLAY` | `:1` | Display de Termux:X11 |
| `MOZ_X11_EGL` | `1` | Firefox: forzar EGL en X11 |
| `MESA_EXTENSION_OVERRIDE` | `-GL_EXT_blend_func_extended` | Oculta extensión específica |
