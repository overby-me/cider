/* Copyright (c) 2006-2007 Christopher J. W. Lloyd <cjwl@objc.net>

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

#import <AppKit/NSColor.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#import <Onyx2D/O2Context.h>
#import <Onyx2D/O2Color.h>
#import <QuartzCore/CALayer.h>
#import <AppKit/NSGraphics.h>
#import <AppKit/NSGraphicsContextFunctions.h>
#import <AppKit/NSRaise.h>
#import <AppKit/NSView.h>

#import <AppKit/NSDisplay.h>
#import <ApplicationServices/ApplicationServices.h>

#import "NSPoofAnimation.h"

const CGFloat NSBlack = 0;
const CGFloat NSDarkGray = 0.333;
const CGFloat NSLightGray = 0.667;
const CGFloat NSWhite = 1.0;

NSString *const NSDeviceBlackColorSpace = @"NSDeviceBlackColorSpace";
NSString *const NSDeviceWhiteColorSpace = @"NSDeviceWhiteColorSpace";
NSString *const NSDeviceRGBColorSpace = @"NSDeviceRGBColorSpace";
NSString *const NSDeviceCMYKColorSpace = @"NSDeviceCMYKColorSpace";
NSString *const NSCalibratedBlackColorSpace = @"NSCalibratedBlackColorSpace";
NSString *const NSCalibratedWhiteColorSpace = @"NSCalibratedWhiteColorSpace";
NSString *const NSCalibratedRGBColorSpace = @"NSCalibratedRGBColorSpace";
NSString *const NSNamedColorSpace = @"NSNamedColorSpace";
NSString *const NSPatternColorSpace = @"NSPatternColorSpace";
NSString *const NSCustomColorSpace = @"NSCustomColorSpace";

NSString *const NSDeviceIsScreen = @"NSDeviceIsScreen";
NSString *const NSDeviceIsPrinter = @"NSDeviceIsPrinter";
NSString *const NSDeviceSize = @"NSDeviceSize";
NSString *const NSDeviceResolution = @"NSDeviceResolution";
NSString *const NSDeviceColorSpaceName = @"NSDeviceColorSpaceName";
NSString *const NSDeviceBitsPerSample = @"NSDeviceBitsPerSample";

static inline CGBlendMode blendModeForCompositeOp(NSCompositingOperation op) {
    static CGBlendMode table[] = {
            kCGBlendModeClear,
            kCGBlendModeCopy,
            kCGBlendModeNormal,
            kCGBlendModeSourceIn,
            kCGBlendModeSourceOut,
            kCGBlendModeSourceAtop,
            kCGBlendModeDestinationOver,
            kCGBlendModeDestinationIn,
            kCGBlendModeDestinationOut,
            kCGBlendModeDestinationAtop,
            kCGBlendModeXOR,
            kCGBlendModePlusDarker,
            kCGBlendModeNormal, // FIXME: highlight
            kCGBlendModePlusLighter,
    };

    if (op < NSCompositeClear || op > NSCompositePlusLighter)
        return NSCompositeCopy;

    return table[op];
}

void NSRectClipList(const NSRect *rects, int count) {
    CGContextRef graphicsPort = NSCurrentGraphicsPort();

    CGContextClipToRects(graphicsPort, rects, count);
}

void NSRectClip(NSRect rect) {
    CGContextRef graphicsPort = NSCurrentGraphicsPort();

    CGContextClipToRect(graphicsPort, rect);
}

void NSRectFillListWithColors(const NSRect *rects, NSColor **colors, int count)
{
    CGContextRef context = NSCurrentGraphicsPort();
    int i;

    CGContextSaveGState(context);
    CGContextSetBlendMode(context, kCGBlendModeCopy);
    for (i = 0; i < count; i++) {
        [colors[i] setFill];
        // FIXME: the groove/button rect generating code can generate negative
        // size rects which draw incorrectly this either needs to be fixed in
        // the drawing or the rect generation
        if (rects[i].size.width > 0 && rects[i].size.height > 0)
            NSRectFill(rects[i]);
    }
    CGContextRestoreGState(context);
}

void NSRectFillListWithGrays(const NSRect *rects, const CGFloat *grays,
                             int count)
{
    CGContextRef context = NSCurrentGraphicsPort();
    int i;

    CGContextSaveGState(context);
    CGContextSetBlendMode(context, kCGBlendModeCopy);
    for (i = 0; i < count; i++) {
        CGContextSetGrayFillColor(context, grays[i], 1.0);
        // FIXME: the groove/button rect generating code can generate negative
        // size rects which draw incorrectly this either needs to be fixed in
        // the drawing or the rect generation
        if (rects[i].size.width > 0 && rects[i].size.height > 0)
            CGContextFillRect(context, rects[i]);
    }
    CGContextRestoreGState(context);
}

void NSRectFillList(const NSRect *rects, int count) {
    CGContextRef context = NSCurrentGraphicsPort();
    CGContextSaveGState(context);
    CGContextSetBlendMode(context, kCGBlendModeCopy);
    CGContextFillRects(NSCurrentGraphicsPort(), rects, count);
    CGContextRestoreGState(context);
}

/* Defined further down, next to NSSetFocusRingStyle, and used here: without the prototype the call
 * below is an implicit int returning declaration and the definition conflicts with it. */
