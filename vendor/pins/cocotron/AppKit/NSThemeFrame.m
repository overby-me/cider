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
#import <AppKit/NSColor.h>
#import <AppKit/NSGraphics.h>
#import <AppKit/NSImage.h>
#import <AppKit/NSMainMenuView.h>
#import <AppKit/NSMenuView.h>
#import <AppKit/NSBezierPath.h>
#import <AppKit/NSFont.h>
#import <AppKit/NSParagraphStyle.h>
#import <AppKit/NSStringDrawing.h>
#import <AppKit/NSThemeFrame.h>
#import <AppKit/NSPanel.h>

/* Measured off the macOS alert in Downloads/macos-images. */
#define CIDER_PANEL_CORNER_RADIUS 10.0
#import <objc/runtime.h>
#import <AppKit/NSToolbarView.h>
#import <AppKit/NSWindow-Private.h>
#import <AppKit/NSWindow.h>

@interface NSWindow (private)
- (BOOL) hasMainMenu;
+ (BOOL) hasMainMenuForStyleMask: (NSUInteger) styleMask;
@end

@implementation NSThemeFrame

- (BOOL) isOpaque {
    return YES;
}

- (NSWindowBorderType) windowBorderType {
    return _borderType;
}

- (void) setWindowBorderType: (NSWindowBorderType) borderType {
    _borderType = borderType;
    [self setNeedsDisplay: YES];
}

- (NSColor *) _borderColorForNSShowAllViews {
    return [NSColor yellowColor];
}

/*
 * THE MACOS TITLE BAR, drawn here because nothing else will draw one.
 *
 * The line this replaces read "when/if we add titlebars and such do it here", and on Apple systems
 * the window server draws it, so cocotron never needed to. On Wayland nobody does: a compositor
 * decorates only if the client asks it to through the decoration protocol, and what it draws is the
 * DESKTOP style. An application whose point is to look like macOS wants the macOS one.
 *
 * What is drawn, top to bottom: a light bar the height the backend reserves, a hairline under it,
 * the three lights on the left at the sizes Apple uses (12 point circles, 8 apart, 20 from the
 * left edge, centred in the bar), and the window title centred in the bar in the small system font.
 * The lights are drawn dimmed when the window is not key, which is also what Apple does.
 *
 * It is DRAWING ONLY so far. Clicking a light does nothing yet and the bar cannot be dragged; that
 * is the next step and is written down in docs/wayland-port.md rather than implied by a button that
 * does not work.
 */
- (void) _ciderDrawTitleBarInBounds: (NSRect) bounds {
    NSWindow *window = [self window];

    if (([window styleMask] & NSTitledWindowMask) == 0) {
        return;
    }

    const CGFloat barHeight = 22.0;

    if (bounds.size.height < barHeight || bounds.size.width < 80.0) {
        return;
    }

    /* The bar is at the TOP, which in this coordinate space is the high end of y. */
    NSRect bar = NSMakeRect(bounds.origin.x, NSMaxY(bounds) - barHeight, bounds.size.width,
                            barHeight);

    [[NSColor colorWithCalibratedWhite: 0.925 alpha: 1.0] setFill];
    NSRectFill(bar);
    [[NSColor colorWithCalibratedWhite: 0.72 alpha: 1.0] setFill];
    NSRectFill(NSMakeRect(bar.origin.x, bar.origin.y, bar.size.width, 1.0));

    const BOOL isKey = [window isKeyWindow];
    const CGFloat lightDiameter = 12.0;
    const CGFloat lightGap = 8.0;
    const CGFloat lightY = bar.origin.y + (barHeight - lightDiameter) / 2.0;
    /* THIRTEEN FROM THE EDGE, which is where Apple puts the group. Twenty left them noticeably
     * further in than the real thing, which is the sort of difference that reads as wrong without
     * being namable. */
    CGFloat lightX = bar.origin.x + 13.0;

    NSColor *lights[3];
    if (isKey) {
        lights[0] = [NSColor colorWithCalibratedRed: 1.00 green: 0.37 blue: 0.35 alpha: 1.0];
        lights[1] = [NSColor colorWithCalibratedRed: 1.00 green: 0.74 blue: 0.20 alpha: 1.0];
        lights[2] = [NSColor colorWithCalibratedRed: 0.16 green: 0.79 blue: 0.25 alpha: 1.0];
    } else {
        lights[0] = [NSColor colorWithCalibratedWhite: 0.80 alpha: 1.0];
        lights[1] = lights[0];
        lights[2] = lights[0];
    }

    for (int i = 0; i < 3; i++) {
        NSRect light = NSMakeRect(lightX, lightY, lightDiameter, lightDiameter);

        [lights[i] setFill];
        [[NSBezierPath bezierPathWithOvalInRect: light] fill];
        [[NSColor colorWithCalibratedWhite: 0.0 alpha: 0.12] setStroke];
        [[NSBezierPath bezierPathWithOvalInRect: NSInsetRect(light, 0.5, 0.5)] stroke];
        lightX += lightDiameter + lightGap;
    }

    NSString *title = [window title];

    if ([title length] == 0) {
        return;
    }

    NSMutableParagraphStyle *centred =
            [[[NSParagraphStyle defaultParagraphStyle] mutableCopy] autorelease];
    [centred setAlignment: NSCenterTextAlignment];
    [centred setLineBreakMode: NSLineBreakByTruncatingTail];

    NSDictionary *attributes = [NSDictionary
            /* BOLD, as macOS has drawn window titles for years. titleBarFontOfSize gives the
             * regular face here, and next to a real title bar the difference is immediate. */
            dictionaryWithObjectsAndKeys: [NSFont boldSystemFontOfSize: 13.0], NSFontAttributeName,
                                          [NSColor colorWithCalibratedWhite: isKey ? 0.15 : 0.55
                                                                      alpha: 1.0],
                                          NSForegroundColorAttributeName, centred,
                                          NSParagraphStyleAttributeName, nil];
    NSSize size = [title sizeWithAttributes: attributes];
    NSRect titleRect = NSMakeRect(bar.origin.x + 70.0,
                                  bar.origin.y + (barHeight - size.height) / 2.0,
                                  MAX(bar.size.width - 140.0, 10.0), size.height);

    [title drawInRect: titleRect withAttributes: attributes];
}

