# PoC: libghostty-vt en Termux (FASE 1 — validar el motor VT)

PoC en C que demuestra que **libghostty-vt** funciona en Termux. Crea un
terminal Ghostty, inyecta secuencias VT (texto, colores SGR, bold, clear,
cursor moves) y lee el **render state** para verificar que el motor procesó
el contenido y los colores correctamente.

Esta es la **FASE 1**: se valida el motor VT antes de construir el renderer
X11 (FASE 2).

## Compilar

```bash
cd poc/ghostty-vt
clang -o poc_vt poc_vt.c -I$PREFIX/include -L$PREFIX/lib -lghostty-vt
```

## Ejecutar

```bash
./poc_vt
```

## Qué demuestra

- El motor VT procesa texto y escape codes correctamente en Termux:
  - `\x1b[2J` / `\x1b[H` — clear screen + cursor home
  - `\x1b[31m...\x1b[0m` — SGR fg rojo (palette 1, `#cc6666`)
  - `\x1b[1;32m...\x1b[0m` — bold + fg verde (palette 2, `#b5bd68`, `bold`)
  - `\x1b[36m...\x1b[0m` — SGR fg cyan (palette 6, `#8abeb7`)
  - `\x1b[5;5H` — CUP absoluto (la `X` aparece en una fila vacía)
- El **render state** expone el grid resultante: rows + cells con codepoints
  UTF-8 (`GRAPHEMES_UTF8`) y colores resueltos (`FG_COLOR` / `BG_COLOR`).
- Los colores del render state están **resueltos a RGB** a través de la
  paleta activa; el estilo por celda conserva el índice de paleta original.

## Estructura de la API usada

Firmas exactas de los headers instalados (`$PREFIX/include/ghostty/`):

| Función | Firma |
|---|---|
| `ghostty_terminal_new` | `GhosttyResult ghostty_terminal_new(const GhosttyAllocator* allocator, GhosttyTerminal* terminal, GhosttyTerminalOptions options)` |
| `ghostty_terminal_resize` | `GhosttyResult ghostty_terminal_resize(GhosttyTerminal terminal, uint16_t cols, uint16_t rows, uint32_t cell_width_px, uint32_t cell_height_px)` |
| `ghostty_terminal_vt_write` | `void ghostty_terminal_vt_write(GhosttyTerminal terminal, const uint8_t* data, size_t len)` |
| `ghostty_terminal_get` | `GhosttyResult ghostty_terminal_get(GhosttyTerminal terminal, GhosttyTerminalData data, void* out)` |
| `ghostty_terminal_free` | `void ghostty_terminal_free(GhosttyTerminal terminal)` |
| `ghostty_render_state_new` | `GhosttyResult ghostty_render_state_new(const GhosttyAllocator* allocator, GhosttyRenderState* state)` |
| `ghostty_render_state_update` | `GhosttyResult ghostty_render_state_update(GhosttyRenderState state, GhosttyTerminal terminal)` |
| `ghostty_render_state_get` | `GhosttyResult ghostty_render_state_get(GhosttyRenderState state, GhosttyRenderStateData data, void* out)` |
| `ghostty_render_state_row_iterator_new` | `GhosttyResult ghostty_render_state_row_iterator_new(const GhosttyAllocator* allocator, GhosttyRenderStateRowIterator* out_iterator)` |
| `ghostty_render_state_row_iterator_next` | `bool ghostty_render_state_row_iterator_next(GhosttyRenderStateRowIterator iterator)` |
| `ghostty_render_state_row_get` | `GhosttyResult ghostty_render_state_row_get(GhosttyRenderStateRowIterator iterator, GhosttyRenderStateRowData data, void* out)` |
| `ghostty_render_state_row_cells_new` | `GhosttyResult ghostty_render_state_row_cells_new(const GhosttyAllocator* allocator, GhosttyRenderStateRowCells* out_cells)` |
| `ghostty_render_state_row_cells_next` | `bool ghostty_render_state_row_cells_next(GhosttyRenderStateRowCells cells)` |
| `ghostty_render_state_row_cells_get` | `GhosttyResult ghostty_render_state_row_cells_get(GhosttyRenderStateRowCells cells, GhosttyRenderStateRowCellsData data, void* out)` |