BOOL NSFocusRingDrawAroundRect(NSRect bounds);

void NSRectFill(NSRect rect) {
    if (NSFocusRingDrawAroundRect(rect)) {
        return;
    }
    CGContextRef context = NSCurrentGraphicsPort();
    CGContextSaveGState(context);
    CGContextSetBlendMode(context, kCGBlendModeCopy);
    CGContextFillRect(NSCurrentGraphicsPort(), rect);
    CGContextRestoreGState(context);
}

void NSEraseRect(NSRect rect) {
    CGContextRef context = NSCurrentGraphicsPort();
    CGContextSaveGState(context);
    [[NSColor whiteColor] setFill];
    CGContextSetBlendMode(context, kCGBlendModeCopy);
    CGContextFillRect(NSCurrentGraphicsPort(), rect);
    CGContextRestoreGState(context);
}

/*
 * A COPY FILL WITH A TRANSPARENT COLOUR IS A HOLE THROUGH THE WINDOW, and on macOS it is not.
 *
 * Copy writes the alpha instead of blending it. On macOS such a fill clears the view's OWN layer,
 * and everything behind, which lives in other layers, still shows. Every view here draws into one
 * window buffer, where what is behind HAS ALREADY BEEN DRAWN, so leaving the pixels alone is what
 * the compositor would have shown and painting anything is not.
 *
 * iTerm2 found both halves of this. PTYTextView clears itself in Copy on every pass; the terminal
 * background it should reveal belongs to its sibling iTermSessionBackgroundColorView, which is
 * layer backed and draws nothing, so -_ciderPaintLayerBackgroundInRect: paints it when that view
 * displays. An earlier version resolved the fill to that same colour instead, which also produced
 * the right background and then erased the text iTermLegacyView had drawn between the two.
 *
 * Gated on CIDER_LAYER_BACKING with the rest of the layer work.
 */
extern BOOL ciderLayerBackingEnabled(void);


void NSRectFillListUsingOperation(const NSRect *rects, int count,
                                  NSCompositingOperation operation)
{
    CGContextRef context = NSCurrentGraphicsPort();

    if (operation == NSCompositeCopy && ciderLayerBackingEnabled()) {
        O2ColorRef fill = O2ContextFillColor((O2ContextRef) context);

        if (fill != NULL && O2ColorGetAlpha(fill) <= 0.0) {
            return;
        }
    }
    CGContextSaveGState(context);
    CGContextSetBlendMode(context, blendModeForCompositeOp(operation));
    CGContextFillRects(NSCurrentGraphicsPort(), rects, count);
    CGContextRestoreGState(context);
}

