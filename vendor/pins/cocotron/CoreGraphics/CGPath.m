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

#import "CGConversions.h"
#import <CoreGraphics/CGPath.h>
#import <CoreGraphics/CGContext.h>
#import <Onyx2D/O2MutablePath.h>
#import <Onyx2D/O2Path.h>

#import <CoreGraphics/CGGeometry.h>
#include <stdio.h>
#include <math.h>

void CGPathRelease(CGPathRef self) {
    O2PathRelease((O2PathRef)self);
}

CGPathRef CGPathRetain(CGPathRef self) {
    return (CGPathRef) O2PathRetain((O2PathRef)self);
}

bool CGPathEqualToPath(CGPathRef self, CGPathRef other) {
    return O2PathEqualToPath((O2PathRef)self, (O2PathRef)other);
}

CGRect CGPathGetBoundingBox(CGPathRef self) {
    return O2PathGetBoundingBox((O2PathRef)self);
}

CGPoint CGPathGetCurrentPoint(CGPathRef self) {
    return O2PathGetCurrentPoint((O2PathRef)self);
}

bool CGPathIsEmpty(CGPathRef self) {
    return O2PathIsEmpty((O2PathRef)self);
}

bool CGPathIsRect(CGPathRef self, CGRect *rect) {
    return O2PathIsRect((O2PathRef)self, rect);
}

void CGPathApply(CGPathRef self, void *info, CGPathApplierFunction function) {
    return O2PathApply((O2PathRef)self, info, O2PathApplierFunctionFromCG(function));
}

CGMutablePathRef CGPathCreateMutableCopy(CGPathRef self) {
    return (CGMutablePathRef)O2PathCreateMutableCopy((O2PathRef)self);
}

CGPathRef CGPathCreateCopy(CGPathRef self) {
    return (CGPathRef) O2PathCreateCopy((O2PathRef)self);
}

bool CGPathContainsPoint(CGPathRef self, const CGAffineTransform *xform,
                         CGPoint point, bool evenOdd)
{
    return O2PathContainsPoint((O2PathRef)self, O2AffineTransformPtrFromCG(xform), point,
                               evenOdd);
}

CGMutablePathRef CGPathCreateMutable(void) {
    return (CGMutablePathRef)O2PathCreateMutable();
}

void CGPathMoveToPoint(CGMutablePathRef self, const CGAffineTransform *xform,
                       CGFloat x, CGFloat y)
{
    O2PathMoveToPoint((O2MutablePathRef)self, O2AffineTransformPtrFromCG(xform), x, y);
}

void CGPathAddLineToPoint(CGMutablePathRef self, const CGAffineTransform *xform,
                          CGFloat x, CGFloat y)
{
    O2PathAddLineToPoint((O2MutablePathRef)self, O2AffineTransformPtrFromCG(xform), x, y);
}

void CGPathAddCurveToPoint(CGMutablePathRef self,
                           const CGAffineTransform *xform, CGFloat cp1x,
                           CGFloat cp1y, CGFloat cp2x, CGFloat cp2y, CGFloat x,
                           CGFloat y)
{
    O2PathAddCurveToPoint((O2MutablePathRef)self, O2AffineTransformPtrFromCG(xform), cp1x, cp1y,
                          cp2x, cp2y, x, y);
}

void CGPathAddQuadCurveToPoint(CGMutablePathRef self,
                               const CGAffineTransform *xform, CGFloat cpx,
                               CGFloat cpy, CGFloat x, CGFloat y)
{
    O2PathAddQuadCurveToPoint((O2MutablePathRef)self, O2AffineTransformPtrFromCG(xform), cpx, cpy,
                              x, y);
}

void CGPathCloseSubpath(CGMutablePathRef self) {
    O2PathCloseSubpath((O2MutablePathRef)self);
}

void CGPathAddLines(CGMutablePathRef self, const CGAffineTransform *xform,
                    const CGPoint *points, size_t count)
{
    O2PathAddLines((O2MutablePathRef)self, O2AffineTransformPtrFromCG(xform), points, count);
}

void CGPathAddRect(CGMutablePathRef self, const CGAffineTransform *xform,
                   CGRect rect)
{
    O2PathAddRect((O2MutablePathRef)self, O2AffineTransformPtrFromCG(xform), rect);
}

void CGPathAddRects(CGMutablePathRef self, const CGAffineTransform *xform,
                    const CGRect *rects, size_t count)
{
    O2PathAddRects((O2MutablePathRef)self, O2AffineTransformPtrFromCG(xform), rects, count);
}