Frees: `ghostty_terminal_free`, `ghostty_render_state_free`,
`ghostty_render_state_row_iterator_free`, `ghostty_render_state_row_cells_free`.

### Flujo usado por el PoC

1. `ghostty_terminal_new(NULL, &term, opts)` — allocator `NULL` = default.
2. `ghostty_terminal_resize(term, 40, 10, 8, 16)`.
3. `ghostty_terminal_vt_write(term, data, len)` — inyecta el texto VT.
4. `ghostty_render_state_new(NULL, &rs)` + `ghostty_render_state_update(rs, term)`.
5. Iterar filas:
   - `ghostty_render_state_row_iterator_new(NULL, &it)`
   - **poblar** con `ghostty_render_state_get(rs, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &it)`
   - `while (ghostty_render_state_row_iterator_next(it))` → `ghostty_render_state_row_get(it, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &cells)`
6. Iterar celdas: `while (ghostty_render_state_row_cells_next(cells))` →
   `ghostty_render_state_row_cells_get(cells, ...)` con
   `GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8` (GhosttyBuffer),
   `_STYLE` (GhosttyStyle, sized struct con `GHOSTTY_INIT_SIZED`),
   `_FG_COLOR` / `_BG_COLOR` (GhosttyColorRgb; `GHOSTTY_INVALID_VALUE` si la
   celda no tiene color explícito).

## Notas y hallazgos de la API

- La lib es **precompilada**: elias8 v0.0.12 (commit `4d605bf`) +
  headers de arcboxlabs (commit `b0947378`).
- **No existe `ghostty_config_new` / `GhosttyConfig`** en esta versión de la
  API: no hay capa de config separada. El terminal se crea directamente con
  `ghostty_terminal_new()` + `GhosttyTerminalOptions` (cols/rows/max_scrollback).
- La escritura de input es **`ghostty_terminal_vt_write()`** — no existen
  `ghostty_terminal_feed` / `inject` / `input` en esta versión.
- No existe `ghostty_terminal_await_render_state`: el render state se obtiene
  con `ghostty_render_state_new()` + `ghostty_render_state_update()`.
- **Gotcha importante**: el row iterator y el row cells se *alocan* con
  `_new()` pero se *pueblan* desde el render state:
  - `ghostty_render_state_get(rs, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &it)`
  - `ghostty_render_state_row_get(it, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &cells)`
  Sin ese paso el grid aparece vacío (el iterador no itera ninguna fila).
- El render state solo consume el dirty state en `update()`; los datos de
  rows/cells son válidos hasta el siguiente `update()`.
- Los colores del render state son RGB **resueltos** (paleta aplicada). El
  `GhosttyStyle` de la celda conserva el tag `GHOSTTY_STYLE_COLOR_PALETTE` /
  `GHOSTTY_STYLE_COLOR_RGB` y el índice original.

---

# PoC: renderer CPU del terminal Ghostty en termux-x11 (FASE 2)

`poc_x11.c` demuestra **"Ghostty renderizando en X11"** (sin GPU todavía):
dibuja el terminal libghostty-vt a una ventana de termux-x11 usando solo CPU:

- **FreeType** rasteriza los glyphs (DejaVu Sans Mono, 8x16 px) a un buffer
  de píxeles
- **XShmPutImage** (con fallback `XPutImage`) sube el buffer a la ventana
- Grid 60x15 celdas → ventana 480x240

## Compilar

```bash
cd poc/ghostty-vt
clang -o poc_x11 poc_x11.c \
  -I$PREFIX/include -L$PREFIX/lib \
  -lghostty-vt -lX11 -lXext -lfreetype -landroid-shmem \
  $(pkg-config --cflags freetype2)
```

