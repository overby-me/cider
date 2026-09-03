/* Copyright (c) 2008 Christopher J. W. Lloyd

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE. */

#import <CoreText/CTFont.h>
#import <CoreText/CoreText.h>
#import <CoreText/KTFont.h>
#import <Foundation/NSString.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <execinfo.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Defined below, and declared here because the advances function above it is a caller. Answers
 * whether the receiver reads or writes glyphs as NSGlyph rather than CGGlyph. */
static bool cider_glyph_arg_is_wide(id object, SEL selector, unsigned int index);

/* Defined in constants.c and declared in no header, the same as in CTFontCollection.m. */
extern const CFStringRef kCTFontSymbolicTrait;

const CFStringRef kCTFontCopyrightNameKey = CFSTR("CTFontCopyrightName");
const CFStringRef kCTFontFamilyNameKey = CFSTR("CTFontFamilyName");
const CFStringRef kCTFontSubFamilyNameKey = CFSTR("CTFontSubFamilyName");
const CFStringRef kCTFontStyleNameKey = CFSTR("CTFontSubFamilyName");
const CFStringRef kCTFontUniqueNameKey = CFSTR("CTFontUniqueName");
const CFStringRef kCTFontFullNameKey = CFSTR("CTFontFullName");
const CFStringRef kCTFontVersionNameKey = CFSTR("CTFontVersionName");
const CFStringRef kCTFontPostScriptNameKey = CFSTR("CTFontPostScriptName");
const CFStringRef kCTFontTrademarkNameKey = CFSTR("CTFontTrademarkName");
const CFStringRef kCTFontManufacturerNameKey = CFSTR("CTFontManufacturerName");
const CFStringRef kCTFontDesignerNameKey = CFSTR("CTFontDesignerName");
const CFStringRef kCTFontDescriptionNameKey = CFSTR("CTFontDescriptionName");
const CFStringRef kCTFontVendorURLNameKey = CFSTR("CTFontVendorURLName");
const CFStringRef kCTFontDesignerURLNameKey = CFSTR("CTFontDesignerURLName");
const CFStringRef kCTFontLicenseNameKey = CFSTR("CTFontLicenseNameName");
const CFStringRef kCTFontLicenseURLNameKey = CFSTR("CTFontLicenseURLName");
const CFStringRef kCTFontSampleTextNameKey = CFSTR("CTFontSampleTextName");
const CFStringRef kCTFontPostScriptCIDNameKey = CFSTR("CTFontPostScriptCIDName");

const CFStringRef kCTFontVariationAxisIdentifierKey = CFSTR("NSCTVariationAxisIdentifier");
const CFStringRef kCTFontVariationAxisMinimumValueKey = CFSTR("NSCTVariationAxisMinimumValue");
const CFStringRef kCTFontVariationAxisMaximumValueKey = CFSTR("NSCTVariationAxisMaximumValue");
const CFStringRef kCTFontVariationAxisDefaultValueKey = CFSTR("NSCTVariationAxisDefaultValue");
const CFStringRef kCTFontVariationAxisNameKey = CFSTR("NSCTVariationAxisName");
const CFStringRef kCTFontVariationAxisHiddenKey = CFSTR("NSCTVariationAxisHidden");

const CFStringRef kCTFontFeatureTypeIdentifierKey = CFSTR("CTFeatureTypeIdentifier");
const CFStringRef kCTFontFeatureTypeNameKey = CFSTR("CTFeatureTypeName");
const CFStringRef kCTFontFeatureTypeExclusiveKey = CFSTR("CTFeatureTypeExclusive");
const CFStringRef kCTFontFeatureTypeSelectorsKey = CFSTR("CTFeatureTypeSelectors");
const CFStringRef kCTFontFeatureSelectorIdentifierKey = CFSTR("CTFeatureSelectorIdentifier");
const CFStringRef kCTFontFeatureSelectorNameKey = CFSTR("CTFeatureSelectorName");
const CFStringRef kCTFontFeatureSelectorDefaultKey = CFSTR("CTFeatureSelectorDefault");
const CFStringRef kCTFontFeatureSelectorSettingKey = CFSTR("CTFeatureSelectorSetting");
const CFStringRef kCTFontFeatureSampleTextKey = CFSTR("CTFeatureSampleText");
const CFStringRef kCTFontFeatureTooltipTextKey = CFSTR("CTFeatureTooltipText");

