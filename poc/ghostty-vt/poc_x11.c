/*
 * poc_x11.c — FASE 2 PoC: renderer CPU del terminal Ghostty en termux-x11
 *
 * Dibuja el terminal libghostty-vt (validado en FASE 1) a una ventana de
 * termux-x11 (DISPLAY=:0) usando SOLO CPU:
 *   - FreeType rasteriza los glyphs (DejaVu Sans Mono) a un buffer de píxeles
 *   - XShmPutImage (con fallback XPutImage) sube el buffer a la ventana X11
 *
 * Flujo:
 *   1. ghostty_terminal_new + resize(60, 15, 8, 16) + vt_write (demo VT)
 *   2. ghostty_render_state_new + update
 *   3. Renderer CPU: por cada celda del render state pinta bg + glyph (fg)
 *   4. Ventana X11 con XShm; loop de eventos; redibuja cada ~100ms
 *   5. Cleanup: XShmDetach / shmdt / XDestroyImage / XCloseDisplay / frees
 *
 * Sin GPU todavía: la FASE 3 (GLES) es aparte.
 *
 * Compilar:
 *   clang -o poc_x11 poc_x11.c \
 *     -I$PREFIX/include -L$PREFIX/lib \
 *     -lghostty-vt -lX11 -lXext -lfreetype \
 *     $(pkg-config --cflags freetype2)
 *
 * Ejecutar (con termux-x11 activo):
 *   DISPLAY=:0 ./poc_x11
 */

#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <sys/select.h>
#include <sys/shm.h>
#include <strings.h> /* ffs */

#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/extensions/XShm.h>

#include <ft2build.h>
#include FT_FREETYPE_H

#include <ghostty/vt.h>

/* ---- Configuración (celdas de 8x16 px) ------------------------------- */
#define GRID_COLS 60u
#define GRID_ROWS 15u
#define CELL_W    8u
#define CELL_H    16u

#define BUF_W (GRID_COLS * CELL_W) /* 480 */
#define BUF_H (GRID_ROWS * CELL_H) /* 240 */

#define FONT_REGULAR "/data/data/com.termux/files/usr/share/fonts/TTF/DejaVuSansMono.ttf"
#define FONT_BOLD    "/data/data/com.termux/files/usr/share/fonts/TTF/DejaVuSansMono-Bold.ttf"

/* VT demo: texto plano, SGR de color, bold, y un cursor move absoluto. */
static const char VT_DEMO[] =
    "\x1b[2J\x1b[H"                                /* clear + home */
    "Hello from Ghostty!\r\n"                      /* texto plano */
    "\x1b[31mRED\x1b[0m \x1b[1;32mBOLD GREEN\x1b[0m\r\n" /* fg rojo; bold+verde */
    "\x1b[36mCyan\x1b[0m and plain text\r\n"       /* fg cyan */
    "\x1b[44m\x1b[37mWhite on blue bg\x1b[0m\r\n"  /* bg azul + fg blanco */
    "\x1b[5;5HX";                                  /* CUP absoluto (fila 5, col 5) */

/* ---- Contexto X11 + buffer ------------------------------------------- */
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