void NSRectFillUsingOperation(NSRect rect, NSCompositingOperation op) {
    NSRectFillListUsingOperation(&rect, 1, op);
}

void NSFrameRectWithWidth(NSRect rect, CGFloat width) {
    NSFrameRectWithWidthUsingOperation(rect, width, NSCompositeCopy);
}

void NSFrameRectWithWidthUsingOperation(NSRect rect, CGFloat width,
                                        NSCompositingOperation operation)
{
    CGContextRef context = NSCurrentGraphicsPort();
    CGContextSaveGState(context);
    CGContextSetBlendMode(context, blendModeForCompositeOp(operation));
    CGRect edge[4];
    // left
    edge[0].origin.x = rect.origin.x;
    edge[0].origin.y = rect.origin.y;
    edge[0].size.width = width;
    edge[0].size.height = rect.size.height;
    // right
    edge[1].origin.x = NSMaxX(rect) - width;
    edge[1].origin.y = rect.origin.y;
    edge[1].size.width = width;
    edge[1].size.height = rect.size.height;
    // bottom
    edge[2].origin.x = rect.origin.x + width;
    edge[2].origin.y = rect.origin.y;
    edge[2].size.width = rect.size.width - width * 2;
    edge[2].size.height = width;
    // top
    edge[3].origin.x = rect.origin.x + width;
    edge[3].origin.y = NSMaxY(rect) - width;
    edge[3].size.width = rect.size.width - width * 2;
    edge[3].size.height = width;

    CGContextFillRects(NSCurrentGraphicsPort(), edge, 4);
    CGContextRestoreGState(context);
}

void NSFrameRect(NSRect rect) {
    CGContextStrokeRectWithWidth(NSCurrentGraphicsPort(), rect, 1);
}

void NSDottedFrameRect(NSRect rect) {
    [[NSColor blackColor] setFill];
    /* Win32 has poor dashed line support...

        DrawFocusRect produces dark spots for the gaps sometimes
        If we use a brush, it becomes black&white, not black&transparent
        The PS_DOT pen is not a single pixel dot.

        Fortunately this is not used heavily...
     */
    /*
     * A NaN SIZE MOVED THE STACK POINTER BY A TERABYTE.
     *
     * `<= 0` is false for NaN, so a control with a NaN frame got past the guard, `(int) NaN` is
     * INT_MIN, and the variable-length array below was declared with INT_MIN + INT_MIN + 4
     * elements. The allocation subtracted about 2^40 from rsp and the first store faulted on the
     * new stack pointer itself. iTerm2 died there one second in, every run.
     */
    if (!(rect.size.width > 0) || !(rect.size.height > 0) ||
        !isfinite(rect.origin.x) || !isfinite(rect.origin.y))
        return; {
        /* Fixed batch, flushed as it fills: the perimeter is the caller's number, not ours. */
        NSRect rects[256];
        int count = 0;
        int x, y, maxx = NSMaxX(rect), maxy = NSMaxY(rect);
        BOOL on = NO;
        CGContextRef port = NSCurrentGraphicsPort();

#define CIDER_EMIT(r)                                     \
    do {                                                  \
        rects[count++] = (r);                             \
        if (count == (int) (sizeof(rects) / sizeof(rects[0]))) { \
            CGContextFillRects(port, rects, count);       \
            count = 0;                                    \
        }                                                 \
    } while (0)

        for (x = rect.origin.x; x < maxx; x++, on = !on)
            if (on)
                CIDER_EMIT(NSMakeRect(x, rect.origin.y, 1, 1));

        for (y = rect.origin.y; y < maxy; y++, on = !on)
            if (on)
                CIDER_EMIT(NSMakeRect(maxx - 1, y, 1, 1));

        for (x = maxx; --x >= rect.origin.x; on = !on)
            if (on)
                CIDER_EMIT(NSMakeRect(x, maxy, 1, 1));

        for (y = maxy; --y >= rect.origin.y; on = !on)
            if (on)
                CIDER_EMIT(NSMakeRect(rect.origin.x, y, 1, 1));

#undef CIDER_EMIT

        if (count > 0)
            CGContextFillRects(port, rects, count);
    }
}