void CGPathAddArc(CGMutablePathRef self, const CGAffineTransform *xform,
                  CGFloat x, CGFloat y, CGFloat radius, CGFloat startRadian,
                  CGFloat endRadian, bool clockwise)
{
    O2PathAddArc((O2MutablePathRef)self, O2AffineTransformPtrFromCG(xform), x, y, radius,
                 startRadian, endRadian, clockwise);
}

void CGPathAddArcToPoint(CGMutablePathRef self, const CGAffineTransform *xform,
                         CGFloat tx1, CGFloat ty1, CGFloat tx2, CGFloat ty2,
                         CGFloat radius)
{
    O2PathAddArcToPoint((O2MutablePathRef)self, O2AffineTransformPtrFromCG(xform), tx1, ty1, tx2,
                        ty2, radius);
}

void CGPathAddEllipseInRect(CGMutablePathRef self,
                            const CGAffineTransform *xform, CGRect rect)
{
    O2PathAddEllipseInRect((O2MutablePathRef)self, O2AffineTransformPtrFromCG(xform), rect);
}

void CGPathAddPath(CGMutablePathRef self, const CGAffineTransform *xform,
                   CGPathRef other)
{
    O2PathAddPath((O2MutablePathRef)self, O2AffineTransformPtrFromCG(xform), (O2PathRef)other);
}

CGPathRef CGPathCreateWithEllipseInRect(CGRect rect,
                                        const CGAffineTransform *transform)
{
    return (CGPathRef) O2PathCreateWithEllipseInRect(
            rect, (O2AffineTransform *) transform);
}

CGPathRef CGPathCreateWithRect(CGRect rect, const CGAffineTransform *transform)
{
    return (CGPathRef) O2PathCreateWithRect(rect,
                                            (O2AffineTransform *) transform);
}

CGRect CGPathGetPathBoundingBox(CGPathRef path) {
    return O2PathGetBoundingBox((O2PathRef)path);
}

CGPathRef CGPathCreateCopyByTransformingPath(CGPathRef path,
                                             CGAffineTransform *transform)
{
    O2MutablePathRef copy = O2PathCreateMutableCopy((O2PathRef)path);
    O2PathApplyTransform(copy, *(O2AffineTransform *) transform);
    return (CGPathRef)copy;
}

/*
 * Equivalent to CGPathAddArc with an end angle of start plus delta, and the direction taken from
 * the sign of delta, which is how the documented behaviour is defined.
 */
void CGPathAddRelativeArc(CGMutablePathRef self, const CGAffineTransform *xform,
                          CGFloat x, CGFloat y, CGFloat radius, CGFloat startRadian,
                          CGFloat deltaRadian)
{
    CGPathAddArc(self, xform, x, y, radius, startRadian, startRadian + deltaRadian,
                 deltaRadian < 0);
}

void CGPathAddRoundedRect(CGMutablePathRef self, const CGAffineTransform *xform,
                          CGRect rect, CGFloat cornerWidth, CGFloat cornerHeight)
{
    /* Four elliptical quarter arcs, so a corner wider than it is tall is drawn as one. */
    const CGFloat kappa = 0.5522847498307933;
    CGFloat minX = CGRectGetMinX(rect), maxX = CGRectGetMaxX(rect);
    CGFloat minY = CGRectGetMinY(rect), maxY = CGRectGetMaxY(rect);
    CGFloat cw = cornerWidth, ch = cornerHeight;

    if (CGRectIsEmpty(rect)) {
        return;
    }
    /* A corner cannot take more than half the side it sits on, which is what macOS clamps to. */
    if (cw > CGRectGetWidth(rect) / 2) cw = CGRectGetWidth(rect) / 2;
    if (ch > CGRectGetHeight(rect) / 2) ch = CGRectGetHeight(rect) / 2;
    if (cw < 0) cw = 0;
    if (ch < 0) ch = 0;

    CGPathMoveToPoint(self, xform, minX + cw, minY);
    CGPathAddLineToPoint(self, xform, maxX - cw, minY);
    CGPathAddCurveToPoint(self, xform, maxX - cw + cw * kappa, minY,
                          maxX, minY + ch - ch * kappa, maxX, minY + ch);
    CGPathAddLineToPoint(self, xform, maxX, maxY - ch);
    CGPathAddCurveToPoint(self, xform, maxX, maxY - ch + ch * kappa,
                          maxX - cw + cw * kappa, maxY, maxX - cw, maxY);
    CGPathAddLineToPoint(self, xform, minX + cw, maxY);
    CGPathAddCurveToPoint(self, xform, minX + cw - cw * kappa, maxY,
                          minX, maxY - ch + ch * kappa, minX, maxY - ch);
    CGPathAddLineToPoint(self, xform, minX, minY + ch);
    CGPathAddCurveToPoint(self, xform, minX, minY + ch - ch * kappa,
                          minX + cw - cw * kappa, minY, minX + cw, minY);
    CGPathCloseSubpath(self);
}

