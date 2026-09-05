/* Copyright (c) 2006-2008 Christopher J. W. Lloyd

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
#include <math.h>
#import <CoreText/KTFont.h>
#import <Onyx2D/O2Context.h>
#import <Onyx2D/O2Font.h>
#import <Foundation/NSArray.h>
#import <Onyx2D/O2Exceptions.h>

@implementation KTFont

- initWithFont: (CGFontRef) font size: (CGFloat) size {
    _font = CGFontRetain(font);
    _unitsPerEm = CGFontGetUnitsPerEm(_font);
    _size = size;
    return self;
}

/* The CGFont this font was built from, for CTFontCopyGraphicsFont. Not retained here: the caller
 * of that function is the one that owns a reference. */
- (CGFontRef) graphicsFont {
    return _font;
}

- initWithUIFontType: (CTFontUIFontType) uiFontType
                size: (CGFloat) size
            language: (NSString *) language
{
    O2InvalidAbstractInvocation();
    return nil;
}

- (void) dealloc {
    CGFontRelease(_font);
    [super dealloc];
}

/*
 * The ink box per glyph, from the glyph's own outline.
 *
 * BUILT ON -createPathForGlyph:transform:, WHICH ALREADY WORKED. That is the same outline
 * CTFontCreatePathForGlyph hands out, so a bounding rect from it agrees with what actually gets
 * drawn by construction; deriving it from FreeType metrics separately would be a second source
 * of truth for the same number.
 *
 * A glyph with no outline, which is what a space is, has no ink and gets CGRectZero. That is the
 * truthful answer rather than a failure: it is exactly what a Mac reports for one.
 */
- (void) getBoundingRects: (CGRect *) rects
                forGlyphs: (const CGGlyph *) glyphs
                    count: (NSUInteger) count
{
    if (rects == NULL || glyphs == NULL) {
        return;
    }
    for (NSUInteger i = 0; i < count; i++) {
        CGPathRef path = [self createPathForGlyph: glyphs[i] transform: NULL];
        if (path != NULL) {
            rects[i] = CGPathGetBoundingBox(path);
            CGPathRelease(path);
        } else {
            rects[i] = CGRectZero;
        }
    }
}

/*
 * Draw a run of glyphs, each at its own position.
 *
 * O2ContextShowGlyphsAtPoint is the path NSString drawing already takes, which is why text
 * appears at all in the AppKit probe. What was missing was any way for a CALLER THAT HAS GLYPHS
 * ALREADY to reach it: LibreOffice does its own shaping and arrives with glyph ids and positions,
 * and CTFontDrawGlyphs was a stub, so every string it laid out drew nothing.
 *
 * THE FONT HAS TO BE SET ON THE CONTEXT FIRST. A CTFontRef carries the font and the size; a
 * CGContext does not know either until it is told, and O2ContextShowGlyphsAtPoint draws with
 * whatever the context last had.
 */
- (void) drawGlyphs: (const CGGlyph *) glyphs
          positions: (const CGPoint *) positions
              count: (NSUInteger) count
          inContext: (CGContextRef) context
{
    if (context == NULL || glyphs == NULL || positions == NULL || count == 0) {
        return;
    }
    O2ContextSetFont(context, _font);
    O2ContextSetFontSize(context, _size);
    for (NSUInteger i = 0; i < count; i++) {
        O2ContextShowGlyphsAtPoint(context, positions[i].x, positions[i].y, &glyphs[i], 1);
    }
}

- (uint32_t) symbolicTraits {
    return 0;
}

- (CFDataRef) copyFontTable: (uint32_t) tag {
    return NULL;
}

- (CFArrayRef) copyAvailableFontTables {
    return NULL;
}

- (CFStringRef) copyName {
    return CGFontCopyFullName(_font);
}

/* CTFont AND NSFont ARE TOLL FREE BRIDGED ON MACOS, so an application casts a CTFontRef to
 * NSFont and calls NSFont API on it. Here KTFont is its own class and every such call raised;
 * AppKit catches the raise per event, so iA Writer opening a document died in silence at
 * coveredCharacterSet. Answer the ones that only need the underlying O2Font, the same way
 * NSFont itself does. */
- (NSCharacterSet *) coveredCharacterSet {
    return O2FontGetCoveredCharacterSet((O2FontRef) _font);
}

/* NSGlyph is 8 bytes and CGGlyph is 2, and mixing the widths has bitten before, so the glyph is
 * truncated explicitly here and nowhere else. */