static NSRect NSDrawColorRects(NSRect boundsRect, NSRect clipRect,
                               const NSRect *sides, NSColor **colors, int count)
{
    CGContextRef graphicsPort = NSCurrentGraphicsPort();

    CGContextSaveGState(graphicsPort);
    CGContextClipToRect(graphicsPort, clipRect);
    NSRectFillListWithColors(sides, colors, count);
    CGContextRestoreGState(graphicsPort);

    return boundsRect;
}

void NSDrawButton(NSRect rect, NSRect clipRect) {
    NSRect rects[7];
    NSColor *colors[7];
    int i;

    for (i = 0; i < 7; i++)
        rects[i] = rect;

    if ([[NSGraphicsContext currentContext] isFlipped]) {
        colors[0] = [NSColor blackColor];
        rects[0].origin.y += rect.size.height - 1;
        rects[0].size.height = 1;

        colors[1] = [NSColor blackColor];
        rects[1].origin.x += rect.size.width - 1;
        rects[1].size.width = 1;

        colors[2] = [NSColor darkGrayColor];
        rects[2].origin.x += 1;
        rects[2].size.width -= 2;
        rects[2].origin.y += rect.size.height - 2;
        rects[2].size.height = 1;

        colors[3] = [NSColor darkGrayColor];
        rects[3].origin.x += rect.size.width - 2;
        rects[3].origin.y += 1;
        rects[3].size.width = 1;
        rects[3].size.height -= 2;

        colors[4] = [NSColor whiteColor];
        rects[4].size.height = 1;
        rects[4].size.width -= 1;

        colors[5] = [NSColor whiteColor];
        rects[5].size.width = 1;
        rects[5].size.height -= 1;

        colors[6] = [NSColor controlColor];
        rects[6].origin.x += 1;
        rects[6].origin.y += 1;
        rects[6].size.width -= 3;
        rects[6].size.height -= 3;
    } else {
        colors[0] = [NSColor blackColor];
        rects[0].size.height = 1;

        colors[1] = [NSColor blackColor];
        rects[1].origin.x += rect.size.width - 1;
        rects[1].size.width = 1;

        colors[2] = [NSColor darkGrayColor];
        rects[2].origin.x += 1;
        rects[2].origin.y += 1;
        rects[2].size.width -= 2;
        rects[2].size.height = 1;

        colors[3] = [NSColor darkGrayColor];
        rects[3].origin.x += rect.size.width - 2;
        rects[3].origin.y += 2;
        rects[3].size.width = 1;
        rects[3].size.height -= 2;

        colors[4] = [NSColor whiteColor];
        rects[4].origin.y += 1;
        rects[4].size.width = 1;
        rects[4].size.height -= 1;

        colors[5] = [NSColor whiteColor];
        rects[5].origin.y += rect.size.height - 1;
        rects[5].size.width -= 1;
        rects[5].size.height = 1;

        colors[6] = [NSColor controlColor];
        rects[6].origin.x += 1;
        rects[6].origin.y += 2;
        rects[6].size.width -= 3;
        rects[6].size.height -= 3;
    }

    NSDrawColorRects(rect, clipRect, rects, colors, 7);
}

