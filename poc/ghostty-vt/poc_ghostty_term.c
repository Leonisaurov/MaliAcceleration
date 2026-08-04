/*
 * poc_ghostty_term.c — FASE 2.5 PoC: TERMINAL INTERACTIVO REAL
 *
 * Convierte el PoC estático (poc_x11.c) en un terminal usable dentro de
 * termux-x11: proceso de shell en un PTY, entrada de teclado X11, redibujo
 * por invalidación y resize.
 *
 * Componentes:
 *   - PTY: posix_openpt + grantpt + unlockpt + fork + setsid + TIOCSCTTY
 *     + dup2 + exec($SHELL). El hijo corre el shell; el padre lee la salida
 *     del master y la inyecta al terminal con ghostty_terminal_vt_write.
 *   - Teclado X11: cada KeyPress se convierte con el key encoder de ghostty
 *     (ghostty_key_encoder_new + setopt_from_terminal + encode), que produce
 *     las secuencias VT correctas según el estado del terminal (cursor key
 *     app mode, kitty flags, etc.). Fallback: texto UTF-8 de XLookupString
 *     para keysyms que no mapeamos (ñ, puntuación shifted exótica, Ctrl+algo).
 *   - Redibujo por invalidación: select() sobre pty + conexión X + timeout
 *     para el blink del cursor. Solo se redibuja cuando el pty produjo datos,
 *     hubo Expose/ConfigureNotify o cambia la fase del blink.
 *   - Cursor: bloque/bar/underline en CURSOR_VIEWPORT_X/Y del render state,
 *     con blink (CURSOR_BLINKING) y color (COLOR_CURSOR).
 *   - Resize: ConfigureNotify → cols/rows = w/CELL_W, h/CELL_H →
 *     ghostty_terminal_resize + ioctl(TIOCSWINSZ) al pty + se recrea el
 *     buffer XShm al nuevo tamaño.
 *   - write_pty callback: responde queries del shell (DSR/DECRQM/XTVERSION)
 *     escribiendo al master del pty.
 *
 * Renderer sigue siendo CPU (FreeType + XShmPutImage) — la FASE 3 (GLES) es
 * aparte.
 *
 * Compilar:
 *   clang -o poc_ghostty_term poc_ghostty_term.c \
 *     -I$PREFIX/include -L$PREFIX/lib \
 *     -lghostty-vt -lX11 -lXext -lfreetype -landroid-shmem -lutil \
 *     $(pkg-config --cflags freetype2)
 *
 * Ejecutar (con termux-x11 activo):
 *   DISPLAY=:0 ./poc_ghostty_term
 *
 * Salir: escribir "exit" en el shell, o cerrar la ventana.
 */

#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <sys/ioctl.h>
#include <sys/select.h>
#include <sys/shm.h>
#include <sys/wait.h>
#include <termios.h>
#include <strings.h> /* ffs */

#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/keysym.h>
#include <X11/extensions/XShm.h>

#include <ft2build.h>
#include FT_FREETYPE_H

#include <ghostty/vt.h>
#include <ghostty/vt/key.h>

/* ---- Configuración ---------------------------------------------------- */
#define GRID_COLS 60u  /* grid inicial de la ventana (480px) */
#define GRID_ROWS 15u  /* grid inicial de la ventana (240px) */
#define CELL_W    8u
#define CELL_H    16u

#define FONT_REGULAR "/data/data/com.termux/files/usr/share/fonts/TTF/DejaVuSansMono.ttf"
#define FONT_BOLD    "/data/data/com.termux/files/usr/share/fonts/TTF/DejaVuSansMono-Bold.ttf"

#define DEFAULT_SHELL "/data/data/com.termux/files/usr/bin/bash"
#define BLINK_MS 530u /* periodo del blink del cursor (ms) */

/* ---- Estado global compartido con callbacks ghostty ------------------- */
static int g_pty_master = -1; /* fd del master del pty (write_pty callback) */

/* ---- Contexto X11 + buffer -------------------------------------------- */
typedef struct {
    Display* dpy;
    Window win;
    GC gc;
    XImage* img;          /* píxeles (shared memory si use_shm) */
    XShmSegmentInfo shmi; /* válido solo si use_shm */
    bool use_shm;
    int width, height;

    /* máscaras/shifts del visual TrueColor para empaquetar RGB en 32 bits */
    unsigned long r_mask, g_mask, b_mask;
    int r_shift, g_shift, b_shift;
} XCtx;

/* Empaqueta (r,g,b) al formato de píxel del XImage (TrueColor 24/32). */
static inline uint32_t xc_pack(const XCtx* x, uint8_t r, uint8_t g, uint8_t b) {
    return (uint32_t)((r << x->r_shift) | (g << x->g_shift) | (b << x->b_shift));
}

/* Pone un píxel sólido en (row, col). */
static inline void xc_set_pixel(XCtx* x, int row, int col,
                                uint8_t r, uint8_t g, uint8_t b) {
    if (row < 0 || row >= x->height || col < 0 || col >= x->width) return;
    uint32_t* px = (uint32_t*)(x->img->data + (size_t)row * x->img->bytes_per_line) + col;
    *px = xc_pack(x, r, g, b);
}

/* Extrae un componente del píxel actual (para blending). */
static inline uint8_t xc_get_component(uint32_t px, unsigned long mask, int shift) {
    return (uint8_t)((px & mask) >> shift);
}

