#import <Onyx2D/O2Font_freetype.h>
#import <pthread.h>
#include <pthread.h>
#include <stdlib.h>
#ifdef FREETYPE_PRESENT
#import <Onyx2D/O2Encoding.h>

@implementation O2Font_freetype

#ifdef DARLING

O2FontRef O2FontCreateWithFontName_platform(NSString *name) {
    return [[O2Font_freetype alloc] initWithFontName: name];
}

O2FontRef O2FontCreateWithDataProvider_platform(O2DataProviderRef provider) {
    return [[O2Font_freetype alloc] initWithDataProvider: provider];
}

#endif


/*
 * ONE GUEST THREAD AT A TIME IN THE HOST FONT LIBRARIES, and a SPINLOCK rather than a mutex.
 *
 * Swift Publisher lays text out on the main thread while an operation queue builds document
 * previews, and both of them arrive here. fontconfig and FreeType are host code reached through
 * elfcalls, and they allocate on the HOST heap, so two guest threads inside them at once corrupt
 * it: every run ended in glibc reporting malloc(): unaligned tcache chunk detected, from
 * +[O2Font_freetype filenameForPattern:] on the preview worker.
 *
 * It cannot be a pthread mutex. A CONTENDED one fails in this guest with psynch_mutexwait
 * failed internally: -111 and aborts, which is the whole reason an earlier attempt at locking
 * this was taken back out. A compare and swap spin never enters the kernel, so it has nothing to
 * fail: the cost is a busy wait, bounded by how long one font match takes.
 */
static volatile int _CiderHostFontSpin = 0;

/*
 * AND IT HAS TO BE RECURSIVE, which the first version was not, and that cost a hang.
 *
 * The glyph run holds this lock while it works through face->glyph, and code under it can ask for a
 * font again: a fallback for a missing glyph goes through +filenameForPattern:, which takes the
 * same lock. A plain spin then waits for a lock its own thread is already holding, forever, with no
 * message of any kind. MoneyMoney showed it as a process that printed main nib load enter and
 * stopped there, having reached the window in every run the day before.
 *
 * The owner is recorded and re-entry counted, so the same thread passes straight through and only
 * the outermost release opens it.
 */
static volatile uintptr_t _CiderHostFontOwner = 0;
static volatile int _CiderHostFontDepth = 0;

void O2FontHostLock(void) {
    uintptr_t me = (uintptr_t) pthread_self();
    int spun = 0;

    if (_CiderHostFontOwner == me) {
        _CiderHostFontDepth++;
        return;
    }

    while (__sync_val_compare_and_swap(&_CiderHostFontSpin, 0, 1) != 0) {
        spun = 1;
#if defined(__x86_64__) || defined(__i386__)
        __builtin_ia32_pause();
#else
        __asm__ __volatile__("yield");
#endif
    }

    _CiderHostFontOwner = me;
    _CiderHostFontDepth = 1;

    /* DOES THIS EVER ACTUALLY CONTEND. The lock was added on the theory that two guest threads meet
     * inside the host font libraries, and the theory is worth no more than the measurement: if this
     * line never prints, no two threads were ever in here at once and the corruption comes from
     * somewhere else entirely. Printed once. */
    if (spun) {
        static int reported = 0;

        if (__sync_val_compare_and_swap(&reported, 0, 1) == 0) {
            fprintf(stderr, "CIDER_FONT host font region CONTENDED, two guest threads met in it\n");
            fflush(stderr);
        }
    }
}

void O2FontHostUnlock(void) {
    if (_CiderHostFontDepth > 1) {
        _CiderHostFontDepth--;
        return;
    }

    _CiderHostFontDepth = 0;
    _CiderHostFontOwner = 0;
    __sync_lock_release(&_CiderHostFontSpin);
}

FT_Library O2FontSharedFreeTypeLibrary() {
    static FT_Library library = NULL;

    if (library == NULL) {
        if (FT_Init_FreeType(&library) != 0) {
            NSLog(@"FT_Init_FreeType failed");
        }
    }

    return library;
}