void NSDrawGrayBezel(NSRect rect, NSRect clipRect) {
    NSRect rects[4];
    NSColor *colors[4];
    int i;

    for (i = 0; i < 4; i++)
        rects[i] = rect;

    if ([[NSGraphicsContext currentContext] isFlipped]) {
        colors[0] = [NSColor whiteColor];
        colors[1] = [NSColor controlShadowColor];
        rects[1].size.width -= 1;
        rects[1].size.height -= 1;
        colors[2] = [NSColor blackColor];
        rects[2].origin.x += 1;
        rects[2].origin.y += 1;
        rects[2].size.width -= 3;
        rects[2].size.height -= 3;
        colors[3] = [NSColor controlColor];
        rects[3].origin.x += 2;
        rects[3].origin.y += 2;
        rects[3].size.width -= 3;
        rects[3].size.height -= 3;
    } else {
        colors[0] = [NSColor whiteColor];
        colors[1] = [NSColor controlShadowColor];
        rects[1].origin.y += 1;
        rects[1].size.width -= 1;
        rects[1].size.height -= 1;
        colors[2] = [NSColor blackColor];
        rects[2].origin.x += 1;
        rects[2].origin.y += 2;
        rects[2].size.width -= 3;
        rects[2].size.height -= 3;
        colors[3] = [NSColor controlColor];
        rects[3].origin.x += 2;
        rects[3].origin.y += 1;
        rects[3].size.width -= 3;
        rects[3].size.height -= 3;
    }

    NSDrawColorRects(rect, clipRect, rects, colors, 4);
}

void NSDrawWhiteBezel(NSRect rect, NSRect clipRect) {
    NSRect rects[7];
    NSColor *colors[7];
    int i;

    for (i = 0; i < 7; i++)
        rects[i] = rect;

    if ([[NSGraphicsContext currentContext] isFlipped]) {
        colors[0] = [NSColor whiteColor];
        colors[1] = [NSColor controlShadowColor];
        rects[1].size.height = 1;
        colors[2] = [NSColor controlShadowColor];
        rects[2].size.width = 1;
        rects[2].size.height -= 1;
        colors[3] = [NSColor controlColor];
        rects[3].origin.x += 1;
        rects[3].origin.y += 1;
        rects[3].size.width -= 2;
        rects[3].size.height -= 2;
        colors[4] = [NSColor blackColor];
        rects[4].origin.x += 1;
        rects[4].origin.y += 1;
        rects[4].size.width -= 2;
        rects[4].size.height = 1;
        colors[5] = [NSColor blackColor];
        rects[5].origin.x += 1;
        rects[5].origin.y += 1;
        rects[5].size.width = 1;
        rects[5].size.height -= 3;
        colors[6] = [NSColor whiteColor];
        rects[6].origin.x += 2;
        rects[6].origin.y += 2;
        rects[6].size.width -= 4;
        rects[6].size.height -= 4;
    } else {
        colors[0] = [NSColor whiteColor];
        colors[1] = [NSColor controlShadowColor];
        rects[1].origin.y += rect.size.height;
        rects[1].size.height = 1;
        colors[2] = [NSColor controlShadowColor];
        rects[2].size.width = 1;
        rects[2].origin.y += 1;
        rects[2].size.height -= 1;
        colors[3] = [NSColor controlColor];
        rects[3].origin.x += 1;
        rects[3].origin.y += 1;
        rects[3].size.width -= 2;
        rects[3].size.height -= 2;
        colors[4] = [NSColor blackColor];
        rects[4].origin.x += 1;
        rects[4].origin.y += rect.size.height - 1;
        rects[4].size.width -= 2;
        rects[4].size.height = 1;
        colors[5] = [NSColor blackColor];
        rects[5].origin.x += 1;
        rects[5].origin.y += 2;
        rects[5].size.width = 1;
        rects[5].size.height -= 3;
        colors[6] = [NSColor whiteColor];
        rects[6].origin.x += 2;
        rects[6].origin.y += 2;
        rects[6].size.width -= 4;
        rects[6].size.height -= 3;
    }

    NSDrawColorRects(rect, clipRect, rects, colors, 7);
}

