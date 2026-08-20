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

#import <AppKit/NSColor_CGColor.h>
#import <AppKit/NSColor_catalog.h>
#include <stdio.h>
#include <stdlib.h>
#import <AppKit/NSDisplay.h>
#import <AppKit/NSGraphics.h>

@interface NSColor (NSAppKitPrivate)
- (CGColorRef) CGColorRef;
@end

void NSColorSetCatalogColor(NSColorListName catalogName, NSColorName colorName,
                            NSColor *color);
NSColor *NSColorGetCatalogColor(NSColorListName catalogName,
                                NSColorName colorName);

@implementation NSColor_catalog

- initWithCatalogName: (NSColorListName) catalogName
            colorName: (NSColorName) colorName
                color: (NSColor *) color
{
    _catalogName = [catalogName copy];
    _colorName = [colorName copy];
    _color = [color copy];
    return self;
}

- (void) dealloc {
    [_colorName release];
    [_catalogName release];
    [_color release];
    NSDeallocateObject(self);
    return;
    [super dealloc];
}

- (BOOL) isEqual: otherObject {
    if (self == otherObject)
        return YES;

    if ([otherObject isKindOfClass: [self class]]) {
        NSColor_catalog *other = otherObject;

        return ([_catalogName isEqualToString: other->_catalogName] &&
                [_colorName isEqualToString: other->_colorName]);
    }

    return NO;
}

- (NSString *) description {
    return [NSString stringWithFormat: @"<%@ catalogName: %@ colorName: %@>",
                                       [[self class] description], _catalogName,
                                       _colorName];
}

+ (NSColor *) colorWithCatalogName: (NSColorListName) catalogName
                         colorName: (NSColorName) colorName
{
    return [[[self alloc]
            initWithCatalogName: catalogName
                      colorName: colorName
                          color: [[NSDisplay currentDisplay]
                                         colorWithName: colorName]]
            autorelease];
}

/*
 * A CATALOG COLOUR IS A NAME, AND THIS SYSTEM RESOLVES IT, NOT THE ONE THE NIB WAS WRITTEN ON.
 *
 * This is the archiving entry point: a nib stores a catalog colour as a catalog, a name, and the
 * value that name HAD when the nib was saved. It used to take that stored value and never ask
 * anybody, so every colour an application set in Interface Builder came from whatever version of
 * macOS its designer used.
 *
 * MoneyMoney's account list is what showed it. Its outline view asks for System
 * _sourceListBackgroundColor, whose stored fallback is System controlBackgroundColor, whose stored
 * fallback is a calibrated white of 0.602715373 from some much older release. The whole sidebar
 * came out filled with exactly that: a flat mid grey, 154 in every channel, where a source list
 * belongs. The stored value is a FALLBACK for a name this system does not know, not the answer.
 */
+ (NSColor *) colorWithCatalogName: (NSColorListName) catalogName
                         colorName: (NSColorName) colorName
                             color: (NSColor *) color
{
    NSColor *resolved = nil;

    /* Only the System catalog, because only that one is ours to answer for. An application with a
     * catalog of its own may well use a name that collides with a system one. */
    if ([catalogName isEqualToString: @"System"])
        resolved = [[NSDisplay currentDisplay] colorWithName: colorName];

    if (resolved == nil)
        resolved = NSColorGetCatalogColor(catalogName, colorName);

    if (resolved == nil) {
        NSColorSetCatalogColor(catalogName, colorName, color);
        resolved = color;
    }

    return [[[self alloc] initWithCatalogName: catalogName
                                    colorName: colorName
                                        color: resolved] autorelease];
}

- (NSColorSpaceName) colorSpaceName {
    return NSNamedColorSpace;
}

- (NSColorListName) catalogNameComponent {
    return _catalogName;
}

- (NSColorName) colorNameComponent {
    return _colorName;
}

- (NSImage *) patternImage {
    return [_color patternImage];
}

- (CGColorRef) CGColor {
    if (_color != nil)
        return [_color CGColor];

    return nil;
}

