// Standalone harness for the C shim: renders a DjVu cover and writes it as PPM.
// Usage: render_smoke <in.djvu> <maxPixelSize> [out.ppm]
#include "DjVuRender.h"
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: %s <in.djvu> <maxPixelSize> [out.ppm]\n", argv[0]);
        return 2;
    }
    DJVBitmap bmp;
    DJVResult r = DJVRenderFirstPage(argv[1], atoi(argv[2]), &bmp);
    char err[512];
    if (r != DJVResultOK) {
        printf("FAIL %s -> result=%d", argv[1], r);
        if (DJVLastErrorMessage(err, sizeof(err))) {
            printf(" (%s)", err);
        }
        printf("\n");
        return 1;
    }
    printf("OK   %s -> %dx%d stride=%d bytes=%zu\n", argv[1], bmp.width, bmp.height,
           bmp.bytesPerRow, bmp.length);
    if (argc > 3) {
        FILE *f = fopen(argv[3], "wb");
        if (!f) {
            perror("fopen");
            return 1;
        }
        fprintf(f, "P6\n%d %d\n255\n", bmp.width, bmp.height);
        for (int y = 0; y < bmp.height; y++) {
            fwrite(bmp.data + (size_t)y * bmp.bytesPerRow, 1, (size_t)bmp.width * 3, f);
        }
        fclose(f);
        // Report the top-left and centre pixels so row order and colour order
        // can be eyeballed from the test output.
        unsigned char *tl = bmp.data;
        unsigned char *c = bmp.data + (size_t)(bmp.height / 2) * bmp.bytesPerRow +
                           (size_t)(bmp.width / 2) * 3;
        printf("     topleft=(%d,%d,%d) center=(%d,%d,%d)\n", tl[0], tl[1], tl[2], c[0], c[1],
               c[2]);
    }
    DJVBitmapFree(&bmp);
    return 0;
}
