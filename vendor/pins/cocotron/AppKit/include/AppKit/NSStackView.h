/*
 This file is part of Darling.

 Copyright (C) 2021 Lubos Dolezel

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

#import <AppKit/NSLayoutConstraint.h>
#import <AppKit/NSView.h>

typedef NS_ENUM(NSInteger, NSUserInterfaceLayoutOrientation) {
    NSUserInterfaceLayoutOrientationHorizontal = 0,
    NSUserInterfaceLayoutOrientationVertical = 1,
};

typedef NS_ENUM(NSInteger, NSStackViewGravity) {
    NSStackViewGravityTop = 1,
    NSStackViewGravityLeading = 1,
    NSStackViewGravityCenter = 2,
    NSStackViewGravityBottom = 3,
    NSStackViewGravityTrailing = 3,
};

typedef NS_ENUM(NSInteger, NSStackViewDistribution) {
    NSStackViewDistributionGravityAreas = -1,
    NSStackViewDistributionFill = 0,
    NSStackViewDistributionFillEqually = 1,
    NSStackViewDistributionFillProportionally = 2,
    NSStackViewDistributionEqualSpacing = 3,
    NSStackViewDistributionEqualCentering = 4,
};

typedef float NSStackViewVisibilityPriority;

@interface NSStackView : NSView {
    NSMutableArray *_arrangedSubviews;
    NSMutableDictionary *_gravities;
    NSMutableDictionary *_visibilityPriorities;
    NSUserInterfaceLayoutOrientation _orientation;
    NSStackViewDistribution _distribution;
    NSLayoutAttribute _alignment;
    NSEdgeInsets _edgeInsets;
    CGFloat _spacing;
    BOOL _detachesHiddenViews;
    NSLayoutPriority _huggingHorizontal;
    NSLayoutPriority _huggingVertical;
    NSLayoutPriority _clippingHorizontal;
    NSLayoutPriority _clippingVertical;
}

+ (instancetype) stackViewWithViews: (NSArray *) views;

- (NSArray *) arrangedSubviews;
- (void) addArrangedSubview: (NSView *) view;
- (void) insertArrangedSubview: (NSView *) view atIndex: (NSInteger) index;
- (void) removeArrangedSubview: (NSView *) view;

- (void) addView: (NSView *) view inGravity: (NSStackViewGravity) gravity;
- (void) insertView: (NSView *) view
            atIndex: (NSUInteger) index
          inGravity: (NSStackViewGravity) gravity;
- (void) removeView: (NSView *) view;
- (NSArray *) viewsInGravity: (NSStackViewGravity) gravity;

- (NSStackViewVisibilityPriority) visibilityPriorityForView: (NSView *) view;
- (void) setVisibilityPriority: (NSStackViewVisibilityPriority) priority
                       forView: (NSView *) view;

- (NSUserInterfaceLayoutOrientation) orientation;
- (void) setOrientation: (NSUserInterfaceLayoutOrientation) orientation;
- (NSStackViewDistribution) distribution;
- (void) setDistribution: (NSStackViewDistribution) distribution;
- (NSLayoutAttribute) alignment;
- (void) setAlignment: (NSLayoutAttribute) alignment;
- (NSEdgeInsets) edgeInsets;
- (void) setEdgeInsets: (NSEdgeInsets) insets;
- (CGFloat) spacing;
- (void) setSpacing: (CGFloat) spacing;
- (NSLayoutPriority) huggingPriorityForOrientation: (NSUserInterfaceLayoutOrientation) orientation;
- (void) setHuggingPriority: (NSLayoutPriority) priority
             forOrientation: (NSUserInterfaceLayoutOrientation) orientation;
- (NSLayoutPriority) clippingResistancePriorityForOrientation:
        (NSUserInterfaceLayoutOrientation) orientation;
- (void) setClippingResistancePriority: (NSLayoutPriority) priority
                        forOrientation: (NSUserInterfaceLayoutOrientation) orientation;
- (BOOL) detachesHiddenViews;
- (void) setDetachesHiddenViews: (BOOL) detaches;

@end
