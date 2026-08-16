// DOES A CGLAYER KEEP WHAT IS DRAWN INTO IT, and does drawing it back put those pixels anywhere.
//
// LibreOffice draws its native controls through CGLayers: its macOS backend uses
// CGLayerCreateWithContext, draws the control into the layer, and blits the layer with
// CGContextDrawLayerInRect. With SAL_NO_NWF=1, which turns that whole path off and makes it draw
// the controls itself, the toolbar dropdowns and the dialog buttons APPEAR. With it on they are
// missing. So the native path is taken and produces nothing.
//
// This is that path with no application around it: a bitmap context, a layer made from it, a red
// rectangle drawn into the layer, the layer drawn back, and the pixel read. Red means the machinery
// works and the fault is further up; anything else means every control drawn this way is empty for
// the same reason.
#import <Foundation/Foundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <stdio.h>
#include <string.h>

/*
 * SCAN THE WHOLE BUFFER, never one pixel.
 *
 * Core Graphics puts the ORIGIN AT THE BOTTOM LEFT, so a rect at (0,0) lands in the LAST rows of
 * the buffer, not the first. Reading a single pixel near the top and calling the result empty is
 * how this probe first reported that layers were broken, when the pixels were there all along, ten
 * rows down. Count them and say where they start.
 */
static void report(const char *label, const unsigned char *pixels, size_t width, size_t height)
{
    size_t painted = 0;
    int firstX = -1, firstY = -1;

    for (size_t y = 0; y < height; y++) {
        for (size_t x = 0; x < width; x++) {
            const unsigned char *p = pixels + (y * width + x) * 4;

            if (p[0] || p[1] || p[2] || p[3]) {
                painted++;
                if (firstX < 0) {
                    firstX = (int) x;
                    firstY = (int) y;
                }
            }
        }
    }
    printf("LAYER_PROBE %s painted=%zu first=%d,%d\n", label, painted, firstX, firstY);
}

