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

#import <CoreGraphics/CGDataProvider.h>
#import <Onyx2D/O2DataProvider.h>

CGDataProviderRef CGDataProviderRetain(CGDataProviderRef provider) {
    return (CGDataProviderRef)O2DataProviderRetain((O2DataProviderRef)provider);
}

void CGDataProviderRelease(CGDataProviderRef provider) {
    O2DataProviderRelease((O2DataProviderRef)provider);
}

CGDataProviderRef CGDataProviderCreateWithCFData(CFDataRef data) {
    return (CGDataProviderRef)O2DataProviderCreateWithCFData(data);
}

COREGRAPHICS_EXPORT CGDataProviderRef
CGDataProviderCreateWithData(void *info, const void *data, size_t size,
                             CGDataProviderReleaseDataCallback releaseCallback)
{
    return (CGDataProviderRef)O2DataProviderCreateWithData(info, data, size, releaseCallback);
}

COREGRAPHICS_EXPORT CFDataRef CGDataProviderCopyData(CGDataProviderRef self) {
    return (CFDataRef) O2DataProviderCopyData((O2DataProviderRef)self);
}

/*
 * A SEQUENTIAL PROVIDER, READ EAGERLY. O2DataProvider is backed by bytes or by an input stream and
 * has no callback form, so the callbacks are drained here, at creation, into one buffer that the
 * ordinary byte provider then serves. THE DIFFERENCE FROM APPLE IS THE TIMING, not the data: the
 * client's getBytes runs during this call rather than while the consumer decodes. That matters
 * only for a provider whose bytes are not ready yet, and it is stated here rather than hidden.
 */
COREGRAPHICS_EXPORT CGDataProviderRef
CGDataProviderCreateSequential(void *info,
                               const CGDataProviderSequentialCallbacks *callbacks)
{
    if (callbacks == NULL || callbacks->getBytes == NULL) {
        return NULL;
    }

    NSMutableData *data = [NSMutableData data];
    unsigned char chunk[64 * 1024];

    for (;;) {
        size_t got = callbacks->getBytes(info, chunk, sizeof(chunk));
        if (got == 0) {
            break;
        }
        if (got > sizeof(chunk)) { // a client that lies about the count would corrupt the heap
            got = sizeof(chunk);
        }
        [data appendBytes: chunk length: got];
    }

    if (callbacks->releaseInfo != NULL) {
        callbacks->releaseInfo(info);
    }

    return (CGDataProviderRef)O2DataProviderCreateWithCFData((CFDataRef)data);
}
