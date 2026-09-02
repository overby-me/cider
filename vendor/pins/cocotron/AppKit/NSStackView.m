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

/*
 * A ROW OR A COLUMN OF VIEWS, laid out here rather than described.
 *
 * This was a forwarding stub, and a stub is worse than nothing for a class like this one. Its
 * signature said every method takes two arguments and returns void, so a two-argument call went
 * through the wrong slots entirely: the log filled with
 *
 *     NSForwardSignatureError: invoked with 4 args, but 2 expected. Selector addView:inGravity:
 *
 * and the run ended in a SIGSEGV inside objc_retain on a value that was never an object. iA Writer
 * builds its toolbars and its inspector out of stack views, so this was not survivable.
 *
 * UNLIKE the constraints, this one LAYS OUT, because it can: a stack is a single row or column and
 * needs no solver. Views are placed in gravity order along the orientation, spaced by `spacing` and
 * inset by `edgeInsets`, and each is given its fitting size along the axis and the full width or
 * height across it. Distribution and alignment are recorded but do not yet change the placement.
 */

#import <AppKit/NSStackView.h>

@implementation NSStackView

+ (instancetype) stackViewWithViews: (NSArray *) views {
    NSStackView *stack = [[[self alloc] initWithFrame: NSMakeRect(0, 0, 0, 0)] autorelease];

    for (NSView *view in views)
        [stack addArrangedSubview: view];
    return stack;
}

- initWithFrame: (NSRect) frame {
    if ((self = [super initWithFrame: frame]) == nil)
        return nil;

    _arrangedSubviews = [[NSMutableArray alloc] init];
    _gravities = [[NSMutableDictionary alloc] init];
    _visibilityPriorities = [[NSMutableDictionary alloc] init];
    _orientation = NSUserInterfaceLayoutOrientationHorizontal;
    _distribution = NSStackViewDistributionGravityAreas;
    _alignment = NSLayoutAttributeCenterY;
    _spacing = 8.0;
    _detachesHiddenViews = YES;
    return self;
}

- initWithCoder: (NSCoder *) coder {
    if ((self = [super initWithCoder: coder]) == nil)
        return nil;

    _arrangedSubviews = [[NSMutableArray alloc] init];
    _gravities = [[NSMutableDictionary alloc] init];
    _visibilityPriorities = [[NSMutableDictionary alloc] init];
    _spacing = 8.0;
    _detachesHiddenViews = YES;

    if ([coder allowsKeyedCoding]) {
        _orientation = [coder decodeIntegerForKey: @"NSStackViewOrientation"];
        if ([coder containsValueForKey: @"NSStackViewSpacing"])
            _spacing = [coder decodeDoubleForKey: @"NSStackViewSpacing"];
    }
    return self;
}

- (void) dealloc {
    [_arrangedSubviews release];
    [_gravities release];
    [_visibilityPriorities release];
    [super dealloc];
}

/* The key for a per-view table: the pointer, because a view is not copyable and not comparable. */
static NSNumber *_CiderViewKey(NSView *view) {
    return [NSNumber numberWithUnsignedLongLong: (unsigned long long) (uintptr_t) view];
}

- (NSArray *) arrangedSubviews {
    return _arrangedSubviews;
}

- (void) addArrangedSubview: (NSView *) view {
    [self insertArrangedSubview: view atIndex: [_arrangedSubviews count]];
}

- (void) insertArrangedSubview: (NSView *) view atIndex: (NSInteger) index {
    if (view == nil)
        return;

    if (index < 0 || index > (NSInteger) [_arrangedSubviews count])
        index = [_arrangedSubviews count];

    [_arrangedSubviews insertObject: view atIndex: index];
    if ([view superview] != self)
        [self addSubview: view];
    [self layout];
}

- (void) removeArrangedSubview: (NSView *) view {
    NSUInteger index = [_arrangedSubviews indexOfObjectIdenticalTo: view];

    if (index == NSNotFound)
        return;

    [_arrangedSubviews removeObjectAtIndex: index];
    [_gravities removeObjectForKey: _CiderViewKey(view)];
    [_visibilityPriorities removeObjectForKey: _CiderViewKey(view)];
    [self layout];
}

/*
 * Gravity decides WHERE in the stack a view sits, and the arranged order is what layout walks, so a
 * view is inserted after the last one of the same or an earlier gravity. That is what makes leading
 * views come before centre ones and centre before trailing without a separate pass.
 */
- (void) addView: (NSView *) view inGravity: (NSStackViewGravity) gravity {
    NSUInteger insertAt = 0;

    for (NSView *existing in _arrangedSubviews) {
        NSNumber *held = [_gravities objectForKey: _CiderViewKey(existing)];
        NSStackViewGravity other = held != nil ? (NSStackViewGravity) [held integerValue]
                                               : NSStackViewGravityLeading;

        if (other > gravity)
            break;
        insertAt++;
    }

    [_gravities setObject: [NSNumber numberWithInteger: gravity] forKey: _CiderViewKey(view)];
    [self insertArrangedSubview: view atIndex: (NSInteger) insertAt];
}

- (void) insertView: (NSView *) view
            atIndex: (NSUInteger) index
          inGravity: (NSStackViewGravity) gravity
{
    [_gravities setObject: [NSNumber numberWithInteger: gravity] forKey: _CiderViewKey(view)];
    [self insertArrangedSubview: view atIndex: (NSInteger) index];
}

