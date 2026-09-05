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
#import <Onyx2D/O2MutablePath.h>
#import <Onyx2D/O2Path.h>

#import <CoreGraphics/CGGeometry.h>
#include <stdio.h>

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
