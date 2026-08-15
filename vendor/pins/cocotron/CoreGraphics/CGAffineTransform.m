/* Copyright (c) 2006-2007 Christopher J. W. Lloyd

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

#import <CoreGraphics/CGAffineTransform.h>

#include <stdio.h>

const CGAffineTransform CGAffineTransformIdentity = {1, 0, 0, 1, 0, 0};

bool CGAffineTransformIsIdentity(CGAffineTransform xform) {
    return xform.a == 1 && xform.b == 0 && xform.c == 0 && xform.d == 1 &&
           xform.tx == 0 && xform.ty == 0;
}

CGAffineTransform CGAffineTransformMakeRotation(CGFloat radians) {
    CGAffineTransform xform = {
            cos(radians), sin(radians), -sin(radians), cos(radians), 0, 0};
    return xform;
}

CGAffineTransform CGAffineTransformMakeScale(CGFloat scalex, CGFloat scaley) {
    CGAffineTransform xform = {scalex, 0, 0, scaley, 0, 0};
    return xform;
}

CGAffineTransform CGAffineTransformMakeTranslation(CGFloat tx, CGFloat ty) {
    CGAffineTransform xform = {1, 0, 0, 1, tx, ty};
    return xform;
}

CGAffineTransform CGAffineTransformConcat(CGAffineTransform xform,
                                          CGAffineTransform append)
{
    CGAffineTransform result;

    result.a = xform.a * append.a + xform.b * append.c;
    result.b = xform.a * append.b + xform.b * append.d;
    result.c = xform.c * append.a + xform.d * append.c;
    result.d = xform.c * append.b + xform.d * append.d;
    result.tx = xform.tx * append.a + xform.ty * append.c + append.tx;
    result.ty = xform.tx * append.b + xform.ty * append.d + append.ty;

    return result;
}

CGAffineTransform CGAffineTransformInvert(CGAffineTransform xform) {
    CGAffineTransform result;
    CGFloat determinant;

    determinant = xform.a * xform.d - xform.c * xform.b;
    if (determinant == 0) {
        return xform;
    }

    result.a = xform.d / determinant;
    result.b = -xform.b / determinant;
    result.c = -xform.c / determinant;
    result.d = xform.a / determinant;
    result.tx = (-xform.d * xform.tx + xform.c * xform.ty) / determinant;
    result.ty = (xform.b * xform.tx - xform.a * xform.ty) / determinant;

    return result;
}

CGAffineTransform CGAffineTransformRotate(CGAffineTransform xform,
                                          CGFloat radians)
{
    CGAffineTransform rotate = CGAffineTransformMakeRotation(radians);
    return CGAffineTransformConcat(rotate, xform);
}

CGAffineTransform CGAffineTransformScale(CGAffineTransform xform,
                                         CGFloat scalex, CGFloat scaley)
{
    CGAffineTransform scale = CGAffineTransformMakeScale(scalex, scaley);
    return CGAffineTransformConcat(scale, xform);
}

CGAffineTransform CGAffineTransformTranslate(CGAffineTransform xform,
                                             CGFloat tx, CGFloat ty)
{
    CGAffineTransform translate = CGAffineTransformMakeTranslation(tx, ty);
    return CGAffineTransformConcat(translate, xform);
}

/*
 * THE RECTANGLE THROUGH THE TRANSFORM, which returned the rectangle UNCHANGED.
 *
 * It is not a rare call: 322 of them in one LibreOffice startup, each one a place where something
 * computed where to draw and was handed back coordinates in the wrong space. A stub that returns
 * its input is the worst kind here, because every caller gets a plausible rectangle and nothing
 * reports an error.
 *
 * The transform of a rectangle is the BOUNDING BOX of its four transformed corners, which is what
 * Core Graphics documents: under a rotation the corners are no longer axis aligned, and the answer
 * is the smallest rectangle that contains them.
 */
CGRect CGRectApplyAffineTransform(CGRect rect, CGAffineTransform t) {
    const CGPoint corners[4] = {
        CGPointApplyAffineTransform(CGPointMake(CGRectGetMinX(rect), CGRectGetMinY(rect)), t),
        CGPointApplyAffineTransform(CGPointMake(CGRectGetMaxX(rect), CGRectGetMinY(rect)), t),
        CGPointApplyAffineTransform(CGPointMake(CGRectGetMinX(rect), CGRectGetMaxY(rect)), t),
        CGPointApplyAffineTransform(CGPointMake(CGRectGetMaxX(rect), CGRectGetMaxY(rect)), t),
    };
    CGFloat minX = corners[0].x, maxX = corners[0].x;
    CGFloat minY = corners[0].y, maxY = corners[0].y;

    for (int i = 1; i < 4; i++) {
        if (corners[i].x < minX) minX = corners[i].x;
        if (corners[i].x > maxX) maxX = corners[i].x;
        if (corners[i].y < minY) minY = corners[i].y;
        if (corners[i].y > maxY) maxY = corners[i].y;
    }
    return CGRectMake(minX, minY, maxX - minX, maxY - minY);
}
