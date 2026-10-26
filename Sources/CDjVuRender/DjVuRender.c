#include "DjVuRender.h"

#include <libdjvu/ddjvuapi.h>
#include <libdjvu/miniexp.h>

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
    // DjVuLibre's message texts are not shipped, so it reports an error as an
    // "Unrecognized DjVu Message" header, then "Message name: <id>" and one line
    // per parameter. Keep everything from the id on, as a single line.
    static const char marker[] = "Message name:";
    const char *name = strstr(message, marker);
    if (name) {
        message = name + sizeof(marker) - 1;
    }
    size_t n = 0;
    for (; *message && n + 1 < sizeof(djv_last_error); message++) {
        char c = *message;
        if ((unsigned char)c < 0x20) {
            c = ' ';  // newlines, tabs and DjVuLibre's separator bytes
        }
        if (c == ' ' && (n == 0 || djv_last_error[n - 1] == ' ')) {
            continue;
        }
        djv_last_error[n++] = c;
    }
    while (n > 0 && djv_last_error[n - 1] == ' ') {
        n--;
    }
    djv_last_error[n] = '\0';
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

// Opens the document and waits until its page directory is known. On failure
// the caller still releases whatever was created, through djv_close.
static DJVResult djv_open(const char *path, ddjvu_context_t **ctx, ddjvu_document_t **doc) {
    *ctx = ddjvu_context_create("DjVuThumbnails");
    if (!*ctx) {
        return DJVResultContextFailed;
    }
    // A one-shot read needs no cache; keep memory use minimal.
    ddjvu_cache_set_size(*ctx, 1);

    *doc = ddjvu_document_create_by_filename_utf8(*ctx, path, /*cache=*/FALSE);
    if (!*doc) {
        return DJVResultDocumentFailed;
    }
    while (!ddjvu_document_decoding_done(*doc)) {
        djv_drain_messages(*ctx, /*wait=*/1);
    }
    if (ddjvu_document_decoding_error(*doc) || ddjvu_document_get_pagenum(*doc) < 1) {
        return DJVResultDocumentFailed;
    }
    return DJVResultOK;
}