/* Blend alfa: mezcla (r,g,b) con alpha (0..255) sobre el píxel actual. */
static inline void xc_blend_pixel(XCtx* x, int row, int col,
                                  uint8_t r, uint8_t g, uint8_t b, uint8_t alpha) {
    if (alpha == 0) return;
    if (row < 0 || row >= x->height || col < 0 || col >= x->width) return;
    uint32_t* px = (uint32_t*)(x->img->data + (size_t)row * x->img->bytes_per_line) + col;
    if (alpha == 255) {
        *px = xc_pack(x, r, g, b);
        return;
    }
    uint32_t cur = *px;
    uint8_t cr = xc_get_component(cur, x->r_mask, x->r_shift);
    uint8_t cg = xc_get_component(cur, x->g_mask, x->g_shift);
    uint8_t cb = xc_get_component(cur, x->b_mask, x->b_shift);
    uint8_t nr = (uint8_t)(((uint16_t)r * alpha + (uint16_t)cr * (255 - alpha)) / 255);
    uint8_t ng = (uint8_t)(((uint16_t)g * alpha + (uint16_t)cg * (255 - alpha)) / 255);
    uint8_t nb = (uint8_t)(((uint16_t)b * alpha + (uint16_t)cb * (255 - alpha)) / 255);
    *px = xc_pack(x, nr, ng, nb);
}

/* Rellena un rectángulo [row0,row0+h) x [col0,col0+w) con un color sólido. */
static void xc_fill_rect(XCtx* x, int row0, int col0, int h, int w,
                         uint8_t r, uint8_t g, uint8_t b) {
    uint32_t packed = xc_pack(x, r, g, b);
    for (int row = row0; row < row0 + h; row++) {
        if (row < 0 || row >= x->height) continue;
        uint32_t* line = (uint32_t*)(x->img->data + (size_t)row * x->img->bytes_per_line);
        for (int col = col0; col < col0 + w; col++) {
            if (col < 0 || col >= x->width) continue;
            line[col] = packed;
        }
    }
}

/* Decodifica el primer codepoint UTF-8 de s[0..len). */
static uint32_t utf8_decode(const uint8_t* s, size_t len) {
    if (len == 0) return 0;
    uint8_t b0 = s[0];
    if (b0 < 0x80) return b0;
    if ((b0 & 0xE0) == 0xC0 && len >= 2)
        return ((uint32_t)(b0 & 0x1F) << 6) | (s[1] & 0x3F);
    if ((b0 & 0xF0) == 0xE0 && len >= 3)
        return ((uint32_t)(b0 & 0x0F) << 12) | ((uint32_t)(s[1] & 0x3F) << 6) | (s[2] & 0x3F);
    if ((b0 & 0xF8) == 0xF0 && len >= 4)
        return ((uint32_t)(b0 & 0x07) << 18) | ((uint32_t)(s[1] & 0x3F) << 12) |
               ((uint32_t)(s[2] & 0x3F) << 6) | (s[3] & 0x3F);
    return b0; /* inválido: lo pintamos como el byte crudo */
}

/* ---- Inicialización X11 ---------------------------------------------- */

/* Destruye el buffer XImage actual (shm o malloc). */
static void xc_destroy_buffer(XCtx* x) {
    if (!x->dpy || !x->img) return;
    if (x->use_shm) {
        XShmDetach(x->dpy, &x->shmi);
        XSync(x->dpy, False);
        x->img->data = NULL; /* la memoria es el segmento shm, no malloc */
        XDestroyImage(x->img);
        shmdt(x->shmi.shmaddr);
        shmctl(x->shmi.shmid, IPC_RMID, NULL);
    } else {
        XDestroyImage(x->img);
    }
    x->img = NULL;
    x->use_shm = false;
}

/* Crea (o recrea) el buffer XImage de width x height. Preferencia XShm,
 * fallback XPutImage con memoria local. Devuelve 0 si OK. */
static int xc_create_buffer(XCtx* x, int width, int height) {
    xc_destroy_buffer(x);
    x->width = width;
    x->height = height;

    Visual* visual = DefaultVisual(x->dpy, DefaultScreen(x->dpy));

    x->use_shm = false;
    if (XShmQueryExtension(x->dpy)) {
        XImage* img = XShmCreateImage(x->dpy, visual, 24, ZPixmap,
                                      NULL, &x->shmi, (unsigned)width, (unsigned)height);
        if (img) {
            x->shmi.shmid = shmget(IPC_PRIVATE,
                                   (size_t)img->bytes_per_line * img->height,
                                   IPC_CREAT | 0600);
            if (x->shmi.shmid >= 0) {
                x->shmi.shmaddr = (char*)shmat(x->shmi.shmid, NULL, 0);
                if (x->shmi.shmaddr != (char*)-1) {
                    x->shmi.readOnly = False;
                    img->data = x->shmi.shmaddr;
                    XShmAttach(x->dpy, &x->shmi);
                    XSync(x->dpy, False); /* asegura que el attach llegó al server */
                    x->img = img;
                    x->use_shm = true;
                    printf("X11: MIT-SHM OK (%dx%d, shmid=%d)\n", width, height, x->shmi.shmid);
                    return 0;
                }
                perror("shmat");
                shmctl(x->shmi.shmid, IPC_RMID, NULL);
                XDestroyImage(img);
            } else {
                perror("shmget");
                XDestroyImage(img);
            }
        }
    }

    /* -- Fallback: XPutImage sin shared memory ------------------------- */
    fprintf(stderr, "X11: MIT-SHM no disponible, fallback XPutImage (memoria local)\n");
    XImage* img = XCreateImage(x->dpy, visual, 24, ZPixmap,
                               0, NULL, (unsigned)width, (unsigned)height, 32, 0);
    if (!img) {
        fprintf(stderr, "FAIL: XCreateImage\n");
        return -1;
    }
    img->data = calloc(1, (size_t)img->bytes_per_line * img->height);
    if (!img->data) {
        fprintf(stderr, "FAIL: calloc buffer XImage\n");
        XDestroyImage(img);
        return -1;
    }
    x->img = img;
    return 0;
}

