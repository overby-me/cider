/* Copyright (c) 2007 Christopher J. W. Lloyd

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

#import <CoreGraphics/CGColorSpace.h>
#import <Onyx2D/O2ColorSpace.h>
#include <string.h>

const CFStringRef kCGColorSpaceDisplayP3 = CFSTR("kCGColorSpaceDisplayP3");
const CFStringRef kCGColorSpaceGenericGray = CFSTR("kCGColorSpaceGenericGray");
const CFStringRef kCGColorSpaceGenericRGB = CFSTR("kCGColorSpaceGenericRGB");
const CFStringRef kCGColorSpaceGenericCMYK = CFSTR("kCGColorSpaceGenericCMYK");
const CFStringRef kCGColorSpaceGenericRGBLinear =
        CFSTR("kCGColorSpaceGenericRGBLinear");
const CFStringRef kCGColorSpaceAdobeRGB1998 =
        CFSTR("kCGColorSpaceAdobeRGB1998");
const CFStringRef kCGColorSpaceSRGB = CFSTR("kCGColorSpaceSRGB");
const CFStringRef kCGColorSpaceGenericGrayGamma2_2 =
        CFSTR("kCGColorSpaceGenericGrayGamma2_2");
const CFStringRef kCGColorSpaceGenericXYZ = CFSTR("kCGColorSpaceGenericXYZ");
const CFStringRef kCGColorSpaceGenericLab = CFSTR("kCGColorSpaceGenericLab");
const CFStringRef kCGColorSpaceACESCGLinear =
        CFSTR("kCGColorSpaceACESCGLinear");
const CFStringRef kCGColorSpaceITUR_709 = CFSTR("kCGColorSpaceITUR_709");
const CFStringRef kCGColorSpaceITUR_2020 = CFSTR("kCGColorSpaceITUR_2020");
const CFStringRef kCGColorSpaceROMMRGB = CFSTR("kCGColorSpaceROMMRGB");
const CFStringRef kCGColorSpaceDCIP3 = CFSTR("kCGColorSpaceDCIP3");
const CFStringRef kCGColorSpaceExtendedSRGB =
        CFSTR("kCGColorSpaceExtendedSRGB");
const CFStringRef kCGColorSpaceLinearSRGB = CFSTR("kCGColorSpaceLinearSRGB");
const CFStringRef kCGColorSpaceExtendedLinearSRGB =
        CFSTR("kCGColorSpaceExtendedLinearSRGB");
const CFStringRef kCGColorSpaceExtendedGray =
        CFSTR("kCGColorSpaceExtendedGray");
const CFStringRef kCGColorSpaceLinearGray = CFSTR("kCGColorSpaceLinearGray");
const CFStringRef kCGColorSpaceExtendedLinearGray =
        CFSTR("kCGColorSpaceExtendedLinearGray");

CGColorSpaceRef CGColorSpaceRetain(CGColorSpaceRef colorSpace) {
    return (CGColorSpaceRef)O2ColorSpaceRetain((O2ColorSpaceRef)colorSpace);
}

void CGColorSpaceRelease(CGColorSpaceRef colorSpace) {
    O2ColorSpaceRelease((O2ColorSpaceRef)colorSpace);
}

CGColorSpaceRef CGColorSpaceCreateDeviceRGB() {
    return (CGColorSpaceRef)O2ColorSpaceCreateDeviceRGB();
}

CGColorSpaceRef CGColorSpaceCreateDeviceGray() {
    return (CGColorSpaceRef)O2ColorSpaceCreateDeviceGray();
}

CGColorSpaceRef CGColorSpaceCreateDeviceCMYK() {
    return (CGColorSpaceRef)O2ColorSpaceCreateDeviceCMYK();
}

/*
 * A LAB SPACE ANSWERED WITH sRGB, WHICH IS A REAL SPACE AND NOT THE RIGHT ONE.
 *
 * There is no CIE Lab space in this implementation, and the alternative to answering is what used to
 * happen: the symbol resolved to a placeholder in the compat library, and iTerm2 jumped to it and
 * died with its nine windows already up, inside
 * +[iTermTextDrawingHelper colorForLineStyleMark:backgroundColor:].
 *
 * THE DIVERGENCE IS IN THE COLOUR, not in whether the program runs. A caller that converts through
 * this space gets its components interpreted as RGB, so a perceptual computation comes out
 * approximate. The white point and range arguments are accepted and ignored for the same reason.
 */