void NSDrawDarkBezel(NSRect rect, NSRect clipRect) {
    NSDrawGrayBezel(rect, clipRect);
}

void NSDrawLightBezel(NSRect rect, NSRect clipRect) {
    NSDrawWhiteBezel(rect, clipRect);
}

void NSDrawGroove(NSRect rect, NSRect clipRect) {
    NSRect rects[4];
    NSColor *colors[4];
    int i;

    for (i = 0; i < 4; i++)
        rects[i] = rect;

    if ([[NSGraphicsContext currentContext] isFlipped]) {
        colors[0] = [NSColor controlShadowColor];
        colors[1] = [NSColor whiteColor];
        rects[1].origin.x += 1;
        rects[1].origin.y += 1;
        colors[2] = [NSColor controlShadowColor];
        rects[2].origin.x += 2;
        rects[2].origin.y += 2;
        rects[2].size.width -= 3;
        rects[2].size.height -= 3;
        colors[3] = [NSColor controlColor];
        rects[3].origin.x += 2;
        rects[3].origin.y += 2;
        rects[3].size.width -= 4;
        rects[3].size.height -= 4;
    } else {
        colors[0] = [NSColor controlShadowColor];
        colors[1] = [NSColor whiteColor];
        rects[1].origin.x += 1;
        rects[1].size.height -= 1;
        colors[2] = [NSColor controlShadowColor];
        rects[2].origin.x += 2;
        rects[2].origin.y += 1;
        rects[2].size.width -= 3;
        rects[2].size.height -= 3;
        colors[3] = [NSColor controlColor];
        rects[3].origin.x += 2;
        rects[3].origin.y += 2;
        rects[3].size.width -= 4;
        rects[3].size.height -= 4;
    }

    NSDrawColorRects(rect, clipRect, rects, colors, 4);
}

void NSDrawWindowBackground(NSRect rect) {
    [[NSColor windowBackgroundColor] setFill];
    NSRectFill(rect);
}

NSRect NSDrawTiledRects(NSRect bounds, NSRect clip, const NSRectEdge *sides,
                        const CGFloat *grays, int count)
{
    return bounds;
}

void NSHighlightRect(NSRect rect) {
    [[NSColor highlightColor] setFill];
    CGContextFillRect(NSCurrentGraphicsPort(), rect);
}

void NSCopyBits(int gState, NSRect rect, NSPoint point) {
    CGContextCopyBits(NSCurrentGraphicsPort(), rect, point, gState);
}

void NSBeep() {
    [[NSDisplay currentDisplay] beep];
}

void NSEnableScreenUpdates(void) {
}

void NSDisableScreenUpdates(void) {
}

void NSShowAnimationEffect(NSAnimationEffect effect, NSPoint center,
                           NSSize size, id delegate, SEL didEndSelector,
                           void *context)
{
    [NSPoofAnimation poofAtLocation: center
                               size: size
                  animationDelegate: delegate
                     didEndSelector: didEndSelector
                        contextInfo: context];
}

/*
 * THE FOCUS RING, which was a STUB that printed and drew nothing.
 *
 * A control that wants a focus ring calls NSSetFocusRingStyle and then FILLS its own shape: the
 * fill is the request, and AppKit turns it into a ring around that shape instead of a filled one.
 * With the call ignored, the fill went through as a fill -- LibreOffice draws focus this way, so a
 * focused control either showed nothing or showed a solid block where a ring belongs.
 *
 * The flag is consumed by the next fill, whichever funnel it comes through, which is exactly the
 * contract: one call, one shape.
 */
static BOOL sFocusRingPending = NO;
static NSFocusRingPlacement sFocusRingPlacement = NSFocusRingOnly;

