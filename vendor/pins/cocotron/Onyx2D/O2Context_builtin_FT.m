#import <objc/runtime.h>
#import <Onyx2D/O2Context_builtin_FT.h>
#include <stdio.h>
#include <stdlib.h>
#include <execinfo.h>
#include <dlfcn.h>
#include <freetype/ftoutln.h>
#import <Onyx2D/O2Font_freetype.h>
#import <Onyx2D/O2GraphicsState.h>
#import <Onyx2D/O2Paint_color.h>

@implementation O2Context (O2BitmapContext)

+ (O2Context *) createWithBytes: (void *) bytes
                          width: (size_t) width
                         height: (size_t) height
               bitsPerComponent: (size_t) bitsPerComponent
                    bytesPerRow: (size_t) bytesPerRow
                     colorSpace: (O2ColorSpaceRef) colorSpace
                     bitmapInfo: (O2BitmapInfo) bitmapInfo
                releaseCallback:
                        (O2BitmapContextReleaseDataCallback) releaseCallback
                    releaseInfo: (void *) releaseInfo
{

    return [[O2Context_builtin_FT alloc] initWithBytes: bytes
                                                 width: width
                                                height: height
                                      bitsPerComponent: bitsPerComponent
                                           bytesPerRow: bytesPerRow
                                            colorSpace: colorSpace
                                            bitmapInfo: bitmapInfo
                                       releaseCallback: releaseCallback
                                           releaseInfo: releaseInfo];
}

@end

@implementation O2Context_builtin_FT

- initWithSurface: (O2Surface *) surface flipped: (BOOL) flipped {
    if ([super initWithSurface: surface flipped: flipped] == nil)
        return nil;

    return self;
}

- (void) dealloc {
    [super dealloc];
}

- (void) establishFontStateInDeviceIfDirty {
    O2GState *gState = O2ContextCurrentGState(self);

    if (gState->_fontIsDirty) {
        O2GStateClearFontIsDirty(gState);
    }
}

static O2Paint *paintFromColor(O2ColorRef color) {
    size_t count = O2ColorGetNumberOfComponents(color);
    const O2Float *components = O2ColorGetComponents(color);

    if (count == 2)
        return [[O2Paint_color alloc] initWithGray: components[0]
                                             alpha: components[1]
                           surfaceToPaintTransform: O2AffineTransformIdentity];
    if (count == 4)
        return [[O2Paint_color alloc] initWithRed: components[0]
                                            green: components[1]
                                             blue: components[2]
                                            alpha: components[3]
                          surfaceToPaintTransform: O2AffineTransformIdentity];

    return [[O2Paint_color alloc] initWithGray: 0
                                         alpha: 1
                       surfaceToPaintTransform: O2AffineTransformIdentity];
}

static void applyCoverageToSpan_lRGBA8888_PRE(O2argb8u *dst,
                                              unsigned char *coverageSpan,
                                              O2argb8u *src, int length)
{
    int i;

    for (i = 0; i < length; i++, src++, dst++) {
        int coverage = coverageSpan[i];
        int oneMinusCoverage = inverseCoverage(coverage);
        O2argb8u r = *src;
        O2argb8u d = *dst;

        *dst = O2argb8uAdd(O2argb8uMultiplyByCoverage(r, coverage),
                           O2argb8uMultiplyByCoverage(d, oneMinusCoverage));
    }
}

/*
 * flipped: the glyph is drawn bottom row first, for a text matrix whose vertical component is
 * POSITIVE. See the call site for what that means and why it happens.
 */
/* The glyph traces below sit on the per glyph path, so the environment is read ONCE. A getenv for
 * every glyph of every line is a measurable cost in a terminal that repaints whole screens. */
static BOOL ciderTraceGlyphRun(void)
{
    static int cached = -1;

    if (cached < 0) {
        const char *value = getenv("CIDER_TRACE_GLYPHRUN");

        /* Empty is OFF: a harness forwarding unset switches writes VAR= and getenv answers "". */
        cached = (value != NULL && value[0] != '\0') ? 1 : 0;
    }
    return cached ? YES : NO;
}

/* CIDER_GLYPH_RED repaints every glyph red at the one place all callers reach, rather than in one
 * CoreGraphics entry point: iTerm2 draws through CTFontDrawGlyphs, so a probe in
 * CGContextShowGlyphsAtPositions said "no glyphs" about a terminal that was drawing them. */
