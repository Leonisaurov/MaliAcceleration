# Plan de Investigación: Mali GPU Hardware Acceleration en Termux

## Objetivo
Investigar TODO sobre aceleración GPU por hardware en Termux con chips Mali:
stack completo (virgl → ANGLE → Vulkan → Mali), limitaciones, alternativas,
performance, troubleshooting, y casos de uso.

## Alcance
✅ Mali GPUs (G52, G57, G68, G72, G76, G78, G715, etc.)
✅ Termux nativo + Termux con proot
✅ virglrenderer + virgl_test_server
✅ ANGLE (Vulkan, GL, Vulkan-null backends)
✅ Mesa virpipe driver
✅ Vulkan ICD wrapper para Mali
✅ Performance comparativa (con/sin aceleración)
✅ Troubleshooting de errores comunes
✅ Alternativas: Zink/Turnip (Adreno), llvmpipe (CPU)
❌ Adreno/Qualcomm GPUs
❌ Root/Jailbreak
❌ KVM/QEMU GPU passthrough
❌ CUDA/OpenCL compute

## Fuentes a revisar
- Repositorio ar37-rs/virgl-angle (principal upstream)
- Documentación de Termux packages (build.sh de cada paquete)
- Mesa3D documentation (virgl, Gallium)
- Google ANGLE project
- Issues de GitHub (termux-packages, virgl-angle)
- Reddit r/termux
- ArchWiki (hardware video acceleration)
- freedesktop.org (virglrenderer)

## Profundidad
Obsesiva — cubrir todas las capas del stack, con comandos exactos,
benchmarks, troubleshooting, y empaquetado como skill.

## Criterio de parada
- Stack completo documentado capa por capa
- Todos los errores conocidos tienen troubleshooting
- Alternativas documentadas con pros/cons
- Skill creado con scripts, referencias y ejemplos
