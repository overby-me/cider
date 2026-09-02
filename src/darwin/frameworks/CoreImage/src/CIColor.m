/*
 This file is part of Darling.

 Copyright (C) 2017 Lubos Dolezel

 Darling is free software: you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation, either version 3 of the License, or
 (at your option) any later version.

 Darling is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with Darling.  If not, see <http://www.gnu.org/licenses/>.
*/

/*
 * A COLOUR AS FOUR NUMBERS, and why the forwarding stub that stood here killed iTerm2.
 *
 * There are two CIColor classes in this tree: this one and cocotron's in QuartzCore. An application
 * binds _OBJC_CLASS_$_CIColor to whichever library its own bind table names, so which of the two it
 * gets is decided at link time and not by us. iTerm2 names CoreImage, so it reached this stub, and a
 * stub answering every selector through forwardInvocation returns whatever happens to be in the
 * return register. Its blend does
 *
 *     CIColor *c = [[CIColor alloc] initWithColor: ...];
 *     const CGFloat *v = [c components];      // register junk, here NULL
 *     ... v[0] ...                            // movsd (%rax) -> SIGSEGV at address 0
 *
 * so the process died half a second in, before any window was drawn.
 *
 * COMPONENTS ARE ALWAYS FOUR, kept in the object rather than read back out of the CGColor. Callers
 * index [0] through [3] without asking how many there are, and a grey or pattern CGColor has fewer,
 * which would read past the end.
 */

#import <CoreImage/CIColor.h>

/* NSColor is AppKit and CoreImage does not link AppKit, so the accessor is declared, not imported. */
@interface NSObject (CiderNSColorComponents)
- (void) getRed: (CGFloat *) red
          green: (CGFloat *) green
           blue: (CGFloat *) blue
          alpha: (CGFloat *) alpha;
@end

@implementation CIColor {
    CGColorRef _cgColor;
    CGFloat _components[4];
}

+ (instancetype) colorWithCGColor: (CGColorRef) cgColor {
    return [[[self alloc] initWithCGColor: cgColor] autorelease];
}

+ (instancetype) colorWithRed: (CGFloat) red green: (CGFloat) green blue: (CGFloat) blue {
    return [[[self alloc] initWithRed: red green: green blue: blue alpha: 1.0] autorelease];
}

+ (instancetype) colorWithRed: (CGFloat) red
                        green: (CGFloat) green
                         blue: (CGFloat) blue
                        alpha: (CGFloat) alpha
{
    return [[[self alloc] initWithRed: red green: green blue: blue alpha: alpha] autorelease];
}

- (instancetype) initWithRed: (CGFloat) red
                       green: (CGFloat) green
                        blue: (CGFloat) blue
                       alpha: (CGFloat) alpha
{
    if ((self = [super init]) == nil)
        return nil;

    _components[0] = red;
    _components[1] = green;
    _components[2] = blue;
    _components[3] = alpha;
    _cgColor = CGColorCreateGenericRGB(red, green, blue, alpha);
    return self;
}

- (instancetype) initWithRed: (CGFloat) red green: (CGFloat) green blue: (CGFloat) blue {
    return [self initWithRed: red green: green blue: blue alpha: 1.0];
}

/* A grey CGColor carries two numbers and its first is the intensity, so it widens into r, g and b. */
- (instancetype) initWithCGColor: (CGColorRef) cgColor {
    CGFloat red = 0, green = 0, blue = 0, alpha = 1;

    if (cgColor != NULL) {
        const CGFloat *given = CGColorGetComponents(cgColor);
        size_t count = CGColorGetNumberOfComponents(cgColor);

        if (given != NULL && count >= 3) {
            red = given[0];
            green = given[1];
            blue = given[2];
            alpha = count >= 4 ? given[3] : 1.0;
        } else if (given != NULL && count >= 1) {
            red = green = blue = given[0];
            alpha = count >= 2 ? given[1] : 1.0;
        }
    }
    return [self initWithRed: red green: green blue: blue alpha: alpha];
}

/*
 * The argument is an NSColor. Its components are taken through getRed:green:blue:alpha: rather than
 * its CGColor because that getter converts to RGB, and a colour in any other space would otherwise
 * arrive here with the wrong number of components.
 */
- (instancetype) initWithColor: (id) color {
    CGFloat red = 0, green = 0, blue = 0, alpha = 1;

    if ([color respondsToSelector: @selector(getRed:green:blue:alpha:)])
        [color getRed: &red green: &green blue: &blue alpha: &alpha];

    return [self initWithRed: red green: green blue: blue alpha: alpha];
}

- (void) dealloc {
    CGColorRelease(_cgColor);
    [super dealloc];
}

- (const CGFloat *) components {
    return _components;
}

- (size_t) numberOfComponents {
    return 4;
}

- (CGColorRef) CGColor {
    return _cgColor;
}

- (CGColorSpaceRef) colorSpace {
    return _cgColor != NULL ? CGColorGetColorSpace(_cgColor) : NULL;
}

- (CGFloat) red {
    return _components[0];
}

- (CGFloat) green {
    return _components[1];
}

- (CGFloat) blue {
    return _components[2];
}

- (CGFloat) alpha {
    return _components[3];
}

- (NSString *) stringRepresentation {
    return [NSString stringWithFormat: @"%g %g %g %g",
                     _components[0], _components[1], _components[2], _components[3]];
}

- (NSString *) description {
    return [NSString stringWithFormat: @"<%@ %@>", [self class], [self stringRepresentation]];
}

@end