/*
 * A CTFontRef here IS a KTFont, which is why CTFontGetSize can send it -pointSize and
 * CTFontGetGlyphsForCharacters can send it -getGlyphs:forCharacters:length:. Those already work;
 * what was missing was any way to MAKE one, so every caller that started from a name or a
 * descriptor got nil and the working half was unreachable.
 *
 * CTFontCreateWithGraphicsFont below has done it correctly all along. These two do the same
 * thing, with the O2 font looked up by family name first.
 */
/* Declared here because Onyx2D's header is not on this file's include path, and its parameter is
 * spelled NSString * upstream while the return is O2FontRef, and CGFontRef is the same type
 * under another name. Both spellings matter: an implicit declaration returns int, which is what
 * the compiler assumed the first time and which truncated the pointer. */
extern CGFontRef O2FontCreateWithFontName(CFStringRef name);

static CTFontRef _CiderFontCreateForFamily(CFStringRef family, CGFloat size)
{
    if (family == NULL) return NULL;
    /* Zero means "the default size" in this API, and a KTFont built at 0 would divide its
     * metrics by nothing later. 12 is the Cocoa default. */
    if (size <= 0.0) size = 12.0;
    CGFontRef cgFont = O2FontCreateWithFontName(family);
    if (cgFont == NULL) {
        /* SAY SO. A creator that answers nil is indistinguishable from one that was never
         * called, and that ambiguity is what made the stub version so slow to diagnose. */
        static int reported = 0;
        if (reported < 8) {
            char name[128];
            if (CFStringGetCString(family, name, sizeof(name), kCFStringEncodingUTF8)) {
                fprintf(stderr, "CoreText: no O2Font for family %s\n", name);
            }
            reported++;
        }
        return NULL;
    }
    CTFontRef font = (CTFontRef)[[KTFont alloc] initWithFont: cgFont size: size];
    CGFontRelease(cgFont);
    return font;
}

CTFontRef CTFontCreateWithName(CFStringRef name, CGFloat size, const CGAffineTransform *matrix)
{
    return _CiderFontCreateForFamily(name, size);
}

CTFontRef CTFontCreateWithNameAndOptions(CFStringRef name, CGFloat size,
                                         const CGAffineTransform *matrix,
                                         CTFontOptions options)
{
    /* The options select where the font may be looked up, and there is one place here. */
    return _CiderFontCreateForFamily(name, size);
}

/*
 * THE STYLE THE DESCRIPTOR ASKED FOR, which was being dropped on the floor.
 *
 * A name here is not a name, it is a FONTCONFIG PATTERN: O2Font_freetype hands the string straight
 * to FcNameParse, so "Liberation Serif:style=Bold" selects the bold face of that family. Everything
 * above this passed the bare family and nothing else, so a bold run and a regular run resolved to
 * the same file and bold text rendered in the regular weight -- with LibreOffice perfectly happy,
 * because it had applied the format and the B in its toolbar was lit.
 *
 * Returns a copy the caller frees, or NULL when there is nothing to add.
 */
static CFStringRef _CiderPatternForFamilyWithTraits(CFStringRef family, unsigned symbolic)
{
    const int italic = (symbolic & (1 << 0)) != 0;
    const int bold = (symbolic & (1 << 1)) != 0;

    if (family == NULL || (!bold && !italic)) return NULL;

    CFStringRef style = NULL;
    if (bold && italic) {
        style = CFSTR("Bold Italic");
    } else if (bold) {
        style = CFSTR("Bold");
    } else {
        style = CFSTR("Italic");
    }
    return CFStringCreateWithFormat(kCFAllocatorDefault, NULL, CFSTR("%@:style=%@"), family, style);
}

/* The symbolic traits a descriptor carries, or zero. */
static unsigned _CiderSymbolicTraitsOfDescriptor(CTFontDescriptorRef descriptor)
{
    CFDictionaryRef traits =
            (CFDictionaryRef) CTFontDescriptorCopyAttribute(descriptor, kCTFontTraitsAttribute);
    if (traits == NULL) return 0;

    unsigned symbolic = 0;
    if (CFGetTypeID(traits) == CFDictionaryGetTypeID()) {
        CFNumberRef n = (CFNumberRef) CFDictionaryGetValue(traits, kCTFontSymbolicTrait);
        if (n != NULL && CFGetTypeID(n) == CFNumberGetTypeID()) {
            int value = 0;
            CFNumberGetValue(n, kCFNumberIntType, &value);
            symbolic = (unsigned) value;
        }
    }
    CFRelease(traits);
    return symbolic;
}