extern long ciderPaintSeq;

static BOOL ciderGlyphRed(void)
{
    static int cached = -1;

    if (cached < 0) {
        const char *value = getenv("CIDER_GLYPH_RED");

        cached = (value != NULL && value[0] != '\0') ? 1 : 0;
    }
    return cached ? YES : NO;
}

static void renderFreeTypeBitmap(O2Context_builtin_FT *self, O2Surface *surface,
                                 FT_Bitmap *bitmap, NSInteger x, NSInteger y,
                                 O2Paint *paint, BOOL flipped)
{
    // Size of the bitmap.
    NSInteger fullWidth = bitmap->width;
    NSInteger fullHeight = bitmap->rows;

    // What we're going to render, taking clippig into account.
    NSInteger minX = MAX(x, self->_vpx);
    NSInteger maxX = MIN(x + fullWidth, self->_vpx + self->_vpwidth);
    NSInteger minY = MAX(y, self->_vpy);
    NSInteger maxY = MIN(y + fullHeight, self->_vpy + self->_vpheight);

    NSInteger renderWidth = maxX - minX;
    NSInteger renderHeight = maxY - minY;

    if (ciderTraceGlyphRun()) {
        static int printedBlit;

        if (printedBlit < 200) {
            printedBlit++;
            fprintf(stderr,
                    "CIDER_GLYPHBLIT at=%ld,%ld bitmap=%ldx%ld vp=%d,%d %dx%d render=%ldx%ld "
                    "surface=%p %zux%zu ctx=%p\n",
                    (long) x, (long) y, (long) fullWidth, (long) fullHeight, (int) self->_vpx,
                    (int) self->_vpy, (int) self->_vpwidth, (int) self->_vpheight,
                    (long) renderWidth, (long) renderHeight, (void *) surface,
                    (size_t) O2ImageGetWidth(surface), (size_t) O2ImageGetHeight(surface),
                    (void *) self);
            fflush(stderr);
        }

        /* THE PER-LINE CAP ONLY EVER DESCRIBES STARTUP, and reading it as the whole run said
         * every glyph in iTerm2 went to the menu bar when the first 200 were simply the chrome
         * being drawn first. These counters cover the run: one row per distinct viewport, so
         * "did anything draw into the document area" is a number rather than an inference. */
        enum { kBuckets = 12 };
        static struct { int y, h, w; size_t sw, sh; long rendered, clipped; } buckets[kBuckets];
        static int bucketCount;
        static long blits;
        size_t surfaceW = O2ImageGetWidth(surface);
        size_t surfaceH = O2ImageGetHeight(surface);
        int i;

        for (i = 0; i < bucketCount; i++) {
            if (buckets[i].y == self->_vpy && buckets[i].h == self->_vpheight &&
                buckets[i].w == self->_vpwidth && buckets[i].sw == surfaceW &&
                buckets[i].sh == surfaceH)
                break;
        }
        if (i == bucketCount && bucketCount < kBuckets) {
            buckets[bucketCount].y = self->_vpy;
            buckets[bucketCount].h = self->_vpheight;
            buckets[bucketCount].w = self->_vpwidth;
            buckets[bucketCount].sw = surfaceW;
            buckets[bucketCount].sh = surfaceH;
            bucketCount++;
        }
        if (i < kBuckets) {
            if (renderWidth > 0 && renderHeight > 0) buckets[i].rendered++;
            else buckets[i].clipped++;
        }

        if ((++blits % 100) == 0) {
            for (i = 0; i < bucketCount; i++) {
                fprintf(stderr,
                        "CIDER_GLYPHSUM vp=%d,%d %dx%d surface=%zux%zu rendered=%ld clipped=%ld\n",
                        0, buckets[i].y, buckets[i].w, buckets[i].h, buckets[i].sw, buckets[i].sh,
                        buckets[i].rendered, buckets[i].clipped);
            }
            fflush(stderr);
        }
    }

    if (renderWidth <= 0 || renderHeight <= 0) {
        // Fully clipped.
        return;
    }

    if (ciderGlyphRed()) {
        static O2Paint *red;

        if (red == nil)
            red = [[O2Paint_color alloc] initWithRed: 1 green: 0 blue: 0 alpha: 1
                             surfaceToPaintTransform: O2AffineTransformIdentity];
        paint = red;
    }

    O2argb8u *dstBuffer = __builtin_alloca(renderWidth * sizeof(O2argb8u));
    O2argb8u *srcBuffer = __builtin_alloca(renderWidth * sizeof(O2argb8u));

    for (NSInteger row = 0; row < renderHeight; row++) {
        // Geometry of this row.
        // We're going to change curX & remainingLength as we move along this
        // row.
        NSInteger curX = minX;
        NSInteger curY = minY + row;
        NSInteger remainingLength = renderWidth;

        // We're going to advance these pointers as we move along this row.
        NSInteger sourceRow = flipped ? (fullHeight - 1 - (curY - y)) : (curY - y);
        unsigned char *coverage =
                bitmap->buffer + sourceRow * fullWidth + (curX - x);
        O2argb8u *src = srcBuffer;
        O2argb8u *dst = dstBuffer;

        // Try to get direct access to the surface data.
        O2argb8u *direct = surface->_read_argb8u(surface, curX, curY, dst,
                                                 remainingLength);
        // If that succeeded, write there directly with no temporary buffer.
        if (direct != NULL)
            dst = direct;

        while (remainingLength > 0) {
            // Read next chunk into src.
            int chunk = O2PaintReadSpan_argb8u_PRE(paint, curX, curY, src,
                                                   remainingLength);

            if (chunk < 0) {
                chunk = -chunk;
                // Skip this much pixels.
            } else {
                /*
                 * A NULL BLEND FUNCTION IS A JUMP TO ZERO, and this path called it without looking.
                 *
                 * O2ContextSetupPaintAndBlendMode clears _blend_argb8u_PRE and then fills it in for
                 * a handful of modes only: normal, clear, copy, source in, XOR and plus lighter.
                 * Every other mode leaves it NULL, and the general rasteriser knows that, which is
                 * why it tests the pointer and falls back to the float blend. This glyph run did
                 * not test it. Swift Publisher drew a toolbar item with one of the other modes and
                 * the process died with rip=0, deterministically, in three runs of three.
                 *
                 * There is no 8 bit variant to fall back to, so text under an unsupported mode is
                 * composited NORMALLY rather than in that mode. It is an approximation and it is
                 * visible in principle; a glyph run that draws with the wrong blend beats one that
                 * ends the process.
                 */
                O2BlendSpan_argb8u blendSpan = self->_blend_argb8u_PRE;

                if (blendSpan == NULL)
                    blendSpan = O2BlendSpanNormal_8888;

                blendSpan(src, dst, chunk);

                applyCoverageToSpan_lRGBA8888_PRE(dst, coverage, src, chunk);

                if (direct == NULL) {
                    // When direct is NULL, dst is a temporary buffer, not the
                    // surface itself, so we have to write it out to the surface
                    // explicitly.
                    O2SurfaceWriteSpan_argb8u_PRE(surface, curX, curY, dst,
                                                  chunk);
                }
            }

            coverage += chunk;
            remainingLength -= chunk;
            curX += chunk;
            src += chunk;
            dst += chunk;
        }
    }

    /* READ THE PIXEL BACK. Everything above says the glyph was submitted; this says whether it
     * landed. A blit that is unclipped, unskipped and still invisible is either going to a surface
     * nobody presents or being painted over, and those two are told apart by looking again later,
     * not by looking harder here. */
    if (ciderTraceGlyphRun()) {
        /* The chrome draws first and would spend a single budget before the document area drew
         * anything, which is how a cap became a false conclusion once already. */
        static int printedBackChrome, printedBackBody;
        int *printedBack = (self->_vpheight > 64) ? &printedBackBody : &printedBackChrome;

        if (*printedBack < 600) {
            O2argb8u probe[1];
            O2argb8u *got = surface->_read_argb8u(surface, minX, minY, probe, 1);

            (*printedBack)++;
            /* WHO DRAWS THE CONTENT, which the fill trace already answers for the background. The
             * two backtraces together give the order the views are painted in. A handful is
             * enough; the rest would only repeat the same chain. */
            if (*printedBack <= 3) {
                void *frames[24];
                int depth = backtrace(frames, 24);

                fprintf(stderr, "CIDER_GLYPHFROM");
                for (int i = 1; i < depth; i++) {
                    Dl_info info;

                    if (dladdr(frames[i], &info) != 0 && info.dli_sname != NULL) {
                        fprintf(stderr, " <- %s", info.dli_sname);
                    }
                }
                fprintf(stderr, "\n");
            }
            fprintf(stderr,
                    "CIDER_GLYPHBACK seq=%ld vph=%d surface=%p dstaddr=%p %zux%zu at=%ld,%ld "
                    "direct=%s rgba=%u,%u,%u,%u\n",
                    ++ciderPaintSeq, (int) self->_vpheight, (void *) surface,
                    (void *) got,
                    (size_t) O2ImageGetWidth(surface), (size_t) O2ImageGetHeight(surface),
                    (long) minX, (long) minY, got ? "yes" : "no",
                    (unsigned) (got ? got[0].r : probe[0].r),
                    (unsigned) (got ? got[0].g : probe[0].g),
                    (unsigned) (got ? got[0].b : probe[0].b),
                    (unsigned) (got ? got[0].a : probe[0].a));
            fflush(stderr);
        }
    }
}