- (NSColor *) colorUsingColorSpaceName: (NSColorSpaceName) colorSpace {
    return [self colorUsingColorSpaceName: colorSpace device: nil];
}

- (NSColor *) colorUsingColorSpaceName: (NSColorSpaceName) colorSpace
                                device: (NSDictionary *) device
{
    if ([colorSpace isEqualToString: [self colorSpaceName]])
        return self;

    /*
     * THE RESULT IS NOT CACHED IN _color, AND THIS IS A USE AFTER FREE FIX.
     *
     * The line here used to be an assignment to _color, storing an AUTORELEASED object in an
     * instance variable with no retain and without releasing what was there. The catalog colour then
     * outlives the pool, and every later -setFill, -CGColor and -patternImage reads freed memory.
     *
     * What that looks like from outside is worth writing down, because nothing about it says "colour
     * object": every window in LibreOffice was filled with a FLAT colour that was the same across
     * the whole application and DIFFERENT ON EVERY RUN, purple, then green, then orange, while the
     * menu bar next to it stayed the correct grey. A wrong palette entry cannot vary per run, and
     * uninitialised pixels cannot be flat, and both were eliminated by measurement first. The system
     * colours are exactly the ones that go through this class, which is why they were the ones that
     * broke, and -[NSThemeFrame drawRect:] fills the whole window with the window backgroundColor,
     * which is a catalog colour.
     *
     * Caching was never right in any case: the answer depends on the colour space AND the device
     * asked for, so a cache keyed on neither returns the previous caller answer to the next one.
     */
    NSColor *converted = [_color colorUsingColorSpaceName: colorSpace device: device];

    /*
     * WHAT A NAMED COLOUR ACTUALLY ANSWERS. A caller that reads the components off a nil, or off a
     * colour whose entry is missing, gets zeros, and zeros are BLACK. That is invisible from the
     * outside: the control simply paints dark and nothing is logged anywhere. Silent by default,
     * on with CIDER_TRACE_SYSCOLOR.
     */
    if (getenv("CIDER_TRACE_SYSCOLOR") != NULL) {
        if (converted == nil) {
            fprintf(stderr, "CIDER_SYSCOLOR %s -> NIL (entry %s)\n", [_colorName UTF8String],
                    _color == nil ? "missing" : "present");
        } else {
            CGFloat r = 0, g = 0, b = 0, a = 0;

            @try {
                [converted getRed: &r green: &g blue: &b alpha: &a];
            } @catch (NSException *e) {
                fprintf(stderr, "CIDER_SYSCOLOR %s -> RAISED %s\n", [_colorName UTF8String],
                        [[e name] UTF8String]);
                return converted;
            }
            fprintf(stderr, "CIDER_SYSCOLOR %s -> %.3f,%.3f,%.3f,%.3f\n", [_colorName UTF8String],
                    (double) r, (double) g, (double) b, (double) a);
        }
    }
    return converted;
}

- (CGColorRef) CGColorRef {
    return [self CGColor];
}

/*
 * A NAMED COLOUR HAS TO ANSWER WHAT IT IS MADE OF, and this class answered nothing.
 *
 * NSColor_catalog implemented conversion, -setFill and -setStroke, and left every component
 * accessor to the abstract superclass, where -getRed:green:blue:alpha: and -getWhite:alpha: call
 * NSInvalidAbstractInvocation and RAISE. So an application that reads a system colour apart, which
 * is an ordinary thing to do when mixing one colour with another, got an exception instead of a
 * number, and an application that catches it is left with whatever its variables held.
 *
 * MoneyMoney reads textBackgroundColor, disabledControlTextColor and windowBackgroundColor and then
 * builds a colour with colorWithCalibratedRed:green:blue:alpha:; the band it fills came out solid
 * black, which is what those components are when nothing filled them in.
 *
 * Each of these converts first, which is exactly what the colour means: a name resolved through its
 * catalog and then expressed in the space being asked about.
 */
