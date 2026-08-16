#import <CoreText/CTFont.h>
#import <CoreText/CTLine.h>
#import <CoreGraphics/CGContext.h>
#import <Foundation/NSAttributedString.h>
#import <Foundation/NSDictionary.h>
#import <Foundation/NSString.h>
#import <objc/runtime.h>
#include <stdio.h>
#include <stdlib.h>

/*
 * A REAL LINE, BECAUSE THE STUB WAS FATAL RATHER THAN MERELY EMPTY.
 *
 * CTLineCreateWithAttributedString answered nil, and a caller that measures a string does this:
 *
 *     CTLineRef line = CTLineCreateWithAttributedString(s);
 *     ... measure ...
 *     CFRelease(line);
 *
 * CFRelease of NULL is a HALT in this CoreFoundation, so the stub did not degrade the measurement,
 * it killed the process. iTerm2 draws its badge through
 * -[NSString(iTerm) it_boundingRectWithSize:attributes:truncated:] and died there, and the same
 * stub was reached 759 times in a single launch.
 *
 * So this is a line that can be measured, drawn and released. It is deliberately a SINGLE RUN in a
 * single font: that is what the callers here ask for, and pretending to do bidi or font fallback
 * would be a lie with more code in it. The font comes from the attributes, accepting either the
 * CoreText or the AppKit spelling of the key since applications use both.
 */
@interface CiderLine : NSObject {
@public
    NSAttributedString *_string;
    CTFontRef _font;
    CGGlyph *_glyphs;
    CGSize *_advances;
    CFIndex _count;
    CGFloat _width;
    CGFloat _ascent;
    CGFloat _descent;
    CGFloat _leading;
    CGFloat _trailingWhitespace;
}
@end

@implementation CiderLine

- (instancetype) initWithAttributedString: (NSAttributedString *) string
{
    if ((self = [super init]) == nil) {
        return nil;
    }

    _string = [string copy];

    NSString *text = [_string string];
    NSUInteger length = [text length];
    NSDictionary *attributes =
            (length > 0) ? [_string attributesAtIndex: 0 effectiveRange: NULL] : nil;

    /* ONE KEY COVERS BOTH SPELLINGS. kCTFontAttributeName and NSFontAttributeName are the same
     * string on macOS, "NSFont", which is why a CoreText caller and an AppKit caller can put a font
     * in the same dictionary and each find it. This header set declares neither constant, so the
     * literal is the honest way to say it. */
    id font = [attributes objectForKey: @"NSFont"];

    _font = (CTFontRef) font;

    if (length == 0 || _font == NULL) {
        return self;
    }

    unichar *characters = (unichar *) calloc(length, sizeof(unichar));
    if (characters == NULL) {
        return self;
    }
    [text getCharacters: characters range: NSMakeRange(0, length)];

    _glyphs = (CGGlyph *) calloc(length, sizeof(CGGlyph));
    _advances = (CGSize *) calloc(length, sizeof(CGSize));
    if (_glyphs == NULL || _advances == NULL) {
        free(characters);
        return self;
    }

    _count = (CFIndex) length;
    CTFontGetGlyphsForCharacters(_font, characters, _glyphs, _count);
    _width = CTFontGetAdvancesForGlyphs(_font, 0, _glyphs, _advances, _count);
    _ascent = CTFontGetAscent(_font);
    _descent = CTFontGetDescent(_font);
    _leading = CTFontGetLeading(_font);

    /* Measured rather than assumed zero: a caller that right aligns a line subtracts this, and a
     * trailing space is common in a badge or a label. */
    for (NSInteger i = (NSInteger) length - 1; i >= 0; i--) {
        unichar c = characters[i];

        if (c != ' ' && c != '\t') {
            break;
        }
        _trailingWhitespace += _advances[i].width;
    }

    free(characters);
    return self;
}

- (void) dealloc
{
    [_string release];
    free(_glyphs);
    free(_advances);
    [super dealloc];
}

@end

CFTypeID CTLineGetTypeID(void)
{
    /* No CF type is registered for this class, and answering a made up id would be worse than
     * answering none: callers compare it against CFGetTypeID of a real object. */
    return 0;
}

CTLineRef CTLineCreateWithAttributedString(CFAttributedStringRef attrString)
{
    if (attrString == NULL) {
        return NULL;
    }
    return (CTLineRef)[[CiderLine alloc]
            initWithAttributedString: (NSAttributedString *) attrString];
}

