/* Copyright (c) 2008 Johannes Fortmann

 Permission is hereby granted, free of charge, to any person obtaining a copy of
 this software and associated documentation files (the "Software"), to deal in
 the Software without restriction, including without limitation the rights to
 use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
 of the Software, and to permit persons to whom the Software is furnished to do
 so, subject to the following conditions:

 The above copyright notice and this permission notice shall be included in all
 copies or substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 SOFTWARE. */

#include <stdio.h>
#include <stdlib.h>
#import <CoreText/KTFont_FT.h>
#import <Onyx2D/O2Font_freetype.h>
#import FT_TRUETYPE_TABLES_H
#import FT_OUTLINE_H

@implementation KTFont (KTFont_FT)
+ (id) allocWithZone: (NSZone *) zone {
    return NSAllocateObject([KTFont_FT class], 0, NULL);
}
@end

@implementation KTFont_FT

- initWithUIFontType: (CTFontUIFontType) uiFontType
                size: (CGFloat) size
            language: (NSString *) language
{
    O2Font *font = nil;

    switch (uiFontType) {

    case kCTFontMenuTitleFontType:
    case kCTFontMenuItemFontType:
        if (size == 0)
            size = 12;
        font = O2FontCreateWithFontName(@"San Francisco");
        break;

    default:
        return nil;
    }

    self = [self initWithFont: (CGFontRef)font size: size];

    [font release];

    return self;
}

/*
 * A raw sfnt table straight out of FreeType.
 *
 * LibreOffice asks for these constantly (140 calls before this existed) to read cmap, OS/2, head
 * and the layout tables: it does its own shaping and needs the bytes, not an interpretation. The
 * two call form is FreeType's own: once with a NULL buffer to learn the length, once to fill it.
 *
 * A face with no sfnt tables at all, which is what a bitmap or Type 1 font is, answers with an
 * error and this returns NULL. That is the truthful answer and the caller has to handle it
 * anyway, since the same is true on a Mac.
 */
/*
 * The style bits, read off the face.
 *
 * CTFontGetSymbolicTraits returned kCTFontTraitItalic unconditionally, which is not a missing
 * answer but a WRONG one: every font in the system reported itself italic, and a caller choosing
 * a face from that gets the wrong one every time. FreeType has already parsed these.
 */
/*
 * The box that contains every glyph in the face, in points.
 *
 * KTFont declares it abstract, so the base class RAISES: LibreOffice asks for it while laying
 * out and the exception was swallowed, which is why this needed an instrument to find rather
 * than a reading of the code.
 *
 * UNITS PER EM CAN BE ZERO, and that is not paranoia: it is zero for every bitmap face, and
 * this run logs "FreeType font face is not scalable" for a good number of them. Dividing by it
 * would take the process out with SIGFPE, which is the same shape of bug as the daemon clock.
 */
/*
 * A glyph outline as a CGPath, decomposed straight from FreeType.
 *
 * FT_Outline_Decompose walks the contours and calls back for each segment; the four callbacks
 * below are the whole translation. TrueType curves are QUADRATIC (conic) and PostScript ones are
 * CUBIC, and both appear in the same corpus, so both callbacks are required: dropping conicTo
 * would silently straighten every TrueType curve.
 *
 * FT_LOAD_NO_SCALE loads in FONT UNITS and the scale is applied here, which keeps this
 * consistent with the metrics above rather than depending on whatever size the face was last
 * set to.
 */
typedef struct {
    CGMutablePathRef path;
    CGFloat scale;
} CiderOutlineContext;

static int _CiderMoveTo(const FT_Vector *to, void *user) {
    CiderOutlineContext *ctx = (CiderOutlineContext *) user;
    CGPathMoveToPoint(ctx->path, NULL, (CGFloat) to->x * ctx->scale, (CGFloat) to->y * ctx->scale);
    return 0;
}

static int _CiderLineTo(const FT_Vector *to, void *user) {
    CiderOutlineContext *ctx = (CiderOutlineContext *) user;
    CGPathAddLineToPoint(ctx->path, NULL, (CGFloat) to->x * ctx->scale, (CGFloat) to->y * ctx->scale);
    return 0;
}

static int _CiderConicTo(const FT_Vector *control, const FT_Vector *to, void *user) {
    CiderOutlineContext *ctx = (CiderOutlineContext *) user;
    CGPathAddQuadCurveToPoint(ctx->path, NULL,
                              (CGFloat) control->x * ctx->scale, (CGFloat) control->y * ctx->scale,
                              (CGFloat) to->x * ctx->scale, (CGFloat) to->y * ctx->scale);
    return 0;
}