- (void) removeView: (NSView *) view {
    [self removeArrangedSubview: view];
    [view removeFromSuperview];
}

- (NSArray *) viewsInGravity: (NSStackViewGravity) gravity {
    NSMutableArray *result = [NSMutableArray array];

    for (NSView *view in _arrangedSubviews) {
        NSNumber *held = [_gravities objectForKey: _CiderViewKey(view)];
        NSStackViewGravity other = held != nil ? (NSStackViewGravity) [held integerValue]
                                               : NSStackViewGravityLeading;

        if (other == gravity)
            [result addObject: view];
    }
    return result;
}

- (NSStackViewVisibilityPriority) visibilityPriorityForView: (NSView *) view {
    NSNumber *held = [_visibilityPriorities objectForKey: _CiderViewKey(view)];

    return held != nil ? (NSStackViewVisibilityPriority) [held floatValue] : 1000;
}

- (void) setVisibilityPriority: (NSStackViewVisibilityPriority) priority
                       forView: (NSView *) view
{
    if (view == nil)
        return;
    [_visibilityPriorities setObject: [NSNumber numberWithFloat: priority]
                             forKey: _CiderViewKey(view)];
}

/*
 * HOW HARD THE STACK HOLDS ITS SIZE, per orientation. Nothing negotiates sizes here, so these are
 * carried and reported; they are the stack's own, distinct from a view's content priorities.
 */
- (NSLayoutPriority) huggingPriorityForOrientation: (NSUserInterfaceLayoutOrientation) orientation {
    return orientation == NSUserInterfaceLayoutOrientationHorizontal ? _huggingHorizontal
                                                                     : _huggingVertical;
}

- (void) setHuggingPriority: (NSLayoutPriority) priority
             forOrientation: (NSUserInterfaceLayoutOrientation) orientation
{
    if (orientation == NSUserInterfaceLayoutOrientationHorizontal)
        _huggingHorizontal = priority;
    else
        _huggingVertical = priority;
}

- (NSLayoutPriority) clippingResistancePriorityForOrientation:
        (NSUserInterfaceLayoutOrientation) orientation
{
    return orientation == NSUserInterfaceLayoutOrientationHorizontal ? _clippingHorizontal
                                                                     : _clippingVertical;
}

- (void) setClippingResistancePriority: (NSLayoutPriority) priority
                        forOrientation: (NSUserInterfaceLayoutOrientation) orientation
{
    if (orientation == NSUserInterfaceLayoutOrientationHorizontal)
        _clippingHorizontal = priority;
    else
        _clippingVertical = priority;
}

- (NSUserInterfaceLayoutOrientation) orientation {
    return _orientation;
}

- (void) setOrientation: (NSUserInterfaceLayoutOrientation) orientation {
    _orientation = orientation;
    [self layout];
}

- (NSStackViewDistribution) distribution {
    return _distribution;
}

- (void) setDistribution: (NSStackViewDistribution) distribution {
    _distribution = distribution;
}

- (NSLayoutAttribute) alignment {
    return _alignment;
}

- (void) setAlignment: (NSLayoutAttribute) alignment {
    _alignment = alignment;
}

- (NSEdgeInsets) edgeInsets {
    return _edgeInsets;
}

- (void) setEdgeInsets: (NSEdgeInsets) insets {
    _edgeInsets = insets;
    [self layout];
}

- (CGFloat) spacing {
    return _spacing;
}

- (void) setSpacing: (CGFloat) spacing {
    _spacing = spacing;
    [self layout];
}

- (BOOL) detachesHiddenViews {
    return _detachesHiddenViews;
}

- (void) setDetachesHiddenViews: (BOOL) detaches {
    _detachesHiddenViews = detaches;
}

/* Each view keeps its fitting size along the axis and fills the stack across it. */
- (void) layout {
    NSRect bounds = [self bounds];
    CGFloat position = _orientation == NSUserInterfaceLayoutOrientationHorizontal
                               ? _edgeInsets.left
                               : _edgeInsets.top;
    BOOL first = YES;

    for (NSView *view in _arrangedSubviews) {
        NSSize fitting;
        NSRect frame;

        if (_detachesHiddenViews && [view isHidden])
            continue;

        if (first == NO)
            position += _spacing;
        first = NO;

        fitting = [view fittingSize];

        if (_orientation == NSUserInterfaceLayoutOrientationHorizontal) {
            frame.origin.x = position;
            frame.origin.y = _edgeInsets.bottom;
            frame.size.width = fitting.width;
            frame.size.height = bounds.size.height - _edgeInsets.top - _edgeInsets.bottom;
            position += frame.size.width;
        } else {
            frame.origin.x = _edgeInsets.left;
            frame.size.width = bounds.size.width - _edgeInsets.left - _edgeInsets.right;
            frame.size.height = fitting.height;
            /* Vertical stacks run top down, and this is a flipped-independent way to say so. */
            frame.origin.y = bounds.size.height - position - frame.size.height;
            position += frame.size.height;
        }

        if (frame.size.width < 0)
            frame.size.width = 0;
        if (frame.size.height < 0)
            frame.size.height = 0;
        [view setFrame: frame];
    }

    [super layout];
}

@end
