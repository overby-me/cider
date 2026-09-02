/*
 This file is part of Darling.

 Copyright (C) 2019 Lubos Dolezel

 Darling is free software: you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation, either version 3 of the License, or
 (at your option) any later version.

 Darling is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with Darling.  If not, see <http://www.gnu.org/licenses/>.
*/

/*
 * A LAYER THAT IS A PATH. This was an empty @implementation and setFillColor: raised, which killed
 * iTerm2 the same way the empty CAGradientLayer did.
 *
 * strokeStart and strokeEnd are carried but the stroke is NOT trimmed to them, because trimming
 * means re-walking the path by arc length and nothing here needs a partial stroke yet. A caller
 * that sets them gets the whole path, which is the pre-existing behaviour of the two defaults.
 */

#import <QuartzCore/CAShapeLayer.h>

NSString *const kCAFillRuleNonZero = @"non-zero";
NSString *const kCAFillRuleEvenOdd = @"even-odd";
NSString *const kCALineJoinMiter = @"miter";
NSString *const kCALineJoinRound = @"round";
NSString *const kCALineJoinBevel = @"bevel";
NSString *const kCALineCapButt = @"butt";
NSString *const kCALineCapRound = @"round";
NSString *const kCALineCapSquare = @"square";

@implementation CAShapeLayer

- init {
    if ((self = [super init]) == nil)
        return nil;

    _fillColor = CGColorCreateGenericGray(0, 1);
    _fillRule = [kCAFillRuleNonZero copy];
    _lineCap = [kCALineCapButt copy];
    _lineJoin = [kCALineJoinMiter copy];
    _lineWidth = 1.0;
    _miterLimit = 10.0;
    _strokeEnd = 1.0;
    return self;
}

- (void) dealloc {
    CGPathRelease(_path);
    CGColorRelease(_fillColor);
    CGColorRelease(_strokeColor);
    [_fillRule release];
    [_lineCap release];
    [_lineJoin release];
    [_lineDashPattern release];
    [super dealloc];
}

- (CGPathRef) path {
    return _path;
}

- (void) setPath: (CGPathRef) path {
    if (path == _path)
        return;

    CGPathRelease(_path);
    _path = CGPathRetain(path);
    [self setNeedsDisplay];
}

- (CGColorRef) fillColor {
    return _fillColor;
}

- (void) setFillColor: (CGColorRef) color {
    if (color == _fillColor)
        return;

    CGColorRelease(_fillColor);
    _fillColor = CGColorRetain(color);
    [self setNeedsDisplay];
}

- (CGColorRef) strokeColor {
    return _strokeColor;
}

- (void) setStrokeColor: (CGColorRef) color {
    if (color == _strokeColor)
        return;

    CGColorRelease(_strokeColor);
    _strokeColor = CGColorRetain(color);
    [self setNeedsDisplay];
}

- (CGFloat) lineWidth {
    return _lineWidth;
}

- (void) setLineWidth: (CGFloat) width {
    _lineWidth = width;
    [self setNeedsDisplay];
}

- (CGFloat) miterLimit {
    return _miterLimit;
}

- (void) setMiterLimit: (CGFloat) limit {
    _miterLimit = limit;
    [self setNeedsDisplay];
}

- (NSString *) fillRule {
    return _fillRule;
}

- (void) setFillRule: (NSString *) rule {
    if (rule == _fillRule)
        return;

    [_fillRule release];
    _fillRule = [rule copy];
    [self setNeedsDisplay];
}

- (NSString *) lineCap {
    return _lineCap;
}

- (void) setLineCap: (NSString *) cap {
    if (cap == _lineCap)
        return;

    [_lineCap release];
    _lineCap = [cap copy];
    [self setNeedsDisplay];
}

- (NSString *) lineJoin {
    return _lineJoin;
}

- (void) setLineJoin: (NSString *) join {
    if (join == _lineJoin)
        return;

    [_lineJoin release];
    _lineJoin = [join copy];
    [self setNeedsDisplay];
}

- (NSArray *) lineDashPattern {
    return _lineDashPattern;
}

- (void) setLineDashPattern: (NSArray *) pattern {
    if (pattern == _lineDashPattern)
        return;

    [_lineDashPattern release];
    _lineDashPattern = [pattern copy];
    [self setNeedsDisplay];
}

- (CGFloat) lineDashPhase {
    return _lineDashPhase;
}

- (void) setLineDashPhase: (CGFloat) phase {
    _lineDashPhase = phase;
    [self setNeedsDisplay];
}

- (CGFloat) strokeStart {
    return _strokeStart;
}

- (void) setStrokeStart: (CGFloat) start {
    _strokeStart = start;
}

- (CGFloat) strokeEnd {
    return _strokeEnd;
}

- (void) setStrokeEnd: (CGFloat) end {
    _strokeEnd = end;
}

- (void) drawInContext: (CGContextRef) context {
    if (context == NULL || _path == NULL)
        return;

    CGContextSaveGState(context);

    if ([_lineCap isEqualToString: kCALineCapRound])
        CGContextSetLineCap(context, kCGLineCapRound);
    else if ([_lineCap isEqualToString: kCALineCapSquare])
        CGContextSetLineCap(context, kCGLineCapSquare);

    if ([_lineJoin isEqualToString: kCALineJoinRound])
        CGContextSetLineJoin(context, kCGLineJoinRound);
    else if ([_lineJoin isEqualToString: kCALineJoinBevel])
        CGContextSetLineJoin(context, kCGLineJoinBevel);

    CGContextSetLineWidth(context, _lineWidth);
    CGContextSetMiterLimit(context, _miterLimit);

    if ([_lineDashPattern count] > 0) {
        NSUInteger count = [_lineDashPattern count];
        CGFloat *lengths = malloc(sizeof(CGFloat) * count);

        for (NSUInteger i = 0; i < count; i++)
            lengths[i] = [[_lineDashPattern objectAtIndex: i] doubleValue];
        CGContextSetLineDash(context, _lineDashPhase, lengths, count);
        free(lengths);
    }

    if (_fillColor != NULL) {
        CGContextAddPath(context, _path);
        CGContextSetFillColorWithColor(context, _fillColor);
        if ([_fillRule isEqualToString: kCAFillRuleEvenOdd])
            CGContextEOFillPath(context);
        else
            CGContextFillPath(context);
    }

    if (_strokeColor != NULL && _lineWidth > 0) {
        CGContextAddPath(context, _path);
        CGContextSetStrokeColorWithColor(context, _strokeColor);
        CGContextStrokePath(context);
    }

    CGContextRestoreGState(context);
}

@end
