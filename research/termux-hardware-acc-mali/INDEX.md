# Mapa de Conocimiento: Aceleración GPU Mali en Termux

## Arquitectura del Stack (capa por capa)

| Capa | Componente | Rol | Path / Comando |
|---|---|---|---|
| 5 - App | Firefox, Alacritty, glmark2 | App que hace llamadas GL | `gpu <app>` |
| 4 - Mesa client | virpipe (Gallium driver) | Serializa GL calls a socket | `GALLIUM_DRIVER=virpipe` |
| 3 - Socket | `$PREFIX/tmp/.virgl_test` | Transporte de comandos GL serializados | Creado por virgl_test_server |
| 2 - Servidor | virgl_test_server (ANGLE) | Deserializa GL → renderiza con ANGLE | `~/vgl angle=vulkan` |
| 1 - ANGLE | libEGL_angle.so, libGLESv2_angle.so | Traduce GLES → Vulkan | 3 backends: vulkan, gl, vulkan-null |
| 0 - HW | Mali GPU + driver Vulkan | Ejecuta comandos Vulkan en hardware | `/vendor/lib64/hw/vulkan.mali.so` |

## Categorías de Conocimiento

### A. Instalación y Setup
- Instalación con pacman (via build-pacman.sh o setup.sh)
- Instalación con apt/pkg
- Vulkan ICD fix (make-or-break)
- Descarga del toolkit vgl
- Instalación del wrapper gpu

### B. Configuración
- Perfiles GL (2.1COMPAT, 3.2COMPAT, 3.3COMPAT, 4.1COMPAT, 4.3COMPAT)
- Backends ANGLE (angle=vulkan, angle=gl, angle=vulkan-null, use-android)
- Config profile (config=gl, config=d3d)
- Sentinel files (~/.vgl-*)
- Alias gpu para proot (env -u LIBGL_ALWAYS_SOFTWARE GALLIUM_DRIVER=virpipe ...)
- Alacritty fix (renderer = "Gles2Pure")

### C. Rendimiento
- ~10% del throughput nativo de la GPU
- glmark2: ~70-77 score
- WebGL Aquarium 500 peces: ~15-20 fps
- Firefox UI sin WebRender (gfx.webrender.all = false)
- Bottleneck: virgl bridge, no el chip Mali

### D. Limitaciones
- Sin VA-API (no video decode hardware)
- Sin Vulkan nativo
- Sin WebRender en Firefox
- Sin compute shaders
- ~10% rendimiento nativo
- OpenGL 4.1COMPAT (no 4.6 completo)
- Alacritty necesita Gles2Pure

### E. Troubleshooting
- texImage2D 0x0502 → ICD fix + angle=vulkan
- X_GetImage BadMatch → no -legacy-drawing, desktop en software
- virgl_fence_set_fd err=-9 → ignorar (ruido)
- Firefox glxtest "No GPUs" → cosmético
- Firefox WebRender bugs → gfx.webrender.all = false
- vgl: command not found → está en host, no en proot
- EGL_BAD_ALLOC → no matar server con apps activas

### F. Alternativas
| GPU | Stack recomendado | Rendimiento relativo |
|---|---|---|
| Mali (G52-G715) | virgl + ANGLE → Vulkan (este skill) | 1x (base) |
| Adreno 6xx/7xx+ | Zink → Turnip → kgsl | 2-3x |
| Cualquiera | llvmpipe (CPU software) | ~0.5x |

### G. Futuro
- Venus (virtio-gpu Vulkan): PR #23104 en termux-packages
- Vulkan Video Decode: No soportado en drivers Mali actuales
- V4L2 M2M: Requiere kernel específico + root
- Wayland: termux-wsi-layer en draft
