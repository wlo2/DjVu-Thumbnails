#include "DjVuRender.h"

#include <libdjvu/ddjvuapi.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// DjVuLibre reports errors asynchronously through the message queue, so the
// last one seen is stashed here for the caller to log.
static _Thread_local char djv_last_error[512];

static void djv_record_error(const char *message) {
    if (!message) {
        return;
    }
    snprintf(djv_last_error, sizeof(djv_last_error), "%s", message);
}

int DJVLastErrorMessage(char *buffer, size_t bufferSize) {
    if (!buffer || bufferSize == 0 || djv_last_error[0] == '\0') {
        return 0;
    }
    snprintf(buffer, bufferSize, "%s", djv_last_error);
    return 1;
}

// Drains the message queue, remembering any error text. `wait` blocks until at
// least one message is available; decoding failures always produce a message,
// so this cannot block forever on a local file.
static void djv_drain_messages(ddjvu_context_t *ctx, int wait) {
    const ddjvu_message_t *msg;
    if (wait) {
        ddjvu_message_wait(ctx);
    }
    while ((msg = ddjvu_message_peek(ctx)) != NULL) {
        if (msg->m_any.tag == DDJVU_ERROR) {
            djv_record_error(msg->m_error.message);
        }
        ddjvu_message_pop(ctx);
    }
}

void DJVBitmapFree(DJVBitmap *bitmap) {
    if (!bitmap) {
        return;
    }
    free(bitmap->data);
    bitmap->data = NULL;
    bitmap->length = 0;
    bitmap->width = 0;
    bitmap->height = 0;
    bitmap->bytesPerRow = 0;
}

DJVResult DJVRenderFirstPage(const char *path, int maxPixelSize, DJVBitmap *out) {
    if (!path || !out || maxPixelSize <= 0) {
        return DJVResultBadArgument;
    }
    memset(out, 0, sizeof(*out));
    djv_last_error[0] = '\0';

    DJVResult result = DJVResultOK;
    ddjvu_context_t *ctx = NULL;
    ddjvu_document_t *doc = NULL;
    ddjvu_page_t *page = NULL;
    ddjvu_format_t *fmt = NULL;
    unsigned char *buffer = NULL;

    ctx = ddjvu_context_create("DjVuThumbnails");
    if (!ctx) {
        result = DJVResultContextFailed;
        goto cleanup;
    }
    // A one-shot render needs no cache; keep memory use minimal.
    ddjvu_cache_set_size(ctx, 1);

    doc = ddjvu_document_create_by_filename_utf8(ctx, path, /*cache=*/FALSE);
    if (!doc) {
        result = DJVResultDocumentFailed;
        goto cleanup;
    }
    while (!ddjvu_document_decoding_done(doc)) {
        djv_drain_messages(ctx, /*wait=*/1);
    }
    if (ddjvu_document_decoding_error(doc) || ddjvu_document_get_pagenum(doc) < 1) {
        result = DJVResultDocumentFailed;
        goto cleanup;
    }

    // Page 0 is the cover, which is what Finder should show.
    page = ddjvu_page_create_by_pageno(doc, 0);
    if (!page) {
        result = DJVResultPageFailed;
        goto cleanup;
    }
    while (!ddjvu_page_decoding_done(page)) {
        djv_drain_messages(ctx, /*wait=*/1);
    }
    if (ddjvu_page_decoding_error(page)) {
        result = DJVResultPageFailed;
        goto cleanup;
    }

    int pageWidth = ddjvu_page_get_width(page);
    int pageHeight = ddjvu_page_get_height(page);
    if (pageWidth <= 0 || pageHeight <= 0) {
        result = DJVResultPageFailed;
        goto cleanup;
    }

    // Fit the longest side into maxPixelSize without ever upscaling.
    int longest = pageWidth > pageHeight ? pageWidth : pageHeight;
    double scale = (double)maxPixelSize / (double)longest;
    if (scale > 1.0) {
        scale = 1.0;
    }
    int width = (int)(pageWidth * scale + 0.5);
    int height = (int)(pageHeight * scale + 0.5);
    if (width < 1) {
        width = 1;
    }
    if (height < 1) {
        height = 1;
    }

    fmt = ddjvu_format_create(DDJVU_FORMAT_RGB24, 0, NULL);
    if (!fmt) {
        result = DJVResultRenderFailed;
        goto cleanup;
    }
    // Core Graphics expects the top row first; DjVuLibre defaults to bottom-up.
    ddjvu_format_set_row_order(fmt, 1);
    ddjvu_format_set_y_direction(fmt, 1);

    size_t bytesPerRow = (size_t)width * 3;
    // Keep rows 4-byte aligned; Core Graphics is markedly faster that way.
    bytesPerRow = (bytesPerRow + 3) & ~(size_t)3;
    size_t length = bytesPerRow * (size_t)height;

    buffer = malloc(length);
    if (!buffer) {
        result = DJVResultOutOfMemory;
        goto cleanup;
    }
    // White, so pages that only partially render don't show garbage.
    memset(buffer, 0xFF, length);

    ddjvu_rect_t rect;
    rect.x = 0;
    rect.y = 0;
    rect.w = (unsigned int)width;
    rect.h = (unsigned int)height;

    int rendered = ddjvu_page_render(page, DDJVU_RENDER_COLOR, &rect, &rect, fmt,
                                     (unsigned long)bytesPerRow, (char *)buffer);
    if (!rendered) {
        // Bitonal scans sometimes carry no colour layer at all.
        rendered = ddjvu_page_render(page, DDJVU_RENDER_MASKONLY, &rect, &rect, fmt,
                                     (unsigned long)bytesPerRow, (char *)buffer);
    }
    if (!rendered) {
        result = DJVResultRenderFailed;
        goto cleanup;
    }

    out->data = buffer;
    out->length = length;
    out->width = width;
    out->height = height;
    out->bytesPerRow = (int)bytesPerRow;
    buffer = NULL;  // ownership transferred

cleanup:
    free(buffer);
    if (fmt) {
        ddjvu_format_release(fmt);
    }
    if (page) {
        ddjvu_page_release(page);
    }
    if (doc) {
        ddjvu_document_release(doc);
    }
    if (ctx) {
        djv_drain_messages(ctx, /*wait=*/0);
        ddjvu_context_release(ctx);
    }
    return result;
}
