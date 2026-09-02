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
 * A PANE IN A SPLIT VIEW CONTROLLER, and what it was before this was a forwarding stub.
 *
 * The stub answered every selector through forwardInvocation, which cannot help a CLASS method at
 * all: iA Writer builds its library window out of these and died on
 * +[NSSplitViewItem splitViewItemWithViewController:] with an unrecognized selector.
 *
 * The item is a description, not a view: it holds the controller and the sizes, and
 * NSSplitViewController is what reads them when it arranges its split view.
 */

#import <AppKit/NSSplitViewItem.h>

const CGFloat NSSplitViewItemUnspecifiedDimension = -1.0;

@implementation NSSplitViewItem

+ (instancetype) splitViewItemWithViewController: (NSViewController *) viewController {
    NSSplitViewItem *item = [[[self alloc] init] autorelease];

    [item setViewController: viewController];
    return item;
}

/*
 * A sidebar collapses and a plain pane does not, which is the only difference these behaviours make
 * here. The visual effects material behind a real sidebar is not drawn.
 */
+ (instancetype) sidebarWithViewController: (NSViewController *) viewController {
    NSSplitViewItem *item = [self splitViewItemWithViewController: viewController];

    [item setBehavior: NSSplitViewItemBehaviorSidebar];
    [item setCanCollapse: YES];
    return item;
}

+ (instancetype) contentListWithViewController: (NSViewController *) viewController {
    NSSplitViewItem *item = [self splitViewItemWithViewController: viewController];

    [item setBehavior: NSSplitViewItemBehaviorContentList];
    return item;
}

+ (instancetype) inspectorWithViewController: (NSViewController *) viewController {
    NSSplitViewItem *item = [self splitViewItemWithViewController: viewController];

    [item setBehavior: NSSplitViewItemBehaviorInspector];
    [item setCanCollapse: YES];
    return item;
}

- init {
    if ((self = [super init]) == nil)
        return nil;

    _minimumThickness = NSSplitViewItemUnspecifiedDimension;
    _maximumThickness = NSSplitViewItemUnspecifiedDimension;
    _preferredThicknessFraction = NSSplitViewItemUnspecifiedDimension;
    _automaticMaximumThickness = NSSplitViewItemUnspecifiedDimension;
    _holdingPriority = 250; /* NSLayoutPriorityDefaultLow */
    return self;
}

- initWithCoder: (NSCoder *) coder {
    if ((self = [self init]) == nil)
        return nil;

    if ([coder allowsKeyedCoding]) {
        _viewController = [[coder decodeObjectForKey: @"NSViewController"] retain];
        _collapsed = [coder decodeBoolForKey: @"NSCollapsed"];
        _canCollapse = [coder decodeBoolForKey: @"NSCanCollapse"];
    }
    return self;
}

- (void) encodeWithCoder: (NSCoder *) coder {
    if ([coder allowsKeyedCoding]) {
        [coder encodeObject: _viewController forKey: @"NSViewController"];
        [coder encodeBool: _collapsed forKey: @"NSCollapsed"];
        [coder encodeBool: _canCollapse forKey: @"NSCanCollapse"];
    }
}

- (void) dealloc {
    [_viewController release];
    [super dealloc];
}

- (NSViewController *) viewController {
    return _viewController;
}

- (void) setViewController: (NSViewController *) viewController {
    [viewController retain];
    [_viewController release];
    _viewController = viewController;
}

- (NSSplitViewItemBehavior) behavior {
    return _behavior;
}

- (void) setBehavior: (NSSplitViewItemBehavior) behavior {
    _behavior = behavior;
}

- (NSSplitViewItemCollapseBehavior) collapseBehavior {
    return _collapseBehavior;
}

- (void) setCollapseBehavior: (NSSplitViewItemCollapseBehavior) behavior {
    _collapseBehavior = behavior;
}

- (BOOL) isCollapsed {
    return _collapsed;
}

/* The pane's view is hidden rather than removed, so the controller keeps its place in the order. */
- (void) setCollapsed: (BOOL) collapsed {
    _collapsed = collapsed;
    [[_viewController view] setHidden: collapsed];
}

- (BOOL) canCollapse {
    return _canCollapse;
}

- (void) setCanCollapse: (BOOL) canCollapse {
    _canCollapse = canCollapse;
}

- (CGFloat) minimumThickness {
    return _minimumThickness;
}

- (void) setMinimumThickness: (CGFloat) thickness {
    _minimumThickness = thickness;
}

- (CGFloat) maximumThickness {
    return _maximumThickness;
}

- (void) setMaximumThickness: (CGFloat) thickness {
    _maximumThickness = thickness;
}

- (CGFloat) preferredThicknessFraction {
    return _preferredThicknessFraction;
}

- (void) setPreferredThicknessFraction: (CGFloat) fraction {
    _preferredThicknessFraction = fraction;
}

- (CGFloat) automaticMaximumThickness {
    return _automaticMaximumThickness;
}

- (void) setAutomaticMaximumThickness: (CGFloat) thickness {
    _automaticMaximumThickness = thickness;
}

- (NSLayoutPriority) holdingPriority {
    return _holdingPriority;
}

- (void) setHoldingPriority: (NSLayoutPriority) priority {
    _holdingPriority = priority;
}

- (BOOL) isSpringLoaded {
    return _springLoaded;
}

- (void) setSpringLoaded: (BOOL) springLoaded {
    _springLoaded = springLoaded;
}

- (BOOL) allowsFullHeightLayout {
    return _allowsFullHeightLayout;
}

- (void) setAllowsFullHeightLayout: (BOOL) allows {
    _allowsFullHeightLayout = allows;
}

@end