/*
 * fontconfig is the ELF bridge library, so it opens HOST paths and a bundle path means nothing to
 * it. Same translation, and the same reason, as CTFontManagerRegisterFontsForURL.
 */
extern int __darling_vchroot_expand(const char *path, char *out);

/*
 * HOW MANY TIMES AN APPLICATION FONT HAS BEEN ADDED.
 *
 * AppKit builds its font family list ONCE and keeps it in a static, so a font registered after that
 * moment does not exist as far as any family lookup is concerned. iA Writer registers 19 of its own
 * and then asks for one by descriptor: the descriptor matched nothing, fontWithDescriptor: answered
 * nil, and the nil went into a typing-attributes dictionary as NSFontAttributeName, which raised.
 *
 * The counter is the seam: this layer cannot call AppKit, and AppKit can ask whether anything has
 * changed since it last built.
 */
int _O2FontAppFontGeneration = 0;

int O2FontAppFontGeneration(void) {
    return _O2FontAppFontGeneration;
}

static void addAppFont(FcConfig *config, NSString *path) {
    path = [[NSBundle mainBundle] pathForResource: path ofType: nil];
    if (path == nil) {
        NSLog(@"Cannot find font %@ in resources", path);
        return;
    }
    BOOL isDirectory;
    [[NSFileManager defaultManager] fileExistsAtPath: path
                                         isDirectory: &isDirectory];

    char host[4096];
    const char *guest = [path UTF8String];
    if (__darling_vchroot_expand(guest, host) < 0 || host[0] == '\0') {
        strlcpy(host, guest, sizeof(host));
    }

    if (isDirectory) {
        FcConfigAppFontAddDir(config, (const FcChar8 *) host);
    _O2FontAppFontGeneration++;
    } else {
        FcConfigAppFontAddFile(config, (const FcChar8 *) host);
    }
}

/*
 * ONE FONTCONFIG CONFIG FOR THE PROCESS, and it must be the CURRENT one.
 *
 * FcInitLoadConfigAndFonts builds a PRIVATE config, so fonts looked up here were invisible to
 * CoreText, which passes NULL and means the default. An application that registers its own faces at
 * startup had them accepted and then rendered with something else.
 *
 * The returned config is owned by fontconfig, so it is never destroyed here.
 */
FcConfig *O2FontSharedFontConfig() {
    static FcConfig *fontConfig = NULL;

    if (fontConfig == NULL) {
        fontConfig = FcConfigGetCurrent();

        id appFontsPath = [[NSBundle mainBundle]
                objectForInfoDictionaryKey: @"ATSApplicationFontsPath"];
        if ([appFontsPath isKindOfClass: [NSString class]]) {
            addAppFont(fontConfig, appFontsPath);
        } else if ([appFontsPath isKindOfClass: [NSArray class]]) {
            for (NSString *path in appFontsPath) {
                addAppFont(fontConfig, path);
            }
        }
    }

    return fontConfig;
}

/*
 * THE APPLE USER INTERFACE FONTS, WHICH ARE NOT HERE AND MUST NOT BECOME DEJAVU.
 *
 * AppKit asks for San Francisco, and applications ask for Helvetica Neue and Lucida Grande. None of
 * them can be shipped: they are Apple fonts. Fontconfig never fails, it SUBSTITUTES, and its answer
 * for an unknown sans family on this system is DejaVu Sans -- a wide, large eyed face that is the
 * single most obvious reason the interface does not look like macOS. Measured, not guessed:
 *
 *     CIDER_FONT pattern=San Francisco file=.../dejavu-fonts-2.37/.../DejaVuSans.ttf
 *
 * INTER FIRST, ADDED 2026-08-15. Inter is the closest open source face to San Francisco: same
 * humanist skeleton, same tall x height, the same slightly narrow proportions. TeX Gyre Heros is a
 * clone of HELVETICA, which is the face Apple REPLACED with San Francisco in 2015, so it is a
 * decade out of date even when it renders perfectly. Inter is not installed everywhere, and that is
 * fine: this is a fontconfig family list, the first one PRESENT wins, and everything behind it is
 * exactly what was chosen before.
 *
 * TeX Gyre Heros is a Helvetica clone and is the closest thing available after Inter, with
 * Liberation Sans (Arial metrics) behind it and Helvetica itself in case a real one is installed.
 * The list is a fontconfig family list, so the first one present wins and the styles still resolve:
 * a request for :style=Bold picks the bold face of whichever family answered.
 */
