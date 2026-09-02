#import <CoreText/CTFontManager.h>
#import <CoreText/CTFontDescriptor.h>
#import <CoreText/CTFontTraits.h>
#import <CoreFoundation/CoreFoundation.h>
#import <fontconfig/fontconfig.h>

extern int _O2FontAppFontGeneration;
#import <ft2build.h>
#import FT_FREETYPE_H
#import <limits.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <sys/stat.h>
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

/*
 * A PATH HANDED TO A NATIVE LIBRARY MUST BE A HOST PATH.
 *
 * libfontconfig is /usr/lib/native/libfontconfig.dylib, the ELF bridge, so its open() is an ordinary
 * Linux one with no vchroot in front of it. A guest stat() of the same name succeeds while
 * fontconfig gets ENOENT, because the host has no /Applications: every registration of a bundled
 * font failed on a file the host's own fc-query parses.
 *
 * __darling_vchroot_expand is the translation the emulation already uses, and hdiutil hands host
 * paths to a host tool the same way.
 */
extern int __darling_vchroot_expand(const char *path, char *out);

static void CTFontManagerHostPath(const char *path, char *out, size_t outSize)
{
    char expanded[4096];
    if (__darling_vchroot_expand(path, expanded) >= 0 && expanded[0] != '\0') {
        strlcpy(out, expanded, outSize);
    } else {
        strlcpy(out, path, outSize);
    }
}

/*
 * A FAILING FUNCTION MUST STILL HONOUR ITS OUT PARAMETER. Callers are written for the contract:
 * LibreOffice's AddTempDevFont does CFRelease(error) the moment this returns false, so leaving
 * *error untouched handed CFRelease an uninitialised pointer and it answered with HALT.
 */
static bool CTFontManagerFail(CFErrorRef *error, CFIndex code, const char *reason)
{
    if (reason != NULL && getenv("CIDER_TRACE_FONT") != NULL) {
        printf("CIDER_FONT register=FAILED reason=%s\n", reason);
    }
    if (error != NULL) {
        *error = CFErrorCreate(kCFAllocatorDefault, kCFErrorDomainCocoa, code, NULL);
    }
    return false;
}

/*
 * The config must be the CURRENT one, which is what Onyx2D renders from (O2FontSharedFontConfig).
 *
 * Failing here is worse than most stubs: fontconfig never fails a lookup, it SUBSTITUTES, so an
 * application whose own typefaces were refused still draws its text, in a face it never asked for
 * and did not lay out against.
 */
bool CTFontManagerRegisterFontsForURL(CFURLRef fontURL, CTFontManagerScope scope, CFErrorRef * error)
{
    char path[PATH_MAX];

    if (fontURL == NULL) return CTFontManagerFail(error, -1, "no url");
    if (!CFURLGetFileSystemRepresentation(fontURL, true, (UInt8 *) path, sizeof(path))) {
        return CTFontManagerFail(error, -1, "url is not a file path");
    }

    struct stat info;
    bool isDirectory = stat(path, &info) == 0 && S_ISDIR(info.st_mode);

    char hostPath[4096];
    CTFontManagerHostPath(path, hostPath, sizeof(hostPath));

    FcConfig *config = FcConfigGetCurrent();
    FcBool added = isDirectory
            ? FcConfigAppFontAddDir(config, (const FcChar8 *) hostPath)
            : FcConfigAppFontAddFile(config, (const FcChar8 *) hostPath);

    /* AppKit builds its family list once; this tells it that the list is now out of date. */
    if (added)
        _O2FontAppFontGeneration++;

    if (getenv("CIDER_TRACE_FONT") != NULL) {
        printf("CIDER_FONT register=%s guest=%s host=%s\n", added ? "ok" : "FAILED", path, hostPath);
    }
    if (!added) return CTFontManagerFail(error, -1, NULL);
    return true;
}