static int _CiderCubicTo(const FT_Vector *c1, const FT_Vector *c2, const FT_Vector *to, void *user) {
    CiderOutlineContext *ctx = (CiderOutlineContext *) user;
    CGPathAddCurveToPoint(ctx->path, NULL,
                          (CGFloat) c1->x * ctx->scale, (CGFloat) c1->y * ctx->scale,
                          (CGFloat) c2->x * ctx->scale, (CGFloat) c2->y * ctx->scale,
                          (CGFloat) to->x * ctx->scale, (CGFloat) to->y * ctx->scale);
    return 0;
}

- (CGPathRef) createPathForGlyph: (CGGlyph) glyph transform: (CGAffineTransform *) xform {
    FT_Face face = [self _face];
    if (face == NULL) {
        return NULL;
    }
    O2FontHostLock();
    FT_Error _ciderLoadError = FT_Load_Glyph(face, (FT_UInt) glyph, FT_LOAD_NO_SCALE | FT_LOAD_NO_BITMAP);
    O2FontHostUnlock();
    if (_ciderLoadError != 0) {
        return NULL;
    }
    if (face->glyph->format != FT_GLYPH_FORMAT_OUTLINE) {
        /* A bitmap glyph has no outline to give, which is not a failure: it is what a bitmap
         * face is, and the caller treats NULL as no ink. */
        return NULL;
    }

    CiderOutlineContext ctx;
    ctx.path = CGPathCreateMutable();
    ctx.scale = [self _unitScale];
    if (ctx.path == NULL) {
        return NULL;
    }

    FT_Outline_Funcs funcs;
    funcs.move_to = _CiderMoveTo;
    funcs.line_to = _CiderLineTo;
    funcs.conic_to = _CiderConicTo;
    funcs.cubic_to = _CiderCubicTo;
    funcs.shift = 0;
    funcs.delta = 0;
    if (FT_Outline_Decompose(&face->glyph->outline, &funcs, &ctx) != 0) {
        CGPathRelease(ctx.path);
        return NULL;
    }
    CGPathCloseSubpath(ctx.path);

    if (xform != NULL) {
        CGPathRef transformed = CGPathCreateCopyByTransformingPath(ctx.path, xform);
        CGPathRelease(ctx.path);
        return transformed;
    }
    return ctx.path;
}

- (CGRect) boundingRect {
    O2Font_freetype *o2Font = (O2Font_freetype *) _font;
    FT_Face face = [o2Font face];
    if (face == NULL || face->units_per_EM == 0) {
        return CGRectZero;
    }
    CGFloat scale = _size / (CGFloat) face->units_per_EM;
    return CGRectMake((CGFloat) face->bbox.xMin * scale,
                      (CGFloat) face->bbox.yMin * scale,
                      (CGFloat) (face->bbox.xMax - face->bbox.xMin) * scale,
                      (CGFloat) (face->bbox.yMax - face->bbox.yMin) * scale);
}

/*
 * THE WHOLE METRIC FAMILY, not one per run.
 *
 * All eight are declared by KTFont and implemented by nobody, so the base class raises for each
 * in turn. Text layout asks for them one after another, so discovering them singly costs a build
 * and a container run each to learn a name the header already lists. This is the same lesson as
 * the NSDisplay batch and the accessibility preferences.
 *
 * Everything scales by size over units per em, and UNITS PER EM CAN BE ZERO for a bitmap face,
 * so the divisor is checked once here rather than in eight places.
 */
- (CGFloat) _unitScale {
    O2Font_freetype *o2Font = (O2Font_freetype *) _font;
    FT_Face face = [o2Font face];
    if (face == NULL || face->units_per_EM == 0) {
        return 0.0;
    }
    return _size / (CGFloat) face->units_per_EM;
}

- (FT_Face) _face {
    O2Font_freetype *o2Font = (O2Font_freetype *) _font;
    return [o2Font face];
}

- (CGFloat) ascender {
    FT_Face face = [self _face];
    return (face == NULL) ? 0.0 : (CGFloat) face->ascender * [self _unitScale];
}

