# 📚 Síntesis: Aceleración GPU Mali en Termux

## 🎯 Objetivo
Investigar y documentar TODO sobre aceleración GPU por hardware en Termux con chips Mali
usando el stack virgl → ANGLE → Vulkan → Mali, incluyendo instalación, configuración,
troubleshooting, rendimiento, alternativas, y limitaciones.

## 📊 Hallazgos Clave

| Categoría | Hallazgo | Fuente | Confianza |
|---|---|---|---|
| Stack funcional | virgl → ANGLE → Vulkan → Mali funciona en Termux nativo y proot | Prueba en Redmi Pad 2 (Mali-G57) | 🟢 Alta |
| ICD fix | Sin mesa-vulkan-icd-wrapper, ANGLE cae a GL roto (texImage2D 0x0502) | ar37-rs issue #1 | 🟢 Alta |
| Rendimiento | ~10% del throughput nativo; bottleneck es virgl bridge, no Mali | Docs Mesa + benchmarks | 🟢 Alta |
| Video decode | No hay VA-API via virgl; mpv --hwdec=mediacodec funciona en Termux nativo | Pruebas empíricas | 🟢 Alta |
| Adreno vs Mali | Zink+Turnip es 2-3x más rápido pero solo Adreno (requiere /dev/kgsl) | LinuxDroidMaster benchmarks | 🟢 Alta |
| Firefox | Necesita gfx.webrender.all=false, webgl.force-enabled=true | Prueba en dispositivo real | 🟢 Alta |
| Alacritty | Necesita [debug] renderer = "Gles2Pure" (dual-source blending roto) | Código fuente de Alacritty | 🟢 Alta |
| Venus (futuro) | Virtio-gpu Vulkan eliminaría capa GL; PR #23104 en termux-packages | PR abierto, no mergeado | 🟡 Media |

## 📁 Archivos de Investigación

| Archivo | Propósito |
|---|---|
| `PLAN.md` | Plan de campaña inicial |
| `FUENTES.md` | 18 fuentes evaluadas con matriz de puntuación |
| `INDEX.md` | Mapa de conocimiento: 6 capas del stack, 7 categorías |
| `HALLAZGOS.md` | 10 hallazgos detallados con nivel de confianza |
| `GAPS.md` | 7 gaps de conocimiento no resueltos |
| `CONTRADICCIONES.md` | 4 contradicciones entre fuentes + 3 notas |
| `REPORTE.md` | Este archivo — síntesis final |
| `skills/termux-hardware-acc-mali/SKILL.md` | Skill empaquetado con todo el conocimiento |
| `skills/termux-hardware-acc-mali/scripts/check-acceleration.sh` | Script de diagnóstico |
| `skills/termux-hardware-acc-mali/references/REFERENCIAS-TECNICAS.md` | URLs, releases, vars de entorno |

## 🧩 Gaps No Resueltos

| Gap | Prioridad | Por qué no se cubrió |
|---|---|---|
| glmark2 score específico para Mali+virgl+ANGLE | Alta | Nadie ha publicado benchmarks numéricos |
| Comparativa proot vs nativo en Mali | Alta | Solo existen datos para Adreno |
| Venus soporte en Termux | Media | PR #23104 no mergeado, sin builds |
| Vulkan Video en drivers Mali | Media | Drivers privativos, sin documentación pública |
| V4L2 M2M sin root | Media | Depende del kernel específico del dispositivo |
| Benchmarks multi-generación Mali | Baja | Cada dispositivo tiene configuración única |
| EGL_BAD_ALLOC reproducible | Baja | Difícil de reproducir controladamente |

## 📦 Skill Creado

| Componente | Ruta | Propósito |
|---|---|---|
| SKILL.md | `skills/termux-hardware-acc-mali/SKILL.md` | Conocimiento completo para agentes IA |
| check-acceleration.sh | `skills/termux-hardware-acc-mali/scripts/check-acceleration.sh` | Diagnóstico del stack en 6 checks |
| REFERENCIAS-TECNICAS.md | `skills/termux-hardware-acc-mali/references/REFERENCIAS-TECNICAS.md` | URLs, releases, env vars, estructura de archivos |

## 🔮 Próximos Pasos

1. Publicar benchmarks de glmark2 para Mali+virgl+ANGLE cuando se tenga acceso a dispositivo
2. Monitorear PR #23104 (Venus) — si se mergea, probar y documentar
3. Recolectar datos de más generaciones Mali (G52, G68, G78, G715)
4. Investigar Vulkan Video decode en nuevas versiones de drivers Mali
5. Mantener el skill actualizado con nuevos hallazgos de la comunidad