CTFontRef CTFontCreateWithFontDescriptor(CTFontDescriptorRef descriptor, CGFloat size,
                                         const CGAffineTransform *matrix)
{
    /* The descriptor is the attribute dictionary CTFontCollection built, so the family name is a
     * lookup away. Copy, because the name says Copy and this owns the result. */
    CFStringRef family = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute);
    CTFontRef font = NULL;

    /*
     * A DESCRIPTOR MAY NAME A FACE INSTEAD OF A FAMILY, and only the family was ever read here.
     *
     * iA Writer asks for its own iAWriterMono-Regular with a descriptor carrying nothing but
     * NSFontNameAttribute, so family was NULL, both lookups below failed, and the NULL came back as
     * a nil NSFont that the application put into a typing-attributes dictionary. The raise was
     * "Tried to init dictionary with nil object", four layers away from anything about fonts.
     *
     * The PostScript name is what CTFontCreateWithName takes, so ask for it first and keep the
     * family as the fallback, which is the order +[NSFont fontWithDescriptor:size:] already uses.
     */
    {
        CFStringRef name = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute);

        if (name != NULL) {
            font = _CiderFontCreateForFamily(name, size);
            CFRelease(name);
        }
    }

    /* STYLE FIRST, FAMILY AS THE FALLBACK. A family with no bold face on disk must still produce a
     * font rather than nothing, and fontconfig would happily substitute a DIFFERENT family for the
     * style, which is worse than the regular weight of the right one. */
    CFStringRef pattern = font != NULL ? NULL :
            _CiderPatternForFamilyWithTraits(family, _CiderSymbolicTraitsOfDescriptor(descriptor));
    if (pattern != NULL) {
        font = _CiderFontCreateForFamily(pattern, size);
        CFRelease(pattern);
    }
    if (font == NULL) {
        font = _CiderFontCreateForFamily(family, size);
    }
    /* WHAT WAS ASKED FOR WHEN NOTHING CAME BACK. A descriptor may name a FACE rather than a family,
     * and this only ever looks the family up, so the answer is NULL and the caller has a nil font
     * that raises somewhere else entirely: iA Writer put one into a typing-attributes dictionary as
     * NSFontAttributeName. */
    if (font == NULL && getenv("CIDER_TRACE_FONT") != NULL) {
        CFStringRef described = CFCopyDescription(descriptor);
        char buffer[1024];

        if (described != NULL &&
            CFStringGetCString(described, buffer, sizeof(buffer), kCFStringEncodingUTF8))
            fprintf(stderr, "CIDER_FONT ctfont=NULL descriptor=%s\n", buffer);
        else
            fprintf(stderr, "CIDER_FONT ctfont=NULL descriptor=?\n");
        if (described != NULL) CFRelease(described);
        fflush(stderr);
    }

    if (family != NULL) CFRelease(family);
    return font;
}

CTFontRef CTFontCreateWithFontDescriptorAndOptions(CTFontDescriptorRef descriptor, CGFloat size,
                                                   const CGAffineTransform *matrix,
                                                   CTFontOptions options)
{
    return CTFontCreateWithFontDescriptor(descriptor, size, matrix);
}

CTFontRef CTFontCreateUIFontForLanguage(CTFontUIFontType uiFontType,
                                        CGFloat size, CFStringRef language)
{
    return (CTFontRef)[[KTFont alloc] initWithUIFontType: uiFontType
                                         size: size
                                     language: (NSString*)language];
}

CTFontRef CTFontCreateCopyWithAttributes(CTFontRef font, CGFloat size,
                                         const CGAffineTransform *matrix,
                                         CTFontDescriptorRef attributes)
{
    /* The same font at another size, or another font named by the descriptor. Size 0 means
     * "keep the current one", which is the documented convention and is why it is not simply
     * passed through. */
    if (font == NULL) return NULL;
    if (size <= 0.0) size = CTFontGetSize(font);
    CFStringRef family = NULL;
    if (attributes != NULL) {
        family = CTFontDescriptorCopyAttribute(attributes, kCTFontFamilyNameAttribute);
    }
    if (family == NULL) {
        family = CTFontCopyFamilyName(font);
    }
    CTFontRef result = _CiderFontCreateForFamily(family, size);
    if (family != NULL) CFRelease(family);
    return result;
}