int main(void)
{
    const size_t width = 20;
    const size_t height = 20;
    unsigned char *pixels = calloc(width * height, 4);
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef bitmap = CGBitmapContextCreate(pixels, width, height, 8, width * 4, space,
                                                kCGImageAlphaPremultipliedLast);

    if (bitmap == NULL) {
        printf("LAYER_PROBE bitmap=FAILED\n");
        return 1;
    }
    printf("LAYER_PROBE bitmap=ok\n");

    /* WHAT THE CONTEXT SAYS ABOUT ITSELF, which an application uses to decide what to draw at all.
     * LibreOffice calls both of these; a clip box of nothing is a reason to skip drawing entirely,
     * and a wrong transform puts the drawing somewhere nobody looks. */
    CGRect clip = CGContextGetClipBoundingBox(bitmap);
    CGAffineTransform ctm = CGContextGetCTM(bitmap);

    printf("LAYER_PROBE clip=%.0f,%.0f,%.0fx%.0f ctm=%.2f,%.2f,%.2f,%.2f,%.1f,%.1f\n", clip.origin.x,
           clip.origin.y, clip.size.width, clip.size.height, ctm.a, ctm.b, ctm.c, ctm.d, ctm.tx,
           ctm.ty);

    CGLayerRef layer = CGLayerCreateWithContext(bitmap, CGSizeMake(10, 10), NULL);

    if (layer == NULL) {
        printf("LAYER_PROBE layer=FAILED\n");
        return 1;
    }

    CGContextRef layerContext = CGLayerGetContext(layer);

    printf("LAYER_PROBE layer=ok context=%s size=%.0fx%.0f\n",
           (layerContext != NULL) ? "ok" : "NULL", CGLayerGetSize(layer).width,
           CGLayerGetSize(layer).height);

    if (layerContext == NULL) {
        return 1;
    }

    /* Red, opaque, over the whole layer. */
    CGContextSetRGBFillColor(layerContext, 1.0, 0.0, 0.0, 1.0);
    CGContextFillRect(layerContext, CGRectMake(0, 0, 10, 10));

    /* And back into the bitmap at the origin. */
    CGContextDrawLayerInRect(bitmap, CGRectMake(0, 0, 10, 10), layer);

    const unsigned char *pixel = pixels + (2 * width + 2) * 4;

    report("layer-inrect", pixels, width, height);

    /* VARIANT TWO: the point form of the same blit, which takes a different path inside. */
    memset(pixels, 0, width * height * 4);
    CGContextDrawLayerAtPoint(bitmap, CGPointMake(0, 0), layer);
    report("layer-atpoint", pixels, width, height);

    /* VARIANT THREE: no layer at all. Draw an image made from a second bitmap context, which is the
     * same blit with the layer machinery taken out of the question. */
    memset(pixels, 0, width * height * 4);
    unsigned char *other = calloc(10 * 10, 4);
    CGContextRef second = CGBitmapContextCreate(other, 10, 10, 8, 40, space,
                                                kCGImageAlphaPremultipliedLast);
    CGContextSetRGBFillColor(second, 1.0, 0.0, 0.0, 1.0);
    CGContextFillRect(second, CGRectMake(0, 0, 10, 10));
    printf("LAYER_PROBE second-context-pixel=%02x%02x%02x%02x\n", other[0], other[1], other[2],
           other[3]);

    CGImageRef image = CGBitmapContextCreateImage(second);
    if (image != NULL) {
        CGContextDrawImage(bitmap, CGRectMake(0, 0, 10, 10), image);
        report("drawimage-from-context", pixels, width, height);
        CGImageRelease(image);
    } else {
        printf("LAYER_PROBE drawimage=NOIMAGE\n");
    }
    /* VARIANT FOUR: the SAME test in the format a window surface uses, premultiplied first with
     * little endian byte order, which is what an application layer inherits when it makes one from
     * a window context. If this works and the RGBA one does not, the gap is format support in the
     * blit rather than the layer machinery. */
    unsigned char *bgra = calloc(width * height, 4);
    CGContextRef bgraContext =
            CGBitmapContextCreate(bgra, width, height, 8, width * 4, space,
                                  kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);

    if (bgraContext == NULL) {
        printf("LAYER_PROBE bgra-context=FAILED\n");
        return 1;
    }

    CGLayerRef bgraLayer = CGLayerCreateWithContext(bgraContext, CGSizeMake(10, 10), NULL);
    CGContextRef bgraLayerContext = (bgraLayer != NULL) ? CGLayerGetContext(bgraLayer) : NULL;

    if (bgraLayerContext == NULL) {
        printf("LAYER_PROBE bgra-layer=FAILED\n");
        return 1;
    }
    CGContextSetRGBFillColor(bgraLayerContext, 1.0, 0.0, 0.0, 1.0);
    CGContextFillRect(bgraLayerContext, CGRectMake(0, 0, 10, 10));
    CGContextDrawLayerInRect(bgraContext, CGRectMake(0, 0, 10, 10), bgraLayer);

    report("bgra-layer-inrect", bgra, width, height);

    /* VARIANT FIVE: an image built from RAW BYTES rather than from a context, drawn into the
     * bitmap. This separates "the image is empty" from "the blit does nothing", which the earlier
     * variants cannot tell apart: both of them made their image out of a context. */
    unsigned char raw[10 * 10 * 4];
    for (size_t i = 0; i < sizeof(raw); i += 4) {
        raw[i + 0] = 0xff;
        raw[i + 1] = 0x00;
        raw[i + 2] = 0x00;
        raw[i + 3] = 0xff;
    }
    CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, raw, sizeof(raw), NULL);
    CGImageRef rawImage =
            (provider != NULL)
                    ? CGImageCreate(10, 10, 8, 32, 40, space,
                                    kCGImageAlphaPremultipliedLast, provider, NULL, false,
                                    kCGRenderingIntentDefault)
                    : NULL;

    memset(pixels, 0, width * height * 4);
    if (rawImage != NULL) {
        CGContextDrawImage(bitmap, CGRectMake(0, 0, 10, 10), rawImage);
        pixel = pixels + (2 * width + 2) * 4;
        printf("LAYER_PROBE rawimage=%s %02x%02x%02x%02x\n",
               (pixel[0] > 200 && pixel[1] < 60) ? "OK" : "EMPTY", pixel[0], pixel[1], pixel[2],
               pixel[3]);

        /* WHERE DID IT LAND, if anywhere. A blit that draws in the wrong place and one that draws
         * nothing look identical through a single pixel, and they are different bugs: the first is
         * a transform, the second is the blit. */
        size_t painted = 0;
        int firstX = -1, firstY = -1;
        for (size_t y = 0; y < height; y++) {
            for (size_t x = 0; x < width; x++) {
                const unsigned char *p = pixels + (y * width + x) * 4;
                if (p[0] || p[1] || p[2] || p[3]) {
                    painted++;
                    if (firstX < 0) {
                        firstX = (int) x;
                        firstY = (int) y;
                    }
                }
            }
        }
        printf("LAYER_PROBE rawimage-painted=%zu first=%d,%d\n", painted, firstX, firstY);
    } else {
        printf("LAYER_PROBE rawimage=NOIMAGE provider=%s\n", provider ? "ok" : "null");
    }
    return 0;
}