- (void) drawRect: (NSRect) rect {
    NSRect bounds = [self bounds];
    CGFloat cheatSheet = 0;

    /* WHAT THIS FILL IS, when asked. This one covers the whole window, so anything the application
     * does not paint over is this colour, and that makes it the first suspect whenever a window
     * comes out a flat wrong colour. Saying which object it is separates a wrong colour from a dead
     * one. */
    if (getenv("CIDER_WAYLAND_TRACE_COLORS") != NULL) {
        NSColor *fill = [[self window] backgroundColor];
        NSColor *rgb = [fill colorUsingColorSpaceName: NSDeviceRGBColorSpace device: nil];
        CGFloat r = -1, g = -1, b = -1, a = -1;
        if (rgb != nil) {
            [rgb getRed: &r green: &g blue: &b alpha: &a];
        }
        NSLog(@"CIDER_THEMEFRAME fill=%@ class=%s rgba=%.3f,%.3f,%.3f,%.3f bounds=%.0fx%.0f", fill,
              fill ? object_getClassName(fill) : "nil", (double) r, (double) g, (double) b,
              (double) a, bounds.size.width, bounds.size.height);
    }

    /*
     * A PANEL IS ROUNDED, and a square one is one of the last things that says this is not a Mac.
     *
     * The backend already clears these surfaces to nothing and only fills what the application
     * paints, which is how a menu gets its rounded shape: the corners are simply never drawn. This
     * fill covered the whole rectangle, so an alert came out square against the macOS reference,
     * which is rounded at about ten points.
     *
     * SCOPED TO PANELS ON PURPOSE. macOS rounds document windows too, but their content view paints
     * to the edge and would square the corners straight back, so rounding them here would be a
     * change with no visible effect and some risk. Panels are what alerts and sheets are.
     */
    BOOL rounded = [[self window] isKindOfClass: [NSPanel class]];

    if (getenv("CIDER_TRACE_ALERT") != NULL && getenv("CIDER_TRACE_ALERT")[0] != '\0') {
        NSLog(@"CIDER_THEMEFRAME draw class=%s rounded=%d style=0x%lx bounds=%.0fx%.0f",
              object_getClassName([self window]), (int) rounded,
              (unsigned long) [[self window] styleMask], bounds.size.width, bounds.size.height);
    }

    [[[self window] backgroundColor] setFill];
    if (rounded) {
        [[NSBezierPath bezierPathWithRoundedRect: bounds
                                         xRadius: CIDER_PANEL_CORNER_RADIUS
                                         yRadius: CIDER_PANEL_CORNER_RADIUS] fill];
    } else {
        NSRectFill(bounds);
    }

    [self _ciderDrawTitleBarInBounds: bounds];

    switch (_borderType) {
    case NSNoBorder:
        break;

    case NSWindowToolTipBorderType:
        [[NSColor blackColor] setStroke];
        NSFrameRect(bounds);
        bounds = NSInsetRect(bounds, 1, 1);
        cheatSheet = 1;
        break;

    case NSWindowSheetBorderType:
        NSDrawButton(bounds, bounds);
        bounds = NSInsetRect(bounds, 2, 2);
        cheatSheet = 2;
        break;
    }

    if ([[self window] isSheet])
        bounds.size.height += cheatSheet;

    /* The rounded fill above already covers this, and repeating it as a plain rectangle would put
     * the square corners straight back. */
    if (!rounded) {
        [[[self window] backgroundColor] setFill];
        NSRectFill([[[self window] contentView] frame]);
    }
}

