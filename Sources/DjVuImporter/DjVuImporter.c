// Spotlight importer for DjVu: indexes the hidden (OCR) text layer, metadata
// and page count. This is a classic CFPlugIn .mdimporter because Spotlight on
// macOS does not call CSImportExtension app extensions for ordinary files.
#include <CoreFoundation/CoreFoundation.h>
#include <CoreFoundation/CFPlugInCOM.h>
#include <CoreServices/CoreServices.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

#include "DjVuRender.h"

// Must match CFPlugInFactories in Info.plist.
#define FACTORY_ID "6BD798CF-EF84-4E6A-AE35-AEAE2CE8EE4D"

// Scanned books can carry far more OCR text than this; mdworker gives each
// import limited time and memory, and the first 10 MB find a book anyway.
#define MAX_TEXT_BYTES ((size_t)10 * 1024 * 1024)

static void set_string(CFMutableDictionaryRef attributes, CFStringRef key, const char *value) {
    CFStringRef string = CFStringCreateWithCString(NULL, value, kCFStringEncodingUTF8);
    if (string) {
        if (CFStringGetLength(string) > 0) {
            CFDictionarySetValue(attributes, key, string);
        }
        CFRelease(string);
    }
}

// Splits `value` on `separator` into a trimmed, non-empty list of strings.
static void set_list(CFMutableDictionaryRef attributes, CFStringRef key, const char *value,
                     CFStringRef separator) {
    CFStringRef string = CFStringCreateWithCString(NULL, value, kCFStringEncodingUTF8);
    if (!string) {
        return;
    }
    CFArrayRef parts = CFStringCreateArrayBySeparatingStrings(NULL, string, separator);
    CFMutableArrayRef list = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    for (CFIndex i = 0; parts && i < CFArrayGetCount(parts); i++) {
        CFMutableStringRef part =
            CFStringCreateMutableCopy(NULL, 0, CFArrayGetValueAtIndex(parts, i));
        CFStringTrimWhitespace(part);
        if (CFStringGetLength(part) > 0) {
            CFArrayAppendValue(list, part);
        }
        CFRelease(part);
    }
    if (CFArrayGetCount(list) > 0) {
        CFDictionarySetValue(attributes, key, list);
    }
    CFRelease(list);
    if (parts) {
        CFRelease(parts);
    }
    CFRelease(string);
}

static void set_number(CFMutableDictionaryRef attributes, CFStringRef key, CFNumberType type,
                       const void *value) {
    CFNumberRef number = CFNumberCreate(NULL, type, value);
    CFDictionarySetValue(attributes, key, number);
    CFRelease(number);
}

Boolean GetMetadataForFile(void *thisInterface, CFMutableDictionaryRef attributes,
                           CFStringRef contentTypeUTI, CFStringRef pathToFile) {
    (void)thisInterface;
    (void)contentTypeUTI;
    char path[PATH_MAX];
    if (!CFStringGetFileSystemRepresentation(pathToFile, path, sizeof(path))) {
        return false;
    }
    DJVDocumentInfo info;
    if (DJVReadDocumentInfo(path, MAX_TEXT_BYTES, &info) != DJVResultOK) {
        return false;
    }

    if (info.text) {
        set_string(attributes, kMDItemTextContent, info.text);
    }
    set_number(attributes, kMDItemNumberOfPages, kCFNumberIntType, &info.pageCount);
    if (info.pageWidth > 0 && info.pageHeight > 0) {
        set_number(attributes, kMDItemPageWidth, kCFNumberDoubleType, &info.pageWidth);
        set_number(attributes, kMDItemPageHeight, kCFNumberDoubleType, &info.pageHeight);
    }
    // Keys follow BibTeX, but tools write both "title" and "Title".
    for (int i = 0; i < info.metadataCount; i++) {
        const char *name = info.metadata[2 * i];
        const char *value = info.metadata[2 * i + 1];
        if (strcasecmp(name, "title") == 0) {
            set_string(attributes, kMDItemTitle, value);
        } else if (strcasecmp(name, "author") == 0) {
            // BibTeX joins several authors with " and ".
            set_list(attributes, kMDItemAuthors, value, CFSTR(" and "));
        } else if (strcasecmp(name, "subject") == 0) {
            set_string(attributes, kMDItemSubject, value);
        } else if (strcasecmp(name, "keywords") == 0) {
            set_list(attributes, kMDItemKeywords, value, CFSTR(","));
        } else if (strcasecmp(name, "publisher") == 0) {
            set_list(attributes, kMDItemPublishers, value, CFSTR(";"));
        }
    }
    DJVDocumentInfoFree(&info);
    return true;
}

// CFPlugIn plumbing: a COM-style object whose interface table points at
// GetMetadataForFile. Spotlight creates one through the factory below.

typedef struct {
    MDImporterInterfaceStruct *interface;
    CFUUIDRef factoryID;
    UInt32 refCount;
} DjVuImporter;

static HRESULT importer_query_interface(void *instance, REFIID iid, LPVOID *out);
static ULONG importer_add_ref(void *instance);
static ULONG importer_release(void *instance);

static MDImporterInterfaceStruct importer_interface = {
    NULL, importer_query_interface, importer_add_ref, importer_release, GetMetadataForFile,
};

static HRESULT importer_query_interface(void *instance, REFIID iid, LPVOID *out) {
    CFUUIDRef interfaceID = CFUUIDCreateFromUUIDBytes(NULL, iid);
    Boolean known = CFEqual(interfaceID, kMDImporterInterfaceID) ||
                    CFEqual(interfaceID, IUnknownUUID);
    CFRelease(interfaceID);
    if (!known) {
        *out = NULL;
        return E_NOINTERFACE;
    }
    importer_add_ref(instance);
    *out = instance;
    return S_OK;
}

static ULONG importer_add_ref(void *instance) {
    return ++((DjVuImporter *)instance)->refCount;
}

static ULONG importer_release(void *instance) {
    DjVuImporter *importer = instance;
    if (--importer->refCount > 0) {
        return importer->refCount;
    }
    CFPlugInRemoveInstanceForFactory(importer->factoryID);
    CFRelease(importer->factoryID);
    free(importer);
    return 0;
}

// Named in Info.plist; exported so CFPlugIn can find it.
__attribute__((visibility("default"))) void *DjVuImporterFactory(CFAllocatorRef allocator,
                                                                 CFUUIDRef typeID) {
    (void)allocator;
    if (!CFEqual(typeID, kMDImporterTypeID)) {
        return NULL;
    }
    DjVuImporter *importer = calloc(1, sizeof(*importer));
    if (!importer) {
        return NULL;
    }
    importer->interface = &importer_interface;
    importer->factoryID = CFUUIDCreateFromString(NULL, CFSTR(FACTORY_ID));
    importer->refCount = 1;
    CFPlugInAddInstanceForFactory(importer->factoryID);
    return importer;
}
