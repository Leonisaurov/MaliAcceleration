# Hallazgos Detallados: Aceleración GPU Mali en Termux

## 1. El stack funciona (con limitaciones)

El stack virgl → ANGLE → Vulkan → Mali es funcional en Termux nativo y
Termux + proot. Proporciona aceleración 3D/WebGL utilizable (~15-20 fps
en WebGL Aquarium con 500 peces, ~70-77 en glmark2).

**Fuente:** Pruebas en Xiaomi Redmi Pad 2 (Mali-G57 MC2), Android 15
**Confianza:** 🟢 Alta (verificada en dispositivo real)

## 2. El ICD fix es el punto crítico

Sin `mesa-vulkan-icd-wrapper`, ANGLE no encuentra el driver Vulkan de Mali
y cae al backend GL, que produce el error `texImage2D 0x0502`. Este es el
error más común y el más fácil de diagnosticar.

**Confianza:** 🟢 Alta (documentado en issue #1 de ar37-rs)

## 3. El bottleneck es virgl, no Mali

El rendimiento está limitado por el bridge virgl (serialización/deserialización
de comandos GL a través de un socket), no por el GPU Mali. Se estima ~10%
del throughput nativo. La latencia adicional por draw call es de 5-50μs.

**Confianza:** 🟢 Alta (consenso en documentación de virgl y benchmarks)

## 4. No hay aceleración de video

VA-API no está disponible a través de virgl. Android MediaCodec no es
accesible desde Firefox desktop Linux. mpv con `--hwdec=mediacodec` funciona
en Termux nativo porque usa la API de Android directamente.

**Confianza:** 🟢 Alta (limitación arquitectónica de virgl)

## 5. Zink+Turnip es 2-3x más rápido pero solo Adreno

Para Adreno, el stack Zink → Turnip → kgsl duplica o triplica el rendimiento
de virgl. Pero Turnip no funciona en Mali (requiere `/dev/kgsl`).
En WebGL, Turnip crashea en proot, pero funciona en Termux nativo.
glmark2 llega a 198 (vs 75 de virgl).

**Confianza:** 🟢 Alta (benchmarks de LinuxDroidMaster y comunidad)

## 6. Firefox necesita configuración especial

- `gfx.webrender.all = false` (WebRender causa UI buggy bajo virgl)
- `webgl.force-enabled = true` (forzar WebGL)
- `MOZ_X11_EGL=1` (forzar EGL en X11)
- `glxtest` "No GPUs" es cosmético

**Confianza:** 🟢 Alta (probado en dispositivo real)

## 7. Alacritty necesita Gles2Pure

El renderer por defecto de Alacritty usa dual-source blending, que virgl/ANGLE
anuncia como soportado pero con `GL_MAX_DUAL_SOURCE_DRAW_BUFFERS = 0`.
La solución es `[debug] renderer = "Gles2Pure"` o `MESA_EXTENSION_OVERRIDE`.

**Confianza:** 🟢 Alta (investigado en código fuente de Alacritty)

## 8. Venus es el futuro más prometedor

Mesa Venus (virtio-gpu para Vulkan) eliminaría la capa de traducción GL de
virgl, serializando Vulkan directamente. El PR #23104 en termux-packages
busca añadir soporte. Podría duplicar o triplicar el rendimiento actual.

**Confianza:** 🟡 Media (PR abierto, no mergeado, no hay builds disponibles)

## 9. El toolkit vgl de ar37-rs es la referencia

El script `vgl` de ar37-rs/virgl-angle es la herramienta principal para
gestionar el stack: iniciar servidor con diferentes backends, cambiar perfiles
GL, actualizar componentes, y lanzar apps. Es un script bash de ~11KB.

**Confianza:** 🟢 Alta (código fuente leído y verificado)

## 10. Los paquetes pacman se pueden construir desde fuente

virglrenderer se puede compilar desde fuente en Termux con meson (v1.3.0).
mesa-vulkan-icd-wrapper se puede generar como JSON ICD.
angle-android requiere prebuilts (build tipo Chromium, impracticable en Termux).
El repo incluye scripts de build en packages/.

**Confianza:** 🟢 Alta (verificado: build de virglrenderer con meson funciona)
