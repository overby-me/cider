#import <CoreText/CTFrameSetter.h>
#import <CoreText/CTLine.h>
#import <Foundation/NSAttributedString.h>
#import <Foundation/NSString.h>
#include <stdio.h>

/*
 * THE FRAMESETTER, AND WHY A STUB HERE WAS FATAL.
 *
 * Every one of these answered nil, and the caller that matters does this:
 *
 *     framesetter = CTFramesetterCreateWithAttributedString(s);
 *     size = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, ...);
 *     CFRelease(framesetter);
 *
 * CFRelease of NULL is a HALT in this CoreFoundation, so the stub did not return a wrong size, it
 * killed the process. That is what -[NSString(iTerm) it_boundingRectWithSize:attributes:truncated:]
 * does, which is how iTerm2 measures its badge, and the disassembly of those twenty instructions is
 * what named this function rather than the CTLine one fixed alongside it.
 *
 * WHAT IT ACTUALLY MEASURES. A framesetter here holds the attributed string and answers a size by
 * laying it out through CTLine, wrapping on the constraint width. That is single font, single run
 * and greedy word wrapping: enough to measure a label, a badge or a tooltip honestly, and not a
 * text engine. Anything that needs real framesetting, CTFramesetterCreateFrame and the typesetter,
 * is still absent and still says so.
 */
@interface CiderFramesetter : NSObject {
@public
    NSAttributedString *_string;
}
@end

@implementation CiderFramesetter

- (instancetype) initWithAttributedString: (NSAttributedString *) string
{
    if ((self = [super init]) != nil) {
        _string = [string copy];
    }
    return self;
}

- (void) dealloc
{
    [_string release];
    [super dealloc];
}

@end

CFTypeID CTFramesetterGetTypeID(void)
{
    /* No CF type is registered for this class. A made up id would be worse than none, since callers
     * compare it against CFGetTypeID of a real object. */
    return 0;
}

CTFramesetterRef CTFramesetterCreateWithTypesetter(CTTypesetterRef typesetter)
{
    printf("STUB %s\n", __PRETTY_FUNCTION__);
    return nil;
}

CTFramesetterRef CTFramesetterCreateWithAttributedString(CFAttributedStringRef attrString)
{
    if (attrString == NULL) {
        return NULL;
    }
    return (CTFramesetterRef)[[CiderFramesetter alloc]
            initWithAttributedString: (NSAttributedString *) attrString];
}

CTFrameRef CTFramesetterCreateFrame(CTFramesetterRef framesetter,
                                    CFRange stringRange,
                                    CGPathRef path,
                                    CFDictionaryRef frameAttributes)
{
    printf("STUB %s\n", __PRETTY_FUNCTION__);
    return nil;
}

CTTypesetterRef CTFramesetterGetTypesetter(CTFramesetterRef framesetter)
{
    printf("STUB %s\n", __PRETTY_FUNCTION__);
    return nil;
}

/* One measured line: its width, and the height of a line box for this font. */
static CGSize cider_measure(NSAttributedString *piece, CGFloat *lineHeight)
{
    CTLineRef line = CTLineCreateWithAttributedString((CFAttributedStringRef) piece);
    CGFloat ascent = 0.0, descent = 0.0, leading = 0.0;
    double width;

    if (line == NULL) {
        return CGSizeMake(0.0, 0.0);
    }

    width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading);
    CFRelease(line);

    if (lineHeight != NULL) {
        *lineHeight = ascent + descent + leading;
    }
    return CGSizeMake((CGFloat) width, ascent + descent + leading);
}

CGSize CTFramesetterSuggestFrameSizeWithConstraints(CTFramesetterRef framesetter,
                                                    CFRange stringRange,
                                                    CFDictionaryRef frameAttributes,
                                                    CGSize constraints,
                                                    CFRange *fitRange)
{
    CiderFramesetter *self = (CiderFramesetter *) framesetter;

    if (self == nil || self->_string == nil) {
        if (fitRange != NULL) {
            fitRange->location = 0;
            fitRange->length = 0;
        }
        return CGSizeZero;
    }

    NSAttributedString *string = self->_string;

    /* A range of zero length means all of it, which is what every caller here passes. */
    NSRange range = NSMakeRange((NSUInteger) stringRange.location,
                                (stringRange.length > 0)
                                        ? (NSUInteger) stringRange.length
                                        : [string length] - (NSUInteger) stringRange.location);
    if (range.location + range.length > [string length]) {
        range.length = [string length] - range.location;
    }
    if (fitRange != NULL) {
        fitRange->location = (CFIndex) range.location;
        fitRange->length = (CFIndex) range.length;
    }

    NSAttributedString *whole = [string attributedSubstringFromRange: range];
    CGFloat lineHeight = 0.0;
    CGSize whole_size = cider_measure(whole, &lineHeight);

    /* Unconstrained, or it already fits: one line, and that is the answer. */
    if (constraints.width <= 0.0 || whole_size.width <= constraints.width) {
        return CGSizeMake(whole_size.width, MAX(whole_size.height, lineHeight));
    }

    /*
     * GREEDY WORD WRAPPING, measured rather than estimated. Splitting on spaces and remeasuring
     * each candidate is slower than a real typesetter and gives the same answer for the labels
     * these callers ask about; dividing the total width by the constraint would not, because a line
     * breaks at a word rather than wherever the arithmetic lands.
     */
    NSString *text = [whole string];
    NSUInteger length = [text length];
    NSUInteger lineStart = 0;
    NSUInteger lastBreak = NSNotFound;
    NSUInteger lines = 0;
    CGFloat widest = 0.0;
    NSUInteger i;

    for (i = 0; i <= length; i++) {
        BOOL atEnd = (i == length);
        unichar c = atEnd ? (unichar) '\n' : [text characterAtIndex: i];

        if (!atEnd && c != ' ' && c != '\n' && c != '\t') {
            continue;
        }

        NSRange candidate = NSMakeRange(lineStart, i - lineStart);
        CGSize size = cider_measure([whole attributedSubstringFromRange: candidate], NULL);

        if (size.width > constraints.width && lastBreak != NSNotFound) {
            /* Too wide: commit the previous break and start the next line after it. */
            NSRange committed = NSMakeRange(lineStart, lastBreak - lineStart);
            CGSize done = cider_measure([whole attributedSubstringFromRange: committed], NULL);

            widest = MAX(widest, done.width);
            lines++;
            lineStart = lastBreak + 1;
            lastBreak = NSNotFound;
            i = lineStart - 1;
            continue;
        }

        widest = MAX(widest, size.width);
        if (atEnd || c == '\n') {
            lines++;
            lineStart = i + 1;
            lastBreak = NSNotFound;
        } else {
            lastBreak = i;
        }
    }

    if (lines == 0) {
        lines = 1;
    }
    return CGSizeMake(MIN(widest, constraints.width), lineHeight * (CGFloat) lines);
}