/* Rellena un rectángulo [row0,row1) x [col0,col1) con un color sólido. */
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
static int xc_init(XCtx* x, int width, int height) {
    memset(x, 0, sizeof(*x));
    x->width = width;
    x->height = height;

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
    XStoreName(x->dpy, x->win, "Ghostty VT PoC — CPU render (FreeType + XShm)");
    XSelectInput(x->dpy, x->win,
                 ExposureMask | KeyPressMask | StructureNotifyMask);
    x->gc = XCreateGC(x->dpy, x->win, 0, NULL);

    /* -- XShm (preferido) --------------------------------------------- */
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
                } else {
                    perror("shmat");
                    shmctl(x->shmi.shmid, IPC_RMID, NULL);
                    XDestroyImage(img);
                }
            } else {
                perror("shmget");
                XDestroyImage(img);
            }
        }
    }

    /* -- Fallback: XPutImage sin shared memory ------------------------- */
    if (!x->use_shm) {
        fprintf(stderr, "X11: MIT-SHM no disponible, fallback XPutImage (memoria local)\n");
        XImage* img = XCreateImage(x->dpy, visual, 24, ZPixmap,
                                   0, NULL, (unsigned)width, (unsigned)height, 32, 0);
        if (!img) {
            fprintf(stderr, "FAIL: XCreateImage\n");
            XFreeGC(x->dpy, x->gc);
            XDestroyWindow(x->dpy, x->win);
            XCloseDisplay(x->dpy);
            return -1;
        }
        img->data = calloc(1, (size_t)img->bytes_per_line * img->height);
        if (!img->data) {
            fprintf(stderr, "FAIL: calloc buffer XImage\n");
            XDestroyImage(img);
            XFreeGC(x->dpy, x->gc);
            XDestroyWindow(x->dpy, x->win);
            XCloseDisplay(x->dpy);
            return -1;
        }
        x->img = img;
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

/* Re-populate the row iterator before each redraw: libghostty-vt's
 * row iterator is one-shot (consumed on first pass), so it must be
 * re-fetched from the render state every frame. */
static void redraw(XCtx* x, FontCtx* f, GhosttyRenderState rs,
                   GhosttyRenderStateRowIterator it,
                   GhosttyRenderStateRowCells cells,
                   GhosttyColorRgb bg, GhosttyColorRgb fg) {
    ghostty_render_state_get(rs, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &it);
    draw_terminal(x, f, rs, it, cells, bg, fg);
    xc_present(x);
}

/* ---- main ------------------------------------------------------------- */
int main(void) {
    printf("=== Ghostty VT X11 PoC (CPU render: FreeType + XShm) ===\n");

    /* 1. Terminal + VT demo. */
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
    ghostty_terminal_vt_write(term, (const uint8_t*)VT_DEMO, sizeof(VT_DEMO) - 1);
    printf("Terminal %ux%u creado, VT demo inyectado (%zu bytes)\n",
           (unsigned)GRID_COLS, (unsigned)GRID_ROWS, sizeof(VT_DEMO) - 1);

    /* 2. Render state. */
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

    GhosttyColorRgb bg_default = {0, 0, 0}, fg_default = {200, 200, 200};
    ghostty_render_state_get(rs, GHOSTTY_RENDER_STATE_DATA_COLOR_BACKGROUND, &bg_default);
    ghostty_render_state_get(rs, GHOSTTY_RENDER_STATE_DATA_COLOR_FOREGROUND, &fg_default);
    printf("Default colors: bg=#%02x%02x%02x fg=#%02x%02x%02x\n",
           bg_default.r, bg_default.g, bg_default.b,
           fg_default.r, fg_default.g, fg_default.b);

    /* Iteradores (allocados y poblados, como en poc_vt.c). */
    GhosttyRenderStateRowIterator it = NULL;
    GhosttyRenderStateRowCells cells = NULL;
    ghostty_render_state_row_iterator_new(NULL, &it);
    ghostty_render_state_get(rs, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &it);
    ghostty_render_state_row_cells_new(NULL, &cells);

    /* 3. FreeType. */
    FontCtx font;
    if (font_init(&font) != 0) {
        fprintf(stderr, "FAIL: no se pudo cargar la fuente\n");
        goto cleanup_iters;
    }
    printf("Font: %s (%s) a %ux%u px\n", FONT_REGULAR, "DejaVu Sans Mono",
           (unsigned)CELL_W, (unsigned)CELL_H);

    /* 4. X11 + XShm. */
    XCtx xc;
    if (xc_init(&xc, BUF_W, BUF_H) != 0) {
        goto cleanup_font;
    }
    printf("Ventana X11 %dx%d lista en DISPLAY=%s (%s)\n", BUF_W, BUF_H,
           getenv("DISPLAY") ? getenv("DISPLAY") : ":0",
           xc.use_shm ? "XShm" : "XPutImage");

    /* 5. Primer frame + loop de eventos (~100ms de redibujo). */
    redraw(&xc, &font, rs, it, cells, bg_default, fg_default);

    bool running = true;
    while (running) {
        /* Espera eventos hasta 100ms (permite redibujo periódico). */
        fd_set rfds;
        FD_ZERO(&rfds);
        int conn = ConnectionNumber(xc.dpy);
        FD_SET(conn, &rfds);
        struct timeval tv = {.tv_sec = 0, .tv_usec = 100000};
        int sel = select(conn + 1, &rfds, NULL, NULL, &tv);

        if (sel > 0) {
            while (XPending(xc.dpy)) {
                XEvent ev;
                XNextEvent(xc.dpy, &ev);
                switch (ev.type) {
                case Expose:
                    redraw(&xc, &font, rs, it, cells, bg_default, fg_default);
                    break;
                case KeyPress: {
                    char buf[8] = {0};
                    KeySym ks = 0;
                    XLookupString(&ev.xkey, buf, sizeof(buf), &ks, NULL);
                    if (ks == XK_q || ks == XK_Escape) {
                        printf("Tecla '%s' — saliendo\n",
                               ks == XK_Escape ? "Escape" : "q");
                        running = false;
                    } else {
                        redraw(&xc, &font, rs, it, cells, bg_default, fg_default);
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

        if (running) {
            /* Redibujo periódico (PoC simple: frame completo cada 100ms). */
            redraw(&xc, &font, rs, it, cells, bg_default, fg_default);
        }
    }

    /* 6. Cleanup. */
    xc_free(&xc);
    FT_Done_Face(font.regular);
    if (font.bold != font.regular) FT_Done_Face(font.bold);
    FT_Done_FreeType(font.ft);
    /* Free Ghostty resources (same as error paths). */
    if (cells) ghostty_render_state_row_cells_free(cells);
    if (it) ghostty_render_state_row_iterator_free(it);
    ghostty_render_state_free(rs);
    ghostty_terminal_free(term);
    printf("=== PoC X11 terminado (cleanup OK) ===\n");
    return 0;

cleanup_font:
    FT_Done_Face(font.regular);
    if (font.bold != font.regular) FT_Done_Face(font.bold);
    FT_Done_FreeType(font.ft);
cleanup_iters:
    if (cells) ghostty_render_state_row_cells_free(cells);
    if (it) ghostty_render_state_row_iterator_free(it);
cleanup_rs:
    ghostty_render_state_free(rs);
cleanup_term:
    ghostty_terminal_free(term);
    return 1;
}
