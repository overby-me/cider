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

#import <Foundation/NSData.h>
#import <Foundation/NSString.h>
#import <Onyx2D/O2ColorSpace.h>
#import <Onyx2D/O2DataProvider.h>
#import <Onyx2D/O2Image.h>
#import <Onyx2D/O2ImageSource_JPEG.h>
#import <Onyx2D/O2ImageSource_TIFF.h>

#import <Onyx2D/O2Defines_libjpeg.h>

#ifdef LIBJPEG_PRESENT
#import <Onyx2D/O2ImageDecoder_JPEG_libjpeg.h>
#else
#import <Onyx2D/O2ImageDecoder_JPEG_stb.h>
#endif

#import <Onyx2D/O2EXIFDecoder.h>

#import <assert.h>
#import <string.h>

@implementation O2ImageSource_JPEG

static O2ImageDecoder *
createImageDecoderWithDataProvider(O2DataProviderRef dataProvider)
{
#ifdef LIBJPEG_PRESENT
    return [[O2ImageDecoder_JPEG_libjpeg alloc]
            initWithDataProvider: dataProvider];
#else
    return [[O2ImageDecoder_JPEG_stb alloc] initWithDataProvider: dataProvider];
#endif
}

NSData *O2DCTDecode(NSData *data, size_t *pBytesPerRow) {
    O2DataProviderRef dataProvider =
            O2DataProviderCreateWithCFData((CFDataRef) data);
    O2ImageDecoderRef decoder =
            createImageDecoderWithDataProvider(dataProvider);
    CFDataRef result = O2ImageDecoderCreatePixelData(decoder);

    if (pBytesPerRow != NULL) {
        *pBytesPerRow = O2ImageDecoderGetBytesPerRow(decoder);
    }

    [decoder release];
    O2DataProviderRelease(dataProvider);

    return (NSData *) result;
}

+ (BOOL) isPresentInDataProvider: (O2DataProvider *) provider {
    enum { signatureLength = 2 };
    unsigned char signature[signatureLength] = {0xFF, 0xD8};
    unsigned char check[signatureLength];
    NSInteger i, size = [provider getBytes: check
                                     range: NSMakeRange(0, signatureLength)];

    if (size != signatureLength)
        return NO;

    for (i = 0; i < signatureLength; i++)
        if (signature[i] != check[i])
            return NO;

    return YES;
}

- initWithDataProvider: (O2DataProviderRef) provider
               options: (NSDictionary *) options
{
    [super initWithDataProvider: provider options: options];
    return self;
}

- (void) dealloc {
    if (_jpg)
        CFRelease(_jpg);
    [super dealloc];
}

- (CFStringRef) type {
    return (CFStringRef) @"public.jpeg";
}

- (NSUInteger) count {
    return 1;
}

/* The frame header carries the size, so there is no need to decode a whole JPEG to answer for it.
 * Markers run 0xFF then a code; the SOFn ones hold precision, height and width in that order, and
 * 0xC4 (huffman tables), 0xC8 and 0xCC are NOT frame headers even though they sit in the range.
 * Returns NO if the file is not shaped like a JPEG, and the caller then falls back to decoding. */
static BOOL O2JPEGFrameSize(const unsigned char *bytes, unsigned long length, size_t *width,
                            size_t *height)
{
    unsigned long at = 2; /* past SOI */

    if (bytes == NULL || length < 4 || bytes[0] != 0xFF || bytes[1] != 0xD8)
        return NO;

    while (at + 3 < length) {
        unsigned char marker;
        unsigned long segment;

        if (bytes[at] != 0xFF) {
            at++; /* fill byte or padding, resynchronise */
            continue;
        }
        marker = bytes[at + 1];
        if (marker == 0xFF) {
            at++; /* run of fill bytes, the marker code is further along */
            continue;
        }
        if (marker == 0xD8 || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
            at += 2; /* no payload */
            continue;
        }
        if (marker == 0xD9 || marker == 0xDA)
            return NO; /* end of image, or entropy coded data with no frame header seen */

        if (at + 3 >= length)
            return NO;
        segment = ((unsigned long) bytes[at + 2] << 8) | bytes[at + 3];
        if (segment < 2)
            return NO;

        if (marker >= 0xC0 && marker <= 0xCF && marker != 0xC4 && marker != 0xC8 &&
            marker != 0xCC) {
            if (at + 9 >= length)
                return NO;
            *height = ((size_t) bytes[at + 5] << 8) | bytes[at + 6];
            *width = ((size_t) bytes[at + 7] << 8) | bytes[at + 8];
            return (*width > 0 && *height > 0) ? YES : NO;
        }
        at += 2 + segment;
    }
    return NO;
}

- (CFDictionaryRef) copyPropertiesAtIndex: (NSUInteger) idx
                                  options: (CFDictionaryRef) options
{
    if (_jpg == NULL) {
        _jpg = O2DataProviderCopyData(_provider);
    }
    const unsigned char *data = CFDataGetBytePtr(_jpg);
    unsigned long length = CFDataGetLength(_jpg);
    O2EXIFDecoder *exif =
            [[[O2EXIFDecoder alloc] initWithBytes: data
                                           length: length] autorelease];
    NSDictionary *tags = [exif tags];
    NSMutableDictionary *properties =
            tags != nil ? [tags mutableCopy] : [[NSMutableDictionary alloc] init];
    size_t width = 0, height = 0;

    /* EXIF is optional and most of these files have none, so the size has to come from the frame
     * header. Without it every property dictionary here was just the tags, which for a plain JPEG
     * means an EMPTY one. */
    if (O2JPEGFrameSize(data, length, &width, &height)) {
        [properties setObject: [NSNumber numberWithUnsignedLong: width] forKey: @"PixelWidth"];
        [properties setObject: [NSNumber numberWithUnsignedLong: height] forKey: @"PixelHeight"];
    } else if ([properties objectForKey: @"PixelWidth"] == nil) {
        [self addPixelSizeAtIndex: idx toProperties: properties];
    }

    return (CFDictionaryRef) properties;
}

- (O2ImageRef) createImageAtIndex: (NSUInteger) index
                          options: (CFDictionaryRef) options
{
    O2ImageDecoderRef decoder = createImageDecoderWithDataProvider(_provider);
    O2DataProviderRef provider = O2ImageDecoderCreatePixelDataProvider(decoder);

    O2Image *image = [[O2Image alloc]
               initWithWidth: O2ImageDecoderGetWidth(decoder)
                      height: O2ImageDecoderGetHeight(decoder)
            bitsPerComponent: O2ImageDecoderGetBitsPerComponent(decoder)
                bitsPerPixel: O2ImageDecoderGetBitsPerPixel(decoder)
                 bytesPerRow: O2ImageDecoderGetBytesPerRow(decoder)
                  colorSpace: O2ImageDecoderGetColorSpace(decoder)
                  bitmapInfo: O2ImageDecoderGetBitmapInfo(decoder)
                     decoder: decoder
                    provider: provider
                      decode: NULL
                 interpolate: NO
             renderingIntent: kO2RenderingIntentDefault];

    O2DataProviderRelease(provider);
    [decoder release];

    return image;
}

@end
