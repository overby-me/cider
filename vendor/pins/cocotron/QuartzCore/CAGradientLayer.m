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
 * A LAYER THAT IS A GRADIENT. This was an empty @implementation, so setColors: raised and killed
 * iTerm2 outright: an unrecognized selector on a layer is not caught by anything.
 *
 * The points are in the UNIT SQUARE of the layer, not in its coordinates, which is what lets the
 * same layer be resized without touching the gradient.
 */

#import <QuartzCore/CAGradientLayer.h>

NSString *const kCAGradientLayerAxial = @"axial";
NSString *const kCAGradientLayerRadial = @"radial";
NSString *const kCAGradientLayerConic = @"conic";

@implementation CAGradientLayer

- init {
    if ((self = [super init]) == nil)
        return nil;

    _startPoint = CGPointMake(0.5, 0.0);
    _endPoint = CGPointMake(0.5, 1.0);
    _type = [kCAGradientLayerAxial copy];
    return self;
}

- (void) dealloc {
    [_colors release];
    [_locations release];
    [_type release];
    [super dealloc];
}

- (NSArray *) colors {
    return _colors;
}

- (void) setColors: (NSArray *) colors {
    if (colors == _colors)
        return;

    [_colors release];
    _colors = [colors copy];
    [self setNeedsDisplay];
}

- (NSArray *) locations {
    return _locations;
}

- (void) setLocations: (NSArray *) locations {
    if (locations == _locations)
        return;

    [_locations release];
    _locations = [locations copy];
    [self setNeedsDisplay];
}

- (CGPoint) startPoint {
    return _startPoint;
}

- (void) setStartPoint: (CGPoint) point {
    _startPoint = point;
    [self setNeedsDisplay];
}

- (CGPoint) endPoint {
    return _endPoint;
}

- (void) setEndPoint: (CGPoint) point {
    _endPoint = point;
    [self setNeedsDisplay];
}

- (NSString *) type {
    return _type;
}

- (void) setType: (NSString *) type {
    if (type == _type)
        return;

    [_type release];
    _type = [type copy];
    [self setNeedsDisplay];
}

/*
 * The array holds CGColorRefs, so it is handed to CGGradientCreateWithColors as it is. With no
 * locations the stops are spread evenly, which is what an absent locations array means.
 */
- (void) drawInContext: (CGContextRef) context {
    CGRect bounds = [self bounds];
    CGColorSpaceRef space;
    CGGradientRef gradient;
    CGFloat *stops = NULL;
    CGPoint start, end;

    if (context == NULL || [_colors count] < 2)
        return;

    if ([_locations count] == [_colors count]) {
        NSUInteger count = [_locations count];

        stops = malloc(sizeof(CGFloat) * count);
        for (NSUInteger i = 0; i < count; i++)
            stops[i] = [[_locations objectAtIndex: i] doubleValue];
    }

    space = CGColorSpaceCreateDeviceRGB();
    gradient = CGGradientCreateWithColors(space, (CFArrayRef) _colors, stops);
    CGColorSpaceRelease(space);
    free(stops);

    if (gradient == NULL)
        return;

    start = CGPointMake(bounds.origin.x + _startPoint.x * bounds.size.width,
                        bounds.origin.y + _startPoint.y * bounds.size.height);
    end = CGPointMake(bounds.origin.x + _endPoint.x * bounds.size.width,
                      bounds.origin.y + _endPoint.y * bounds.size.height);

    if ([_type isEqualToString: kCAGradientLayerRadial]) {
        CGFloat radius = MAX(bounds.size.width, bounds.size.height) / 2;

        CGContextDrawRadialGradient(context, gradient, start, 0, start, radius,
                                    kCGGradientDrawsBeforeStartLocation |
                                            kCGGradientDrawsAfterEndLocation);
    } else {
        CGContextDrawLinearGradient(context, gradient, start, end,
                                    kCGGradientDrawsBeforeStartLocation |
                                            kCGGradientDrawsAfterEndLocation);
    }

    CGGradientRelease(gradient);
}

@end
