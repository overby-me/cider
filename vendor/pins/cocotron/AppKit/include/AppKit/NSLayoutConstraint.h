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

#import <AppKit/AppKitExport.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/NSString.h>
#import <Foundation/NSArray.h>
#import <Foundation/NSObject.h>

typedef float NSLayoutPriority;

typedef NS_ENUM(NSInteger, NSLayoutConstraintOrientation) {
	NSLayoutConstraintOrientationHorizontal = 0,
	NSLayoutConstraintOrientationVertical = 1,
};

APPKIT_EXPORT const CGFloat NSViewNoInstrinsicMetric;
APPKIT_EXPORT const CGFloat NSViewNoIntrinsicMetric;

/*
 * AUTO LAYOUT, AS FAR AS AN APPLICATION THAT ONLY MAKES CONSTRAINTS NEEDS IT.
 *
 * MoneyMoney reaches for exactly three things once AppKit claims to be newer than 10.15:
 * +constraintWithItem:..., the class itself, and -setActive:. Two constraints, activated once. What
 * it does NOT do is rely on a solver for its layout, because every view in its nibs still carries an
 * autoresizing mask and translatesAutoresizingMaskIntoConstraints defaults to YES.
 *
 * So there is an object and its accounting, and no solver. THE CLASS ITSELF IS IN FOUNDATION, which
 * has carried a stub of that name since the nib decoder needed one, along with three subclasses of
 * it. Two Objective-C classes with one name is a coin toss the runtime announces and then resolves
 * however it likes, and the application got the stub. See Foundation/NSLayoutConstraint.h.
 */
#import <Foundation/NSLayoutConstraint.h>