static int xc_init(XCtx* x, int width, int height) {
    memset(x, 0, sizeof(*x));

    x->dpy = XOpenDisplay(NULL);
    if (!x->dpy) {
        fprintf(stderr, "FAIL: XOpenDisplay(NULL) — ¿termux-x11 activo en DISPLAY=%s?\n",
                getenv("DISPLAY") ? getenv("DISPLAY") : "(unset)");
        return -1;
    }
    int screen = DefaultScreen(x->dpy);
    Visual* visual = DefaultVisual(x->dpy, screen);

    /* TrueColor 24/32 → máscaras RGB. Shift = posición del bit menos
     * significativo de cada máscara. */
    x->r_mask = visual->red_mask;
    x->g_mask = visual->green_mask;
    x->b_mask = visual->blue_mask;
    x->r_shift = ffs((int)x->r_mask) - 1;
    x->g_shift = ffs((int)x->g_mask) - 1;
    x->b_shift = ffs((int)x->b_mask) - 1;
    if (!x->r_mask || !x->g_mask || !x->b_mask) {
        fprintf(stderr, "WARN: visual no es TrueColor RGB (0x%lx/0x%lx/0x%lx)\n",
                x->r_mask, x->g_mask, x->b_mask);
    }

    x->win = XCreateSimpleWindow(x->dpy, RootWindow(x->dpy, screen),
                                 0, 0, (unsigned)width, (unsigned)height, 0,
                                 BlackPixel(x->dpy, screen), BlackPixel(x->dpy, screen));
    XStoreName(x->dpy, x->win, "Ghostty terminal — PTY interactivo (CPU render)");
    XSelectInput(x->dpy, x->win,
                 ExposureMask | KeyPressMask | StructureNotifyMask);
    x->gc = XCreateGC(x->dpy, x->win, 0, NULL);

    if (xc_create_buffer(x, width, height) != 0) {
        XFreeGC(x->dpy, x->gc);
        XDestroyWindow(x->dpy, x->win);
        XCloseDisplay(x->dpy);
        return -1;
    }

    XMapWindow(x->dpy, x->win);
    XFlush(x->dpy);
    return 0;
}

/* Sube el buffer completo a la ventana. */
static void xc_present(XCtx* x) {
    if (x->use_shm) {
        XShmPutImage(x->dpy, x->win, x->gc, x->img,
                     0, 0, 0, 0, (unsigned)x->width, (unsigned)x->height, True);
    } else {
        XPutImage(x->dpy, x->win, x->gc, x->img,
                  0, 0, 0, 0, (unsigned)x->width, (unsigned)x->height);
    }
    XFlush(x->dpy);
    /* Espera a que el server copie el buffer antes de volver a escribirlo
     * (evita tearing/race con shm). */
    XSync(x->dpy, False);
}

static void xc_free(XCtx* x) {
    if (!x->dpy) return;
    xc_destroy_buffer(x);
    XFreeGC(x->dpy, x->gc);
    XDestroyWindow(x->dpy, x->win);
    XCloseDisplay(x->dpy);
}

/* ---- Dibujo del terminal --------------------------------------------- */
typedef struct {
    FT_Library ft;
    FT_Face regular; /* DejaVuSansMono */
    FT_Face bold;    /* DejaVuSansMono-Bold */
    int ascender, descender; /* px, del face regular a 16px */
} FontCtx;

static int font_init(FontCtx* f) {
    memset(f, 0, sizeof(*f));
    if (FT_Init_FreeType(&f->ft) != 0) {
        fprintf(stderr, "FAIL: FT_Init_FreeType\n");
        return -1;
    }
    if (FT_New_Face(f->ft, FONT_REGULAR, 0, &f->regular) != 0) {
        fprintf(stderr, "FAIL: FT_New_Face(%s)\n", FONT_REGULAR);
        return -1;
    }
    /* Ancho 8 = celda mono exacta; alto 16. */
    FT_Set_Pixel_Sizes(f->regular, CELL_W, CELL_H);
    f->ascender = f->regular->size->metrics.ascender >> 6;
    f->descender = f->regular->size->metrics.descender >> 6; /* negativo */
    if (FT_New_Face(f->ft, FONT_BOLD, 0, &f->bold) != 0) {
        fprintf(stderr, "WARN: no carga %s; bold usará regular\n", FONT_BOLD);
        f->bold = f->regular;
    } else {
        FT_Set_Pixel_Sizes(f->bold, CELL_W, CELL_H);
    }
    return 0;
}

/* Rasteriza el codepoint en el face dado (render normal, antialiased) y
 * lo dibuja en la celda (row, col) con el color fg. */
static void draw_codepoint(XCtx* x, FontCtx* f, FT_Face face, uint32_t cp,
                           int row, int col, uint8_t r, uint8_t g, uint8_t b) {
    FT_UInt gi = FT_Get_Char_Index(face, cp);
    if (gi == 0) return; /* sin glyph en la fuente */
    if (FT_Load_Glyph(face, gi, FT_LOAD_DEFAULT) != 0) return;
    if (FT_Render_Glyph(face->glyph, FT_RENDER_MODE_NORMAL) != 0) return;

    FT_Bitmap* bm = &face->glyph->bitmap;
    if (bm->width == 0 || bm->rows == 0) return;

    /* Baseline vertical centrado en la celda de CELL_H px. */
    int line_h = f->ascender - f->descender;
    int baseline = row * (int)CELL_H + ((int)CELL_H - line_h) / 2 + f->ascender;
    int pen_x = col * (int)CELL_W + face->glyph->bitmap_left;
    int pen_y = baseline - face->glyph->bitmap_top;

    const uint8_t* src = bm->buffer; /* 1 byte por píxel (coverage) */
    for (int y = 0; y < bm->rows; y++) {
        for (int xx = 0; xx < bm->width; xx++) {
            uint8_t cov = src[y * bm->pitch + xx];
            if (cov)
                xc_blend_pixel(x, pen_y + y, pen_x + xx, r, g, b, cov);
        }
    }
}

