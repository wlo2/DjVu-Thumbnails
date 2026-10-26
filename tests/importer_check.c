// Calls the Spotlight importer's GetMetadataForFile directly and prints the
// attributes as an XML property list, so the mapping is tested without Spotlight.
// Usage: importer_check <in.djvu>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>

Boolean GetMetadataForFile(void *thisInterface, CFMutableDictionaryRef attributes,
                           CFStringRef contentTypeUTI, CFStringRef pathToFile);

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <in.djvu>\n", argv[0]);
        return 2;
    }
    CFMutableDictionaryRef attributes = CFDictionaryCreateMutable(
        NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFStringRef path = CFStringCreateWithCString(NULL, argv[1], kCFStringEncodingUTF8);
    if (!GetMetadataForFile(NULL, attributes, CFSTR("com.lizardtech.djvu"), path)) {
        printf("FAIL %s\n", argv[1]);
        return 1;
    }
    CFDataRef xml = CFPropertyListCreateData(NULL, attributes, kCFPropertyListXMLFormat_v1_0,
                                             0, NULL);
    fwrite(CFDataGetBytePtr(xml), 1, (size_t)CFDataGetLength(xml), stdout);
    CFRelease(xml);
    CFRelease(path);
    CFRelease(attributes);
    return 0;
}
