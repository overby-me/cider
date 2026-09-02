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

#import <AppKit/AppKitExport.h>
#import <AppKit/NSLayoutConstraint.h>
#import <AppKit/NSViewController.h>
#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, NSSplitViewItemBehavior) {
    NSSplitViewItemBehaviorDefault = 0,
    NSSplitViewItemBehaviorSidebar = 1,
    NSSplitViewItemBehaviorContentList = 2,
    NSSplitViewItemBehaviorInspector = 3,
};

typedef NS_ENUM(NSInteger, NSSplitViewItemCollapseBehavior) {
    NSSplitViewItemCollapseBehaviorDefault = 0,
    NSSplitViewItemCollapseBehaviorPreferResizingSplitViewWithFixedSiblings = 1,
    NSSplitViewItemCollapseBehaviorPreferResizingSiblingsWithFixedSplitView = 2,
    NSSplitViewItemCollapseBehaviorUseConstraints = 3,
};

APPKIT_EXPORT const CGFloat NSSplitViewItemUnspecifiedDimension;

@interface NSSplitViewItem : NSObject <NSCoding> {
    NSViewController *_viewController;
    CGFloat _minimumThickness;
    CGFloat _maximumThickness;
    CGFloat _preferredThicknessFraction;
    CGFloat _automaticMaximumThickness;
    NSLayoutPriority _holdingPriority;
    NSSplitViewItemBehavior _behavior;
    NSSplitViewItemCollapseBehavior _collapseBehavior;
    BOOL _collapsed;
    BOOL _canCollapse;
    BOOL _springLoaded;
    BOOL _allowsFullHeightLayout;
}

+ (instancetype) splitViewItemWithViewController: (NSViewController *) viewController;
+ (instancetype) sidebarWithViewController: (NSViewController *) viewController;
+ (instancetype) contentListWithViewController: (NSViewController *) viewController;
+ (instancetype) inspectorWithViewController: (NSViewController *) viewController;

- (NSViewController *) viewController;
- (void) setViewController: (NSViewController *) viewController;

- (NSSplitViewItemBehavior) behavior;
- (void) setBehavior: (NSSplitViewItemBehavior) behavior;

- (NSSplitViewItemCollapseBehavior) collapseBehavior;
- (void) setCollapseBehavior: (NSSplitViewItemCollapseBehavior) behavior;

- (BOOL) isCollapsed;
- (void) setCollapsed: (BOOL) collapsed;

- (BOOL) canCollapse;
- (void) setCanCollapse: (BOOL) canCollapse;

- (CGFloat) minimumThickness;
- (void) setMinimumThickness: (CGFloat) thickness;

- (CGFloat) maximumThickness;
- (void) setMaximumThickness: (CGFloat) thickness;

- (CGFloat) preferredThicknessFraction;
- (void) setPreferredThicknessFraction: (CGFloat) fraction;

- (CGFloat) automaticMaximumThickness;
- (void) setAutomaticMaximumThickness: (CGFloat) thickness;

- (NSLayoutPriority) holdingPriority;
- (void) setHoldingPriority: (NSLayoutPriority) priority;

- (BOOL) isSpringLoaded;
- (void) setSpringLoaded: (BOOL) springLoaded;

- (BOOL) allowsFullHeightLayout;
- (void) setAllowsFullHeightLayout: (BOOL) allows;

@end