Nota: en Termux las funciones `shmget/shmdt/shmctl/shmdt` viven en
`libandroid-shmem` (NO en la libc); sin `-landroid-shmem` el link falla con
`undefined symbol: libandroid_shmget` etc.

## Ejecutar

Con termux-x11 activo (DISPLAY=:0):

```bash
DISPLAY=:0 ./poc_x11
```

- Abre una ventana "Ghostty VT PoC — CPU render" de 480x240 mostrando
  "Hello from Ghostty!" con colores (rojo, bold verde, cyan, blanco sobre
  fondo azul) y una `X` en la fila 5 col 5.
- Loop de eventos: redibuja cada ~100ms; `q` / `Escape` cierra, o cierra la
  ventana.
- Verificación rápida (el timeout matando el proceso = el loop corría bien):

```bash
timeout 5 env DISPLAY=:0 ./poc_x11 2>&1; echo "exit=$?"  # 124 = OK
```

## Cómo dibuja (flujo)

1. `ghostty_terminal_new` + `resize(60, 15, 8, 16)` + `vt_write` (demo VT
   con SGR de color/bold/bg).
2. `ghostty_render_state_new` + `update`; lee `COLOR_BACKGROUND` /
   `COLOR_FOREGROUND` como defaults.
3. FreeType: `FT_New_Face(DejaVuSansMono.ttf)` (+ `-Bold.ttf` para `bold`),
   `FT_Set_Pixel_Sizes(face, 8, 16)` → advance exacto de 8px por celda.
4. Por cada celda del render state (row_iterator + row_cells):
   - `GRAPHEMES_UTF8` → primer codepoint UTF-8 → `FT_Get_Char_Index` +
     `FT_Load_Glyph` + `FT_Render_Glyph(NORMAL)`.
   - `FG_COLOR` / `BG_COLOR` resueltos (RGB) del render state; si no hay
     color explícito se usan los defaults del terminal.
   - bg explícito → rectángulo sólido; glyph → blend alfa (coverage del
     bitmap FreeType) con el color fg; baseline centrado en la celda.
5. X11: `XOpenDisplay(NULL)`, `XCreateSimpleWindow(480x240)`,
   `XShmCreateImage` + `shmget`/`shmat` + `XShmAttach`; si MIT-SHM no
   está, fallback `XCreateImage` + `calloc` + `XPutImage`.
6. Presentar: `XShmPutImage`/`XPutImage` + `XSync` (espera a que el server
   copie antes de reescribir el buffer compartido).
7. Cleanup: `XShmDetach` → `img->data = NULL` → `XDestroyImage` → `shmdt` +
   `shmctl(IPC_RMID)` → `XCloseDisplay`, frees de ghostty/FreeType.

## Orden de bytes del XImage

El buffer XImage es de 32 bits (`bits_per_pixel=32`, TrueColor 24). Los
píxeles se empaquetan **según las máscaras del visual** (`red_mask`/
`green_mask`/`blue_mask`; shift = `ffs(mask) - 1`), no asumiendo BGRA ni
RGBA fijos. En termux-x11 (little-endian, `0x00ff0000`/`0x0000ff00`/
`0x000000ff`) el byte 0 es B, el 1 G, el 2 R y el 3 sin uso → equivalente a
BGRA en memoria. Con `XShmCreateImage` el `img->data` apunta al segmento
shm y se escribe directo (cero copias).

## Estado

- [x] FASE 1 — motor VT validado (`poc_vt.c`)
- [x] FASE 2 — renderer **CPU** (FreeType + XShm) a termux-x11 (`poc_x11.c`)
- [ ] FASE 3 — renderer GPU (GLES) — aparte, aún no implementado

Verificado en ejecución: `X11: MIT-SHM OK (480x240)`, proceso vivo en loop
hasta que el timeout lo mata (exit 124). El usuario confirma visualmente la
ventana.