static void djv_close(ddjvu_context_t *ctx, ddjvu_document_t *doc) {
    if (doc) {
        ddjvu_document_release(doc);
    }
    if (ctx) {
        djv_drain_messages(ctx, /*wait=*/0);
        ddjvu_context_release(ctx);
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

    result = djv_open(path, &ctx, &doc);
    if (result != DJVResultOK) {
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
    djv_close(ctx, doc);
    return result;
}

void DJVDocumentInfoFree(DJVDocumentInfo *info) {
    if (!info) {
        return;
    }
    free(info->text);
    for (int i = 0; i < 2 * info->metadataCount; i++) {
        free(info->metadata[i]);
    }
    free(info->metadata);
    memset(info, 0, sizeof(*info));
}

// Appends `length` bytes of UTF-8 to info->text, never past `maxBytes` and never
// splitting a character. Returns 0 on success, -1 when out of memory.
static int djv_append_text(DJVDocumentInfo *info, size_t *capacity, const char *s,
                           size_t length, size_t maxBytes) {
    size_t room = maxBytes - info->textLength;
    if (length > room) {
        length = room;
        // Back up over continuation bytes (10xxxxxx) to a character start.
        while (length > 0 && ((unsigned char)s[length] & 0xC0) == 0x80) {
            length--;
        }
        info->textTruncated = 1;
    }
    size_t needed = info->textLength + length + 1;
    if (needed > *capacity) {
        size_t grown = *capacity ? *capacity * 2 : 4096;
        if (grown < needed) {
            grown = needed;
        }
        char *text = realloc(info->text, grown);
        if (!text) {
            return -1;
        }
        info->text = text;
        *capacity = grown;
    }
    memcpy(info->text + info->textLength, s, length);
    info->textLength += length;
    info->text[info->textLength] = '\0';
    return 0;
}

// Turns every byte that is not part of a valid UTF-8 character into a space.
// OCR layers often carry stray bytes (a Latin-1 "ø" for a footnote mark), and
// one of them makes CFString reject the whole text. Length never changes.
static void djv_make_valid_utf8(char *text, size_t length) {
    unsigned char *s = (unsigned char *)text;
    size_t i = 0;
    while (i < length) {
        unsigned char c = s[i];
        size_t n = c < 0x80 ? 1 : c >= 0xC2 && c <= 0xDF ? 2
                 : c >= 0xE0 && c <= 0xEF ? 3 : c >= 0xF0 && c <= 0xF4 ? 4 : 0;
        // The second byte has a narrower range after E0, ED, F0 and F4, which
        // rules out overlong forms, surrogates and code points past U+10FFFF.
        unsigned char low = c == 0xE0 ? 0xA0 : c == 0xF0 ? 0x90 : 0x80;
        unsigned char high = c == 0xED ? 0x9F : c == 0xF4 ? 0x8F : 0xBF;
        int valid = n > 0 && i + n <= length;
        for (size_t k = 1; valid && k < n; k++) {
            valid = k == 1 ? s[i + k] >= low && s[i + k] <= high
                           : s[i + k] >= 0x80 && s[i + k] <= 0xBF;
        }
        if (valid) {
            i += n;
        } else {
            s[i++] = ' ';
        }
    }
}

// Collects every page's hidden text (the OCR layer), separated by blank lines.
static DJVResult djv_read_text(ddjvu_context_t *ctx, ddjvu_document_t *doc,
                               size_t maxBytes, DJVDocumentInfo *info) {
    size_t capacity = 0;
    for (int pageno = 0; pageno < info->pageCount && !info->textTruncated; pageno++) {
        miniexp_t text;
        // "page" detail flattens the page into (page x0 y0 x1 y1 "text").
        while ((text = ddjvu_document_get_pagetext(doc, pageno, "page")) == miniexp_dummy) {
            djv_drain_messages(ctx, /*wait=*/1);
        }
        miniexp_t string = miniexp_nth(5, text);
        int failed = 0;
        if (miniexp_stringp(string)) {
            const char *s = miniexp_to_str(string);
            size_t length = strlen(s);
            if (length > 0) {
                failed = (info->textLength > 0 &&
                          djv_append_text(info, &capacity, "\n\n", 2, maxBytes) != 0) ||
                         djv_append_text(info, &capacity, s, length, maxBytes) != 0;
            }
        }
        // A page whose text cannot be read is skipped; the rest still counts.
        ddjvu_miniexp_release(doc, text);
        if (failed) {
            return DJVResultOutOfMemory;
        }
    }
    djv_make_valid_utf8(info->text, info->textLength);
    return DJVResultOK;
}

// Copies the document metadata (title, author, ...) as key/value pairs.
static DJVResult djv_read_metadata(ddjvu_context_t *ctx, ddjvu_document_t *doc,
                                   DJVDocumentInfo *info) {
    miniexp_t anno;
    // compat=1 also reads the shared annotation chunk most tools write.
    while ((anno = ddjvu_document_get_anno(doc, /*compat=*/1)) == miniexp_dummy) {
        djv_drain_messages(ctx, /*wait=*/1);
    }
    DJVResult result = DJVResultOK;
    miniexp_t *keys = miniexp_consp(anno) ? ddjvu_anno_get_metadata_keys(anno) : NULL;
    int count = 0;
    while (keys && keys[count]) {
        count++;
    }
    if (count > 0) {
        info->metadata = calloc((size_t)count * 2, sizeof(char *));
        if (!info->metadata) {
            result = DJVResultOutOfMemory;
        }
        for (int i = 0; info->metadata && i < count; i++) {
            const char *value = ddjvu_anno_get_metadata(anno, keys[i]);
            char *key = strdup(miniexp_to_name(keys[i]));
            char *copy = strdup(value ? value : "");
            info->metadata[2 * i] = key;
            info->metadata[2 * i + 1] = copy;
            info->metadataCount = i + 1;
            if (!key || !copy) {
                result = DJVResultOutOfMemory;
                break;
            }
            djv_make_valid_utf8(key, strlen(key));
            djv_make_valid_utf8(copy, strlen(copy));
        }
    }
    free(keys);
    ddjvu_miniexp_release(doc, anno);
    return result;
}

DJVResult DJVReadDocumentInfo(const char *path, size_t maxTextBytes, DJVDocumentInfo *out) {
    if (!path || !out) {
        return DJVResultBadArgument;
    }
    memset(out, 0, sizeof(*out));
    djv_last_error[0] = '\0';

    ddjvu_context_t *ctx = NULL;
    ddjvu_document_t *doc = NULL;
    DJVResult result = djv_open(path, &ctx, &doc);
    if (result == DJVResultOK) {
        out->pageCount = ddjvu_document_get_pagenum(doc);

        ddjvu_pageinfo_t pageinfo;
        ddjvu_status_t status;
        while ((status = ddjvu_document_get_pageinfo(doc, 0, &pageinfo)) < DDJVU_JOB_OK) {
            djv_drain_messages(ctx, /*wait=*/1);
        }
        if (status == DDJVU_JOB_OK && pageinfo.dpi > 0) {
            // Points are 1/72 inch; an odd rotation turns the page on its side.
            double width = pageinfo.width * 72.0 / pageinfo.dpi;
            double height = pageinfo.height * 72.0 / pageinfo.dpi;
            out->pageWidth = (pageinfo.rotation & 1) ? height : width;
            out->pageHeight = (pageinfo.rotation & 1) ? width : height;
        }

        result = djv_read_metadata(ctx, doc, out);
        if (result == DJVResultOK && maxTextBytes > 0) {
            result = djv_read_text(ctx, doc, maxTextBytes, out);
        }
    }
    djv_close(ctx, doc);
    if (result != DJVResultOK) {
        DJVDocumentInfoFree(out);
    }
    return result;
}