CTFontRef CTFontCreateCopyWithSymbolicTraits(CTFontRef font, CGFloat size,
                                             const CGAffineTransform *matrix,
                                             CTFontSymbolicTraits symTraitValue, 
                                             CTFontSymbolicTraits symTraitMask)
{
    printf("STUB %s\n", __PRETTY_FUNCTION__);
    return nil;
}

CTFontRef CTFontCreateCopyWithFamily(CTFontRef font, CGFloat size,
                                     const CGAffineTransform *matrix, CFStringRef family)
{
    printf("STUB %s\n", __PRETTY_FUNCTION__);
    return nil;
}

/*
 * Glyph fallback: which font can render this range of the string.
 *
 * THE CURRENT FONT IS THE TERMINATING ANSWER. There is no substitution table here, so the honest
 * reply is "no better font than the one you have", and it must be a font rather than nil: a
 * caller asking for a fallback is in a loop over runs it cannot render, and nil invites it to ask
 * again. LibreOffice does exactly that kind of loop, and this was a stub returning nil while the
 * process span at 1.2 cores.
 *
 * Retained, because the name says Create and the caller releases it. Returning currentFont
 * WITHOUT retaining would hand back a font the caller then over-releases, which is the same class
 * of defect as the font manager error parameter.
 */
CTFontRef CTFontCreateForString(CTFontRef currentFont, CFStringRef string, CFRange range)
{
    if (currentFont == NULL) return NULL;
    return (CTFontRef) CFRetain((CFTypeRef) currentFont);
}

CTFontRef CTFontCreateForStringWithLanguage(CTFontRef currentFont, CFStringRef string,
                                            CFRange range, CFStringRef language)
{
    /* The language only narrows the choice, and there is one font to choose from. */
    return CTFontCreateForString(currentFont, string, range);
}

CTFontDescriptorRef CTFontCopyFontDescriptor(CTFontRef font)
{
    /* A descriptor is the attribute dictionary, the same shape CTFontCollection builds, so
     * describing a font is filling one in from what the font already knows. */
    if (font == NULL) return NULL;
    CFStringRef family = CTFontCopyFamilyName(font);
    if (family == NULL) return NULL;
    CFMutableDictionaryRef attributes = CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    if (attributes == NULL) {
        CFRelease(family);
        return NULL;
    }
    CFDictionarySetValue(attributes, kCTFontFamilyNameAttribute, family);
    CFRelease(family);

    int symbolic = (int) [font symbolicTraits];
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
    return (CTFontDescriptorRef) attributes;
}

CFTypeRef CTFontCopyAttribute(CTFontRef font, CFStringRef attribute)
{
    printf("STUB %s\n", __PRETTY_FUNCTION__);
    return nil;
}

CGFloat CTFontGetSize(CTFontRef self) {
    return [self pointSize];
}

CGAffineTransform CTFontGetMatrix(CTFontRef font)
{
    printf("STUB %s\n", __PRETTY_FUNCTION__);
    return CGAffineTransformIdentity;
}

CTFontSymbolicTraits CTFontGetSymbolicTraits(CTFontRef font)
{
    /* It answered kCTFontTraitItalic for EVERY font, which is worse than answering nothing: a
     * caller picking a face from this got an italic one every time. */
    if (font == NULL) return 0;
    return (CTFontSymbolicTraits) [font symbolicTraits];
}

CFDictionaryRef CTFontCopyTraits(CTFontRef font)
{
    printf("STUB %s\n", __PRETTY_FUNCTION__);
    return nil;
}

/*
 * THE FONTS TO FALL BACK TO for characters this one does not have. There is no cascade list here,
 * and the honest answer to that is an EMPTY list, not nil: the name says Copy, so a caller owns the
 * result and is entitled to send it CFArrayGetCount. Returning nil put a null where an array was
 * expected and the crash landed inside objc, two frames below CoreFoundation, nowhere near here.
 */
CFArrayRef CTFontCopyDefaultCascadeListForLanguages(CTFontRef font, CFArrayRef languagePrefList)
{
    return CFArrayCreate(kCFAllocatorDefault, NULL, 0, &kCFTypeArrayCallBacks);
}

CFStringRef CTFontCopyPostScriptName(CTFontRef font)
{
    printf("STUB %s\n", __PRETTY_FUNCTION__);
    return nil;
}