/* Renderiza el render state completo al buffer X11. */
static void draw_terminal(XCtx* x, FontCtx* f,
                          GhosttyRenderState rs,
                          GhosttyRenderStateRowIterator it,
                          GhosttyRenderStateRowCells cells,
                          GhosttyColorRgb bg_default,
                          GhosttyColorRgb fg_default) {
    /* Fondo por defecto en todo el buffer. */
    xc_fill_rect(x, 0, 0, x->height, x->width,
                 bg_default.r, bg_default.g, bg_default.b);

    uint16_t row_idx = 0;
    while (ghostty_render_state_row_iterator_next(it)) {
        if (ghostty_render_state_row_get(it, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS,
                                         &cells) != GHOSTTY_SUCCESS) {
            row_idx++;
            continue;
        }

        uint16_t col_idx = 0;
        while (ghostty_render_state_row_cells_next(cells)) {
            /* Grafenas UTF-8 de la celda. */
            char gbuf[64] = {0};
            GhosttyBuffer gout = {.ptr = (uint8_t*)gbuf,
                                  .cap = sizeof(gbuf),
                                  .len = 0};
            ghostty_render_state_row_cells_get(
                cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8, &gout);

            /* Estilo + colores resueltos (RGB). */
            GhosttyStyle style = GHOSTTY_INIT_SIZED(GhosttyStyle);
            ghostty_render_state_row_cells_get(
                cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style);

            GhosttyColorRgb fg = fg_default;
            if (ghostty_render_state_row_cells_get(
                    cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &fg)
                != GHOSTTY_SUCCESS)
                fg = fg_default;

            GhosttyColorRgb bg = bg_default;
            if (ghostty_render_state_row_cells_get(
                    cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &bg)
                == GHOSTTY_SUCCESS) {
                /* Fondo explícito (ej: \x1b[44m). */
                xc_fill_rect(x, row_idx * (int)CELL_H, col_idx * (int)CELL_W,
                             CELL_H, CELL_W, bg.r, bg.g, bg.b);
            }

            if (gout.len > 0) {
                uint32_t cp = utf8_decode((const uint8_t*)gbuf, gout.len);
                FT_Face face = style.bold ? f->bold : f->regular;
                draw_codepoint(x, f, face, cp, row_idx, col_idx,
                               fg.r, fg.g, fg.b);
            }
            col_idx++;
        }
        row_idx++;
    }
}

/* Tiempo monotónico en ms (para el blink del cursor). */
static uint64_t now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000u + (uint64_t)ts.tv_nsec / 1000000u;
}

/* Dibuja el cursor según el render state (bloque, bar o underline). */
static void draw_cursor(XCtx* x, GhosttyRenderState rs, GhosttyColorRgb fg_default) {
    bool visible = false;
    ghostty_render_state_get(rs, GHOSTTY_RENDER_STATE_DATA_CURSOR_VISIBLE, &visible);
    if (!visible) return;

    bool has_pos = false;
    ghostty_render_state_get(rs, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_HAS_VALUE,
                             &has_pos);
    if (!has_pos) return;

    uint16_t cx = 0, cy = 0;
    ghostty_render_state_get(rs, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_X, &cx);
    ghostty_render_state_get(rs, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_Y, &cy);

    bool blinking = false;
    ghostty_render_state_get(rs, GHOSTTY_RENDER_STATE_DATA_CURSOR_BLINKING, &blinking);
    if (blinking) {
        /* Alterna visibilidad cada BLINK_MS. */
        uint64_t phase = (now_ms() / BLINK_MS) & 1u;
        if (phase == 0) return;
    }

    /* Color del cursor (explicito o fg default). */
    GhosttyColorRgb col = fg_default;
    bool has_cursor_col = false;
    ghostty_render_state_get(rs, GHOSTTY_RENDER_STATE_DATA_COLOR_CURSOR_HAS_VALUE,
                             &has_cursor_col);
    if (has_cursor_col)
        ghostty_render_state_get(rs, GHOSTTY_RENDER_STATE_DATA_COLOR_CURSOR, &col);

    int px = (int)cx * (int)CELL_W;
    int py = (int)cy * (int)CELL_H;

    GhosttyRenderStateCursorVisualStyle style = GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK;
    ghostty_render_state_get(rs, GHOSTTY_RENDER_STATE_DATA_CURSOR_VISUAL_STYLE, &style);

    switch (style) {
    case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BAR:
        xc_fill_rect(x, py, px, CELL_H, 2, col.r, col.g, col.b);
        break;
    case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_UNDERLINE:
        xc_fill_rect(x, py + CELL_H - 2, px, 2, CELL_W, col.r, col.g, col.b);
        break;
    case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK_HOLLOW:
        /* Borde de 2px (deja el interior con el fondo del terminal). */
        xc_fill_rect(x, py, px, 2, CELL_W, col.r, col.g, col.b);
        xc_fill_rect(x, py + CELL_H - 2, px, 2, CELL_W, col.r, col.g, col.b);
        xc_fill_rect(x, py, px, CELL_H, 2, col.r, col.g, col.b);
        xc_fill_rect(x, py, px + CELL_W - 2, CELL_H, 2, col.r, col.g, col.b);
        break;
    case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK:
    default:
        xc_fill_rect(x, py, px, CELL_H, CELL_W, col.r, col.g, col.b);
        break;
    }
}

/* Re-populate the row iterator before each redraw: libghostty-vt's
 * row iterator is one-shot (consumed on first pass), so it must be
 * re-fetched from the render state every frame. */
static void redraw(XCtx* x, FontCtx* f, GhosttyRenderState rs,
                   GhosttyRenderStateRowIterator it,
                   GhosttyRenderStateRowCells cells,
                   GhosttyColorRgb bg, GhosttyColorRgb fg) {
    ghostty_render_state_get(rs, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &it);
    draw_terminal(x, f, rs, it, cells, bg, fg);
    draw_cursor(x, rs, fg);
    xc_present(x);
}

