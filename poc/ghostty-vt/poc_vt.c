/*
 * poc_vt.c — FASE 1 PoC: validar libghostty-vt en Termux
 *
 * Crea un terminal Ghostty, inyecta secuencias VT (texto, SGR de color,
 * bold, clear, cursor moves) y lee el render state para verificar que
 * el motor procesó el contenido y los colores correctamente.
 *
 * Este PoC valida el motor ANTES de construir el renderer X11 (FASE 2).
 *
 * API usada (headers de arcboxlabs, commit b0947378; lib elias8 v0.0.12):
 *   - ghostty_terminal_new / ghostty_terminal_resize / ghostty_terminal_vt_write
 *   - ghostty_render_state_new / ghostty_render_state_update
 *   - ghostty_render_state_row_iterator_* / ghostty_render_state_row_cells_*
 *
 * Compilar:
 *   clang -o poc_vt poc_vt.c -I$PREFIX/include -L$PREFIX/lib -lghostty-vt
 *
 * Ejecutar:
 *   ./poc_vt
 */

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include <ghostty/vt.h>

#define MAX_COLORED_CELLS 512

/* Una celda con estilo explícito (SGR) detectada en el grid. */
typedef struct {
    uint16_t row;
    uint16_t col;
    char text[16];
    GhosttyStyle style;
    GhosttyColorRgb fg;
    GhosttyColorRgb bg;
    bool fg_ok;
    bool bg_ok;
} ColoredCell;

static void print_rgb(const GhosttyColorRgb* c) {
    printf("#%02x%02x%02x", c->r, c->g, c->b);
}

/* Imprime un color de estilo: indice de paleta (+ RGB resuelto) o RGB directo. */
static void print_style_color(const GhosttyStyleColor* sc,
                              const GhosttyColorRgb* resolved,
                              bool has_resolved) {
    switch (sc->tag) {
    case GHOSTTY_STYLE_COLOR_PALETTE:
        printf("%u ", (unsigned)sc->value.palette);
        if (has_resolved) print_rgb(resolved);
        break;
    case GHOSTTY_STYLE_COLOR_RGB:
        print_rgb(&sc->value.rgb);
        break;
    default:
        printf("-");
        break;
    }
}