static NSString *_CiderPreferredFamilies(NSString *family)
{
    static NSDictionary *map = nil;

    if (map == nil) {
        map = [[NSDictionary alloc]
                initWithObjectsAndKeys:
                        @"Inter,Helvetica,TeX Gyre Heros,Liberation Sans,sans-serif", @"san francisco",
                        @"Inter,Helvetica,TeX Gyre Heros,Liberation Sans,sans-serif", @".applesystemuifont",
                        @"Inter,Helvetica,TeX Gyre Heros,Liberation Sans,sans-serif", @"sf pro",
                        @"Inter,Helvetica,TeX Gyre Heros,Liberation Sans,sans-serif", @"sf pro text",
                        @"Inter,Helvetica,TeX Gyre Heros,Liberation Sans,sans-serif", @"sf pro display",
                        @"Inter,Helvetica,TeX Gyre Heros,Liberation Sans,sans-serif", @"helvetica neue",
                        @"Inter,Helvetica,TeX Gyre Heros,Liberation Sans,sans-serif", @"lucida grande",
                        /*
                         * THE MONOSPACED APPLE FACES, none of which exist on a Linux box and none
                         * of which fontconfig has an alias for: asking for Menlo or Monaco returned
                         * DejaVu SANS, a proportional face, and a terminal laid out in it is not a
                         * terminal. Measured with fc-match on this machine before the list was
                         * written. The generic monospace is last so the list still answers on a
                         * system that has none of the named ones.
                         */
                        @"DejaVu Sans Mono,Liberation Mono,Noto Sans Mono,monospace", @"menlo",
                        @"DejaVu Sans Mono,Liberation Mono,Noto Sans Mono,monospace", @"monaco",
                        @"DejaVu Sans Mono,Liberation Mono,Noto Sans Mono,monospace", @"sf mono",
                        @"DejaVu Sans Mono,Liberation Mono,Noto Sans Mono,monospace", @"andale mono",
                        @"DejaVu Sans Mono,Liberation Mono,Noto Sans Mono,monospace", @"consolas",
                        @"Liberation Mono,DejaVu Sans Mono,Noto Sans Mono,monospace", @"courier",
                        @"Liberation Mono,DejaVu Sans Mono,Noto Sans Mono,monospace", @"courier new",
                        nil];
    }
    return [map objectForKey: [family lowercaseString]];
}