/*
 * POSITIVE, because this is the CORE TEXT descent and not the Cocoa one.
 *
 * FreeType reports face->descender as a negative number, the distance BELOW the baseline, and so
 * does Cocoa for -[NSFont descender]. CTFontGetDescent is the other convention: a positive
 * distance. The two are one negation apart and the base class does it, KTFont -descender being
 * -(CGFontGetDescent/upem)*size; this override dropped it, and the sign then travelled:
 *
 *     -[NSFont descender] is -CTFontGetDescent, so it came out POSITIVE 3.408
 *     -defaultLineHeightForFont is round(ascent + descent + leading), so it came out 10 for a
 *      12 point font whose glyphs need 17
 *
 * A line height smaller than the glyphs is a clip: [NSAttributedString size] returned 9 for a
 * button title, drawTitle clips to that rect, and Cancel and Open in the file picker were drawn
 * cut through the middle. Every string AppKit lays out went through the same number.
 */
- (CGFloat) descender {
    FT_Face face = [self _face];
    return (face == NULL) ? 0.0 : -((CGFloat) face->descender * [self _unitScale]);
}

/* The gap BETWEEN lines, which is the line height minus what the glyphs themselves occupy.
 * face->height is the full line advance, so the subtraction is what makes this leading rather
 * than line height. */
- (CGFloat) leading {
    FT_Face face = [self _face];
    if (face == NULL) return 0.0;
    CGFloat gap = (CGFloat) (face->height - (face->ascender - face->descender));
    return gap * [self _unitScale];
}

- (CGFloat) underlineThickness {
    FT_Face face = [self _face];
    return (face == NULL) ? 0.0 : (CGFloat) face->underline_thickness * [self _unitScale];
}

- (CGFloat) underlinePosition {
    FT_Face face = [self _face];
    return (face == NULL) ? 0.0 : (CGFloat) face->underline_position * [self _unitScale];
}

/*
 * From the post table, where it is a 16.16 fixed point number. A face with no post table is not
 * italic by omission, it is simply undeclared, and 0 is what Cocoa reports for upright text.
 */
- (CGFloat) italicAngle {
    FT_Face face = [self _face];
    if (face == NULL) return 0.0;
    TT_Postscript *post = (TT_Postscript *) FT_Get_Sfnt_Table(face, FT_SFNT_POST);
    if (post == NULL) return 0.0;
    return (CGFloat) post->italicAngle / 65536.0;
}

/*
 * x height and cap height live in OS/2, and only from version 2 of that table. WHERE THEY ARE
 * ABSENT THIS APPROXIMATES rather than answering zero: a zero x height makes a layout engine
 * divide by nothing or centre text on the baseline, and the conventional ratios are far closer
 * to right than that. The approximation is marked here so it is not mistaken for measurement.
 */
- (CGFloat) xHeight {
    FT_Face face = [self _face];
    if (face == NULL) return 0.0;
    TT_OS2 *os2 = (TT_OS2 *) FT_Get_Sfnt_Table(face, FT_SFNT_OS2);
    if (os2 != NULL && os2->version >= 2 && os2->sxHeight != 0) {
        return (CGFloat) os2->sxHeight * [self _unitScale];
    }
    return [self ascender] * 0.5;
}

- (CGFloat) capHeight {
    FT_Face face = [self _face];
    if (face == NULL) return 0.0;
    TT_OS2 *os2 = (TT_OS2 *) FT_Get_Sfnt_Table(face, FT_SFNT_OS2);
    if (os2 != NULL && os2->version >= 2 && os2->sCapHeight != 0) {
        return (CGFloat) os2->sCapHeight * [self _unitScale];
    }
    return [self ascender] * 0.7;
}

- (uint32_t) symbolicTraits {
    O2Font_freetype *o2Font = (O2Font_freetype *) _font;
    FT_Face face = [o2Font face];
    if (face == NULL) {
        return 0;
    }
    uint32_t traits = 0;
    if (face->style_flags & FT_STYLE_FLAG_ITALIC) traits |= (1u << 0);
    if (face->style_flags & FT_STYLE_FLAG_BOLD) traits |= (1u << 1);
    if (FT_IS_FIXED_WIDTH(face)) traits |= (1u << 10);
    return traits;
}

- (CFDataRef) copyFontTable: (uint32_t) tag {
    O2Font_freetype *o2Font = (O2Font_freetype *) _font;
    FT_Face face = [o2Font face];
    if (face == NULL) return NULL;

    FT_ULong length = 0;
    if (FT_Load_Sfnt_Table(face, (FT_ULong) tag, 0, NULL, &length) != 0 || length == 0) {
        return NULL;
    }
    CFMutableDataRef data = CFDataCreateMutable(kCFAllocatorDefault, (CFIndex) length);
    if (data == NULL) return NULL;
    CFDataSetLength(data, (CFIndex) length);
    if (FT_Load_Sfnt_Table(face, (FT_ULong) tag, 0,
                           (FT_Byte *) CFDataGetMutableBytePtr(data), &length) != 0) {
        CFRelease(data);
        return NULL;
    }
    return data;
}