- (void) resizeSubviewsWithOldSize: (NSSize) oldSize {
    NSView *menuView = nil;
    NSToolbarView *toolbarView = nil;
    NSView *contentView = nil;

    // tile the subviews, when/if we add titlebars and such do it here
    for (NSView *view in _subviews) {
        if ([view isKindOfClass: [NSMenuView class]])
            menuView = view;
        else if ([view isKindOfClass: [NSToolbarView class]])
            toolbarView = (NSToolbarView *) view;
        else
            contentView = view;
    }

    // subtracts menu height but not toolbar height
    NSRect contentFrame = [[[self window] class]
            contentRectForFrameRect: [self bounds]
                          styleMask: [[self window] styleMask]];

    // If the class thinks there is a menu but the instance does not want an
    // instance we need to add the menu height back to the content view as
    // contentRectForFrameRect subtracts it

    if ([[[self window] class]
                hasMainMenuForStyleMask: [[self window] styleMask]]) {
        if (![[self window] hasMainMenu])
            contentFrame.size.height += [NSMainMenuView menuHeight];
    }

    NSRect menuFrame = (menuView != nil) ? [menuView frame] : NSZeroRect;
    NSRect toolbarFrame =
            (toolbarView != nil) ? [toolbarView frame] : NSZeroRect;

    menuFrame.origin.y = NSMaxY(contentFrame);
    menuFrame.origin.x = contentFrame.origin.x;
    menuFrame.size.width = contentFrame.size.width;
    [menuView setFrame: menuFrame];

    toolbarFrame.origin.y = NSMaxY(contentFrame) - toolbarFrame.size.height;
    toolbarFrame.origin.x = contentFrame.origin.x;
    toolbarFrame.size.width = contentFrame.size.width;

    [toolbarView setFrame: toolbarFrame];
    [toolbarView layoutViews];

    contentFrame.size.height -= toolbarFrame.size.height;
    [contentView setFrame: contentFrame];
}

/*
 * THE TITLE BAR IS NOT DECORATION ONLY, and this is the half that makes it a title bar.
 *
 * A Wayland client cannot move or minimise ITSELF: it asks the compositor, and the ask carries the
 * serial of the event that caused it. Those three requests live on the platform window, which is
 * what -[NSWindow platformWindow] answers, and they are sent by NAME so this file does not have to
 * know anything about the backend beyond the fact that it is the one on the other side.
 *
 * The geometry repeats what -_ciderDrawTitleBarInBounds: draws, deliberately: a hit target that is
 * computed differently from the thing it is under is a hit target that drifts.
 */
- (BOOL) _ciderHandleTitleBarMouseDown: (NSEvent *) event {
    NSWindow *window = [self window];

    if (([window styleMask] & NSTitledWindowMask) == 0) {
        return NO;
    }

    NSRect bounds = [self bounds];
    const CGFloat barHeight = 22.0;
    NSPoint point = [self convertPoint: [event locationInWindow] fromView: nil];

    if (point.y < NSMaxY(bounds) - barHeight || point.y > NSMaxY(bounds)) {
        return NO;
    }

    const CGFloat lightDiameter = 12.0;
    const CGFloat lightGap = 8.0;
    const CGFloat lightY = NSMaxY(bounds) - barHeight + (barHeight - lightDiameter) / 2.0;
    CGFloat lightX = bounds.origin.x + 20.0;
    id platform = [window platformWindow];

    for (int i = 0; i < 3; i++) {
        NSRect light = NSMakeRect(lightX, lightY, lightDiameter, lightDiameter);

        if (NSPointInRect(point, NSInsetRect(light, -2.0, -2.0))) {
            switch (i) {
            case 0:
                [window performClose: nil];
                break;
            case 1:
                if ([platform respondsToSelector: @selector(ciderSetMinimized)]) {
                    [platform performSelector: @selector(ciderSetMinimized)];
                }
                break;
            default:
                if ([platform respondsToSelector: @selector(ciderToggleMaximized)]) {
                    [platform performSelector: @selector(ciderToggleMaximized)];
                }
                break;
            }
            return YES;
        }
        lightX += lightDiameter + lightGap;
    }

    /* Anywhere else in the bar drags the window, which the compositor does for us: a client that
     * moved its own surface would fight whatever the compositor thinks the position is. */
    if ([platform respondsToSelector: @selector(ciderBeginInteractiveMove)]) {
        [platform performSelector: @selector(ciderBeginInteractiveMove)];
        return YES;
    }
    return NO;
}

- (void) mouseDown: (NSEvent *) event {
    if ([self _ciderHandleTitleBarMouseDown: event]) {
        return;
    }

    if (![[self window] isMovableByWindowBackground])
        return;

    NSPoint origin = [[self window] frame].origin;
    NSPoint firstLocation =
            [[self window] convertBaseToScreen: [event locationInWindow]];
    do {
        event = [[self window] nextEventMatchingMask: NSLeftMouseUpMask |
                                                      NSLeftMouseDraggedMask];

        NSPoint delta =
                [[self window] convertBaseToScreen: [event locationInWindow]];

        delta.x -= firstLocation.x;
        delta.y -= firstLocation.y;

        [[self window] setFrameOrigin: NSMakePoint(origin.x + delta.x,
                                                   origin.y + delta.y)];

    } while ([event type] != NSLeftMouseUp);
}

@end