+ (NSString *) filenameForPattern: (NSString *) pattern {
    /*
     * MEMOISED, because this is a pure function of the pattern and the shared configuration, and it
     * is not cheap: a fontconfig match walks the whole font set comparing every property of every
     * candidate. Nothing above it caches, so a font asked for by name is matched again on every
     * single creation.
     *
     * Measured with perf on a live LibreOffice, resolving the guest stacks through the image list:
     * FcFontMatch reached from here was 28 percent of ALL samples, more than the rasteriser, the
     * font renderer and the application put together. The shared config is built once and never
     * mutated afterwards, so the answer cannot change under the cache.
     *
     * A MISS IS CACHED TOO, as an empty string. A name that resolves to nothing is exactly the case
     * that goes on to ask again with a different pattern, and not caching it means the expensive
     * question is repeated for every miss.
     */
    static NSMutableDictionary *cache = nil;
    static pthread_mutex_t cacheLock = PTHREAD_MUTEX_INITIALIZER;
    NSString *key = (pattern != nil) ? pattern : @"";

    pthread_mutex_lock(&cacheLock);
    NSString *hit = [[cache objectForKey: key] retain];
    pthread_mutex_unlock(&cacheLock);
    if (hit != nil) {
        return [[hit autorelease] length] != 0 ? hit : nil;
    }

    FcConfig *config = O2FontSharedFontConfig();

    /* The family is everything before the first colon in a fontconfig pattern. Only that part is
     * rewritten, so a style, a weight or a size the caller asked for survives untouched. */
    NSString *resolved = pattern;
    NSRange colon = [pattern rangeOfString: @":"];
    NSString *family = (colon.location == NSNotFound) ? pattern
                                                      : [pattern substringToIndex: colon.location];
    NSString *preferred = _CiderPreferredFamilies(family);

    if (preferred != nil) {
        resolved = (colon.location == NSNotFound)
                ? preferred
                : [preferred stringByAppendingString: [pattern substringFromIndex: colon.location]];
    }

    O2FontHostLock();
    FcPattern *pat = FcNameParse((unsigned char *) [resolved UTF8String]);

    /*
     * SCALABLE ONLY, and this is not a preference. A bitmap X11 font can win a match, and one did:
     * fifty two faces in a single iTerm2 start came back family=Fixed style=Regular glyphs=224,
     * which has one size, no outline to scale, and 224 glyphs. Everything above this draws by
     * scaling an outline to a point size, so a face without one renders as nothing at all.
     */
    FcPatternAddBool(pat, FC_SCALABLE, FcTrue);

    /*
     * A PATTERN THAT ALREADY NAMES ITS FILE NEEDS NO MATCH AT ALL.
     *
     * The typeface names this system hands to AppKit are fontconfig patterns produced by
     * FcNameUnparse during enumeration, and they now carry the file the font came from. Asking
     * fontconfig to find that file again means walking the entire font set and comparing every
     * property of every candidate, which is exactly the work that made FcFontMatch 29.69 percent of
     * a text to PDF conversion. Reading it out of the pattern is a hash lookup.
     *
     * The memo above stays: a pattern WITHOUT a file, which is what an application asking for a
     * font by name produces, still has to be matched, and matching it twice is still waste.
     */
    FcChar8 *known = NULL;
    if (FcPatternGetString(pat, FC_FILE, 0, &known) == FcResultMatch && known != NULL) {
        NSString *direct = [NSString stringWithUTF8String: (char *) known];

        FcPatternDestroy(pat);
        O2FontHostUnlock();
        pthread_mutex_lock(&cacheLock);
        if (cache == nil) {
            cache = [[NSMutableDictionary alloc] init];
        }
        [cache setObject: (direct != nil) ? direct : @"" forKey: key];
        pthread_mutex_unlock(&cacheLock);
        return direct;
    }

    FcConfigSubstitute(config, pat, FcMatchPattern);
    FcDefaultSubstitute(pat);

    FcResult fcResult;
    FcPattern *match = FcFontMatch(config, pat, &fcResult);
    FcPatternDestroy(pat);
    if (match == NULL) {
        O2FontHostUnlock();
        return nil;
    }

    FcChar8 *filename = NULL;
    FcPatternGetString(match, FC_FILE, 0, &filename);

    NSString *res = nil;
    if (filename != NULL) {
        res = [NSString stringWithUTF8String: (char *) filename];
    }

    /* WHICH FILE A NAME ACTUALLY BECAME. A user interface that looks foreign usually resolved its
     * font to something else entirely, and nothing here said so: the match always succeeds, because
     * fontconfig substitutes rather than failing. Set CIDER_TRACE_FONTS to see every distinct
     * answer once. */
    if (getenv("CIDER_TRACE_FONTS") != NULL) {
        NSLog(@"CIDER_FONT pattern=%@ asked=%@ file=%@", resolved, pattern, res);
    }

    FcPatternDestroy(match);
    O2FontHostUnlock();

    pthread_mutex_lock(&cacheLock);
    if (cache == nil) {
        cache = [[NSMutableDictionary alloc] init];
    }
    [cache setObject: (res != nil) ? res : @"" forKey: key];
    pthread_mutex_unlock(&cacheLock);
    return res;
}