CTLineRef CTLineCreateTruncatedLine(CTLineRef line, double width,
                                    CTLineTruncationType truncationType,
                                    CTLineRef truncationToken)
{
    /* Truncation is not implemented, and the honest answer is the line itself RETAINED, because
     * the caller owns what it gets back and will release it. Returning NULL here would be the same
     * fatal CFRelease this file was written to stop. */
    if (line == NULL) {
        return NULL;
    }
    return (CTLineRef)[(id) line retain];
}

CTLineRef CTLineCreateJustifiedLine(CTLineRef line, CGFloat justificationFactor,
                                    double justificationWidth)
{
    if (line == NULL) {
        return NULL;
    }
    return (CTLineRef)[(id) line retain];
}

CFIndex CTLineGetGlyphCount(CTLineRef line)
{
    return (line != NULL) ? ((CiderLine *) line)->_count : 0;
}

CFArrayRef CTLineGetGlyphRuns(CTLineRef line)
{
    /* One run per line is what this builds, and CTRun is not implemented, so there is nothing
     * truthful to hand back. Empty rather than NULL: callers iterate the answer. */
    return (CFArrayRef)[NSArray array];
}

CFRange CTLineGetStringRange(CTLineRef line)
{
    CFRange range = {0, 0};

    if (line != NULL) {
        range.length = ((CiderLine *) line)->_count;
    }
    return range;
}

double CTLineGetPenOffsetForFlush(CTLineRef line, CGFloat flushFactor, double flushWidth)
{
    if (line == NULL) {
        return 0.0;
    }
    return flushFactor * (flushWidth - ((CiderLine *) line)->_width);
}

void CTLineDraw(CTLineRef line, CGContextRef context)
{
    CiderLine *self = (CiderLine *) line;

    if (self == nil || context == NULL || self->_count == 0 || self->_font == NULL) {
        return;
    }

    CGPoint *positions = (CGPoint *) calloc((size_t) self->_count, sizeof(CGPoint));
    if (positions == NULL) {
        return;
    }

    /* Positions are relative to the text position, which is where the caller left it. */
    CGFloat pen = 0.0;
    for (CFIndex i = 0; i < self->_count; i++) {
        positions[i] = CGPointMake(pen, 0.0);
        pen += self->_advances[i].width;
    }

    CTFontDrawGlyphs(self->_font, self->_glyphs, positions, (size_t) self->_count, context);
    free(positions);
}

double CTLineGetTypographicBounds(CTLineRef line, CGFloat *ascent, CGFloat *descent,
                                  CGFloat *leading)
{
    CiderLine *self = (CiderLine *) line;

    if (self == nil) {
        if (ascent != NULL) *ascent = 0.0;
        if (descent != NULL) *descent = 0.0;
        if (leading != NULL) *leading = 0.0;
        return 0.0;
    }

    if (ascent != NULL) *ascent = self->_ascent;
    if (descent != NULL) *descent = self->_descent;
    if (leading != NULL) *leading = self->_leading;
    return self->_width;
}

CGRect CTLineGetBoundsWithOptions(CTLineRef line, CTLineBoundsOptions options)
{
    CiderLine *self = (CiderLine *) line;

    if (self == nil) {
        return CGRectZero;
    }
    return CGRectMake(0.0, -self->_descent, self->_width, self->_ascent + self->_descent);
}

double CTLineGetTrailingWhitespaceWidth(CTLineRef line)
{
    return (line != NULL) ? ((CiderLine *) line)->_trailingWhitespace : 0.0;
}

CGRect CTLineGetImageBounds(CTLineRef line, CGContextRef context)
{
    return CTLineGetBoundsWithOptions(line, 0);
}

CFIndex CTLineGetStringIndexForPosition(CTLineRef line, CGPoint position)
{
    CiderLine *self = (CiderLine *) line;

    if (self == nil || self->_count == 0) {
        return 0;
    }

    CGFloat pen = 0.0;
    for (CFIndex i = 0; i < self->_count; i++) {
        CGFloat next = pen + self->_advances[i].width;

        /* The index a click belongs to is decided at the MIDPOINT of the glyph, which is what puts
         * a caret before or after the character the pointer is nearest. */
        if (position.x < (pen + next) / 2.0) {
            return i;
        }
        pen = next;
    }
    return self->_count;
}

CGFloat CTLineGetOffsetForStringIndex(CTLineRef line, CFIndex charIndex, CGFloat *secondaryOffset)
{
    CiderLine *self = (CiderLine *) line;
    CGFloat pen = 0.0;

    if (self != nil) {
        for (CFIndex i = 0; i < self->_count && i < charIndex; i++) {
            pen += self->_advances[i].width;
        }
    }
    if (secondaryOffset != NULL) {
        *secondaryOffset = pen;
    }
    return pen;
}
