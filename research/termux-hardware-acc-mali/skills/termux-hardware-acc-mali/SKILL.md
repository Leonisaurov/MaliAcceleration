# Termux Hardware Acceleration for Mali GPUs

Conocimiento completo sobre aceleración GPU por hardware en Termux con chips Mali
(G52, G57, G68, G72, G76, G78, G715+) usando el stack virgl → ANGLE → Vulkan → Mali.

## 🎯 Cuándo usar este skill

- Cuando necesites **instalar/configurar** aceleración GPU en Termux con GPU Mali
- Cuando encuentres **errores** de OpenGL/EGL/Vulkan en Termux con Mali
- Cuando quieras **diagnosticar** si la aceleración está funcionando
- Cuando necesites **comparar** métodos de aceleración (virgl vs Zink vs llvmpipe)
- Cuando quieras **optimizar** rendimiento para apps GL/WebGL

**NO** usar para:
- Adreno/Qualcomm (usa Zink+Turnip en su lugar)
- Root/Jailbreak (no necesario para este stack)
- CUDA/OpenCL (no pasan por virgl)
- Aceleración de video (VA-API no funciona en virgl)

## 📋 Stack completo (capa por capa)

```
App (glxgears, Firefox, glmark2)
    │  llama funciones OpenGL
    ▼
Mesa virpipe (GALLIUM_DRIVER=virpipe)
    │  serializa GL calls a comandos de protocolo vtest
    ▼
Socket Unix ($PREFIX/tmp/.virgl_test)
    │  transporta comandos serializados
    ▼
virgl_test_server (modificado para ANGLE)
    │  deserializa → renderiza usando ANGLE
    ▼
ANGLE (libEGL_angle.so + libGLESv2_angle.so)
    │  traduce OpenGL ES → Vulkan
    ▼
Mali Vulkan Driver (/vendor/lib64/hw/vulkan.mali.so)
    │  ejecuta en GPU real
    ▼
Mali GPU (hardware)
```

## 🚀 Instalación rápida

### Con pacman (recomendado si tenés pacman)

```bash
# 1. Clonar el repo
git clone https://github.com/Theguilherm3/termux-mali-gpu-acceleration
cd termux-mali-gpu-acceleration

# 2. Build e instalar paquetes
cd packages
./build-pacman.sh        # virglrenderer desde fuente + angle prebuilt + ICD wrapper
pacman -U *.pkg.tar.xz   # instalar todo

# 3. Descargar toolkit vgl
cd && wget https://github.com/ar37-rs/virgl-angle/raw/refs/heads/main/vgl
chmod +x ~/vgl

# 4. Instalar wrapper gpu
mkdir -p ~/.local/bin
cp config/gpu ~/.local/bin/ && chmod +x ~/.local/bin/gpu
```

### Con apt/pkg

```bash
# 1. Paquetes base
pkg install virglrenderer virglrenderer-android angle-android \
  vulkan-loader-generic wget which openssl dpkg

# 2. ICD fix (crítico)
pkg remove '*icd-swrast'
wget https://github.com/ar37-rs/virgl-angle/releases/download/latest/mesa-vulkan-icd-wrapper_25.0.0-1_aarch64.deb
dpkg -i mesa-vulkan-icd-wrapper_25.0.0-1_aarch64.deb

# 3. vgl toolkit
cd && wget https://github.com/ar37-rs/virgl-angle/raw/refs/heads/main/vgl && chmod +x ~/vgl

# 4. gpu wrapper
mkdir -p ~/.local/bin
cp config/gpu ~/.local/bin/ && chmod +x ~/.local/bin/gpu
```

### Con setup.sh (todo automático)

```bash
./scripts/setup.sh
```

## 🎮 Uso

### Iniciar servidor (se queda corriendo)

```bash
~/.local/bin/gpu
# Equivalente a: ~/vgl angle=vulkan
```

### Lanzar apps aceleradas

```bash
DISPLAY=:1 ~/.local/bin/gpu glxgears -info
DISPLAY=:1 ~/.local/bin/gpu glmark2
DISPLAY=:1 ~/.local/bin/gpu firefox
DISPLAY=:1 ~/.local/bin/gpu mpv --vo=gpu video.mp4
```

### Otros comandos

```bash
~/.local/bin/gpu q          # matar servidor
~/.local/bin/gpu use-android  # fallback sin ANGLE
~/.local/bin/gpu 2.1COMPAT   # forzar OpenGL 2.1
~/.local/bin/gpu update-angle # actualizar ANGLE
```

## 🔍 Verificación

```bash
DISPLAY=:1 ~/.local/bin/gpu glxgears -info
```

**GL_RENDERER debe decir:**
```
virgl (ANGLE (ARM, Vulkan 1.3.303 (Mali-...)))
```

