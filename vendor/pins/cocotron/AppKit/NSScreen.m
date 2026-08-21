/* Copyright (c) 2006-2007 Christopher J. W. Lloyd

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

// Original - Christopher Lloyd <cjwl@objc.net>
#import <AppKit/NSApplication.h>
#import <AppKit/NSDisplay.h>
#import <AppKit/NSGraphics.h>
#import <AppKit/NSScreen.h>
#include <stdio.h>
#include <stdlib.h>
#import <AppKit/NSWindow.h>

NSNotificationName const NSScreenColorSpaceDidChangeNotification = @"NSScreenColorSpaceDidChangeNotification";

@implementation NSScreen

/*
 * THE NAME A USER WOULD SEE for this screen. It has been in AppKit since 10.15 and an application
 * that lists displays calls it: iTerm2 does while it finishes launching, and the unrecognized
 * selector terminated it.
 *
 * There is one display here and it comes from the compositor, which does not hand out a marketing
 * name, so this answers a plain descriptive one rather than inventing a model. That is what macOS
 * does for a display whose name it cannot read.
 */
- (NSString *) localizedName {
    return @"Display";
}


- initWithFrame: (NSRect) frame visibleFrame: (NSRect) visibleFrame {
    _frame = frame;
    _visibleFrame = visibleFrame;
    return self;
}

- (void) dealloc {
    if (_edid)
        [_edid release];
    [super dealloc];
}

+ (NSScreen *) mainScreen {
    NSScreen *result = [[NSApp keyWindow] screen];

    if (result == nil)
        result = [[self screens] objectAtIndex: 0];

    return result;
}

/*
 * NO, AND SAYING SO IS THE WHOLE FEATURE. macOS answers this from the Mission Control preference
 * that gives each display its own set of Spaces; there is one screen here and no Spaces at all.
 *
 * MoneyMoney asks it inside -[NSWindow setFrameAutosaveName:], which is early enough in window setup
 * that an unrecognized selector there leaves the window half built. The application CATCHES the
 * exception, so nothing crashes and nothing draws either, which is the shape described in the plan:
 * a caught exception hides a whole feature.
 */
+ (BOOL) screensHaveSeparateSpaces {
    return NO;
}

+ (NSArray *) screens {
    return [[NSDisplay currentDisplay] screens];
}

- (NSWindowDepth) depth {
    return _depth;
}

- (NSRect) frame {
    return _frame;
}

- (NSRect) visibleFrame {
    /* WHAT A WINDOW IS SIZED AGAINST. An application that computes its first window from the
     * visible frame gets whatever this says, and a zero here is a window with no content area,
     * which is how a terminal ends up reporting a width of minus one. */
    /* NON EMPTY, not merely set: a harness that forwards CIDER_TRACE_SCREEN=${CIDER_TRACE_SCREEN:-}
     * passes an EMPTY STRING when it is unset, and getenv answers "" for that, which is not NULL. */
    const char *trace = getenv("CIDER_TRACE_SCREEN");
    if (trace != NULL && *trace != '\0') {
        static int spoken = 0;
        if (spoken < 4) {
            spoken++;
            fprintf(stderr, "CIDER_SCREEN frame=%gx%g+%g+%g visible=%gx%g+%g+%g\n",
                    _frame.size.width, _frame.size.height, _frame.origin.x, _frame.origin.y,
                    _visibleFrame.size.width, _visibleFrame.size.height, _visibleFrame.origin.x,
                    _visibleFrame.origin.y);
            fflush(stderr);
        }
    }
    return _visibleFrame;
}

- (CGFloat) userSpaceScaleFactor {
    return 1.0;
}

/*
 * The pixel-to-point ratio, 10.7 and later, and the replacement for -userSpaceScaleFactor above.
 * Its absence is not a missing feature but a TERMINATED PROCESS: an unrecognised selector raises,
 * and applications call this on ordinary layout paths without expecting it to fail. LibreOffice
 * dies here on startup.
 *
 * ONE, because that is what this screen is. The Wayland display backend already divides the
 * wl_output mode by the output scale before it reports a frame, so the rectangle above is in
 * points and the ratio between the two is exactly 1. Reporting the output scale here as well
 * would apply it twice.
 */
- (CGFloat) backingScaleFactor {
    return 1.0;
}

- (id) description {
    return [NSString stringWithFormat: @"< %@ - frame %@, visible %@ >",
                                       [super description],
                                       NSStringFromRect(_frame),
                                       NSStringFromRect(_visibleFrame)];
}

/*
 * AN EMPTY DICTIONARY IS A WRONG ANSWER, not a missing one. Every key here is documented, and an
 * application reads them with objectForKeyedSubscript: and sends the result a message: a nil value
 * then answers zero without any error at all, so the caller scales by nothing and shows nothing.
 *
 * Swift Publisher builds its canvas that way. Its view constructor keeps a static
 *
 *     fk = [[[NSScreen mainScreen] deviceDescription][NSDeviceResolution] sizeValue].width
 *
 * and gives every canvas a zoom of fk / 72. With no NSDeviceResolution that is a zoom of ZERO, so
 * the page collapsed to nothing and the geometry that divides by it produced nan by nan, which the
 * application reported against its own canvas and which read for days like a drawing fault.
 *
 * NSDeviceResolution is in dots per inch, and a point IS a seventy-second of an inch, so a screen
 * whose frame is already in points reports 72 times its backing scale. The other keys are what a
 * screen device is: it is a screen, and it draws eight bits per sample of calibrated RGB, which is
 * what every surface this backend allocates actually is. NSBitsPerSampleFromDepth and
 * NSColorSpaceFromDepth would be the general way to say that, and neither is declared in these
 * headers, so an undeclared call would have compiled as returning int and gone into the dictionary
 * as a non object.
 */
- (NSDictionary<NSDeviceDescriptionKey, id> *) deviceDescription {
    CGFloat dpi = 72.0 * [self backingScaleFactor];

    return @{
        NSDeviceResolution : [NSValue valueWithSize: NSMakeSize(dpi, dpi)],
        NSDeviceSize : [NSValue valueWithSize: _frame.size],
        NSDeviceIsScreen : @"YES",
        NSDeviceBitsPerSample : [NSNumber numberWithInt: 8],
        NSDeviceColorSpaceName : NSCalibratedRGBColorSpace,
    };
}

@end

@implementation NSScreen (Darling)
- (NSData *) edid {
    return self->_edid;
}

- (void) setEdid: (NSData *) data {
    NSData *old = self->_edid;
    self->_edid = [data retain];
    [old release];
}

- (CGDirectDisplayID) cgDirectDisplayID {
    return self->_directDisplayID;
}

- (void) setCgDirectDisplayID: (CGDirectDisplayID) displayID {
    self->_directDisplayID = displayID;
}

@end