- (NSSize) advancementForGlyph: (NSUInteger) glyph {
    CGGlyph cgGlyph = (CGGlyph) glyph;
    CGSize advance = CGSizeZero;

    [self getAdvancements: &advance forGlyphs: &cgGlyph count: 1];

    return NSMakeSize(advance.width, advance.height);
}

- (NSSize) maximumAdvancement {
    NSUInteger glyphCount = [self numberOfGlyphs];
    NSSize max = NSZeroSize;

    for (NSUInteger glyph = 0; glyph < glyphCount; glyph++) {
        CGGlyph cgGlyph = (CGGlyph) glyph;
        CGSize advance = CGSizeZero;

        [self getAdvancements: &advance forGlyphs: &cgGlyph count: 1];
        max.width = MAX(max.width, advance.width);
        max.height = MAX(max.height, advance.height);
    }
    return max;
}

- (CGFloat) pointSize {
    return _size;
}

- (CGFloat) fontSize {
    return _size;
}

- (CGRect) boundingRect {
    O2InvalidAbstractInvocation();
    return CGRectZero;
}

- (CGFloat) ascender {
    CGFloat ascent = CGFontGetAscent(_font);

    return (ascent / _unitsPerEm) * _size;
}

// CT descenter is the opposite of the CG one on Cocoa
- (CGFloat) descender {
    CGFloat descent = CGFontGetDescent(_font);
    return -(descent / _unitsPerEm) * _size;
}

- (CGFloat) leading {
    CGFloat leading = CGFontGetLeading(_font);

    return (leading / _unitsPerEm) * _size;
}

/*
 * A CORETEXT FONT ANSWERS THE APPKIT METRIC TOO. CTFont and NSFont are the same object on macOS, so
 * an application is free to put either in a text attribute and AppKit asks whichever it gets. Ours
 * are separate classes, and a layout manager handed a CTFont raised: iA Writer terminated on
 * -[KTFont_FT defaultLineHeightForFont] while laying out a document.
 */
- (CGFloat) defaultLineHeightForFont {
    return roundf([self ascender] + fabs([self descender]) + [self leading]);
}

- (CGFloat) underlineThickness {
    O2InvalidAbstractInvocation();
    return 0;
}

- (CGFloat) underlinePosition {
    O2InvalidAbstractInvocation();
    return 0;
}

- (CGFloat) italicAngle {
    return CGFontGetItalicAngle(_font);
}

- (CGFloat) xHeight {
    CGFloat xHeight = CGFontGetXHeight(_font);

    return (xHeight / _unitsPerEm) * _size;
}

- (CGFloat) capHeight {
    CGFloat capHeight = CGFontGetCapHeight(_font);

    return (capHeight / _unitsPerEm) * _size;
}

- (NSUInteger) numberOfGlyphs {
    return CGFontGetNumberOfGlyphs(_font);
}

- (CGPoint) positionOfGlyph: (CGGlyph) current
            precededByGlyph: (CGGlyph) previous
                  isNominal: (BOOL *) isNominalp
{
    int advancement;

    if (previous == 0)
        return CGPointMake(0, 0);

    *isNominalp = YES;
    CGFontGetGlyphAdvances(_font, &previous, 1, &advancement);

    return CGPointMake(((CGFloat) advancement / _unitsPerEm) * _size, 0);
}

- (void) getGlyphs: (CGGlyph *) glyphs
        forCharacters: (const unichar *) characters
               length: (NSUInteger) length
{
    int i;

    for (i = 0; i < length; i++) {
        uint16_t code = characters[i];
        uint8_t group = code >> 8;
        uint8_t index = code & 0xFF;

        if (_twoLevel[group] == NULL)
            glyphs[i] = 0;
        else
            glyphs[i] = _twoLevel[group][index];
    }
}

- (void) getAdvancements: (CGSize *) advancements
               forGlyphs: (const CGGlyph *) glyphs
                   count: (NSUInteger) count
{
    int advances[count];

    CGFontGetGlyphAdvances(_font, glyphs, count, advances);
    for (int i = 0; i < count; i++) {
        advancements[i].width =
                ((CGFloat) advances[i] / (CGFloat) _unitsPerEm) * _size;
        advancements[i].height = 0;
    }
}

- (CGPathRef) createPathForGlyph: (CGGlyph) glyph
                       transform: (CGAffineTransform *) xform
{
    O2InvalidAbstractInvocation();
    return nil;
}

@end