- (void) showGlyphs: (const O2Glyph *) glyphs
           advances: (const O2Size *) advances
              count: (NSUInteger) count
{
    // FIXME: use advances if not NULL

    O2SurfaceLock(_surface);

    O2GState *gState = O2ContextCurrentGState(self);
    O2Paint *paint = paintFromColor(gState->_fillColor);
    O2AffineTransform Trm = O2ContextGetTextRenderingMatrix(self);

    NSPoint point = O2PointApplyAffineTransform(NSMakePoint(0, 0), Trm);

    /* CIDER_TRACE_TEXTCTM here prints the TEXT RENDERING matrix, which is the text matrix and the
     * transform together and is what actually decides which way up a glyph goes. The trace in
     * O2Context prints the transform alone, and the two are not the same question. */
    if (getenv("CIDER_TRACE_TEXTCTM") != NULL) {
        static int printedFT;

        if (printedFT < 40) {
            printedFT++;
            fprintf(stderr, "CIDER_TEXTTRM trm=[%.2f %.2f %.2f %.2f %.1f %.1f] origin=%.1f,%.1f\n",
                    (double) Trm.a, (double) Trm.b, (double) Trm.c, (double) Trm.d,
                    (double) Trm.tx, (double) Trm.ty, (double) point.x, (double) point.y);
            fflush(stderr);
        }
    }

    // Only use the scaling part of the current transform to scale the font size
    O2Float scaleX = sqrt((Trm.a * Trm.a) + (Trm.c * Trm.c));
    O2Float scaleY = sqrt((Trm.b * Trm.b) + (Trm.d * Trm.d));
    O2AffineTransform scalingTransform =
            O2AffineTransformMakeScale(scaleX, scaleY);
    O2Size fontSize = O2SizeApplyAffineTransform(
            O2SizeMake(0, O2GStatePointSize(gState)), scalingTransform);

    [self establishFontStateInDeviceIfDirty];

    O2Font_freetype *font = (O2Font_freetype *) gState->_font;
    FT_Face face = [font face];

    if (ciderTraceGlyphRun()) {
        static int printedEntry;

        if (printedEntry < 200) {
            printedEntry++;
            fprintf(stderr,
                    "CIDER_GLYPHFT count=%lu pointSize=%.2f size=%.2f font=%p cls=%s face=%p\n",
                    (unsigned long) count, (double) O2GStatePointSize(gState),
                    (double) fontSize.height, (void *) font,
                    font ? object_getClassName(font) : "<nil>", (void *) face);
            fflush(stderr);
        }
    }

    int i;
    FT_Error ftError;

    if (face == NULL) {
        NSLog(@"face is NULL");
        O2SurfaceUnlock(_surface);
        return;
    }

    /*
     * THE SAME ONE THREAD AT A TIME AS THE MEASURING PATHS, and for the same shared thing. This
     * whole run works through face->glyph, ONE slot that FT_Set_Char_Size, FT_Load_Glyph and
     * FT_Render_Glyph all write, and the bitmap is read out of it afterwards. Swift Publisher draws
     * previews on an operation queue while the main thread draws the window, and without this the
     * two met here: rip=0 inside renderFreeTypeBitmap, a call through a pointer another thread had
     * already replaced.
     */
    O2FontHostLock();

    FT_GlyphSlot slot = face->glyph;

    if ((ftError =
                 FT_Set_Char_Size(face, 0, fontSize.height * 64, 72.0, 72.0))) {
        NSLog(@"FT_Set_Char_Size returned %d", ftError);
        O2FontHostUnlock();
        O2SurfaceUnlock(_surface);
        return;
    }

    /*
     * A FRACTIONAL PEN, AND THE GLYPH MOVED ONTO IT.
     *
     * This used to add slot->advance.x >> 6 to an integer pen, which throws away up to a
     * sixty-fourth of a pixel per glyph and then accumulates: a line of forty characters can end up
     * most of a pixel short, and the spacing inside a word visibly wobbles because each glyph lands
     * on whichever pixel the truncation left. macOS positions glyphs at fractional x, which is most
     * of why its text looks even at small sizes.
     *
     * So the pen is kept in 26.6 fixed point, the glyph outline is TRANSLATED by the fractional
     * part before it is rasterised, and only the whole part decides which pixel the bitmap starts
     * at. FreeType antialiases the shifted outline, so the fraction shows up as coverage rather
     * than as a jump.
     */
    FT_Pos penX = (FT_Pos) lround(point.x * 64.0);
    FT_Pos penStart = penX;

    for (i = 0; i < count; i++) {

        ftError = FT_Load_Glyph(face, glyphs[i], FT_LOAD_DEFAULT);
        if (ftError) {
            /* A glyph index the face does not have is skipped silently here, which is why a whole
             * line of text can come out blank with nothing in the log to say so. */
            if (ciderTraceGlyphRun()) {
                static int printedLoad;

                if (printedLoad < 40) {
                    printedLoad++;
                    fprintf(stderr,
                            "CIDER_GLYPHLOAD FAILED glyph=%u error=%d face=%p numGlyphs=%ld\n",
                            (unsigned) glyphs[i], (int) ftError, (void *) face,
                            (long) face->num_glyphs);
                    fflush(stderr);
                }
            }
            continue;
        }

        FT_Pos whole = penX & ~63;
        FT_Pos fraction = penX - whole;

        if (fraction != 0 && slot->format == FT_GLYPH_FORMAT_OUTLINE) {
            FT_Outline_Translate(&slot->outline, fraction, 0);
        }

        ftError = FT_Render_Glyph(face->glyph, FT_RENDER_MODE_NORMAL);
        if (ftError)
            continue;

        /*
         * WHICH WAY UP THE GLYPH GOES IS IN THE TEXT MATRIX, and this used to ignore it.
         *
         * The scale is taken out of the text rendering matrix with a square root above, which is
         * always positive, so the SIGN was thrown away. That is right for the usual case and wrong
         * for the other one, and both happen in LibreOffice:
         *
         *     trm=[1 0 0 -1 ...]   the document window, and everything looked correct
         *     trm=[1 0 0  1 ...]   the status bar, drawing each item into its own bitmap context
         *
         * A glyph outline is defined with y going UP. With a negative d that becomes y going DOWN
         * in the device, which is exactly how FreeType hands back its bitmap, so the rows go out in
         * order. With a POSITIVE d the outline keeps its direction and the glyph belongs on the
         * screen mirrored: the rows go out in reverse, and the top of the glyph sits BELOW the
         * baseline rather than above it.
         *
         * Without this the status bar and every dropdown list in the application came out upside
         * down, text and all, while the document beside them was right.
         */
        BOOL flipped = (Trm.d > 0.0);
        NSInteger glyphTop = flipped
                ? (NSInteger) (point.y + slot->bitmap_top - (NSInteger) slot->bitmap.rows + 1)
                : (NSInteger) (point.y - slot->bitmap_top);

        renderFreeTypeBitmap(self, _surface, &slot->bitmap,
                             (whole >> 6) + slot->bitmap_left, glyphTop, paint, flipped);

        penX += slot->advance.x;
    }
    point.x += (penX - penStart) / 64.0;

    O2PaintRelease(paint);

    int glyphAdvances[count];
    O2Float unitsPerEm = O2FontGetUnitsPerEm(font);

    O2FontGetGlyphAdvances(font, glyphs, count, glyphAdvances);

    O2Float total = 0;

    for (i = 0; i < count; i++)
        total += glyphAdvances[i];

    total = (total / O2FontGetUnitsPerEm(font)) * gState->_pointSize;

    O2FontHostUnlock();
    O2SurfaceUnlock(_surface);
}

@end
