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

#import <AppKit/NSSplitView.h>
#import <AppKit/NSSplitViewController.h>
#import <AppKit/NSSplitViewItem.h>
#import <AppKit/NSWindow.h>

@implementation NSSplitViewController

/*
 * A SPLIT VIEW CONTROLLER MAKES A SPLIT VIEW, which is the whole reason the class exists.
 *
 * -[NSViewController loadView] now hands back a plain NSView when there is no nib, which is what
 * AppKit documents and what let Swift Publisher get past the exception this class used to cause.
 * But a plain NSView is not what a split view controller is for: the application then sent
 *
 *   -[NSView adjustSubviews]: unrecognized selector
 *
 * because adjustSubviews lives on NSSplitView. That was a consequence of the fallback, not of the
 * application doing anything unusual, and the place to fix it is here rather than by special casing
 * classes inside NSViewController: a subclass that wants a particular view overrides loadView, and
 * this is that subclass.
 *
 * WHAT IS STILL MISSING is the split view ITEM machinery, addSplitViewItem: and splitViewItems, so
 * a controller built this way has a real split view with no children in it yet. The forwarding
 * stubs below still catch those and log them.
 */
- (void) loadView {
    NSSplitView *splitView = [[[NSSplitView alloc]
            initWithFrame: NSMakeRect(0, 0, 0, 0)] autorelease];

    [splitView setDelegate: self];
    [self setView: splitView];

    /* Items added before the view existed have no pane yet, so place them now. */
    for (NSSplitViewItem *item in [self splitViewItems]) {
        NSView *view = [[item viewController] view];

        if (view != nil)
            [splitView addSubview: view];
    }
    [splitView adjustSubviews];
}

- (NSSplitView *) splitView {
    NSView *view = [self view];

    return [view isKindOfClass: [NSSplitView class]] ? (NSSplitView *) view : nil;
}

- (void) setSplitView: (NSSplitView *) splitView {
    [self setView: splitView];
}

/*
 * THE ITEMS, which is what the controller is FOR.
 *
 * An item is a description: a controller and the sizes it will accept. Adding one puts that
 * controller's view into the split view, in the item's order, and the split view does the rest.
 * The items are held here rather than in the split view because collapsing an item must not lose
 * its place, and because the application asks for them back.
 */
- (NSArray *) splitViewItems {
    if (_ciderSplitViewItems == nil)
        _ciderSplitViewItems = [[NSMutableArray alloc] init];
    return _ciderSplitViewItems;
}

- (void) setSplitViewItems: (NSArray *) items {
    while ([[self splitViewItems] count] > 0)
        [self removeSplitViewItem: [[self splitViewItems] objectAtIndex: 0]];

    for (NSSplitViewItem *item in items)
        [self addSplitViewItem: item];
}

- (void) addSplitViewItem: (NSSplitViewItem *) item {
    [self insertSplitViewItem: item atIndex: [[self splitViewItems] count]];
}

- (void) insertSplitViewItem: (NSSplitViewItem *) item atIndex: (NSInteger) index {
    if (item == nil)
        return;

    NSMutableArray *items = (NSMutableArray *) [self splitViewItems];
    if (index < 0 || index > (NSInteger) [items count])
        index = [items count];
    [items insertObject: item atIndex: index];

    NSViewController *controller = [item viewController];
    if (controller != nil) {
        [self insertChildViewController: controller atIndex: index];

        /* -view builds it, which is the point at which the pane exists at all. */
        NSView *view = [controller view];
        NSSplitView *splitView = [self splitView];

        if (view != nil && splitView != nil) {
            NSArray *panes = [splitView subviews];

            if (index >= (NSInteger) [panes count])
                [splitView addSubview: view];
            else
                [splitView addSubview: view
                          positioned: NSWindowBelow
                          relativeTo: [panes objectAtIndex: index]];
            [splitView adjustSubviews];
        }
    }
}

- (void) removeSplitViewItem: (NSSplitViewItem *) item {
    NSMutableArray *items = (NSMutableArray *) [self splitViewItems];
    NSUInteger index = [items indexOfObjectIdenticalTo: item];

    if (index == NSNotFound)
        return;

    NSViewController *controller = [item viewController];
    if (controller != nil) {
        [[controller view] removeFromSuperview];
        [controller removeFromParentViewController];
    }
    [items removeObjectAtIndex: index];
    [[self splitView] adjustSubviews];
}

- (NSSplitViewItem *) splitViewItemForViewController: (NSViewController *) controller {
    for (NSSplitViewItem *item in [self splitViewItems]) {
        if ([item viewController] == controller)
            return item;
    }
    return nil;
}

/*
 * The minimum and maximum a pane will accept, which the item carries and the split view asks for by
 * divider index. An unspecified dimension leaves the proposed position alone.
 */
- (CGFloat) splitView: (NSSplitView *) splitView
        constrainMinCoordinate: (CGFloat) proposed
                   ofSubviewAt: (NSInteger) dividerIndex
{
    NSArray *items = [self splitViewItems];

    if (dividerIndex < (NSInteger) [items count]) {
        NSSplitViewItem *item = [items objectAtIndex: dividerIndex];
        CGFloat minimum = [item minimumThickness];

        if (minimum != NSSplitViewItemUnspecifiedDimension && minimum > proposed)
            return minimum;
    }
    return proposed;
}

- (CGFloat) splitView: (NSSplitView *) splitView
        constrainMaxCoordinate: (CGFloat) proposed
                   ofSubviewAt: (NSInteger) dividerIndex
{
    NSArray *items = [self splitViewItems];

    if (dividerIndex < (NSInteger) [items count]) {
        NSSplitViewItem *item = [items objectAtIndex: dividerIndex];
        CGFloat maximum = [item maximumThickness];

        if (maximum != NSSplitViewItemUnspecifiedDimension && maximum < proposed)
            return maximum;
    }
    return proposed;
}

- (BOOL) splitView: (NSSplitView *) splitView canCollapseSubview: (NSView *) subview {
    for (NSSplitViewItem *item in [self splitViewItems]) {
        if ([[item viewController] view] == subview)
            return [item canCollapse];
    }
    return NO;
}

- (void) dealloc {
    [_ciderSplitViewItems release];
    [super dealloc];
}

@end