/*
 * Path stroking and dashing (task #176). libswiftCoreGraphics imports these two and nothing else
 * provides them, so a Swift stroke/dash faulted at bind time; Onyx2D has no stroke-to-outline
 * primitive, hence the manual flatten-and-build here. The stroke approximates: one offset quad per
 * flattened segment, butt caps and overlapping-quad joins, no miter or round. A scaling transform
 * scales the finished outline rather than the pre-stroke geometry.
 */
#define CIDER_FLATTEN_STEPS 16

typedef struct {
    CGMutablePathRef out;
    CGPoint cur, start;
    CGFloat half;
    bool have;
} CiderStrokeCtx;

static void ciderStrokeSeg(CiderStrokeCtx *s, CGPoint a, CGPoint b) {
    CGFloat dx = b.x - a.x, dy = b.y - a.y;
    CGFloat len = sqrt(dx * dx + dy * dy);
    if (len < 1e-6)
        return;
    CGFloat nx = -dy / len * s->half, ny = dx / len * s->half;
    CGPathMoveToPoint(s->out, NULL, a.x + nx, a.y + ny);
    CGPathAddLineToPoint(s->out, NULL, b.x + nx, b.y + ny);
    CGPathAddLineToPoint(s->out, NULL, b.x - nx, b.y - ny);
    CGPathAddLineToPoint(s->out, NULL, a.x - nx, a.y - ny);
    CGPathCloseSubpath(s->out);
}

static CGPoint ciderBezier(CGPoint p0, CGPoint c1, CGPoint c2, CGPoint p1, bool cubic, CGFloat t) {
    CGFloat u = 1 - t;
    if (cubic) {
        CGFloat a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t;
        return CGPointMake(a * p0.x + b * c1.x + c * c2.x + d * p1.x,
                           a * p0.y + b * c1.y + c * c2.y + d * p1.y);
    }
    CGFloat a = u * u, b = 2 * u * t, c = t * t;
    return CGPointMake(a * p0.x + b * c1.x + c * p1.x, a * p0.y + b * c1.y + c * p1.y);
}

static void ciderStrokeApply(void *info, const CGPathElement *e) {
    CiderStrokeCtx *s = info;
    CGPoint *p = e->points;
    switch (e->type) {
    case kCGPathElementMoveToPoint:
        s->cur = s->start = p[0];
        s->have = true;
        break;
    case kCGPathElementAddLineToPoint:
        if (s->have)
            ciderStrokeSeg(s, s->cur, p[0]);
        s->cur = p[0];
        break;
    case kCGPathElementAddQuadCurveToPoint:
    case kCGPathElementAddCurveToPoint: {
        bool cubic = e->type == kCGPathElementAddCurveToPoint;
        CGPoint c1 = p[0], c2 = cubic ? p[1] : p[0], end = cubic ? p[2] : p[1];
        CGPoint prev = s->cur;
        if (s->have) {
            for (int i = 1; i <= CIDER_FLATTEN_STEPS; i++) {
                CGPoint pt = ciderBezier(s->cur, c1, c2, end, cubic, (CGFloat)i / CIDER_FLATTEN_STEPS);
                ciderStrokeSeg(s, prev, pt);
                prev = pt;
            }
        }
        s->cur = end;
        break;
    }
    case kCGPathElementCloseSubpath:
        if (s->have)
            ciderStrokeSeg(s, s->cur, s->start);
        s->cur = s->start;
        break;
    }
}

CGPathRef CGPathCreateCopyByStrokingPath(CGPathRef path, const CGAffineTransform *transform,
                                         CGFloat lineWidth, CGLineCap lineCap, CGLineJoin lineJoin,
                                         CGFloat miterLimit)
{
    (void)lineCap;
    (void)lineJoin;
    (void)miterLimit;
    CGMutablePathRef out = CGPathCreateMutable();
    if (path == NULL || lineWidth <= 0)
        return out;
    CiderStrokeCtx s = {out, CGPointZero, CGPointZero, lineWidth / 2, false};
    CGPathApply(path, &s, ciderStrokeApply);
    if (transform != NULL) {
        CGAffineTransform t = *transform;
        CGPathRef moved = CGPathCreateCopyByTransformingPath(out, &t);
        CGPathRelease(out);
        return moved;
    }
    return out;
}

