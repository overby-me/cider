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

#import <QuartzCore/CALayer.h>

CA_EXPORT NSString *const kCAFillRuleNonZero;
CA_EXPORT NSString *const kCAFillRuleEvenOdd;
CA_EXPORT NSString *const kCALineJoinMiter;
CA_EXPORT NSString *const kCALineJoinRound;
CA_EXPORT NSString *const kCALineJoinBevel;
CA_EXPORT NSString *const kCALineCapButt;
CA_EXPORT NSString *const kCALineCapRound;
CA_EXPORT NSString *const kCALineCapSquare;

@interface CAShapeLayer : CALayer {
    CGPathRef _path;
    CGColorRef _fillColor;
    CGColorRef _strokeColor;
    NSString *_fillRule;
    NSString *_lineCap;
    NSString *_lineJoin;
    NSArray *_lineDashPattern;
    CGFloat _lineWidth;
    CGFloat _lineDashPhase;
    CGFloat _miterLimit;
    CGFloat _strokeStart;
    CGFloat _strokeEnd;
}

- (CGPathRef) path;
- (void) setPath: (CGPathRef) path;

- (CGColorRef) fillColor;
- (void) setFillColor: (CGColorRef) color;
- (CGColorRef) strokeColor;
- (void) setStrokeColor: (CGColorRef) color;

- (CGFloat) lineWidth;
- (void) setLineWidth: (CGFloat) width;
- (CGFloat) miterLimit;
- (void) setMiterLimit: (CGFloat) limit;

- (NSString *) fillRule;
- (void) setFillRule: (NSString *) rule;
- (NSString *) lineCap;
- (void) setLineCap: (NSString *) cap;
- (NSString *) lineJoin;
- (void) setLineJoin: (NSString *) join;

- (NSArray *) lineDashPattern;
- (void) setLineDashPattern: (NSArray *) pattern;
- (CGFloat) lineDashPhase;
- (void) setLineDashPhase: (CGFloat) phase;

/* Carried, but the stroke is not trimmed to them. */
- (CGFloat) strokeStart;
- (void) setStrokeStart: (CGFloat) start;
- (CGFloat) strokeEnd;
- (void) setStrokeEnd: (CGFloat) end;

@end
