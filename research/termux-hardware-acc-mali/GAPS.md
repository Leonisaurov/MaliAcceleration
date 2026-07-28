# Gaps de Conocimiento

| Gap | Prioridad | Intentos de cubrirlo | Por qué no se cubrió |
|---|---|---|---|
| Benchmarks precisos de Mali G57 con virgl+ANGLE (glmark2 score numérico) | Alta | Búsqueda en Reddit, GitHub, foros | Nadie ha publicado números específicos de glmark2 para Mali+virgl. Los benchmarks existentes son de Adreno o WebGL |
| Comparativa proot vs Termux-nativo en Mali (con virgl+ANGLE) | Alta | Búsqueda en todos los canales | Los únicos benchmarks proot vs nativo son de Adreno. Para Mali no hay datos publicados |
| Soporte de Venus (virtio-gpu Vulkan) en Termux | Media | Revisión del PR #23104 | PR abierto desde Feb 2025, no mergeado. No hay builds ni documentación de uso |
| Estado de Vulkan Video Decode en drivers Mali | Media | Búsqueda en foros de desarrolladores Mali | Los drivers Vulkan de Mali son privativos y no hay documentación pública sobre extensiones de video |
| Acceso a V4L2 M2M en kernels Android sin root | Media | Búsqueda en XDA, foros de kernel | Depende del kernel específico del dispositivo. En la mayoría de ROMs stock, /dev/video* no es accesible sin root |
| Rendimiento comparativo de diferentes generaciones Mali (G52, G68, G78, G715) | Baja | Búsqueda general | Cada dispositivo usa su propia configuración de kernel/driver. No hay datos comparativos controlados |
| Error EGL_BAD_ALLOC en escenarios de alta presión de memoria GL | Baja | Observación empírica | Ocurre en condiciones específicas de uso intensivo de memoria. Difícil de reproducir controladamente |