typedef struct {
    CGMutablePathRef out;
    CGPoint cur, start;
    bool have;
    const CGFloat *lens;
    size_t count;
    size_t idx;
    CGFloat rem;
    bool on;
    bool penActive;
} CiderDashCtx;

static void ciderDashNext(CiderDashCtx *d) {
    /* The caller guarantees the pattern sums to > 0, so a non-zero element is at most one cycle away. */
    for (size_t guard = 0; guard <= d->count; guard++) {
        d->idx = (d->idx + 1) % d->count;
        d->on = !d->on;
        d->rem = d->lens[d->idx];
        if (d->rem > 1e-9)
            return;
    }
    d->rem = 1e-9;
}

static void ciderDashSeg(CiderDashCtx *d, CGPoint a, CGPoint b) {
    CGFloat dx = b.x - a.x, dy = b.y - a.y;
    CGFloat len = sqrt(dx * dx + dy * dy);
    if (len < 1e-9)
        return;
    CGFloat ux = dx / len, uy = dy / len, pos = 0;
    for (long guard = 0; pos < len && guard < (1L << 22); guard++) {
        CGFloat step = d->rem;
        if (step > len - pos)
            step = len - pos;
        if (d->on) {
            if (!d->penActive) {
                CGPathMoveToPoint(d->out, NULL, a.x + ux * pos, a.y + uy * pos);
                d->penActive = true;
            }
            CGPathAddLineToPoint(d->out, NULL, a.x + ux * (pos + step), a.y + uy * (pos + step));
        }
        pos += step;
        d->rem -= step;
        if (d->rem <= 1e-9) {
            bool wasOn = d->on;
            ciderDashNext(d);
            if (wasOn && !d->on)
                d->penActive = false;
        }
    }
}

static void ciderDashApply(void *info, const CGPathElement *e) {
    CiderDashCtx *d = info;
    CGPoint *p = e->points;
    switch (e->type) {
    case kCGPathElementMoveToPoint:
        d->cur = d->start = p[0];
        d->have = true;
        d->penActive = false;
        break;
    case kCGPathElementAddLineToPoint:
        if (d->have)
            ciderDashSeg(d, d->cur, p[0]);
        d->cur = p[0];
        break;
    case kCGPathElementAddQuadCurveToPoint:
    case kCGPathElementAddCurveToPoint: {
        bool cubic = e->type == kCGPathElementAddCurveToPoint;
        CGPoint c1 = p[0], c2 = cubic ? p[1] : p[0], end = cubic ? p[2] : p[1];
        CGPoint prev = d->cur;
        if (d->have) {
            for (int i = 1; i <= CIDER_FLATTEN_STEPS; i++) {
                CGPoint pt = ciderBezier(d->cur, c1, c2, end, cubic, (CGFloat)i / CIDER_FLATTEN_STEPS);
                ciderDashSeg(d, prev, pt);
                prev = pt;
            }
        }
        d->cur = end;
        break;
    }
    case kCGPathElementCloseSubpath:
        if (d->have)
            ciderDashSeg(d, d->cur, d->start);
        d->cur = d->start;
        break;
    }
}

CGPathRef CGPathCreateCopyByDashingPath(CGPathRef path, const CGAffineTransform *transform,
                                        CGFloat phase, const CGFloat *lengths, size_t count)
{
    CGFloat total = 0;
    for (size_t i = 0; lengths != NULL && i < count; i++)
        total += lengths[i] > 0 ? lengths[i] : 0;
    /* No usable pattern: hand back the path itself (drawn solid) rather than fault. */
    if (path == NULL || count == 0 || total <= 1e-9) {
        if (path == NULL)
            return CGPathCreateMutable();
        if (transform != NULL) {
            CGAffineTransform t = *transform;
            return CGPathCreateCopyByTransformingPath(path, &t);
        }
        return CGPathCreateCopy(path);
    }
    CGMutablePathRef out = CGPathCreateMutable();
    CiderDashCtx d = {out, CGPointZero, CGPointZero, false, lengths, count, 0, lengths[0], true, false};
    /* Consume the phase (wrapped into one pattern length) before drawing begins. */
    CGFloat ph = fmod(phase < 0 ? -phase : phase, total);
    while (ph > 1e-9) {
        CGFloat step = d.rem < ph ? d.rem : ph;
        ph -= step;
        d.rem -= step;
        if (d.rem <= 1e-9)
            ciderDashNext(&d);
    }
    CGPathApply(path, &d, ciderDashApply);
    if (transform != NULL) {
        CGAffineTransform t = *transform;
        CGPathRef moved = CGPathCreateCopyByTransformingPath(out, &t);
        CGPathRelease(out);
        return moved;
    }
    return out;
}