CGColorSpaceRef CGColorSpaceCreateLab(const CGFloat *whitePoint, const CGFloat *blackPoint,
                                      const CGFloat *range) {
    return (CGColorSpaceRef) O2ColorSpaceCreateDeviceRGB();
}

CGColorSpaceRef CGColorSpaceCreatePattern(CGColorSpaceRef baseSpace) {
    return (CGColorSpaceRef)O2ColorSpaceCreatePattern((O2ColorSpaceRef)baseSpace);
}

CGColorSpaceModel CGColorSpaceGetModel(CGColorSpaceRef self) {
    return (CGColorSpaceModel)O2ColorSpaceGetModel((O2ColorSpaceRef)self);
}

size_t CGColorSpaceGetNumberOfComponents(CGColorSpaceRef self) {
    return O2ColorSpaceGetNumberOfComponents((O2ColorSpaceRef)self);
}

CGColorSpaceRef CGColorSpaceCreateWithName(CFStringRef name) {
    return (CGColorSpaceRef) O2ColorSpaceCreateWithName(name);
}

CFStringRef CGColorSpaceGetName(CGColorSpaceRef colorSpace) {
    return O2ColorSpaceGetName((O2ColorSpaceRef)colorSpace);
}

CFStringRef CGColorSpaceCopyName(CGColorSpaceRef colorSpace) {
    CFStringRef name = O2ColorSpaceGetName((O2ColorSpaceRef) colorSpace);

    return name != NULL ? CFRetain(name) : NULL;
}

/*
 * NO PROFILE IS AN HONEST ANSWER, and callers are written for it: Skia asks for the ICC data of a
 * space and treats NULL as "this is sRGB, carry on". A fabricated profile would be worse than none.
 */
CFDataRef CGColorSpaceCopyICCData(CGColorSpaceRef colorSpace) {
    return NULL;
}

/*
 * The ALTERNATE space is what a reader that cannot parse the profile is told to use, so it is the
 * right answer here rather than a failure; with none given, three components mean RGB and one grey.
 */
CGColorSpaceRef CGColorSpaceCreateICCBased(size_t nComponents, const CGFloat *range,
                                           CGDataProviderRef profile,
                                           CGColorSpaceRef alternate) {
    if (alternate != NULL) {
        return (CGColorSpaceRef) O2ColorSpaceRetain((O2ColorSpaceRef) alternate);
    }
    return nComponents == 1 ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB();
}

/*
 * A NON INDEXED SPACE ANSWERS NULL AND ZERO rather than raising, which is what macOS does and what
 * lets a caller ask any space whether it has a palette.
 */
CGColorSpaceRef CGColorSpaceGetBaseColorSpace(CGColorSpaceRef self) {
    if (self == NULL || O2ColorSpaceGetModel((O2ColorSpaceRef) self) != kO2ColorSpaceModelIndexed) {
        return NULL;
    }
    return (CGColorSpaceRef) [(O2ColorSpace_indexed *) self baseColorSpace];
}

size_t CGColorSpaceGetColorTableCount(CGColorSpaceRef self) {
    if (self == NULL || O2ColorSpaceGetModel((O2ColorSpaceRef) self) != kO2ColorSpaceModelIndexed) {
        return 0;
    }
    /* hival is the LAST index, so the table holds one more entry than that. */
    return [(O2ColorSpace_indexed *) self hival] + 1;
}

void CGColorSpaceGetColorTable(CGColorSpaceRef self, uint8_t *table) {
    if (table == NULL || CGColorSpaceGetColorTableCount(self) == 0) {
        return;
    }
    O2ColorSpace_indexed *indexed = (O2ColorSpace_indexed *) self;
    size_t components = O2ColorSpaceGetNumberOfComponents([indexed baseColorSpace]);
    memcpy(table, [indexed paletteBytes], components * ([indexed hival] + 1));
}
