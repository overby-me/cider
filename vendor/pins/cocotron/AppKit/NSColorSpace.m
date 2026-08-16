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

#import <AppKit/NSColorSpace.h>
#import <Foundation/NSRaise.h>

// not sure where these belong
NSString *const _NSColorCoreUICatalogMainBundleID =
        @"_NSColorCoreUICatalogMainBundleID";
NSString *const _NSColorCoreUICatalogNamePrefix =
        @"_NSColorCoreUICatalogNamePrefix";

@implementation NSColorSpace

+ (NSColorSpace *) sRGBColorSpace {
    CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    NSColorSpace *colorSpace =
            [[[self alloc] initWithCGColorSpace: srgb] autorelease];
    return colorSpace;
}

+ (NSColorSpace *) deviceRGBColorSpace {
    CGColorSpaceRef device = CGColorSpaceCreateDeviceRGB();
    NSColorSpace *result =
            [[[self alloc] initWithCGColorSpace: device] autorelease];

    CGColorSpaceRelease(device);

    return result;
}

/* THE GENERIC SPACES, which are what an application asks for when it wants a colour that does not
 * depend on a particular display. This backend draws everything through one RGB space, so generic
 * RGB IS sRGB here; saying so is better than an unrecognized selector, which is fatal. */
+ (NSColorSpace *) genericRGBColorSpace {
    return [self sRGBColorSpace];
}

+ (NSColorSpace *) genericGrayColorSpace {
    CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
    NSColorSpace *result = [[[self alloc] initWithCGColorSpace: gray] autorelease];

    CGColorSpaceRelease(gray);

    return result;
}

+ (NSColorSpace *) deviceGrayColorSpace {
    return [self genericGrayColorSpace];
}

+ (NSColorSpace *) genericCMYKColorSpace {
    CGColorSpaceRef cmyk = CGColorSpaceCreateDeviceCMYK();
    NSColorSpace *result = [[[self alloc] initWithCGColorSpace: cmyk] autorelease];

    CGColorSpaceRelease(cmyk);

    return result;
}

+ (NSColorSpace *) deviceCMYKColorSpace {
    return [self genericCMYKColorSpace];
}

- initWithCGColorSpace: (CGColorSpaceRef) cgColorSpace {
    _cgColorSpace = CGColorSpaceRetain(cgColorSpace);
    return self;
}

- (void) dealloc {
    CGColorSpaceRelease(_cgColorSpace);
    [super dealloc];
}

- (CGColorSpaceRef) CGColorSpace {
    return _cgColorSpace;
}

@end

NSString* _NSColorSpaceNameFromNum(void) {
    NSUnimplementedFunction();
    return nil;
};
