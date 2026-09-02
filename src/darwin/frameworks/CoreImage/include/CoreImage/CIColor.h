/*
 This file is part of Darling.

 Copyright (C) 2017 Lubos Dolezel

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

#include <Foundation/Foundation.h>
#include <CoreGraphics/CGColor.h>

@interface CIColor : NSObject

+ (instancetype) colorWithCGColor: (CGColorRef) cgColor;
+ (instancetype) colorWithRed: (CGFloat) red green: (CGFloat) green blue: (CGFloat) blue;
+ (instancetype) colorWithRed: (CGFloat) red
                        green: (CGFloat) green
                         blue: (CGFloat) blue
                        alpha: (CGFloat) alpha;

- (instancetype) initWithCGColor: (CGColorRef) cgColor;
- (instancetype) initWithRed: (CGFloat) red green: (CGFloat) green blue: (CGFloat) blue;
- (instancetype) initWithRed: (CGFloat) red
                       green: (CGFloat) green
                        blue: (CGFloat) blue
                       alpha: (CGFloat) alpha;
/* An NSColor, typed id because CoreImage does not link AppKit. */
- (instancetype) initWithColor: (id) color;

/* Always four, so [0] through [3] are in bounds whatever space the colour came from. */
- (const CGFloat *) components;
- (size_t) numberOfComponents;

- (CGColorRef) CGColor;
- (CGColorSpaceRef) colorSpace;
- (CGFloat) red;
- (CGFloat) green;
- (CGFloat) blue;
- (CGFloat) alpha;
- (NSString *) stringRepresentation;

@end
