/* Reference command-stream dumper for the Nuklear `overview` demo.
 *
 * Drives the canonical overview() with a scripted, deterministic input and
 * prints each frame's command buffer in a canonical text format that the
 * zuklear dumper (dump_zk.zig) reproduces, so the two can be diffed.
 *
 * Build (from this directory):
 *   zig cc -O2 -I../../../nuklear dump_nk.c -lm -o dump_nk
 * Run:
 *   ./dump_nk            # dump frames
 *   ./dump_nk --font     # dump the font width table (metrics check)
 */
#include <math.h>
#include <string.h>

#define NK_INCLUDE_FIXED_TYPES
#define NK_INCLUDE_STANDARD_IO
#define NK_INCLUDE_STANDARD_VARARGS
#define NK_INCLUDE_DEFAULT_ALLOCATOR
#define NK_INCLUDE_FONT_BAKING
#define NK_INCLUDE_DEFAULT_FONT
#define NK_IMPLEMENTATION
#include "nuklear.h"

#include "../../../nuklear/demo/common/overview.c"

#define PIXEL_HEIGHT 13.0f
#define WIN_W 480
#define WIN_H 600

/* Scripted input shared with dump_zk.zig: expand the Window, Widgets, Layout and
 * Input tabs bottom-up (so each header stays at its frame-0 Y), press/release per
 * click. Chart and Popup are left collapsed on purpose: Chart's data uses libm
 * cos/sin (differs from std.math at the last ULP, not a port issue) and Popup has
 * tooltip variants not yet ported. */
static const int script[][3] = {
    {200, 209, 1}, {200, 209, 0}, /* Input  */
    {200, 184, 1}, {200, 184, 0}, /* Layout */
    {200, 109, 1}, {200, 109, 0}, /* Widgets */
    {200, 84, 1},  {200, 84, 0},  /* Window */
    {5, 5, 0},                    /* settle, mouse in corner */
};
#define FRAMES ((int)(sizeof(script) / sizeof(script[0])))

static int ri(float v) { return (int)nearbyintf(v); }
static void col(struct nk_color c) { printf("%02x%02x%02x%02x", c.r, c.g, c.b, c.a); }

static void put_string(const char *s, int len) {
    putchar('"');
    for (int i = 0; i < len; ++i) {
        char ch = s[i];
        if (ch == '\\' || ch == '"') { putchar('\\'); putchar(ch); }
        else if (ch == '\n') { putchar('\\'); putchar('n'); }
        else putchar(ch);
    }
    putchar('"');
}

