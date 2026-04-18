#include <CoreFoundation/CoreFoundation.h>

int macos_is_dark_mode(void) {
    CFStringRef key = CFStringCreateWithCString(NULL, "AppleInterfaceStyle", kCFStringEncodingUTF8);
    CFStringRef style = (CFStringRef) CFPreferencesCopyAppValue(key, kCFPreferencesAnyApplication);
    int is_dark = 0;
    
    if (style) {
        if (CFStringCompare(style, CFSTR("Dark"), 0) == kCFCompareEqualTo) {
            is_dark = 1;
        }
        CFRelease(style);
    }
    
    CFRelease(key);
    return is_dark;
}
