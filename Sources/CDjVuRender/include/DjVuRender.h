// Thin C wrapper over DjVuLibre's ddjvu API: decodes the first page of a
// DjVu document into a plain RGB bitmap that Core Graphics can wrap directly,
// and reads the text and metadata that Spotlight indexes.
#ifndef DJVU_RENDER_H
#define DJVU_RENDER_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    unsigned char *data;   // RGB888, top row first. Free with DJVBitmapFree.
    size_t length;
    int width;
    int height;
    int bytesPerRow;
} DJVBitmap;

typedef enum {
    DJVResultOK = 0,
    DJVResultBadArgument = -1,
    DJVResultContextFailed = -2,
    DJVResultDocumentFailed = -3,   // not a DjVu file, or unreadable
    DJVResultPageFailed = -4,       // page 1 could not be decoded
    DJVResultRenderFailed = -5,
    DJVResultOutOfMemory = -6,
} DJVResult;

/// Decodes page 1 (the cover) and scales it so its longest side is at most
/// `maxPixelSize` pixels, never upscaling beyond the page's natural size.
/// On DJVResultOK the caller owns `out->data` and must call DJVBitmapFree.
DJVResult DJVRenderFirstPage(const char *path, int maxPixelSize, DJVBitmap *out);

void DJVBitmapFree(DJVBitmap *bitmap);

/// What Spotlight indexes about a document. Free with DJVDocumentInfoFree.
typedef struct {
    char *text;            // hidden (OCR) text of all pages, UTF-8; NULL if none
    size_t textLength;
    int textTruncated;     // 1 if the text stopped at maxTextBytes
    int pageCount;
    double pageWidth;      // page 1 in points (1/72 inch); 0 if unknown
    double pageHeight;
    char **metadata;       // key, value, key, value, ...
    int metadataCount;     // number of key/value pairs
} DJVDocumentInfo;

/// Reads page count, page 1 size, metadata and up to `maxTextBytes` of hidden
/// text, cut on a UTF-8 character boundary. Decodes no images.
/// On DJVResultOK the caller must call DJVDocumentInfoFree.
DJVResult DJVReadDocumentInfo(const char *path, size_t maxTextBytes, DJVDocumentInfo *out);

void DJVDocumentInfoFree(DJVDocumentInfo *info);

/// Copies the most recent DjVuLibre error for the calling thread into `buffer`.
/// Returns 1 if a message was available.
int DJVLastErrorMessage(char *buffer, size_t bufferSize);

#ifdef __cplusplus
}
#endif

#endif /* DJVU_RENDER_H */
