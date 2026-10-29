// Renders one file from 8 threads at once in a fresh process, as Quick Look
// does when Finder opens a folder. Run it many times: without the shim's
// document lock about 1 process in 100 fails, crashes or hangs.
// Usage: threads_smoke <in.djvu>
#include "DjVuRender.h"
#include <pthread.h>
#include <stdio.h>

static const char *path;

static void *render(void *unused) {
    (void)unused;
    DJVBitmap bitmap;
    if (DJVRenderFirstPage(path, 64, &bitmap) != DJVResultOK) {
        return (void *)1;
    }
    DJVBitmapFree(&bitmap);
    return NULL;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <in.djvu>\n", argv[0]);
        return 2;
    }
    path = argv[1];
    pthread_t threads[8];
    int failed = 0;
    for (int i = 0; i < 8; i++) {
        pthread_create(&threads[i], NULL, render, NULL);
    }
    for (int i = 0; i < 8; i++) {
        void *result;
        pthread_join(threads[i], &result);
        failed += result != NULL;
    }
    return failed;
}