void NSSetFocusRingStyle(NSFocusRingPlacement placement) {
    sFocusRingPending = YES;
    sFocusRingPlacement = placement;
    if (getenv("CIDER_TRACE_CELLS") != NULL) {
        static int said = 0;

        if (said < 3) {
            said++;
            fprintf(stderr, "CIDER_FOCUSRING placement=%d\n", (int) placement);
            fflush(stderr);
        }
    }
}

BOOL NSFocusRingDrawAroundRect(NSRect bounds) {
    if (!sFocusRingPending) {
        return NO;
    }
    sFocusRingPending = NO;

    if (sFocusRingPlacement == NSFocusRingBelow || NSIsEmptyRect(bounds)) {
        return YES;
    }

    /* Apple draws a soft blue ring a couple of points outside the shape. Two strokes, the outer one
     * fainter, is enough to read as a glow at this size without a blur. */
    NSRect outer = NSInsetRect(bounds, -2.5, -2.5);
    NSRect inner = NSInsetRect(bounds, -1.0, -1.0);
    NSBezierPath *outerPath = [NSBezierPath bezierPathWithRoundedRect: outer
                                                             xRadius: 5.0
                                                             yRadius: 5.0];
    NSBezierPath *innerPath = [NSBezierPath bezierPathWithRoundedRect: inner
                                                             xRadius: 4.0
                                                             yRadius: 4.0];

    [[NSColor colorWithCalibratedRed: 0.0 green: 0.478 blue: 1.0 alpha: 0.25] setStroke];
    [outerPath setLineWidth: 3.0];
    [outerPath stroke];
    [[NSColor colorWithCalibratedRed: 0.0 green: 0.478 blue: 1.0 alpha: 0.75] setStroke];
    [innerPath setLineWidth: 1.5];
    [innerPath stroke];

    return YES;
}

void NSRectFillListWithColorsUsingOperation(const NSRect *rects, NSColor *const *colors,
                                            NSInteger count, NSCompositingOperation operation)
{
    CGContextRef context = NSCurrentGraphicsPort();
    NSInteger i;

    CGContextSaveGState(context);
    CGContextSetBlendMode(context, blendModeForCompositeOp(operation));
    for (i = 0; i < count; i++) {
        [colors[i] setFill];
        /* A transparent Copy fill is a NO-OP, not a hole punched through what is underneath. */
        if (operation == NSCompositeCopy && ciderLayerBackingEnabled()) {
            O2ColorRef fill = O2ContextFillColor((O2ContextRef) context);

            if (fill != NULL && O2ColorGetAlpha(fill) <= 0.0) {
                continue;
            }
        }
        if (rects[i].size.width > 0 && rects[i].size.height > 0) {
            CGContextFillRect(context, rects[i]);
        }
    }
    CGContextRestoreGState(context);
}

/* The three this backend can actually allocate, smallest first, terminated by zero as callers expect. */
static const NSWindowDepth _ciderWindowDepths[] = {
    NSWindowDepthTwentyfourBitRGB,
    NSWindowDepthSixtyfourBitRGB,
    NSWindowDepthOnehundredtwentyeightBitRGB,
    0
};

const NSWindowDepth *NSAvailableWindowDepths(void) {
    return _ciderWindowDepths;
}

NSWindowDepth NSBestDepth(NSString *colorSpace, NSInteger bps, NSInteger bpp, BOOL planar,
                          BOOL *exactMatch)
{
    NSWindowDepth chosen;
    NSInteger got;

    if (bps <= 8) {
        chosen = NSWindowDepthTwentyfourBitRGB;
        got = 8;
    } else if (bps <= 16) {
        chosen = NSWindowDepthSixtyfourBitRGB;
        got = 16;
    } else {
        chosen = NSWindowDepthOnehundredtwentyeightBitRGB;
        got = 32;
    }
    /* Every depth here is packed RGB, so a planar request is answered but never matched. */
    if (exactMatch != NULL) {
        *exactMatch = (got == bps) && !planar;
    }
    return chosen;
}