/* ---- PTY -------------------------------------------------------------- */

/* Abre un par de pty (master + slave) vía posix_openpt. Devuelve el master,
 * o -1 en error. *out_slave recibe el fd del slave (a usar en el hijo). */
static int pty_open(int* out_slave) {
    int master = posix_openpt(O_RDWR | O_NOCTTY);
    if (master < 0) {
        perror("posix_openpt");
        return -1;
    }
    if (grantpt(master) != 0) {
        perror("grantpt");
        close(master);
        return -1;
    }
    if (unlockpt(master) != 0) {
        perror("unlockpt");
        close(master);
        return -1;
    }
    char* name = ptsname(master);
    if (!name) {
        perror("ptsname");
        close(master);
        return -1;
    }
    int slave = open(name, O_RDWR | O_NOCTTY);
    if (slave < 0) {
        perror("open(slave)");
        close(master);
        return -1;
    }
    *out_slave = slave;
    return master;
}

/* Ajusta la winsize del pty (cols/rows + píxeles de celda). */
static void pty_set_winsize(int master, uint16_t cols, uint16_t rows) {
    struct winsize ws = {
        .ws_row = rows,
        .ws_col = cols,
        .ws_xpixel = cols * CELL_W,
        .ws_ypixel = rows * CELL_H,
    };
    ioctl(master, TIOCSWINSZ, &ws);
}

/* Fork + exec del shell del usuario en el pty. Devuelve el pid del hijo. */
static pid_t pty_spawn_shell(int master, int slave, uint16_t cols, uint16_t rows) {
    pty_set_winsize(master, cols, rows);

    pid_t pid = fork();
    if (pid < 0) {
        perror("fork");
        return -1;
    }
    if (pid == 0) {
        /* -- Hijo: sesión nueva con el pty como terminal controlante. -- */
        close(master); /* el hijo no usa el master */

        if (setsid() < 0) {
            perror("setsid");
            _exit(126);
        }
        if (ioctl(slave, TIOCSCTTY, 0) < 0) {
            perror("TIOCSCTTY");
            _exit(126);
        }
        dup2(slave, 0);
        dup2(slave, 1);
        dup2(slave, 2);
        if (slave > 2) close(slave);

        setenv("TERM", "xterm-256color", 1);

        const char* shell = getenv("SHELL");
        if (!shell || !shell[0]) shell = DEFAULT_SHELL;
        const char* base = strrchr(shell, '/');
        base = base ? base + 1 : shell;
        execl(shell, base, (char*)NULL);
        perror("execl(shell)");
        _exit(127);
    }
    /* -- Padre: cierra su copia del slave. -- */
    close(slave);
    return pid;
}

/* Lee todo lo disponible del pty y lo inyecta al terminal. Devuelve true si
 * se inyectó algo; pone *eof si el pty se cerró (shell terminó). */
static bool pty_drain(GhosttyTerminal term, bool* eof) {
    bool got = false;
    char buf[8192];
    for (;;) {
        ssize_t n = read(g_pty_master, buf, sizeof(buf));
        if (n > 0) {
            ghostty_terminal_vt_write(term, (const uint8_t*)buf, (size_t)n);
            got = true;
            continue;
        }
        if (n == 0) {
            *eof = true; /* shell cerrado (EOF) */
        } else if (errno != EAGAIN && errno != EINTR) {
            *eof = true; /* error real de lectura */
        }
        break;
    }
    return got;
}

/* Escribe datos al master del pty (con loop ante escrituras parciales). */
static void pty_write(const uint8_t* data, size_t len) {
    size_t off = 0;
    while (off < len) {
        ssize_t n = write(g_pty_master, data + off, len - off);
        if (n > 0) {
            off += (size_t)n;
        } else if (n < 0 && errno == EINTR) {
            continue;
        } else {
            break; /* EAGAIN / error: se descarta (best-effort) */
        }
    }
}

/* Callback ghostty: el terminal necesita escribir respuestas al pty
 * (DSR/DECRQM/XTVERSION consultados por el shell). */
static void write_pty_cb(GhosttyTerminal term, void* userdata,
                         const uint8_t* data, size_t len) {
    (void)term;
    (void)userdata;
    if (len > 0) pty_write(data, len);
}

/* ---- Teclado X11 ------------------------------------------------------ */

/* Modificadores X11 → bitmask GhosttyMods. */
static GhosttyMods x11_mods(unsigned int state) {
    GhosttyMods m = 0;
    if (state & ShiftMask) m |= GHOSTTY_MODS_SHIFT;
    if (state & ControlMask) m |= GHOSTTY_MODS_CTRL;
    if (state & Mod1Mask) m |= GHOSTTY_MODS_ALT;    /* Alt */
    if (state & Mod4Mask) m |= GHOSTTY_MODS_SUPER;  /* Super/Meta */
    if (state & LockMask) m |= GHOSTTY_MODS_CAPS_LOCK;
    if (state & Mod2Mask) m |= GHOSTTY_MODS_NUM_LOCK;
    return m;
}

/* ¿Es una tecla modificadora pura (no genera output)? */
static bool x11_keysym_is_modifier(KeySym ks) {
    switch (ks) {
    case XK_Shift_L: case XK_Shift_R:
    case XK_Control_L: case XK_Control_R:
    case XK_Alt_L: case XK_Alt_R:
    case XK_Meta_L: case XK_Meta_R:
    case XK_Super_L: case XK_Super_R:
    case XK_Hyper_L: case XK_Hyper_R:
    case XK_Caps_Lock: case XK_Num_Lock: case XK_Scroll_Lock:
        return true;
    default:
        return false;
    }
}

