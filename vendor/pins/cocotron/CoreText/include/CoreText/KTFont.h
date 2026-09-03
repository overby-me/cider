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
#import <CoreGraphics/CoreGraphics.h>
#import <CoreText/CTFont.h>
#import <Foundation/NSString.h>

enum { CGNullGlyph = 0x0 };

@interface KTFont : NSObject {
    CGFontRef _font;
    CGFloat _size;
    CGFloat _unitsPerEm;
    CGGlyph **_twoLevel;
}

- initWithFont: (CGFontRef) font size: (CGFloat) size;
- initWithUIFontType: (CTFontUIFontType) uiFontType
                size: (CGFloat) size
            language: (NSString *) language;

- (CGFontRef) graphicsFont;
- (CFStringRef) copyName;

/* One raw sfnt table, or NULL. Overridden where there is a real face to read it from; the base
 * answers NULL because a font backend that cannot produce tables must say so rather than hand
 * back an empty CFData, which a caller would parse as a valid but empty table. */
- (CFDataRef) copyFontTable: (uint32_t) tag;

/* Which sfnt tables this font has, as an array of raw tags. See the implementation for why the
 * values are not CFNumbers. */
- (CFArrayRef) copyAvailableFontTables;
- (CGFloat) pointSize;
- (CGFloat) fontSize;

- (CGRect) boundingRect;
- (CGFloat) ascender;
- (CGFloat) descender;
- (CGFloat) leading;
- (CGFloat) defaultLineHeightForFont;
- (CGFloat) underlineThickness;
- (CGFloat) underlinePosition;
- (CGFloat) italicAngle;
- (CGFloat) leading;
- (CGFloat) xHeight;
- (CGFloat) capHeight;

- (NSUInteger) numberOfGlyphs;

- (CGPoint) positionOfGlyph: (CGGlyph) current
            precededByGlyph: (CGGlyph) previous
                  isNominal: (BOOL *) isNominalp;

- (void) getGlyphs: (CGGlyph *) glyphs
        forCharacters: (const unichar *) characters
               length: (NSUInteger) length;

- (void) getAdvancements: (CGSize *) advancements
               forGlyphs: (const CGGlyph *) glyphs
                   count: (NSUInteger) count;

- (CGPathRef) createPathForGlyph: (CGGlyph) glyph
                       transform: (CGAffineTransform *) xform;

/* The ink box of each glyph, and drawing a run of them at given positions. See the
 * implementation for why both are built out of methods that already worked. */
- (void) getBoundingRects: (CGRect *) rects
                forGlyphs: (const CGGlyph *) glyphs
                    count: (NSUInteger) count;

/* The style bits this face actually has. Zero from the base class, real from the FreeType one. */
- (uint32_t) symbolicTraits;

- (void) drawGlyphs: (const CGGlyph *) glyphs
          positions: (const CGPoint *) positions
              count: (NSUInteger) count
          inContext: (CGContextRef) context;

@end