- (void) getRed: (CGFloat *) red
          green: (CGFloat *) green
           blue: (CGFloat *) blue
          alpha: (CGFloat *) alpha
{
    if (getenv("CIDER_TRACE_COLOR") != NULL) {
        static int printed;

        if (printed < 6) {
            printed++;
            fprintf(stderr, "CIDER_COLOR catalog %s asked for its components\n",
                    _colorName != nil ? [_colorName UTF8String] : "(nil)");
            fflush(stderr);
        }
    }

    [[self colorUsingColorSpaceName: NSCalibratedRGBColorSpace] getRed: red
                                                                 green: green
                                                                  blue: blue
                                                                 alpha: alpha];
}

- (void) getWhite: (CGFloat *) white alpha: (CGFloat *) alpha {
    [[self colorUsingColorSpaceName: NSCalibratedWhiteColorSpace] getWhite: white
                                                                    alpha: alpha];
}

- (void) getHue: (CGFloat *) hue
     saturation: (CGFloat *) saturation
     brightness: (CGFloat *) brightness
          alpha: (CGFloat *) alpha
{
    [[self colorUsingColorSpaceName: NSCalibratedRGBColorSpace] getHue: hue
                                                            saturation: saturation
                                                            brightness: brightness
                                                                 alpha: alpha];
}

- (void) getCyan: (CGFloat *) cyan
         magenta: (CGFloat *) magenta
          yellow: (CGFloat *) yellow
           black: (CGFloat *) black
           alpha: (CGFloat *) alpha
{
    [[self colorUsingColorSpaceName: NSDeviceCMYKColorSpace] getCyan: cyan
                                                            magenta: magenta
                                                             yellow: yellow
                                                              black: black
                                                              alpha: alpha];
}

- (CGFloat) alphaComponent {
    return [_color alphaComponent];
}

/*
 * A NAMED COLOUR WITH AN ALPHA APPLIED MUST STILL BE A COLOUR.
 *
 * The abstract -colorWithAlphaComponent: answers SELF for alpha 1 and NIL for anything less, and
 * this class did not override it. So [[NSColor textBackgroundColor] colorWithAlphaComponent: 0.5]
 * was nil, and a caller that then sends -set to it sets nothing at all, leaving whatever colour the
 * context already had. Converting first gives a real colour that can carry the alpha.
 */
- (NSColor *) colorWithAlphaComponent: (CGFloat) alpha {
    NSColor *converted = [self colorUsingColorSpaceName: NSCalibratedRGBColorSpace];

    if (getenv("CIDER_TRACE_COLOR") != NULL) {
        static int printed;

        if (printed < 12) {
            CGFloat r = 0, g = 0, b = 0, a = 0;

            printed++;
            [converted getRed: &r green: &g blue: &b alpha: &a];
            fprintf(stderr, "CIDER_COLOR catalog %s alpha %.2f over rgb %.3f %.3f %.3f\n",
                    _colorName != nil ? [_colorName UTF8String] : "(nil)", (double) alpha,
                    (double) r, (double) g, (double) b);
            fflush(stderr);
        }
    }

    return [converted colorWithAlphaComponent: alpha];
}

- (void) setFill {
    /* WHICH NAMED COLOUR, not just which components. The components alone cannot say whether a
     * black fill came from a system colour we get wrong or from the applications own choice. */
    if (getenv("CIDER_TRACE_COLOR") != NULL) {
        static int printed;

        if (printed < 40) {
            printed++;
            fprintf(stderr, "CIDER_COLOR catalog setFill %s\n",
                    _colorName != nil ? [_colorName UTF8String] : "(nil)");
            fflush(stderr);
        }
    }

    [_color setFill];
}

- (void) setStroke {
    [_color setStroke];
}

- (NSColor *) highlightWithLevel: (CGFloat) level {
    printf("STUB %s\n", __PRETTY_FUNCTION__);

    level = MIN(1.0, MAX(0.0, level));

    // TODO: verify if it is a use of blendedColorWithFraction:ofColor:
    // that use highlightColor
    // NSLog(@"Level %f", level);

    return self;
}

@end