CFStringRef CTFontCopyFamilyName(CTFontRef font)
{
    /* -copyName is the KTFont accessor and follows the same Copy convention, so this is a
     * rename rather than a reimplementation. */
    if (font == NULL) return NULL;
    return [font copyName];
}

CFStringRef CTFontCopyFullName(CTFontRef self) {
    return [self copyName];
}

CFStringRef CTFontCopyDisplayName(CTFontRef font)
{
    printf("STUB %s\n", __PRETTY_FUNCTION__);
    return nil;
}

CFStringRef _Nullable CTFontCopyName(CTFontRef font, CFStringRef nameKey)
{
    printf("STUB %s\n", __PRETTY_FUNCTION__);
    return nil;
}

CFStringRef CTFontCopyLocalizedName(CTFontRef font, CFStringRef nameKey,
                                    CFStringRef  _Nullable *actualLanguage)
{
    printf("STUB %s\n", __PRETTY_FUNCTION__);
    return nil;
}

CFCharacterSetRef CTFontCopyCharacterSet(CTFontRef font)
{
    printf("STUB %s\n", __PRETTY_FUNCTION__);
    return nil;
}

CFStringEncoding CTFontGetStringEncoding(CTFontRef font)
{
    printf("STUB %s\n", __PRETTY_FUNCTION__);
    return CFStringGetSystemEncoding();
}

CFArrayRef CTFontCopySupportedLanguages(CTFontRef font)
{
    printf("STUB %s\n", __PRETTY_FUNCTION__);
    return nil;
}

CGFloat CTFontGetAscent(CTFontRef self) {
    return [self ascender];
}

CGFloat CTFontGetDescent(CTFontRef self) {
    return [self descender];
}

CGFloat CTFontGetLeading(CTFontRef self) {
    return [self leading];
}

unsigned int CTFontGetUnitsPerEm(CTFontRef font)
{
    printf("STUB %s\n", __PRETTY_FUNCTION__);
    return 0;
}

CFIndex CTFontGetGlyphCount(CTFontRef font) {
    return [font numberOfGlyphs];
}

CGRect CTFontGetBoundingBox(CTFontRef self) {
    return [self boundingRect];
}

CGFloat CTFontGetUnderlinePosition(CTFontRef self) {
    return [self underlinePosition];
}

CGFloat CTFontGetUnderlineThickness(CTFontRef self) {
    return [self underlineThickness];
}

CGFloat CTFontGetSlantAngle(CTFontRef self) {
    return [self italicAngle];
}

CGFloat CTFontGetCapHeight(CTFontRef self) {
    return [self capHeight];
}

CGFloat CTFontGetXHeight(CTFontRef self) {
    return [self xHeight];
}

CGPathRef CTFontCreatePathForGlyph(CTFontRef self, CGGlyph glyph,
                                   CGAffineTransform *xform)
{
    return (CGPathRef) [self createPathForGlyph: glyph transform: xform];
}

CGGlyph CTFontGetGlyphWithName(CTFontRef font, CFStringRef glyphName)
{
    printf("STUB %s\n", __PRETTY_FUNCTION__);
    return CGNullGlyph;
}

CGRect CTFontGetBoundingRectsForGlyphs(CTFontRef font, CTFontOrientation orientation,
                                       const CGGlyph *glyphs, CGRect *boundingRects,
                                       CFIndex count)
{
    if (font == NULL || glyphs == NULL || count <= 0) {
        return CGRectZero;
    }
    /* The out parameter is OPTIONAL: callers that only want the union pass NULL, so the per
     * glyph rects go to a local buffer in that case rather than being skipped. */
    CGRect *rects = boundingRects;
    CGRect *owned = NULL;
    if (rects == NULL) {
        owned = malloc(sizeof(CGRect) * (size_t) count);
        if (owned == NULL) return CGRectZero;
        rects = owned;
    }
    [font getBoundingRects: rects forGlyphs: glyphs count: (NSUInteger) count];

    /* The RETURN is the union of them all, which is what the caller uses to size a run. */
    CGRect union_ = rects[0];
    for (CFIndex i = 1; i < count; i++) {
        union_ = CGRectUnion(union_, rects[i]);
    }
    if (owned != NULL) free(owned);
    return union_;
}

/* KTFont and NSFont are both handed to these functions and only one of them answers -fontName. */
static const char *CiderFontNameOf(id object) {
    if (![object respondsToSelector: @selector(fontName)])
        return object_getClassName(object);
    return [[object fontName] UTF8String] ?: "?";
}

