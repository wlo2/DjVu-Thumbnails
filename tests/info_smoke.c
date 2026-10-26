// Standalone harness for DJVReadDocumentInfo: prints what Spotlight would get.
// Usage: info_smoke <in.djvu> <maxTextBytes>
// Output: a summary line, one "meta <key>=<value>" line per metadata entry,
// then "text:" followed by the raw text.
#include "DjVuRender.h"
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: %s <in.djvu> <maxTextBytes>\n", argv[0]);
        return 2;
    }
    DJVDocumentInfo info;
    DJVResult r = DJVReadDocumentInfo(argv[1], (size_t)strtoull(argv[2], NULL, 10), &info);
    if (r != DJVResultOK) {
        char err[512];
        printf("FAIL %s -> result=%d", argv[1], r);
        if (DJVLastErrorMessage(err, sizeof(err))) {
            printf(" (%s)", err);
        }
        printf("\n");
        return 1;
    }
    printf("OK pages=%d size=%.0fx%.0f truncated=%d length=%zu\n", info.pageCount,
           info.pageWidth, info.pageHeight, info.textTruncated, info.textLength);
    for (int i = 0; i < info.metadataCount; i++) {
        printf("meta %s=%s\n", info.metadata[2 * i], info.metadata[2 * i + 1]);
    }
    printf("text:%s", info.text ? info.text : "");
    DJVDocumentInfoFree(&info);
    return 0;
}