/*
 * The list of sfnt tables in this face.
 *
 * THE VALUES ARE RAW TAGS CAST TO POINTERS, NOT CFNumbers, and that is not a shortcut: it is what
 * the API does on a Mac, where the documented way to read the result is
 * (CTFontTableTag)(uintptr_t)CFArrayGetValueAtIndex(tags, i). The array is therefore created with
 * NULL callbacks, since retaining an integer would crash immediately. Returning CFNumbers instead
 * would look tidier and break every correct caller.
 *
 * FreeType enumerates the same way in two calls: a NULL tag pointer asks for the COUNT, then each
 * index is asked for its tag. LibreOffice called this 782 times in one run and got nil each time.
 */
- (CFArrayRef) copyAvailableFontTables {
    O2Font_freetype *o2Font = (O2Font_freetype *) _font;
    FT_Face face = [o2Font face];
    if (face == NULL) return NULL;

    FT_ULong count = 0;
    if (FT_Sfnt_Table_Info(face, 0, NULL, &count) != 0 || count == 0) return NULL;

    CFMutableArrayRef tables = CFArrayCreateMutable(kCFAllocatorDefault, (CFIndex) count, NULL);
    if (tables == NULL) return NULL;
    for (FT_ULong i = 0; i < count; i++) {
        FT_ULong tag = 0, length = 0;
        if (FT_Sfnt_Table_Info(face, (FT_UInt) i, &tag, &length) != 0) continue;
        CFArrayAppendValue(tables, (const void *)(uintptr_t) tag);
    }
    return tables;
}

- (void) getGlyphs: (CGGlyph *) glyphs
        forCharacters: (const unichar *) characters
               length: (NSUInteger) length
{
    O2Font_freetype *o2Font = (O2Font_freetype *) _font;
    FT_Face face = [o2Font face];

    int i;
    for (i = 0; i < length; i++) {
        O2FontHostLock();
        glyphs[i] = FT_Get_Char_Index(face, characters[i]);
        O2FontHostUnlock();
        /* A CHARACTER THE FACE CANNOT DRAW, and WHICH face that was. A missing glyph is invisible
         * and zero width, so it looks like the string was never there: the Command symbol in every
         * menu shortcut measured zero and drew nothing. Naming the face separates a font without
         * the glyph from a lookup that cannot find it. */
        if (glyphs[i] == 0 && characters[i] > 0x2000 && getenv("CIDER_TRACE_FONTS") != NULL) {
            static int said = 0;

            if (said < 4) {
                said++;
                fprintf(stderr, "CIDER_NOGLYPH u+%04x face=%s style=%s\n",
                        (unsigned) characters[i], face ? face->family_name : "nil",
                        face ? face->style_name : "nil");
                fflush(stderr);
            }
        }
    }
}

- (void) getAdvancements: (CGSize *) advancements
               forGlyphs: (const CGGlyph *) glyphs
                   count: (NSUInteger) count
{
    O2Font_freetype *o2Font = (O2Font_freetype *) _font;
    FT_Face face = [o2Font face];

    int i;
    O2FontHostLock();
    FT_Set_Pixel_Sizes(face, _size, _size);

    for (i = 0; i < count; i++) {
        FT_Load_Glyph(face, glyphs[i], FT_LOAD_DEFAULT);
        advancements[i] = CGSizeMake(face->glyph->advance.x / (O2Float)(2 << 5),
                       face->glyph->advance.y / (O2Float)(2 << 5));
    }
    /* THE SLOT IS READ INSIDE THE LOCK. face->glyph is one shared buffer that every FT_Load_Glyph
     * overwrites, so releasing before reading it out would hand back another threads glyph. */
    O2FontHostUnlock();
}

- (CGPoint) positionOfGlyph: (CGGlyph) current
            precededByGlyph: (CGGlyph) previous
                  isNominal: (BOOL *) isNominalp
{
    O2Font_freetype *o2Font = (O2Font_freetype *) _font;
    FT_Face face = [o2Font face];

    *isNominalp = YES;

    if (!current)
        return NSZeroPoint;

    O2FontHostLock();
    FT_Set_Pixel_Sizes(face, _size, _size);

    FT_Load_Glyph(face, current, FT_LOAD_DEFAULT);

    NSPoint advance = NSMakePoint(face->glyph->advance.x / (O2Float)(2 << 5),
                                  face->glyph->advance.y / (O2Float)(2 << 5));

    O2FontHostUnlock();

    return advance;
}

@end