/* A metric of zero is a defect that reads as a hang: iA Writer multiplies the width of one
 * character by a counter until it reaches the viewport width, so a zero advance never terminates.
 * Only the zero cases print. */
static BOOL CiderTraceFontMetric(void) {
    static BOOL on = NO, asked = NO;

    if (!asked) {
        const char *value = getenv("CIDER_TRACE_FONTMETRIC");

        asked = YES;
        on = (value != NULL && value[0] != '\0');
    }
    return on;
}

/* THE SAME TWO CLASSES, THE SAME SELECTOR, AND THE MISMATCH RUNS THE OTHER WAY.
 *
 * -getGlyphs: above is about what the method WRITES. This one is about what it READS: KTFont takes
 * CGGlyph, two bytes each, and NSFont takes NSGlyph, eight. Handing an NSFont the caller CGGlyph
 * array makes it read four glyphs worth of bytes as one index, so the glyphs it measures are
 * nonsense and so are the advances.
 *
 * That is not academic. iTerm2 sizes its character cell from these advances and its terminal grid
 * from the cell: after a resize it reported 225 columns in a 1000 pixel window, a cell of 4.4
 * pixels, while drawing glyphs about twice that wide.
 *
 * And the sum was accumulated onto an UNINITIALISED double, so the return value was whatever the
 * stack held plus the advances. Both are fixed here.
 */
double CTFontGetAdvancesForGlyphs(CTFontRef font, CTFontOrientation orientation,
                                const CGGlyph *glyphs, CGSize *advances,
                                CFIndex count)
{
    id object = (id) font;
    uintptr_t stack[256];
    uintptr_t *wide = NULL;
    double sum = 0.0;
    CFIndex i;

    if (object == nil || glyphs == NULL || count <= 0) {
        return 0.0;
    }

    /*
     * THE ADVANCES ARRAY IS OPTIONAL, and answering zero when it is NULL is not a safe refusal: the
     * RETURN is the total advance and a caller that only wants the total passes NULL, exactly as it
     * does for the bounding rects above. iA Writer measures the width of one character that way to
     * get its en width, then divides its viewport by it, and a zero came back as a layout loop that
     * stepped by nothing and never reached the far edge. The application span 100 percent of a core
     * inside -[IATypographyLayout initWithViewportWidth:viewportSizeClass:enWidth:...].
     */
    CGSize local[64];
    CGSize *owned = NULL;

    if (advances == NULL) {
        if (count <= (CFIndex) (sizeof(local) / sizeof(local[0]))) {
            advances = local;
        } else {
            owned = (CGSize *) calloc((size_t) count, sizeof(CGSize));
            if (owned == NULL) {
                return 0.0;
            }
            advances = owned;
        }
    }

    if (cider_glyph_arg_is_wide(object, @selector(getAdvancements:forGlyphs:count:), 3)) {
        wide = (count <= (CFIndex) (sizeof(stack) / sizeof(stack[0])))
                   ? stack
                   : (uintptr_t *) calloc((size_t) count, sizeof(uintptr_t));
        if (wide == NULL) {
            free(owned);
            return 0.0;
        }
        for (i = 0; i < count; i++) {
            wide[i] = glyphs[i];
        }
        [object getAdvancements: advances forGlyphs: (const CGGlyph *) wide count: count];
        if (wide != stack) {
            free(wide);
        }
    } else {
        [object getAdvancements: advances forGlyphs: glyphs count: count];
    }

    for (i = 0; i < count; i++) {
        sum += advances[i].width;
    }

    if (owned != NULL) {
        free(owned);
    }

    if (count == 1 && CiderTraceFontMetric())
        fprintf(stderr, "cider-fontmetric advance font=%s size=%g glyph=%u w=%g h=%g sum=%g\n",
                CiderFontNameOf(object),
                [object respondsToSelector: @selector(pointSize)] ? (double) [object pointSize] : -1,
                (unsigned) glyphs[0], (double) advances[0].width, (double) advances[0].height,
                sum);

    return sum;
}

CGRect CTFontGetOpticalBoundsForGlyphs(CTFontRef font, const CGGlyph *glyphs,
                                       CGRect *boundingRects, CFIndex count,
                                       CFOptionFlags options)
{
    printf("STUB %s\n", __PRETTY_FUNCTION__);
    return CGRectMake(0, 0, 0, 0);
}

