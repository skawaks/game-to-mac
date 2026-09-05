/*
 * winlist.c — list on-screen windows, for render verification.
 *
 * Build:
 *   cc -o /tmp/winlist winlist.c -framework CoreGraphics -framework CoreFoundation
 *
 * Output (TSV):  <windowID>\t<x>,<y>\t<W>x<H>\t<title>\t<owner>
 *
 * Needs no Screen Recording permission: CGWindowListCopyWindowInfo returns
 * metadata (ids, bounds, titles) without it. Only *pixel* capture needs the
 * permission, which is why this tool works when `screencapture` does not.
 */
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <stdio.h>

int main(void) {
    CFArrayRef list = CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
        kCGNullWindowID);
    if (!list) {
        fprintf(stderr, "CGWindowListCopyWindowInfo failed\n");
        return 1;
    }

    CFIndex n = CFArrayGetCount(list);
    for (CFIndex i = 0; i < n; i++) {
        CFDictionaryRef d = (CFDictionaryRef)CFArrayGetValueAtIndex(list, i);

        CGWindowID wid = 0;
        CFNumberRef num = (CFNumberRef)CFDictionaryGetValue(d, kCGWindowNumber);
        if (num) CFNumberGetValue(num, kCFNumberIntType, &wid);

        CGRect rc = CGRectZero;
        CFDictionaryRef b = (CFDictionaryRef)CFDictionaryGetValue(d, kCGWindowBounds);
        if (b) CGRectMakeWithDictionaryRepresentation(b, &rc);

        CFStringRef owner = (CFStringRef)CFDictionaryGetValue(d, kCGWindowOwnerName);
        CFStringRef name  = (CFStringRef)CFDictionaryGetValue(d, kCGWindowName);

        char o[512] = "", t[512] = "";
        if (owner) CFStringGetCString(owner, o, sizeof(o), kCFStringEncodingUTF8);
        if (name)  CFStringGetCString(name,  t, sizeof(t), kCFStringEncodingUTF8);

        printf("%u\t%g,%g\t%gx%g\t%s\t%s\n",
               (unsigned)wid, rc.origin.x, rc.origin.y,
               rc.size.width, rc.size.height,
               t[0] ? t : "(untitled)", o);
    }

    CFRelease(list);
    return 0;
}
