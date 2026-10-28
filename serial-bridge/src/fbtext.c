/*
 * fbtext - minimal streaming text renderer for the Linux framebuffer.
 *
 * balenaOS boots with console=null and the VT layer does not render
 * post-boot writes, so we bypass /dev/tty1 entirely and draw text
 * directly into the framebuffer (mmap). Reads a text stream on stdin
 * and behaves like a dumb terminal: newline scrolls up one glyph row.
 *
 * Supported fonts: PSF1 and PSF2 console fonts (from the kbd/console-data
 * packages). Only ASCII/Latin-1 is rendered; other bytes map to '?'.
 * ANSI escape sequences on the input are stripped.
 *
 * Build: gcc -O2 -o fbtext fbtext.c
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>
#include <linux/fb.h>

/* ------------------------------------------------------------------ font */
static unsigned char *glyphs;
static long glyph_offset;
static int nglyphs = 256;
static int charsize; /* bytes per glyph bitmap */
static int gw = 8, gh = 16, row_bytes = 1;

static int load_font(const char *path)
{
    FILE *f = fopen(path, "rb");
    if (!f)
        return -1;
    unsigned char hdr[32];
    if (fread(hdr, 1, 32, f) < 32) {
        fclose(f);
        return -1;
    }
    if (hdr[0] == 0x36 && hdr[1] == 0x04) { /* PSF1 */
        glyph_offset = 4;
        gh = hdr[3];
        charsize = gh;
        row_bytes = 1;
        nglyphs = (hdr[2] & 0x01) ? 512 : 256;
    } else if (hdr[0] == 0x72 && hdr[1] == 0xb5 && hdr[2] == 0x4a && hdr[3] == 0x86) { /* PSF2 */
        const unsigned char *u = hdr + 8; /* magic + version */
        uint32_t headersize = u[0] | (u[1] << 8) | (u[2] << 16) | ((uint32_t)u[3] << 24);
        uint32_t csz = u[12] | (u[13] << 8) | (u[14] << 16) | ((uint32_t)u[15] << 24);
        uint32_t height = u[16] | (u[17] << 8) | (u[18] << 16) | ((uint32_t)u[19] << 24);
        uint32_t width = u[20] | (u[21] << 8) | (u[22] << 16) | ((uint32_t)u[23] << 24);
        glyph_offset = (long)headersize;
        charsize = (int)csz;
        gh = (int)height;
        gw = (int)width;
        row_bytes = (gw + 7) / 8;
        nglyphs = charsize ? (int)(csz / (uint32_t)row_bytes) : 256;
    } else {
        fclose(f);
        return -1;
    }
    if (gh <= 0 || gw <= 0 || charsize <= 0) {
        fclose(f);
        return -1;
    }
    size_t want = (size_t)charsize * (size_t)nglyphs;
    glyphs = malloc(want);
    if (!glyphs) {
        fclose(f);
        return -1;
    }
    fseek(f, glyph_offset, SEEK_SET);
    if (fread(glyphs, 1, want, f) != want) {
        fclose(f);
        return -1;
    }
    fclose(f);
    return 0;
}

/* ------------------------------------------------------------- framebuffer */
static unsigned char *fb;
static struct fb_var_screeninfo vi;
static struct fb_fix_screeninfo fi;
static unsigned char white[4], black[4];

static void putpx(int x, int y, int on)
{
    size_t pxsz = vi.bits_per_pixel / 8;
    unsigned char *p = fb + (size_t)y * fi.line_length + (size_t)x * pxsz;
    memcpy(p, on ? white : black, pxsz);
}

static void clear_row(int y)
{
    memset(fb + (size_t)y * fi.line_length, 0, (size_t)vi.xres * (vi.bits_per_pixel / 8));
}

static void draw_char(int col, int row, unsigned char c)
{
    if ((int)c >= nglyphs)
        c = '?';
    const unsigned char *g = glyphs + (size_t)c * charsize;
    for (int r = 0; r < gh; r++) {
        for (int b = 0; b < gw; b++) {
            int on = g[r * row_bytes + b / 8] & (0x80 >> (b % 8));
            putpx(col * gw + b, row * gh + r, on);
        }
    }
}

static int cols, rows;

static void flush_line(const char *line, int n)
{
    size_t lh = (size_t)gh * fi.line_length;
    memmove(fb, fb + lh, ((size_t)vi.yres - gh) * fi.line_length);
    for (int y = (int)vi.yres - gh; y < (int)vi.yres; y++)
        clear_row(y);
    if (n > cols)
        n = cols;
    for (int i = 0; i < n; i++)
        draw_char(i, rows - 1, (unsigned char)line[i]);
}

int main(int argc, char **argv)
{
    const char *fbpath = "/dev/fb0";
    const char *fontpath = NULL;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--fb") && i + 1 < argc)
            fbpath = argv[++i];
        else if (!strcmp(argv[i], "--font") && i + 1 < argc)
            fontpath = argv[++i];
    }
    if (!fontpath)
        fontpath = getenv("FBTEXT_FONT");
    if (!fontpath || load_font(fontpath) != 0) {
        fprintf(stderr, "fbtext: cannot load PSF font\n");
        return 1;
    }

    int fd = open(fbpath, O_RDWR);
    if (fd < 0) {
        perror("fbtext: open fb");
        return 1;
    }
    if (ioctl(fd, FBIOGET_VSCREENINFO, &vi) || ioctl(fd, FBIOGET_FSCREENINFO, &fi)) {
        perror("fbtext: ioctl fb");
        return 1;
    }
    if (vi.bits_per_pixel != 16 && vi.bits_per_pixel != 24 && vi.bits_per_pixel != 32) {
        fprintf(stderr, "fbtext: unsupported bpp %d\n", vi.bits_per_pixel);
        return 1;
    }
    size_t len = (size_t)fi.line_length * vi.yres;
    fb = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (fb == MAP_FAILED) {
        perror("fbtext: mmap");
        return 1;
    }

    memset(white, 0xff, sizeof(white));
    memset(black, 0x00, sizeof(black));
    for (int y = 0; y < (int)vi.yres; y++)
        clear_row(y);

    cols = (int)vi.xres / gw;
    rows = (int)vi.yres / gh;
    if (cols < 1)
        cols = 1;
    if (rows < 1)
        rows = 1;

    static char line[8192];
    int n = 0, esc = 0, last_cr = 0;

    for (;;) {
        int c = getchar();
        if (c == EOF)
            break;
        if (esc) { /* strip ANSI CSI: eat until a final letter arrives */
            if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z'))
                esc = 0;
            continue;
        }
        if (c == 0x1b) {
            esc = 1;
            continue;
        }
        if (c == '\n') {
            if (!last_cr)
                flush_line(line, n);
            last_cr = 0;
            n = 0;
            continue;
        }
        if (c == '\r') {
            flush_line(line, n);
            last_cr = 1;
            n = 0;
            continue;
        }
        last_cr = 0;
        if (c == '\t') {
            if (n < cols)
                line[n++] = ' ';
            continue;
        }
        if (c < 32)
            continue; /* drop other control bytes */
        if (n < cols) {
            line[n++] = (char)c;
        } else { /* line longer than the screen: flush and keep the tail */
            flush_line(line, n);
            n = 0;
            line[n++] = (char)c;
        }
    }
    if (n > 0)
        flush_line(line, n);
    return 0;
}
