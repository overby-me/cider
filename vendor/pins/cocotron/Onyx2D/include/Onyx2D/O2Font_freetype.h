#import <Onyx2D/O2Defines_FreeType.h>
#import <Onyx2D/O2Font.h>

#ifdef FREETYPE_PRESENT

#ifdef DARLING
#define __linux__
#endif

#import <ft2build.h>
#import FT_FREETYPE_H
#import FT_RENDER_H

#import <fontconfig/fontconfig.h>

#ifdef DARLING
#undef __linux__
#endif

@interface O2Font_freetype : O2Font {
    FT_Face _face;
    FT_Encoding _ftEncoding;
    O2Encoding *_macRomanEncoding;
    O2Encoding *_macExpertEncoding;
    O2Encoding *_winAnsiEncoding;
}

- (instancetype) initWithFace: (FT_Face) face;
- (instancetype) initWithDataProvider: (O2DataProviderRef) provider;

- (FT_Face) face;

FT_Face O2FontFreeTypeFace(O2Font_freetype *self);

FT_Library O2FontSharedFreeTypeLibrary();
FcConfig *O2FontSharedFontConfig();

@end

#endif

/* THE HOST FONT LIBRARIES TAKE ONE GUEST THREAD AT A TIME. fontconfig and FreeType are host code
 * reached through elfcalls and they allocate on the host heap; two guest threads inside them at
 * once corrupt it. Declared here because the glyph paths that also need it live in CoreText.
 * A spin, not a mutex: a contended pthread mutex fails in this guest with psynch -111. */
void O2FontHostLock(void);
void O2FontHostUnlock(void);
