#import <CoreText/CTFontManager.h>
#import <CoreText/CTFontDescriptor.h>
#import <CoreText/CTFontTraits.h>
#import <CoreFoundation/CoreFoundation.h>
#import <ft2build.h>
#import FT_FREETYPE_H
#import <stdio.h>
#import <unistd.h>

extern const CFStringRef kCTFontSymbolicTrait;

/*
 * A descriptor for a font that exists only as BYTES.
 *
 * Skia asks for this when LibreOffice embeds a font in a document, and a missing lazy symbol is
 * an abort at first call rather than a degraded feature: the process died with
 * "Symbol not found: _CTFontManagerCreateFontDescriptorFromData" and nothing else.
 *
 * THE DATA IS WRITTEN TO A FILE, which is not a detour. Descriptors here carry a
 * kCTFontURLAttribute because that is how anything turns one back into a usable font, and there
 * is no in-memory font object in this stack to point at instead. FreeType reads the family and
 * style out of the same file, so the descriptor describes the real font rather than a guess.
 *
 * The file is deliberately NOT unlinked: the descriptor outlives this call and the URL inside it
 * has to keep resolving. They land in /tmp, which the container discards with the process.
 */
CTFontDescriptorRef CTFontManagerCreateFontDescriptorFromData(CFDataRef data)
{
    if (data == NULL || CFDataGetLength(data) == 0) return NULL;

    static int counter = 0;
    char path[128];
    snprintf(path, sizeof(path), "/tmp/cider-embedded-font-%d-%d.dat", (int) getpid(), counter++);
    FILE *f = fopen(path, "wb");
    if (f == NULL) return NULL;
    size_t length = (size_t) CFDataGetLength(data);
    if (fwrite(CFDataGetBytePtr(data), 1, length, f) != length) {
        fclose(f);
        unlink(path);
        return NULL;
    }
    fclose(f);

    FT_Library library = NULL;
    FT_Face face = NULL;
    if (FT_Init_FreeType(&library) != 0) {
        unlink(path);
        return NULL;
    }
    if (FT_New_Face(library, path, 0, &face) != 0) {
        FT_Done_FreeType(library);
        unlink(path);
        return NULL;
    }

    CFMutableDictionaryRef attributes = CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    if (attributes != NULL) {
        if (face->family_name != NULL) {
            CFStringRef family = CFStringCreateWithCString(kCFAllocatorDefault,
                    face->family_name, kCFStringEncodingUTF8);
            if (family != NULL) {
                CFDictionarySetValue(attributes, kCTFontFamilyNameAttribute, family);
                CFRelease(family);
            }
        }
        if (face->style_name != NULL) {
            CFStringRef style = CFStringCreateWithCString(kCFAllocatorDefault,
                    face->style_name, kCFStringEncodingUTF8);
            if (style != NULL) {
                CFDictionarySetValue(attributes, kCTFontStyleNameAttribute, style);
                CFRelease(style);
            }
        }
        CFStringRef filePath = CFStringCreateWithCString(kCFAllocatorDefault, path,
                kCFStringEncodingUTF8);
        if (filePath != NULL) {
            CFURLRef url = CFURLCreateWithFileSystemPath(kCFAllocatorDefault, filePath,
                    kCFURLPOSIXPathStyle, false);
            if (url != NULL) {
                CFDictionarySetValue(attributes, kCTFontURLAttribute, url);
                CFRelease(url);
            }
            CFRelease(filePath);
        }

        /* The same symbolic bits the collection reports, read from the face this time. */
        int symbolic = 0;
        if (face->style_flags & FT_STYLE_FLAG_ITALIC) symbolic |= (1 << 0);
        if (face->style_flags & FT_STYLE_FLAG_BOLD) symbolic |= (1 << 1);
        if (FT_IS_FIXED_WIDTH(face)) symbolic |= (1 << 10);
        CFMutableDictionaryRef traits = CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
                &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        if (traits != NULL) {
            CFNumberRef n = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &symbolic);
            if (n != NULL) {
                CFDictionarySetValue(traits, kCTFontSymbolicTrait, n);
                CFRelease(n);
            }
            CFDictionarySetValue(attributes, kCTFontTraitsAttribute, traits);
            CFRelease(traits);
        }
        CFDictionarySetValue(attributes, kCTFontEnabledAttribute, kCFBooleanTrue);
    }

    FT_Done_Face(face);
    FT_Done_FreeType(library);
    return (CTFontDescriptorRef) attributes;
}


const CFStringRef kCTFontManagerRegisteredFontsChangedNotification = CFSTR("CTFontManagerFontChangedNotification");

bool CTFontManagerRegisterGraphicsFont(CGFontRef font, CFErrorRef* error)
{
    printf("STUB %s\n", __PRETTY_FUNCTION__);
    return nil;
}

bool CTFontManagerUnregisterGraphicsFont(CGFontRef font, CFErrorRef *error)
{
    printf("STUB %s\n", __PRETTY_FUNCTION__);
    return nil;
}

CFArrayRef CTFontManagerCopyAvailableFontFamilyNames(void)
{
    printf("STUB %s\n", __PRETTY_FUNCTION__);
    return nil;
}

bool CTFontManagerRegisterFontsForURL(CFURLRef fontURL, CTFontManagerScope scope, CFErrorRef * error)
{
    printf("STUB %s\n", __PRETTY_FUNCTION__);
    /*
     * A FAILING FUNCTION MUST STILL HONOUR ITS OUT PARAMETER. The contract is that on failure
     * *error points to a CFError the caller owns, and callers are written for it: LibreOffice's
     * AddTempDevFont does CFRelease(error) the moment this returns false. Returning false while
     * leaving error untouched therefore handed CFRelease an uninitialised pointer, and CFRelease
     * meets that with HALT, an int3 that names nothing.
     *
     * That is a stub failing in a way the real function cannot, which is the worst kind: the
     * caller was correct and the crash landed three frames away from the cause.
     */
    if (error != NULL) {
        *error = CFErrorCreate(kCFAllocatorDefault, kCFErrorDomainCocoa, -1, NULL);
    }
    return false;
}