static void dump_commands(struct nk_context *ctx) {
    const struct nk_command *cmd;
    nk_foreach(cmd, ctx) {
        switch (cmd->type) {
        case NK_COMMAND_NOP: break;
        case NK_COMMAND_SCISSOR: {
            const struct nk_command_scissor *c = (const void *)cmd;
            printf("SCISSOR %d %d %d %d\n", ri(c->x), ri(c->y), ri(c->w), ri(c->h));
        } break;
        case NK_COMMAND_LINE: {
            const struct nk_command_line *c = (const void *)cmd;
            printf("LINE %d %d %d %d %d ", ri(c->begin.x), ri(c->begin.y), ri(c->end.x), ri(c->end.y), c->line_thickness);
            col(c->color); putchar('\n');
        } break;
        case NK_COMMAND_RECT: {
            const struct nk_command_rect *c = (const void *)cmd;
            printf("RECT %d %d %d %d %d %d ", ri(c->x), ri(c->y), ri(c->w), ri(c->h), c->rounding, c->line_thickness);
            col(c->color); putchar('\n');
        } break;
        case NK_COMMAND_RECT_FILLED: {
            const struct nk_command_rect_filled *c = (const void *)cmd;
            printf("FILLRECT %d %d %d %d %d ", ri(c->x), ri(c->y), ri(c->w), ri(c->h), c->rounding);
            col(c->color); putchar('\n');
        } break;
        case NK_COMMAND_RECT_MULTI_COLOR: {
            const struct nk_command_rect_multi_color *c = (const void *)cmd;
            printf("RECTMULTI %d %d %d %d ", ri(c->x), ri(c->y), ri(c->w), ri(c->h));
            col(c->left); putchar(' '); col(c->top); putchar(' '); col(c->bottom); putchar(' '); col(c->right); putchar('\n');
        } break;
        case NK_COMMAND_CIRCLE: {
            const struct nk_command_circle *c = (const void *)cmd;
            printf("CIRCLE %d %d %d %d %d ", ri(c->x), ri(c->y), ri(c->w), ri(c->h), c->line_thickness);
            col(c->color); putchar('\n');
        } break;
        case NK_COMMAND_CIRCLE_FILLED: {
            const struct nk_command_circle_filled *c = (const void *)cmd;
            printf("FILLCIRCLE %d %d %d %d ", ri(c->x), ri(c->y), ri(c->w), ri(c->h));
            col(c->color); putchar('\n');
        } break;
        case NK_COMMAND_TRIANGLE: {
            const struct nk_command_triangle *c = (const void *)cmd;
            printf("TRI %d %d %d %d %d %d %d ", ri(c->a.x), ri(c->a.y), ri(c->b.x), ri(c->b.y), ri(c->c.x), ri(c->c.y), c->line_thickness);
            col(c->color); putchar('\n');
        } break;
        case NK_COMMAND_TRIANGLE_FILLED: {
            const struct nk_command_triangle_filled *c = (const void *)cmd;
            printf("FILLTRI %d %d %d %d %d %d ", ri(c->a.x), ri(c->a.y), ri(c->b.x), ri(c->b.y), ri(c->c.x), ri(c->c.y));
            col(c->color); putchar('\n');
        } break;
        case NK_COMMAND_POLYGON: {
            const struct nk_command_polygon *c = (const void *)cmd;
            printf("POLY %d ", c->line_thickness); col(c->color); printf(" %d", c->point_count);
            for (int i = 0; i < c->point_count; ++i) printf(" %d %d", ri(c->points[i].x), ri(c->points[i].y));
            putchar('\n');
        } break;
        case NK_COMMAND_POLYGON_FILLED: {
            const struct nk_command_polygon_filled *c = (const void *)cmd;
            printf("FILLPOLY "); col(c->color); printf(" %d", c->point_count);
            for (int i = 0; i < c->point_count; ++i) printf(" %d %d", ri(c->points[i].x), ri(c->points[i].y));
            putchar('\n');
        } break;
        case NK_COMMAND_POLYLINE: {
            const struct nk_command_polyline *c = (const void *)cmd;
            printf("POLYLINE %d ", c->line_thickness); col(c->color); printf(" %d", c->point_count);
            for (int i = 0; i < c->point_count; ++i) printf(" %d %d", ri(c->points[i].x), ri(c->points[i].y));
            putchar('\n');
        } break;
        case NK_COMMAND_ARC: {
            const struct nk_command_arc *c = (const void *)cmd;
            printf("ARC %d %d %d %.3f %.3f %d ", ri(c->cx), ri(c->cy), c->r, c->a[0], c->a[1], c->line_thickness);
            col(c->color); putchar('\n');
        } break;
        case NK_COMMAND_ARC_FILLED: {
            const struct nk_command_arc_filled *c = (const void *)cmd;
            printf("FILLARC %d %d %d %.3f %.3f ", ri(c->cx), ri(c->cy), c->r, c->a[0], c->a[1]);
            col(c->color); putchar('\n');
        } break;
        case NK_COMMAND_CURVE: {
            const struct nk_command_curve *c = (const void *)cmd;
            printf("CURVE %d %d %d %d %d %d %d %d %d ", ri(c->begin.x), ri(c->begin.y), ri(c->ctrl[0].x), ri(c->ctrl[0].y), ri(c->ctrl[1].x), ri(c->ctrl[1].y), ri(c->end.x), ri(c->end.y), c->line_thickness);
            col(c->color); putchar('\n');
        } break;
        case NK_COMMAND_TEXT: {
            const struct nk_command_text *c = (const void *)cmd;
            printf("TEXT %d %d %d %d ", ri(c->x), ri(c->y), ri(c->w), ri(c->h));
            col(c->foreground); putchar(' '); col(c->background); putchar(' ');
            put_string(c->string, c->length); putchar('\n');
        } break;
        case NK_COMMAND_IMAGE: {
            const struct nk_command_image *c = (const void *)cmd;
            printf("IMAGE %d %d %d %d ", ri(c->x), ri(c->y), ri(c->w), ri(c->h));
            col(c->col); putchar('\n');
        } break;
        default: break;
        }
    }
}

int main(int argc, char **argv) {
    struct nk_context ctx;
    struct nk_font_atlas atlas;
    nk_font_atlas_init_default(&atlas);
    nk_font_atlas_begin(&atlas);
    struct nk_font *font = nk_font_atlas_add_default(&atlas, PIXEL_HEIGHT, 0);
    int iw, ih;
    nk_font_atlas_bake(&atlas, &iw, &ih, NK_FONT_ATLAS_RGBA32);
    nk_font_atlas_end(&atlas, nk_handle_id(0), 0);
    nk_init_default(&ctx, &font->handle);

    const struct nk_user_font *f = &font->handle;
    if (argc > 1 && strcmp(argv[1], "--font") == 0) {
        printf("height %.3f\n", f->height);
        for (int ch = 32; ch < 127; ++ch) {
            char s[2] = {(char)ch, 0};
            printf("%d %.3f\n", ch, f->width(f->userdata, f->height, s, 1));
        }
        return 0;
    }

    for (int frame = 0; frame < FRAMES; ++frame) {
        nk_input_begin(&ctx);
        nk_input_motion(&ctx, script[frame][0], script[frame][1]);
        nk_input_button(&ctx, NK_BUTTON_LEFT, script[frame][0], script[frame][1], script[frame][2]);
        nk_input_end(&ctx);

        overview(&ctx);

        printf("FRAME %d\n", frame);
        dump_commands(&ctx);
        nk_clear(&ctx);
    }
    return 0;
}
