#import <ImageIO/CGImageSource.h>
#import <Onyx2D/O2ImageSource.h>
#import <Onyx2D/O2BitmapContext.h>
#import <Onyx2D/O2ColorSpace.h>
#import <Onyx2D/O2Image.h>

const CFStringRef kCGImageSourceCreateThumbnailFromImageAlways = CFSTR("kCGImageSourceCreateThumbnailFromImageAlways");
const CFStringRef kCGImageSourceCreateThumbnailFromImageIfAbsent = CFSTR("kCGImageSourceCreateThumbnailFromImageIfAbsent");
const CFStringRef kCGImageSourceCreateThumbnailWithTransform = CFSTR("kCGImageSourceCreateThumbnailWithTransform");
const CFStringRef kCGImageSourceShouldAllowFloat = CFSTR("kCGImageSourceShouldAllowFloat");
const CFStringRef kCGImageSourceShouldCache = CFSTR("kCGImageSourceShouldCache");
const CFStringRef kCGImageSourceThumbnailMaxPixelSize = CFSTR("kCGImageSourceThumbnailMaxPixelSize");

@interface _O2ImageSource : O2ImageSource
@end

CGImageSourceRef CGImageSourceCreateWithData(CFDataRef data,CFDictionaryRef options) {
	return (CGImageSourceRef)[O2ImageSource newImageSourceWithData:data options:options];
}

CGImageSourceRef CGImageSourceCreateWithURL(CFURLRef url,CFDictionaryRef options) {
	return (CGImageSourceRef)[O2ImageSource newImageSourceWithURL:(NSURL *)url options:options];
}

size_t CGImageSourceGetCount(CGImageSourceRef self) {
   return [self count];
}

CGImageRef CGImageSourceCreateImageAtIndex(CGImageSourceRef self,size_t index,CFDictionaryRef options) {
   return (CGImageRef)[self createImageAtIndex:index options:options];
}

CFDictionaryRef CGImageSourceCopyPropertiesAtIndex(CGImageSourceRef self, size_t index,CFDictionaryRef options) {
   return (CFDictionaryRef)[self copyPropertiesAtIndex:index options:options];
}


/*
 * THE ABSENCE OF THIS FUNCTION KILLED SWIFT PUBLISHER, and it did it in the least readable way
 * available: the call sites are lazily bound, so the process ran normally until the first document
 * layout reached one, and then dyld could not resolve it and aborted with a SIGILL through
 * dyld_stub_binder. From outside that looks like a trap somewhere in application code, which is
 * where several rungs went looking. The name only appears in abort_with_payload: Symbol not found:
 * _CGImageSourceCreateThumbnailAtIndex.
 *
 * The thumbnail is produced by decoding the image and scaling it down, which is what
 * kCGImageSourceCreateThumbnailFromImageAlways asks for anyway. Two option keys are honoured,
 * kCGImageSourceThumbnailMaxPixelSize and the two FromImage flags; a source with an embedded
 * thumbnail is not consulted for one, so kCGImageSourceCreateThumbnailFromImageIfAbsent behaves
 * exactly like Always. The orientation transform is NOT applied.
 */
CGImageRef CGImageSourceCreateThumbnailAtIndex(CGImageSourceRef self, size_t index, CFDictionaryRef options) {
   O2ImageRef full = (O2ImageRef)[(O2ImageSource *)self createImageAtIndex:index options:options];

   if (full == NULL)
    return NULL;

   size_t maxPixelSize = 0;

   if (options != NULL) {
    CFNumberRef requested = CFDictionaryGetValue(options, kCGImageSourceThumbnailMaxPixelSize);

    if (requested != NULL) {
     long value = 0;

     if (CFNumberGetValue(requested, kCFNumberLongType, &value) && value > 0)
      maxPixelSize = (size_t)value;
    }
   }

   size_t width = O2ImageGetWidth(full);
   size_t height = O2ImageGetHeight(full);
   size_t largest = (width > height) ? width : height;

   /* Already within the bound, or no bound given: the decoded image IS the thumbnail, and the
    * caller owns it either way. */
   if (maxPixelSize == 0 || largest <= maxPixelSize || largest == 0)
    return (CGImageRef)full;

   double scale = (double)maxPixelSize / (double)largest;
   size_t thumbWidth = (size_t)((double)width * scale + 0.5);
   size_t thumbHeight = (size_t)((double)height * scale + 0.5);

   if (thumbWidth < 1)
    thumbWidth = 1;
   if (thumbHeight < 1)
    thumbHeight = 1;

   O2ColorSpaceRef colorSpace = O2ColorSpaceCreateDeviceRGB();
   O2ContextRef context = O2BitmapContextCreate(NULL, thumbWidth, thumbHeight, 8, 0, colorSpace,
                                                kO2ImageAlphaPremultipliedFirst | kO2BitmapByteOrder32Little);

   if (context == NULL) {
    /* Scaling is the part that failed, not decoding, so hand back the full size image rather than
     * nothing: a thumbnail that is too big still draws. */
    O2ColorSpaceRelease(colorSpace);
    return (CGImageRef)full;
   }

   O2ContextDrawImage(context, O2RectMake(0, 0, thumbWidth, thumbHeight), full);

   O2ImageRef thumbnail = O2BitmapContextCreateImage(context);

   O2ContextRelease(context);
   O2ColorSpaceRelease(colorSpace);
   O2ImageRelease(full);

   return (CGImageRef)thumbnail;
}

CFStringRef CGImageSourceGetType(CGImageSourceRef self)
{
    return [(O2ImageSource*)self type];
}

CGImageSourceRef CGImageSourceCreateWithDataProvider(CGDataProviderRef provider, CFDictionaryRef options)
{
    printf("STUB %s\n", __PRETTY_FUNCTION__);
    return nil;
}