- (instancetype) initWithDataProvider: (O2DataProviderRef) provider {
    self = [super initWithDataProvider: provider];
    if (self == nil) {
        return nil;
    }

    const void *bytes = [provider bytes];
    size_t length = [provider length];

    FT_Face face;
    O2FontHostLock();
    int error = FT_New_Memory_Face(O2FontSharedFreeTypeLibrary(), bytes, length,
                                   0, &face);
    O2FontHostUnlock();

    if (error != 0) {
        NSLog(@"FT_New_Memory_Face() = %d", error);
        [self release];
        return nil;
    }

    return [self initWithFace: face];
}

- (instancetype) initWithFontName: (NSString *) name {
    self = [super initWithFontName: name];

    NSString *filename = [[self class] filenameForPattern: name];
    if (filename == nil) {
        filename = [[self class] filenameForPattern: @""];
    }
    if (filename == nil) {
        NSLog(@"No font found for name %@", name);
        [self release];
        return nil;
    }

    FT_Face face;
    O2FontHostLock();
    FT_Error error = FT_New_Face(O2FontSharedFreeTypeLibrary(),
                                 [filename fileSystemRepresentation], 0, &face);
    O2FontHostUnlock();

    if (error != 0) {
        NSLog(@"FT_New_Face() = %d", error);
        [self release];
        return nil;
    }

    return [self initWithFace: face];
}

- (instancetype) initWithFace: (FT_Face) face {
    _face = face;
    _platformType = O2FontPlatformTypeFreeType;

    int i, numberOfCharMaps = face->num_charmaps;
    BOOL hasUnicode = FALSE;
    BOOL hasMacRoman = FALSE;

    for (i = 0; i < numberOfCharMaps; i++) {

        if (face->charmaps[i]->encoding == FT_ENCODING_UNICODE) {
            hasUnicode = TRUE;
        }
        if (face->charmaps[i]->encoding == FT_ENCODING_APPLE_ROMAN) {
            hasMacRoman = TRUE;
        }
    }
    if (hasUnicode) {
        _ftEncoding = FT_ENCODING_UNICODE;
    } else if (hasMacRoman) {
        _ftEncoding = FT_ENCODING_APPLE_ROMAN;
    } else {
        NSLog(@"encoding = %c %c %c %c", face->charmaps[0]->encoding >> 24,
              face->charmaps[0]->encoding >> 16,
              face->charmaps[0]->encoding >> 8, face->charmaps[0]->encoding);
        _ftEncoding = face->charmaps[0]->encoding;
    }

    if (FT_Select_Charmap(face, _ftEncoding) != 0) {
        NSLog(@"FT_Select_Charmap(%d) failed", _ftEncoding);
    }

    if (!(face->face_flags & FT_FACE_FLAG_SCALABLE)) {
        /* WHICH FACE, because the message alone cannot be acted on: fifty two of these in one
         * iTerm2 start and no way to tell whether it was one font asked for fifty two times or
         * fifty two different ones. The family and style are what fontconfig matched on. */
        NSLog(@"FreeType font face is not scalable: family=%s style=%s glyphs=%ld",
              (face->family_name != NULL) ? face->family_name : "(none)",
              (face->style_name != NULL) ? face->style_name : "(none)",
              (long) face->num_glyphs);
    }

    _unitsPerEm = (O2Float) face->units_per_EM;
    _ascent = face->ascender;
    _descent = face->descender;
    _leading = 0;
    _capHeight = face->height;
    _xHeight = face->height;
    _italicAngle = 0;
    _stemV = 0;
    _bbox.origin.x = face->bbox.xMin;
    _bbox.origin.y = face->bbox.yMin;
    _bbox.size.width = face->bbox.xMax - face->bbox.xMin;
    _bbox.size.height = face->bbox.yMax - face->bbox.yMin;
    _numberOfGlyphs = face->num_glyphs;
    _advances = NULL;
    return self;
}

- (void) dealloc {
    FT_Done_Face(_face);
    [_macRomanEncoding release];
    [_macExpertEncoding release];
    [_winAnsiEncoding release];
    [super dealloc];
}

- (FT_Face) face {
    return _face;
}

