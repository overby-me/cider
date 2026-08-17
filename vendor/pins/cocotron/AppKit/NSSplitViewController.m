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

    [self setView: splitView];
}

- (NSSplitView *) splitView {
    NSView *view = [self view];

    return [view isKindOfClass: [NSSplitView class]] ? (NSSplitView *) view : nil;
}

- (void) setSplitView: (NSSplitView *) splitView {
    [self setView: splitView];
}

- (NSMethodSignature *)methodSignatureForSelector:(SEL)aSelector
{
    return [NSMethodSignature signatureWithObjCTypes: "v@:"];
}

- (void)forwardInvocation:(NSInvocation *)anInvocation
{
    NSLog(@"Stub called: %@ in %@", NSStringFromSelector([anInvocation selector]), [self class]);
}

@end