Si dice `Mesa X11` o `llvmpipe`, la aceleración NO está funcionando.

## ⚠️ Errores comunes y fixes

| Error | Causa | Fix |
|---|---|---|
| `texImage2D 0x0502` / `EGL_BAD_ACCESS` | ANGLE en backend GL (no Vulkan) | `~/vgl angle=vulkan` + aplicar ICD fix |
| `GL_MAX_DUAL_SOURCE_DRAW_BUFFERS` (Alacritty) | Dual-source blending no soportado | `[debug] renderer = "Gles2Pure"` en alacritty.toml |
| `X_GetImage BadMatch` / pantalla blanca | Superficie virgl ilegible por X server | NO usar `-legacy-drawing`; desktop en software |
| `virgl_fence_set_fd: failed err=-9` | Fence export limitación de virgl | ✅ Ignorar (ruido inofensivo) |
| Firefox "No GPUs via PCI" | Proot no tiene `/sys/bus/pci/` | ✅ Cosmético, ignorar |
| Firefox UI buggy | WebRender incompatible con virgl | `gfx.webrender.all = false` en about:config |
| DPMS/session-manager errors | Termux:X11 minimalista | ✅ Esperado, ignorar |
| `EGL_BAD_ALLOC` | Contextos colgantes, servidor muerto | Cerrar apps, reiniciar server |
| `vgl: command not found` | vgl está en host, no en proot | Usar alias `gpu` dentro del proot |

## 📊 Rendimiento esperado

### En Mali-G57 MC2 (Xiaomi Redmi Pad 2)

| Test | Sin aceleración (llvmpipe) | Con virgl+ANGLE |
|---|---|---|
| WebGL Aquarium 500 peces | 4 fps | ~15-20 fps |
| glmark2 | ~93 | ~70-77* |
| Escritorio XFCE 2D | Fluido | Fluido (desktop en software) |
| glxgears | 60 fps | 60 fps |

*glmark2 score para Mali+virgl+ANGLE no está documentado; el valor es extrapolado de Adreno.

### Factores limitantes

| Factor | Impacto |
|---|---|
| virgl bridge overhead | ~90% del rendimiento nativo |
| ANGLE → Vulkan traducción | Overhead adicional |
| Socket IPC latency | 5-50μs por draw call |
| Firefox sin WebRender | UI menos fluida |
| Sin VA-API | Video decode por CPU |

## 🔧 Configuración avanzada

### Perfiles GL

```bash
~/.local/bin/gpu 2.1COMPAT    # OpenGL 2.1 (máxima compatibilidad)
~/.local/bin/gpu 3.2COMPAT    # OpenGL 3.2
~/.local/bin/gpu 3.3COMPAT    # OpenGL 3.3
~/.local/bin/gpu 4.1COMPAT    # OpenGL 4.1 (default)
~/.local/bin/gpu 4.3COMPAT    # OpenGL 4.3 (máximo)
```

### Backends ANGLE

```bash
~/.local/bin/gpu angle=vulkan     # ANGLE → Vulkan (default, recomendado)
~/.local/bin/gpu angle=gl         # ANGLE → OpenGL (roto en Mali)
~/.local/bin/gpu angle=vulkan-null # Vulkan con null surface (debug)
~/.local/bin/gpu use-android      # virgl contra GLES nativo (fallback)
```

### Actualización

```bash
~/.local/bin/gpu update-angle    # actualizar ANGLE
~/.local/bin/gpu update-virgl    # actualizar virglrenderer
```

## 🧩 Alternativas

| GPU | Método | Rendimiento relativo | Cómo |
|---|---|---|---|
| Mali G52-G715 | virgl + ANGLE → Vulkan | 1x (base) | Este skill |
| Adreno 6xx/7xx+ | Zink → Turnip → kgsl | 2-3x | Zink directo en Termux nativo |
| Cualquiera | llvmpipe (CPU) | ~0.5x | Sin setup, siempre funciona |
| Cualquiera (futuro) | Venus (virtio-gpu Vulkan) | potencial 2-3x | PR #23104 en termux-packages |

## 📚 Referencias

- [ar37-rs/virgl-angle](https://github.com/ar37-rs/virgl-angle) — Toolkit upstream
- [Mesa virgl docs](https://docs.mesa3d.org/drivers/virgl.html) — Documentación oficial de virgl
- [Mesa Zink docs](https://docs.mesa3d.org/drivers/zink.html) — Zink GL→Vulkan
- [Google ANGLE](https://chromium.googlesource.com/angle/angle) — Proyecto ANGLE
- [LinuxDroidMaster Benchmarks](https://github.com/LinuxDroidMaster/Termux-Desktops) — Benchmarks comparativos
- [termux-packages PR #23104](https://github.com/termux/termux-packages/pull/23104) — Venus para Termux