/* Keysym X11 → tecla física Ghostty (GHOSTTY_KEY_UNIDENTIFIED si no mapea).
 * Cubre letras/dígitos (minúsculas y mayúsculas), puntuación US (incl. la
 * versión shiftada, p.ej. XK_exclam → DIGIT_1) y las teclas especiales. */
static GhosttyKey x11_keysym_to_ghostty(KeySym ks) {
    if (ks >= XK_a && ks <= XK_z) return (GhosttyKey)(GHOSTTY_KEY_A + (ks - XK_a));
    if (ks >= XK_A && ks <= XK_Z) return (GhosttyKey)(GHOSTTY_KEY_A + (ks - XK_A));
    if (ks >= XK_0 && ks <= XK_9) return (GhosttyKey)(GHOSTTY_KEY_DIGIT_0 + (ks - XK_0));
    if (ks >= XK_F1 && ks <= XK_F12) return (GhosttyKey)(GHOSTTY_KEY_F1 + (ks - XK_F1));

    switch (ks) {
    /* puntuación sin shift */
    case XK_space: return GHOSTTY_KEY_SPACE;
    case XK_minus: return GHOSTTY_KEY_MINUS;
    case XK_equal: return GHOSTTY_KEY_EQUAL;
    case XK_bracketleft: return GHOSTTY_KEY_BRACKET_LEFT;
    case XK_bracketright: return GHOSTTY_KEY_BRACKET_RIGHT;
    case XK_backslash: return GHOSTTY_KEY_BACKSLASH;
    case XK_semicolon: return GHOSTTY_KEY_SEMICOLON;
    case XK_quoteleft: return GHOSTTY_KEY_BACKQUOTE;
    case XK_quoteright: return GHOSTTY_KEY_QUOTE;
    case XK_comma: return GHOSTTY_KEY_COMMA;
    case XK_period: return GHOSTTY_KEY_PERIOD;
    case XK_slash: return GHOSTTY_KEY_SLASH;
    /* puntuación con shift (la tecla física es la del carácter base) */
    case XK_exclam: return GHOSTTY_KEY_DIGIT_1;
    case XK_at: return GHOSTTY_KEY_DIGIT_2;
    case XK_numbersign: return GHOSTTY_KEY_DIGIT_3;
    case XK_dollar: return GHOSTTY_KEY_DIGIT_4;
    case XK_percent: return GHOSTTY_KEY_DIGIT_5;
    case XK_asciicircum: return GHOSTTY_KEY_DIGIT_6;
    case XK_ampersand: return GHOSTTY_KEY_DIGIT_7;
    case XK_asterisk: return GHOSTTY_KEY_DIGIT_8;
    case XK_parenleft: return GHOSTTY_KEY_DIGIT_9;
    case XK_parenright: return GHOSTTY_KEY_DIGIT_0;
    case XK_underscore: return GHOSTTY_KEY_MINUS;
    case XK_plus: return GHOSTTY_KEY_EQUAL;
    case XK_braceleft: return GHOSTTY_KEY_BRACKET_LEFT;
    case XK_braceright: return GHOSTTY_KEY_BRACKET_RIGHT;
    case XK_bar: return GHOSTTY_KEY_BACKSLASH;
    case XK_colon: return GHOSTTY_KEY_SEMICOLON;
    case XK_quotedbl: return GHOSTTY_KEY_QUOTE;
    case XK_asciitilde: return GHOSTTY_KEY_BACKQUOTE;
    case XK_less: return GHOSTTY_KEY_COMMA;
    case XK_greater: return GHOSTTY_KEY_PERIOD;
    case XK_question: return GHOSTTY_KEY_SLASH;
    /* teclas especiales */
    case XK_Return: return GHOSTTY_KEY_ENTER;
    case XK_Tab: return GHOSTTY_KEY_TAB;
    case XK_BackSpace: return GHOSTTY_KEY_BACKSPACE;
    case XK_Escape: return GHOSTTY_KEY_ESCAPE;
    case XK_Delete: return GHOSTTY_KEY_DELETE;
    case XK_Insert: return GHOSTTY_KEY_INSERT;
    case XK_Home: return GHOSTTY_KEY_HOME;
    case XK_End: return GHOSTTY_KEY_END;
    case XK_Prior: return GHOSTTY_KEY_PAGE_UP;
    case XK_Next: return GHOSTTY_KEY_PAGE_DOWN;
    case XK_Left: return GHOSTTY_KEY_ARROW_LEFT;
    case XK_Right: return GHOSTTY_KEY_ARROW_RIGHT;
    case XK_Up: return GHOSTTY_KEY_ARROW_UP;
    case XK_Down: return GHOSTTY_KEY_ARROW_DOWN;
    default:
        return GHOSTTY_KEY_UNIDENTIFIED;
    }
}

/* Convierte un KeyPress X11 en bytes y los escribe al pty.
 *
 * Estrategia (doble camino):
 *   1. Tecla mapeada a GhosttyKey → ghostty key encoder (conoce los modos
 *      del terminal: cursor key application, kitty, alt-esc, etc.).
 *   2. Keysym no mapeada con texto UTF-8 → fallback: escribir el texto de
 *      XLookupString directo (ñ, puntuación exótica, Ctrl+algo raro).
 */