void CTFontGetVerticalTranslationsForGlyphs(CTFontRef font, const CGGlyph *glyphs,
                                            CGSize *translations, CFIndex count)
{
    printf("STUB %s\n", __PRETTY_FUNCTION__);
}

CFArrayRef CTFontCopyVariationAxes(CTFontRef font)
{
    printf("STUB %s\n", __PRETTY_FUNCTION__);
    return nil;
}

CFDictionaryRef CTFontCopyVariation(CTFontRef font)
{
    printf("STUB %s\n", __PRETTY_FUNCTION__);
    return nil;
}

CFArrayRef CTFontCopyFeatures(CTFontRef font)
{
    printf("STUB %s\n", __PRETTY_FUNCTION__);
    return nil;
}

CFArrayRef CTFontCopyFeatureSettings(CTFontRef font)
{
    printf("STUB %s\n", __PRETTY_FUNCTION__);
    return nil;
}

/* TWO DIFFERENT CLASSES ANSWER -getGlyphs:forCharacters:length: WITH DIFFERENT ELEMENT WIDTHS.
 *
 * KTFont writes CGGlyph, which is two bytes. NSFont writes NSGlyph, which is NSUInteger, so eight.
 * A caller of the C function allocates count * sizeof(CGGlyph) and is entitled to expect that much
 * to be written; forwarding its buffer to an NSFont overruns it by a factor of four.
 *
 * That is not a cosmetic mismatch. iTerm2 allocates the glyph buffer with alloca directly below its
 * locals and passes the NSFont straight out of its attributes dictionary, so the overrun runs up
 * the stack and over the saved font pointer. The value read back was 0x47, a glyph index, and the
 * process then died messaging it. So decide by what the method actually writes.
 */
static bool cider_glyph_arg_is_wide(id object, SEL selector, unsigned int index)
{
    Method method = class_getInstanceMethod(object_getClass(object), selector);
    char *type;
    bool wide;

    if (method == NULL) {
        return false;
    }

    /* Argument 2 is the first one after self and _cmd. "^S" is unsigned short *, which is CGGlyph
     * and needs no translation; anything wider is an NSGlyph array. */
    type = method_copyArgumentType(method, index);
    if (type == NULL) {
        return false;
    }

    /* A CGGlyph array encodes as a pointer to unsigned short, with or without the const marker.
     * Anything else is an NSGlyph array, which is four times as wide. */
    wide = (strcmp(type, "^S") != 0 && strcmp(type, "r^S") != 0);
    free(type);
    return wide;
}

static bool cider_glyph_method_is_wide(id object)
{
    return cider_glyph_arg_is_wide(object, @selector(getGlyphs:forCharacters:length:), 2);
}

bool CTFontGetGlyphsForCharacters(CTFontRef font, const UniChar *characters,
                                  CGGlyph *glyphs, CFIndex count)
{
    id object = (id) font;
    uintptr_t stack[256];
    uintptr_t *wide;
    CFIndex i;

    if (object == nil || glyphs == NULL || characters == NULL || count <= 0) {
        return false;
    }

    if (!cider_glyph_method_is_wide(object)) {
        [object getGlyphs: glyphs forCharacters: characters length: (NSUInteger) count];
        return true;
    }

    wide = (count <= (CFIndex) (sizeof(stack) / sizeof(stack[0])))
               ? stack
               : (uintptr_t *) calloc((size_t) count, sizeof(uintptr_t));
    if (wide == NULL) {
        return false;
    }

    [object getGlyphs: (CGGlyph *) wide forCharacters: characters length: (NSUInteger) count];

    for (i = 0; i < count; i++) {
        /* NSControlGlyph is 0xFFFFFF and does not fit. CoreText answers 0 for a character it
         * cannot map, so say that rather than truncating to a real glyph index. */
        glyphs[i] = (wide[i] > 0xFFFF) ? 0 : (CGGlyph) wide[i];
        if (glyphs[i] == 0 && CiderTraceFontMetric())
            fprintf(stderr, "cider-fontmetric noglyph font=%s char=U+%04X\n",
                    CiderFontNameOf(object), (unsigned) characters[i]);
    }

    if (wide != stack) {
        free(wide);
    }

    return true;
}

void CTFontDrawGlyphs(CTFontRef font, const CGGlyph *glyphs, const CGPoint *positions,
                      size_t count, CGContextRef context)
{
    [font drawGlyphs: glyphs positions: positions count: (NSUInteger) count inContext: context];
}

