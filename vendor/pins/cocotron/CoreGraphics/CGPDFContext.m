/* Copyright (c) 2009 Christopher J. W. Lloyd <cjwl@objc.net>

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files(the "Software"), to deal in the
Software without restriction, including without limitation the rights to use,
copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the
Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE. */
#import <CoreGraphics/CGPDFContext.h>
#import <Onyx2D/O2PDFContext.h>

#include <CoreFoundation/CFData.h>
#include <CoreFoundation/CFDictionary.h>
#include <CoreFoundation/CFString.h>

const CFStringRef kCGPDFContextTitle = CFSTR("kCGPDFContextTitle");
const CFStringRef kCGPDFContextKeywords = CFSTR("kCGPDFContextKeywords");
const CFStringRef kCGPDFContextMediaBox = CFSTR("MediaBox");

CGContextRef CGPDFContextCreate(CGDataConsumerRef consumer,
                                const CGRect *mediaBox,
                                CFDictionaryRef auxiliaryInfo)
{
    return (CGContextRef)[[O2PDFContext alloc]
            initWithConsumer: (O2DataConsumer*)consumer
                    mediaBox: mediaBox
               auxiliaryInfo: (NSDictionary *) auxiliaryInfo];
}

COREGRAPHICS_EXPORT void CGPDFContextClose(CGContextRef self) {
    [self close];
}

/*
 * THE OTHER TWO PIECES OF METADATA a PDF carries in its document information dictionary. Title and
 * Keywords were already here; an application that fills in who made the document needs these.
 */
const CFStringRef kCGPDFContextAuthor = CFSTR("kCGPDFContextAuthor");
const CFStringRef kCGPDFContextCreator = CFSTR("kCGPDFContextCreator");

/*
 * WRITING A PDF STRAIGHT TO A FILE, which is what an application that exports a document does. The
 * consumer form above already existed and this is the same context with a file behind it, so the
 * only thing that can fail is opening the URL.
 */
CGContextRef CGPDFContextCreateWithURL(CFURLRef url, const CGRect *mediaBox,
                                       CFDictionaryRef auxiliaryInfo) {
    CGDataConsumerRef consumer = CGDataConsumerCreateWithURL(url);

    if (consumer == NULL)
        return NULL;

    CGContextRef result = CGPDFContextCreate(consumer, mediaBox, auxiliaryInfo);

    CGDataConsumerRelease(consumer);

    return result;
}

/*
 * A PAGE AT A TIME. The page dictionary can name a MediaBox of its own, which is how a document
 * with a mixture of page sizes is written; without one the page takes the size the context was
 * created with, which is what the null below means to O2PDFContext.
 */
void CGPDFContextBeginPage(CGContextRef context, CFDictionaryRef pageInfo) {
    CGRect mediaBox;
    const CGRect *box = NULL;
    CFTypeRef value =
            (pageInfo != NULL) ? CFDictionaryGetValue(pageInfo, kCGPDFContextMediaBox) : NULL;

    if (value != NULL && CFGetTypeID(value) == CFDataGetTypeID()
        && CFDataGetLength((CFDataRef) value) == (CFIndex) sizeof(CGRect)) {
        CFDataGetBytes((CFDataRef) value, CFRangeMake(0, sizeof(CGRect)), (UInt8 *) &mediaBox);
        box = &mediaBox;
    }

    [(O2Context *) context beginPage: box];
}

void CGPDFContextEndPage(CGContextRef context) {
    [(O2Context *) context endPage];
}