static void handle_key(XKeyEvent* xke, GhosttyTerminal term,
                       GhosttyKeyEncoder enc, GhosttyKeyEvent ev) {
    KeySym ks = XLookupKeysym(xke, 0);
    if (ks == NoSymbol) return;
    if (x11_keysym_is_modifier(ks)) return; /* shift/ctrl/alt sueltos */

    GhosttyKey key = x11_keysym_to_ghostty(ks);
    GhosttyMods mods = x11_mods(xke->state);

    /* Texto UTF-8 del layout (XLookupString). Se descarta si contiene C0
     * (el encoder deriva Ctrl+letra de key+mods, como exige el header). */
    char text[64];
    int tlen = XLookupString(xke, text, (int)sizeof(text) - 1, NULL, NULL);
    text[tlen] = '\0';
    bool has_c0 = false;
    for (int i = 0; i < tlen; i++) {
        unsigned char c = (unsigned char)text[i];
        if (c < 0x20 || c == 0x7f) { has_c0 = true; break; }
    }
    /* Si el keymap no produjo texto pero la keysym es ASCII imprimible,
     * lo usamos igualmente (robusto si termux-x11 no tiene keymap). */
    if (tlen == 0 && ks >= 0x20 && ks <= 0x7e) {
        text[0] = (char)ks;
        tlen = 1;
    }

    /* (e) Keysym sin mapear con texto plano → escribir el texto directo. */
    if (key == GHOSTTY_KEY_UNIDENTIFIED && tlen > 0) {
        pty_write((const uint8_t*)text, (size_t)tlen);
        return;
    }
    if (key == GHOSTTY_KEY_UNIDENTIFIED) return; /* sin texto, sin mapeo */

    /* (h) Tecla mapeada → encoder de ghostty. */
    ghostty_key_encoder_setopt_from_terminal(enc, term);
    ghostty_key_event_set_action(ev, GHOSTTY_KEY_ACTION_PRESS);
    ghostty_key_event_set_key(ev, key);
    ghostty_key_event_set_mods(ev, mods);
    ghostty_key_event_set_consumed_mods(ev, 0);
    ghostty_key_event_set_utf8(ev, (tlen > 0 && !has_c0) ? text : NULL,
                               (tlen > 0 && !has_c0) ? (size_t)tlen : 0);

    char out[128];
    size_t written = 0;
    GhosttyResult r = ghostty_key_encoder_encode(enc, ev, out, sizeof(out), &written);
    if (r == GHOSTTY_SUCCESS && written > 0) {
        pty_write((const uint8_t*)out, written);
        return;
    }
    if (r == GHOSTTY_OUT_OF_SPACE) {
        char* big = malloc(written > 0 ? written : 256);
        if (big) {
            ghostty_key_encoder_encode(enc, ev, big, written, &written);
            if (written > 0) pty_write((const uint8_t*)big, written);
            free(big);
        }
        return;
    }

    /* (i) Fallback final: si el encoder no produjo nada, usar el texto. */
    if (tlen > 0) pty_write((const uint8_t*)text, (size_t)tlen);
}

