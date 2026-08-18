#include <stdio.h>
#include <stdlib.h>
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
#import <Onyx2D/O2DataProvider.h>
#import <Onyx2D/O2Exceptions.h>
#import <Onyx2D/O2Image.h>
#import <Onyx2D/O2ImageSource.h>
#import <Foundation/NSDictionary.h>
#import <Foundation/NSValue.h>

NSString *kO2ImagePropertyDPIWidth = @"DPIWidth";
NSString *kO2ImagePropertyDPIHeight = @"DPIHeight";
NSString *kO2ImagePropertyPixelHeight = @"PixelHeight";
NSString *kO2ImagePropertyPixelWidth = @"PixelWidth";
NSString *kO2ImagePropertyOrientation = @"Orientation";

NSString *kO2ImagePropertyTIFFDictionary = @"{TIFF}";
NSString *kO2ImagePropertyExifDictionary = @"{Exif}";

NSString *kO2ImagePropertyTIFFXResolution = @"XResolution";
NSString *kO2ImagePropertyTIFFYResolution = @"YResolution";
NSString *kO2ImagePropertyTIFFOrientation = @"Orientation";

@interface _O2ImageSource : O2ImageSource
@end

@implementation O2ImageSource

+ (O2ImageSourceRef) newImageSourceWithDataProvider: (O2DataProvider *) provider
                                            options: (CFDictionaryRef) options
{
    NSString *classes[] = {@"O2ImageSource_PNG",
                           @"O2ImageSource_TIFF",
                           @"O2ImageSource_JPEG",
                           @"O2ImageSource_BMP",
                           @"O2ImageSource_GIF",
                           @"O2ImageSource_ICNS",
                           nil};
    int i;

    for (i = 0; classes[i] != nil; i++) {
        Class cls = NSClassFromString(classes[i]);

        if ([cls isPresentInDataProvider: provider]) {
            [provider rewind];
            if (getenv("CIDER_TRACE_IMAGESOURCE") != NULL) {
                fprintf(stderr, "CIDER_IMAGESOURCE matched %s\n", [classes[i] UTF8String]);
                fflush(stderr);
            }
            /* BRACKETED, because the matched line prints BEFORE the decoder is built and a decoder
             * that never returns looks exactly like one that was never asked. MoneyMoney dies with
             * two of these matched lines as the last thing it ever says. */
            id source = [[cls alloc] initWithDataProvider: provider
                                                  options: (NSDictionary *) options];

            if (getenv("CIDER_TRACE_IMAGESOURCE") != NULL) {
                fprintf(stderr, "CIDER_IMAGESOURCE built %s -> %p\n", [classes[i] UTF8String],
                        (void *) source);
                fflush(stderr);
            }
            return source;
        }
    }

    /* SAY SO WHEN NOTHING RECOGNISES IT. A decoder that answers nil and a decoder that was never
     * asked look identical from the caller, and an application that quietly draws no picture is
     * exactly that ambiguity. */
    if (getenv("CIDER_TRACE_IMAGESOURCE") != NULL) {
        fprintf(stderr, "CIDER_IMAGESOURCE no decoder recognised the data\n");
        fflush(stderr);
    }
    return nil;
}

+ (O2ImageSourceRef) newImageSourceWithData: (CFDataRef) data
                                    options: (CFDictionaryRef) options
{
    O2DataProviderRef provider = O2DataProviderCreateWithCFData(data);
    O2ImageSourceRef result = [self newImageSourceWithDataProvider: provider
                                                           options: options];
    O2DataProviderRelease(provider);
    return result;
}

+ (O2ImageSourceRef) newImageSourceWithURL: (NSURL *) url
                                   options: (CFDictionaryRef) options
{
    O2DataProviderRef provider = [[O2DataProvider alloc] initWithURL: url];
    O2ImageSourceRef result = [self newImageSourceWithDataProvider: provider
                                                           options: options];
    O2DataProviderRelease(provider);
    return result;
}

+ (BOOL) isPresentInDataProvider: (O2DataProvider *) provider {
    return NO;
}

- initWithDataProvider: (O2DataProvider *) provider
               options: (NSDictionary *) options
{
    _provider = [provider retain];
    _options = [options retain];
    return self;
}

- (void) dealloc {
    [_provider release];
    [_options release];
    [super dealloc];
}

- (CFStringRef) type {
    O2InvalidAbstractInvocation();
    return nil;
}

- (NSUInteger) count {
    O2InvalidAbstractInvocation();
    return 0;
}

/* macOS ALWAYS reports PixelWidth and PixelHeight here, from the image itself and not from any
 * metadata block. Returning a dictionary without them is what made Swift Publisher log
 *   key 'PixelWidth' for '<path>' returns nil
 * a hundred times in one document load: a layout application asks for the pixel size of every
 * picture before it can place it. The keys are plain strings, the same ones ImageIO exports as
 * kCGImagePropertyPixelWidth and kCGImagePropertyPixelHeight. */
- (CFDictionaryRef) copyPropertiesAtIndex: (NSUInteger) index
                                  options: (CFDictionaryRef) options
{
    NSMutableDictionary *properties = [[NSMutableDictionary alloc] init];

    [self addPixelSizeAtIndex: index toProperties: properties];

    return (CFDictionaryRef) properties;
}

/* The general answer, correct for every format: decode and measure. A subclass that can read its
 * own header cheaply should override this rather than pay for a decode. */
- (void) addPixelSizeAtIndex: (NSUInteger) index
                toProperties: (NSMutableDictionary *) properties
{
    O2Image *image = [self createImageAtIndex: index options: NULL];

    if (image == nil)
        return;

    [properties setObject: [NSNumber numberWithUnsignedLong: O2ImageGetWidth((O2ImageRef) image)]
                   forKey: @"PixelWidth"];
    [properties setObject: [NSNumber numberWithUnsignedLong: O2ImageGetHeight((O2ImageRef) image)]
                   forKey: @"PixelHeight"];
    [image release];
}

- (O2Image *) createImageAtIndex: (NSUInteger) index
                         options: (CFDictionaryRef) options
{
    O2InvalidAbstractInvocation();
    return nil;
}

O2ImageRef O2ImageSourceCreateImageAtIndex(O2ImageSourceRef self, size_t index,
                                           CFDictionaryRef options)
{
    return [(O2ImageSource *) self createImageAtIndex: index options: options];
}

@end