CFIndex CTFontGetLigatureCaretPositions(CTFontRef font, CGGlyph glyph, CGFloat *positions,
                                        CFIndex maxPositions)
{
    printf("STUB %s\n", __PRETTY_FUNCTION__);
    return -1;
}

/* THE CALLER OWNS WHAT COMES BACK, and it is usually not a CTFont that arrives here. AppKit NSFont
 * is toll free bridged to CTFont on macOS, so applications hand their NSFont straight to this
 * function; iTerm2 does exactly that when it measures a character cell. Both classes answer
 * -graphicsFont, so ask for that rather than assuming which one this is. */
CGFontRef CTFontCopyGraphicsFont(CTFontRef font, CTFontDescriptorRef _Nullable *attributes)
{
    id object = (id) font;

    if (object == nil) {
        return NULL;
    }

    /* A POINTER THIS SMALL OR THIS MISALIGNED IS NOT AN OBJECT, and messaging it faults inside
     * objc_msgSend where the caller looks like the culprit. iTerm2 hands over whatever its
     * attributes dictionary holds under NSFontAttributeName, and it has handed over 0x18. Say the
     * value and answer NULL, which is what this function already answers for anything it cannot
     * unwrap, rather than taking the process down. */
    if ((uintptr_t) object < 0x1000 || ((uintptr_t) object & 0x7) != 0) {
        static int reported = 0;

        if (reported < 8) {
            void *frames[24];
            int count = backtrace(frames, 24);

            reported++;
            fprintf(stderr, "CTFontCopyGraphicsFont: %p is not an object, frames=%d\n",
                    (void *) object, count);
            fflush(stderr);
            backtrace_symbols_fd(frames, count, 2);
        }
        return NULL;
    }

    if (![object respondsToSelector: @selector(graphicsFont)]) {
        NSLog(@"CTFontCopyGraphicsFont: %@ is not a font this implementation can unwrap",
              [object class]);
        return NULL;
    }

    CGFontRef graphics = ((CGFontRef(*)(id, SEL)) objc_msgSend)(object, @selector(graphicsFont));

    /* A font that answers the selector but has no graphics font underneath makes the caller set a
     * NULL font on its context, after which every glyph it draws goes nowhere and the failure looks
     * like a blank view rather than a missing font. Say which font it was. */
    if (graphics == NULL) {
        static int reported = 0;

        if (reported < 8) {
            reported++;
            NSLog(@"CTFontCopyGraphicsFont: %@ has no graphics font, so text drawn with it will be "
                  @"invisible",
                  [object respondsToSelector: @selector(fontName)] ? [object fontName]
                                                                   : (id) [object class]);
        }
        return NULL;
    }

    return CGFontRetain(graphics);
}

CTFontRef
CTFontCreateWithGraphicsFont(CGFontRef cgFont, CGFloat size,
                             CGAffineTransform *xform,
                             CTFontDescriptorRef attributes)
{
    return (CTFontRef)[[KTFont alloc] initWithFont: cgFont size: size];
}

ATSFontRef CTFontGetPlatformFont(CTFontRef font, CTFontDescriptorRef  _Nullable *attributes)
{
    printf("STUB %s\n", __PRETTY_FUNCTION__);
    return 0;
}

CTFontRef CTFontCreateWithPlatformFont(ATSFontRef platformFont, CGFloat size,
                                       const CGAffineTransform *matrix,
                                       CTFontDescriptorRef attributes)
{
    printf("STUB %s\n", __PRETTY_FUNCTION__);
    return nil;
}

CTFontRef CTFontCreateWithQuickdrawInstance(ConstStr255Param name, int16_t identifier,
                                            uint8_t style, CGFloat size)
{
    printf("STUB %s\n", __PRETTY_FUNCTION__);
    return nil;
}

CFArrayRef CTFontCopyAvailableTables(CTFontRef font, CTFontTableOptions options)
{
    return [font copyAvailableFontTables];
}

CFDataRef CTFontCopyTable(CTFontRef font, CTFontTableTag table, CTFontTableOptions options)
{
    /* The options ask for tables to be excluded from the copy, and there is nothing here that
     * would exclude one. */
    return [font copyFontTable: (uint32_t) table];
}

CFTypeID CTFontGetTypeID(void)
{
    printf("STUB %s\n", __PRETTY_FUNCTION__);
    return 0;
}