int main(void) {
    GhosttyResult res;
    GhosttyTerminal term = NULL;
    GhosttyRenderState rs = NULL;
    GhosttyRenderStateRowIterator it = NULL;
    GhosttyRenderStateRowCells cells = NULL;
    int rc = 1;

    printf("=== Ghostty VT PoC (libghostty-vt on Termux) ===\n");

    /* 1. Crear el terminal. Esta API NO tiene objeto de config separado
     *    (no existe ghostty_config_new); GhosttyTerminalOptions lo reemplaza.
     *    Allocator NULL = default (libc malloc). */
    GhosttyTerminalOptions opts = {
        .cols = 80,
        .rows = 24,
        .max_scrollback = 1000,
    };
    res = ghostty_terminal_new(NULL, &term, opts);
    if (res != GHOSTTY_SUCCESS) {
        fprintf(stderr, "FAIL ghostty_terminal_new: %d\n", res);
        return 1;
    }
    printf("=== Terminal created ===\n");

    /* 2. Resize a un grid pequeno (40x10). cell 8x16 px. */
    res = ghostty_terminal_resize(term, 40, 10, 8, 16);
    if (res != GHOSTTY_SUCCESS) {
        fprintf(stderr, "FAIL ghostty_terminal_resize: %d\n", res);
        goto cleanup;
    }
    uint16_t cols = 0, rows = 0;
    ghostty_terminal_get(term, GHOSTTY_TERMINAL_DATA_COLS, &cols);
    ghostty_terminal_get(term, GHOSTTY_TERMINAL_DATA_ROWS, &rows);
    printf("Terminal grid: %ux%u\n", cols, rows);

    /* 3. Inyectar VT: clear + home, texto plano, SGR de color/bold, y un
     *    cursor move absoluto. */
    static const char input[] =
        "\x1b[2J\x1b[H"                            /* ED(2) clear screen + CUP home */
        "Hello from Ghostty!\r\n"                  /* linea de texto plano */
        "\x1b[31mRED\x1b[0m \x1b[1;32mBOLD GREEN\x1b[0m\r\n" /* SGR fg rojo; bold+verde */
        "\x1b[36mCyan\x1b[0m and plain text\r\n"   /* SGR fg cyan */
        "\x1b[5;5HX";                             /* CUP absoluto (fila 5, col 5) + char */
    ghostty_terminal_vt_write(term, (const uint8_t*)input, sizeof(input) - 1);
    printf("VT input injected (%zu bytes)\n", sizeof(input) - 1);

    /* 4. Render state: update = begin + end en una llamada. */
    res = ghostty_render_state_new(NULL, &rs);
    if (res != GHOSTTY_SUCCESS) {
        fprintf(stderr, "FAIL ghostty_render_state_new: %d\n", res);
        goto cleanup;
    }
    res = ghostty_render_state_update(rs, term);
    if (res != GHOSTTY_SUCCESS) {
        fprintf(stderr, "FAIL ghostty_render_state_update: %d\n", res);
        goto cleanup;
    }
    ghostty_render_state_get(rs, GHOSTTY_RENDER_STATE_DATA_COLS, &cols);
    ghostty_render_state_get(rs, GHOSTTY_RENDER_STATE_DATA_ROWS, &rows);
    printf("Render state: %ux%u\n\n", cols, rows);

    /* 5. Iterar rows / cells del render state. */
    res = ghostty_render_state_row_iterator_new(NULL, &it);
    if (res != GHOSTTY_SUCCESS) {
        fprintf(stderr, "FAIL row_iterator_new: %d\n", res);
        goto cleanup;
    }
    /* El iterador se ALOCA con row_iterator_new y se PUEBLA con los datos
     * del render state via ghostty_render_state_get(ROW_ITERATOR). */
    res = ghostty_render_state_get(rs, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &it);
    if (res != GHOSTTY_SUCCESS) {
        fprintf(stderr, "FAIL render_state_get(ROW_ITERATOR): %d\n", res);
        goto cleanup;
    }
    res = ghostty_render_state_row_cells_new(NULL, &cells);
    if (res != GHOSTTY_SUCCESS) {
        fprintf(stderr, "FAIL row_cells_new: %d\n", res);
        goto cleanup;
    }

    ColoredCell colored[MAX_COLORED_CELLS];
    size_t colored_count = 0;

    printf("--- Grid (rows) ---\n");
    uint16_t row_idx = 0;
    while (ghostty_render_state_row_iterator_next(it)) {
        res = ghostty_render_state_row_get(it,
                                           GHOSTTY_RENDER_STATE_ROW_DATA_CELLS,
                                           &cells);
        if (res != GHOSTTY_SUCCESS) {
            fprintf(stderr, "FAIL row_get at row %u: %d\n", row_idx, res);
            goto cleanup;
        }

        char row_text[512] = {0};
        size_t row_len = 0;
        bool have_first = false;
        GhosttyStyleColor first_fg = {.tag = GHOSTTY_STYLE_COLOR_NONE};
        GhosttyStyleColor first_bg = {.tag = GHOSTTY_STYLE_COLOR_NONE};

        uint16_t col_idx = 0;
        while (ghostty_render_state_row_cells_next(cells)) {
            uint32_t glen = 0;
            ghostty_render_state_row_cells_get(
                cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN, &glen);

            char gbuf[64] = {0};
            GhosttyBuffer gout = {.ptr = (uint8_t*)gbuf,
                                  .cap = sizeof(gbuf),
                                  .len = 0};
            if (glen > 0) {
                ghostty_render_state_row_cells_get(
                    cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8, &gout);
                if (gout.len > 0 && row_len + gout.len + 1 < sizeof(row_text)) {
                    memcpy(row_text + row_len, gbuf, gout.len);
                    row_len += gout.len;
                    row_text[row_len] = '\0';
                }
            }

            GhosttyStyle style = GHOSTTY_INIT_SIZED(GhosttyStyle);
            ghostty_render_state_row_cells_get(
                cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style);

            bool has_style =
                style.fg_color.tag != GHOSTTY_STYLE_COLOR_NONE ||
                style.bg_color.tag != GHOSTTY_STYLE_COLOR_NONE;
            if (has_style) {
                if (!have_first) {
                    first_fg = style.fg_color;
                    first_bg = style.bg_color;
                    have_first = true;
                }
                if (colored_count < MAX_COLORED_CELLS) {
                    ColoredCell* cc = &colored[colored_count++];
                    cc->row = row_idx;
                    cc->col = col_idx;
                    snprintf(cc->text, sizeof(cc->text), "%s",
                             glen > 0 ? gbuf : "");
                    cc->style = style;
                    cc->fg_ok = ghostty_render_state_row_cells_get(
                                    cells,
                                    GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR,
                                    &cc->fg) == GHOSTTY_SUCCESS;
                    cc->bg_ok = ghostty_render_state_row_cells_get(
                                    cells,
                                    GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR,
                                    &cc->bg) == GHOSTTY_SUCCESS;
                }
            }
            col_idx++;
        }

        printf("[row %2u] '%.*s' fg=", row_idx, (int)row_len, row_text);
        if (have_first)
            print_style_color(&first_fg, NULL, false);
        else
            printf("-");
        printf(" bg=");
        if (have_first)
            print_style_color(&first_bg, NULL, false);
        else
            printf("-");
        printf("\n");
        row_idx++;
    }

    /* 6. Detalle de celdas con estilo (verificacion SGR por celda). */
    printf("\n--- Colored cells (SGR verified) ---\n");
    for (size_t i = 0; i < colored_count; i++) {
        ColoredCell* cc = &colored[i];
        printf("(r=%u,c=%u) '%s' fg=", cc->row, cc->col, cc->text);
        print_style_color(&cc->style.fg_color, &cc->fg, cc->fg_ok);
        printf(" bg=");
        print_style_color(&cc->style.bg_color, &cc->bg, cc->bg_ok);
        if (cc->style.bold) printf(" bold");
        printf("\n");
    }

    printf("\n=== PoC OK ===\n");
    rc = 0;

cleanup:
    if (cells) ghostty_render_state_row_cells_free(cells);
    if (it) ghostty_render_state_row_iterator_free(it);
    if (rs) ghostty_render_state_free(rs);
    if (term) ghostty_terminal_free(term);
    return rc;
}