FT_Face O2FontFreeTypeFace(O2Font_freetype *self) {
    return self->_face;
}

- (void) fetchAdvances {
    FT_Set_Char_Size(_face, 0, _unitsPerEm * 64, 72, 72);

    _advances = NSZoneMalloc(NULL, sizeof(NSInteger) * _numberOfGlyphs);

    for (O2Glyph glyph = 0; glyph < _numberOfGlyphs; glyph++) {
        FT_Load_Glyph(_face, glyph, FT_LOAD_DEFAULT);

        _advances[glyph] = _face->glyph->advance.x / (O2Float)(2 << 5);
    }
}

- (O2Glyph) glyphWithGlyphName: (NSString *) name {
    return FT_Get_Name_Index(_face, (char *) [name cString]);
}

- (NSString *) copyGlyphNameForGlyph: (O2Glyph) glyph {
    unsigned char buffer[100];
    if (FT_Get_Glyph_Name(_face, glyph, buffer, sizeof(buffer)) != 0) {
        return nil;
    }
    return [[NSString alloc] initWithUTF8String: (const char *) buffer];
}

- (void) getGlyphs: (O2Glyph *) glyphs
        forCodePoints: (uint16_t *) codes
               length: (NSInteger) length
{
    for (int i = 0; i < length; i++) {
        glyphs[i] = FT_Get_Char_Index(_face, codes[i]);
    }
}

- (O2Encoding *) unicode_createEncodingForTextEncoding:
        (O2TextEncoding) encoding
{
    unichar unicode[256];
    O2Glyph glyphs[256];

    switch (encoding) {
    case kO2EncodingFontSpecific:
    case kO2EncodingMacRoman:
        if (_macRomanEncoding == nil) {
            O2EncodingGetMacRomanUnicode(unicode);
            [self getGlyphs: glyphs forCodePoints: unicode length: 256];
            _macRomanEncoding = [[O2Encoding alloc] initWithGlyphs: glyphs
                                                           unicode: unicode];
        }
        return [_macRomanEncoding retain];

    case kO2EncodingMacExpert:
        if (_macExpertEncoding == nil) {
            O2EncodingGetMacExpertUnicode(unicode);
            [self getGlyphs: glyphs forCodePoints: unicode length: 256];
            _macExpertEncoding = [[O2Encoding alloc] initWithGlyphs: glyphs
                                                            unicode: unicode];
        }
        return [_macExpertEncoding retain];

    case kO2EncodingWinAnsi:
        if (_winAnsiEncoding == nil) {
            O2EncodingGetWinAnsiUnicode(unicode);
            [self getGlyphs: glyphs forCodePoints: unicode length: 256];
            _winAnsiEncoding = [[O2Encoding alloc] initWithGlyphs: glyphs
                                                          unicode: unicode];
        }
        return [_winAnsiEncoding retain];

    default:
        return nil;
    }
    return nil;
}

- (O2Encoding *) MacRoman_createEncodingForTextEncoding:
        (O2TextEncoding) encoding
{

    uint16_t codes[256];
    O2Glyph glyphs[256];
    unichar unicode[256];

    if (_macRomanEncoding == nil) {

        if (encoding != kO2EncodingMacRoman &&
            encoding != kO2EncodingFontSpecific) {
            NSLog(@"font encoding is MacRoman, requesting encoding %d failed",
                  encoding);
        }

        for (int i = 0; i < 256; i++) {
            codes[i] = i;
        }

        [self getGlyphs: glyphs forCodePoints: codes length: 256];

        O2EncodingGetMacExpertUnicode(unicode);

        _macRomanEncoding = [[O2Encoding alloc] initWithGlyphs: glyphs
                                                       unicode: unicode];
    }

    return [_macRomanEncoding retain];
}

- (O2Encoding *) createEncodingForTextEncoding: (O2TextEncoding) encoding {
    if (_ftEncoding == FT_ENCODING_APPLE_ROMAN) {
        return [self MacRoman_createEncodingForTextEncoding: encoding];
    }

    return [self unicode_createEncodingForTextEncoding: encoding];
}

@end
#endif
