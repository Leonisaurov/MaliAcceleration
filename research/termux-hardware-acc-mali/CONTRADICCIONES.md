# Contradicciones entre Fuentes

| Tema | Fuente A | Fuente B | Resolución |
|---|---|---|---|
| glmark2 score en virgl | LinuxDroidMaster dice 75 en Adreno 650 | N/A (no hay datos Mali) | No hay contradicción, pero no se puede extrapolar a Mali directamente |
| Zink directo funciona | Reddit tutorial dice funciona en Termux nativo (40 fps WebGL) | PR #23104 sugiere que Zink directo no es recomendado para producción | Ambos pueden ser ciertos: funciona pero no es óptimo. La diferencia es experimental vs estable |
| Performance proot vs nativo | LinuxDroidMaster muestra proot mejor en llvmpipe (93 vs 69) | Sentido común sugiere nativo debería ser más rápido | La diferencia puede deberse a diferentes configuraciones de CPU/test. No es una contradicción real, es ruido de medición |
| ANGLE backend gl vs vulkan | ar37-rs recomienda angle=vulkan para Mali | Google ANGLE docs dicen que el backend gl también debería funcionar | En Mali específicamente, el backend GL de ANGLE produce texImage2D 0x0502. Es un bug del driver GL de Mali, no de ANGLE |

## Notas sobre inconsistencias

1. Los benchmarks de glmark2 para Mali+virgl+ANGLE no existen públicamente.
   Solo hay datos de Adreno+virgl y Adreno+Turnip.
2. El rendimiento de virgl varía enormemente según la GPU (Mali vs Adreno)
   y según el método (proot vs nativo), pero no hay datos suficientes
   para aislar cada variable.
3. La comunidad Termux está fragmentada: usuarios Adreno usan Zink+Turnip,
   usuarios Mali usan virgl+ANGLE, y hay poca superposición.