/* ---- main ------------------------------------------------------------- */
int main(void) {
    printf("=== Ghostty interactive terminal (PTY + keyboard, CPU render) ===\n");

    /* 1. Terminal Ghostty. */
    GhosttyTerminalOptions opts = {
        .cols = GRID_COLS,
        .rows = GRID_ROWS,
        .max_scrollback = 1000,
    };
    GhosttyResult res;
    GhosttyTerminal term = NULL;
    res = ghostty_terminal_new(NULL, &term, opts);
    if (res != GHOSTTY_SUCCESS) {
        fprintf(stderr, "FAIL ghostty_terminal_new: %d\n", res);
        return 1;
    }
    res = ghostty_terminal_resize(term, GRID_COLS, GRID_ROWS, CELL_W, CELL_H);
    if (res != GHOSTTY_SUCCESS) {
        fprintf(stderr, "FAIL ghostty_terminal_resize: %d\n", res);
        goto cleanup_term;
    }

    /* write_pty callback: respuestas del terminal al shell (DSR/DECRQM).
     * OJO: ghostty_terminal_set interpreta el valor como el puntero a
     * función EN SÍ (cast a void*), NO como puntero-a-puntero-de-función.
     * Pasar `&fnptr` (modo A) hace que el terminal llame la dirección de la
     * pila como si fuera código → SIGSEGV al responder queries del shell
     * (OSC 11, DECRQM, kitty `?u`). Verificado con test harness. */
    ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_WRITE_PTY, (void*)write_pty_cb);
    ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_USERDATA, NULL);

    /* 2. Render state + iteradores (one-shot, se re-pueblan cada frame). */
    GhosttyRenderState rs = NULL;
    res = ghostty_render_state_new(NULL, &rs);
    if (res != GHOSTTY_SUCCESS) {
        fprintf(stderr, "FAIL ghostty_render_state_new: %d\n", res);
        goto cleanup_term;
    }
    res = ghostty_render_state_update(rs, term);
    if (res != GHOSTTY_SUCCESS) {
        fprintf(stderr, "FAIL ghostty_render_state_update: %d\n", res);
        goto cleanup_rs;
    }
    GhosttyRenderStateRowIterator it = NULL;
    GhosttyRenderStateRowCells cells = NULL;
    ghostty_render_state_row_iterator_new(NULL, &it);
    ghostty_render_state_get(rs, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &it);
    ghostty_render_state_row_cells_new(NULL, &cells);

    GhosttyColorRgb bg_default = {0, 0, 0}, fg_default = {200, 200, 200};
    ghostty_render_state_get(rs, GHOSTTY_RENDER_STATE_DATA_COLOR_BACKGROUND, &bg_default);
    ghostty_render_state_get(rs, GHOSTTY_RENDER_STATE_DATA_COLOR_FOREGROUND, &fg_default);

    /* 3. Key encoder + evento reutilizable. */
    GhosttyKeyEncoder enc = NULL;
    GhosttyKeyEvent kev = NULL;
    ghostty_key_encoder_new(NULL, &enc);
    ghostty_key_event_new(NULL, &kev);

    /* 4. FreeType. */
    FontCtx font;
    if (font_init(&font) != 0) {
        fprintf(stderr, "FAIL: no se pudo cargar la fuente\n");
        goto cleanup_key;
    }

    /* 5. X11 + XShm. */
    XCtx xc;
    if (xc_init(&xc, GRID_COLS * CELL_W, GRID_ROWS * CELL_H) != 0) {
        goto cleanup_font;
    }
    printf("Ventana X11 %dx%d en DISPLAY=%s (%s)\n",
           xc.width, xc.height,
           getenv("DISPLAY") ? getenv("DISPLAY") : ":0",
           xc.use_shm ? "XShm" : "XPutImage");

    /* 6. PTY + shell. */
    int slave = -1;
    g_pty_master = pty_open(&slave);
    if (g_pty_master < 0) {
        fprintf(stderr, "FAIL: no se pudo abrir el pty\n");
        goto cleanup_x11;
    }
    /* Non-blocking: el drain del pty no debe bloquear el loop. */
    fcntl(g_pty_master, F_SETFL, fcntl(g_pty_master, F_GETFL) | O_NONBLOCK);

    pid_t shell_pid = pty_spawn_shell(g_pty_master, slave, GRID_COLS, GRID_ROWS);
    if (shell_pid < 0) {
        fprintf(stderr, "FAIL: no se pudo lanzar el shell\n");
        goto cleanup_pty;
    }
    printf("Shell lanzado (pid=%d) en pty fd=%d\n", (int)shell_pid, g_pty_master);

    /* 7. Primer frame + loop. */
    redraw(&xc, &font, rs, it, cells, bg_default, fg_default);

    bool running = true;
    bool pty_eof = false;
    bool blink_on = false; /* última fase del blink dibujada */

    while (running) {
        fd_set rfds;
        FD_ZERO(&rfds);
        int xfd = ConnectionNumber(xc.dpy);
        int maxfd = g_pty_master > xfd ? g_pty_master : xfd;
        FD_SET(g_pty_master, &rfds);
        FD_SET(xfd, &rfds);
        struct timeval tv = {.tv_sec = 0, .tv_usec = 50000}; /* 50ms: blink */

        int sel = select(maxfd + 1, &rfds, NULL, NULL, &tv);
        if (sel < 0 && errno == EINTR) continue;

        bool need_redraw = false;

        if (sel > 0) {
            /* (a) Datos del pty → inyectar al terminal. */
            if (FD_ISSET(g_pty_master, &rfds)) {
                if (pty_drain(term, &pty_eof)) need_redraw = true;
            }
            /* (b) Eventos X11. */
            if (FD_ISSET(xfd, &rfds)) {
                while (XPending(xc.dpy)) {
                    XEvent ev;
                    XNextEvent(xc.dpy, &ev);
                    switch (ev.type) {
                    case Expose:
                        need_redraw = true;
                        break;
                    case KeyPress:
                        handle_key(&ev.xkey, term, enc, kev);
                        /* El echo del shell puede llegar ya; lo drenamos. */
                        if (pty_drain(term, &pty_eof)) need_redraw = true;
                        break;
                    case ConfigureNotify: {
                        int w = ev.xconfigure.width;
                        int h = ev.xconfigure.height;
                        if (w < (int)CELL_W) w = CELL_W;
                        if (h < (int)CELL_H) h = CELL_H;
                        if (w != xc.width || h != xc.height) {
                            uint16_t cols = (uint16_t)(w / CELL_W);
                            uint16_t rows = (uint16_t)(h / CELL_H);
                            if (cols < 1) cols = 1;
                            if (rows < 1) rows = 1;
                            ghostty_terminal_resize(term, cols, rows, CELL_W, CELL_H);
                            pty_set_winsize(g_pty_master, cols, rows);
                            xc_create_buffer(&xc, w, h);
                            printf("Resize -> %ux%u celdas (ventana %dx%d)\n",
                                   cols, rows, w, h);
                            need_redraw = true;
                        }
                        break;
                    }
                    case DestroyNotify:
                        printf("Ventana cerrada — saliendo\n");
                        running = false;
                        break;
                    default:
                        break;
                    }
                }
            }
        }

        if (pty_eof) {
            printf("PTY EOF — shell terminado, saliendo\n");
            running = false;
        }

        if (running && need_redraw) {
            ghostty_render_state_update(rs, term);
            redraw(&xc, &font, rs, it, cells, bg_default, fg_default);
        }

        /* (c) Blink del cursor: redibujar solo cuando cambia la fase. */
        if (running) {
            bool cur = (now_ms() / BLINK_MS) & 1u;
            if (cur != blink_on) {
                blink_on = cur;
                ghostty_render_state_update(rs, term);
                redraw(&xc, &font, rs, it, cells, bg_default, fg_default);
            }
        }
    }

    /* 8. Cleanup. */
    if (shell_pid > 0) {
        kill(shell_pid, SIGHUP);
        waitpid(shell_pid, NULL, 0);
    }
    close(g_pty_master);
    xc_free(&xc);
    FT_Done_Face(font.regular);
    if (font.bold != font.regular) FT_Done_Face(font.bold);
    FT_Done_FreeType(font.ft);
    if (kev) ghostty_key_event_free(kev);
    if (enc) ghostty_key_encoder_free(enc);
    if (cells) ghostty_render_state_row_cells_free(cells);
    if (it) ghostty_render_state_row_iterator_free(it);
    ghostty_render_state_free(rs);
    ghostty_terminal_free(term);
    printf("=== Terminal interactivo terminado (cleanup OK) ===\n");
    return 0;

cleanup_pty:
    close(g_pty_master);
cleanup_x11:
    xc_free(&xc);
cleanup_font:
    FT_Done_Face(font.regular);
    if (font.bold != font.regular) FT_Done_Face(font.bold);
    FT_Done_FreeType(font.ft);
cleanup_key:
    if (kev) ghostty_key_event_free(kev);
    if (enc) ghostty_key_encoder_free(enc);
    if (cells) ghostty_render_state_row_cells_free(cells);
    if (it) ghostty_render_state_row_iterator_free(it);
cleanup_rs:
    ghostty_render_state_free(rs);
cleanup_term:
    ghostty_terminal_free(term);
    return 1;
}
