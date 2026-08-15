/* Copyright (c) 2006-2007 Christopher J. W. Lloyd <cjwl@objc.net>

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE. */

#import <AppKit/NSMainMenuView.h>
#include <objc/runtime.h>
#include <stdio.h>

#import <AppKit/NSMenuView.h>
#import <AppKit/NSMenuWindow.h>
#import <AppKit/NSRaise.h>

enum {
    kNSMenuKeyboardNavigationNone,
    kNSMenuKeyboardNavigationUp,
    kNSMenuKeyboardNavigationDown,
    kNSMenuKeyboardNavigationLeft,
    kNSMenuKeyboardNavigationRight,
    kNSMenuKeyboardNavigationLetter
};

@implementation NSMenuView

- (void) dealloc {
    [_visibleArray release];
    [super dealloc];
}

- (NSUInteger) itemIndexAtPoint: (NSPoint) point {
    NSInvalidAbstractInvocation();
    return NSNotFound;
}

- (NSUInteger) itemIndexAtPoint: (NSPoint) point rect: (NSRect*) rect {
    NSInvalidAbstractInvocation();
    return NSNotFound;
}

- (NSUInteger) selectedItemIndex {
    return _selectedItemIndex;
}

- (void) setSelectedItemIndex: (NSUInteger) itemIndex {
    if (_selectedItemIndex != itemIndex) {
        _selectedItemIndex = itemIndex;
        [self setNeedsDisplay: YES];
    }
}

- (NSArray *) itemArray {
    return [[self menu] itemArray];
}

/*
 * THE HELP MENU SEARCH, which is a real macOS feature and not a decoration.
 *
 * On macOS the Help menu has a search field at the top, and typing in it filters every menu the
 * application has. Cocotron has no view items in menus, so the field is not a field: typing while
 * the Help menu is open collects a query, the menu shows it on the first row, and the rows under it
 * become the matching items FROM EVERY MENU.
 *
 * THE MATCHES ARE THE ORIGINAL ITEMS, not copies. An application puts its own state on its menu
 * items -- LibreOffice hands a SalNSMenuItem to its own -menuItemTriggered: and reads a pointer off
 * it -- so a copied item with the same target and action would call that with a sender it cannot
 * use. Putting the real item in the list means the click is the same click it would have been in
 * the menu it came from.
 */
/* The window a filtered menu lives in has to change size with it. NSMenuView does not know how big
 * its items are; NSSubmenuView does, and overrides this. */
- (void) _resizeForCurrentItems {
}

- (BOOL) _isApplicationHelpMenu {
    NSMenu *menu = [self menu];

    if (menu == nil || [NSApp mainMenu] == nil) {
        return NO;
    }
    if ([[menu title] caseInsensitiveCompare: @"Help"] != NSOrderedSame) {
        return NO;
    }
    /* A menu called Help that is not IN the menu bar is somebody else's. */
    NSArray *top = [[NSApp mainMenu] itemArray];
    NSInteger i, count = [top count];

    for (i = 0; i < count; i++) {
        if ([[top objectAtIndex: i] submenu] == menu) {
            return YES;
        }
    }
    return NO;
}

- (NSString *) _searchQuery {
    return _searchQuery;
}

static void cider_collect_matches(NSMenu *menu, NSString *query, NSMutableArray *into,
                                  NSUInteger limit, NSMutableSet *seen)
{
    NSArray *items = [menu itemArray];
    NSInteger i, count = [items count];

    for (i = 0; i < count && [into count] < limit; i++) {
        NSMenuItem *item = [items objectAtIndex: i];

        if ([item isSeparatorItem] || [item isHidden]) {
            continue;
        }
        if ([item hasSubmenu]) {
            cider_collect_matches([item submenu], query, into, limit, seen);
            continue;
        }
        if ([item action] == NULL) {
            continue;
        }

        NSString *title = [item title];

        if ([title length] == 0 || [seen containsObject: title]) {
            continue;
        }
        if ([title rangeOfString: query options: NSCaseInsensitiveSearch].location != NSNotFound) {
            [seen addObject: title];
            [into addObject: item];
        }
    }
}

- (void) _setSearchQuery: (NSString *) query {
    if (query == _searchQuery || [query isEqualToString: _searchQuery]) {
        return;
    }
    [_searchQuery release];
    _searchQuery = [query copy];

    if (_searchResults == nil) {
        _searchResults = [[NSMutableArray alloc] init];
    }
    [_searchResults removeAllObjects];

    if ([_searchQuery length] > 0) {
        /* The first row is the query itself, which is what the search FIELD would have shown. It is
         * disabled, so arrow navigation and clicking both skip over it. */
        NSMenuItem *header = [[[NSMenuItem alloc]
                initWithTitle: [NSString stringWithFormat: @"Search: %@", _searchQuery]
                       action: NULL
                keyEquivalent: @""] autorelease];

        [header setEnabled: NO];
        [_searchResults addObject: header];

        NSMutableSet *seen = [NSMutableSet set];

        cider_collect_matches([NSApp mainMenu], _searchQuery, _searchResults, 12, seen);

        if ([_searchResults count] == 1) {
            NSMenuItem *none = [[[NSMenuItem alloc] initWithTitle: @"No Results"
                                                           action: NULL
                                                    keyEquivalent: @""] autorelease];

            [none setEnabled: NO];
            [_searchResults addObject: none];
        }
    }

    _selectedItemIndex = NSNotFound;
    [self setNeedsDisplay: YES];
}

- (NSArray *) visibleItemArray {
    if (_searchQuery != nil && [_searchQuery length] > 0 && _searchResults != nil) {
        return _searchResults;
    }
    NSArray *items = [[self menu] itemArray];

    // Construct a new array of just the visible items
    if (_visibleArray == NULL)
        _visibleArray = [[NSMutableArray alloc] init];

    [_visibleArray removeAllObjects];

    int i;
    for (i = 0; i < [items count]; i++) {
        NSMenuItem *item = [items objectAtIndex: i];
        if (![item isHidden])
            [_visibleArray addObject: item];
    }

    return _visibleArray;
}

- (NSMenuItem *) itemAtSelectedIndex {
    NSArray *items = [self visibleItemArray];

    if (_selectedItemIndex < [items count])
        return [items objectAtIndex: _selectedItemIndex];

    return nil;
}

- (NSMenuView *) viewAtSelectedIndexPositionOnScreen: (NSScreen *) screen {
    NSInvalidAbstractInvocation();
    return nil;
}

- (void) rightMouseDown: (NSEvent *) event {
    // do nothing
}

- (NSScreen *) _screenForPoint: (NSPoint) point {
    NSArray *screens = [NSScreen screens];
    int i, count = [screens count];

    for (i = 0; i < count; i++) {
        NSScreen *check = [screens objectAtIndex: i];

        if (NSPointInRect(point, [check frame]))
            return check;
    }

    return [screens objectAtIndex: 0]; // should not happen
}

#if 0
#define MENUDEBUG(...) NSLog(__VA_ARGS__)
#else
#define MENUDEBUG(...)
#endif

// This threshold is not really applicable with regular
// menus - but in the event that the popup and regular menu
// logic is merged the behaviour as been replicated here.
// If a user clicks and releases on a menu it should remain
// visible. If a user clicks and holds for a period and then releases
// the current item should be reselected. This threshold is the dividing
// line between those two behaviours.
const NSTimeInterval kMenuInitialClickThreshold = .3f;
const NSTimeInterval kMouseMovementThreshold = .001f;

- (NSMenuItem *) trackForEvent: (NSEvent *) event {
    NSMenuItem *item = nil;

    enum {
        STATE_FIRSTMOUSEDOWN,
        STATE_MOUSEDOWN,
        STATE_MOUSEUP,
        STATE_EXIT
    } state = STATE_FIRSTMOUSEDOWN;

    // Get the menu management ball rolling
    NSPoint point = [event locationInWindow];
    NSPoint firstPoint = point;
    NSTimeInterval firstTimestamp = [event timestamp];

    // Cascading menus we manage will be pushed and popped on the viewStack
    __block NSMutableArray *viewStack = [NSMutableArray array];

    // Make sure we can put things back the way we found them
    BOOL oldAcceptsMouseMovedEvents = [[self window] acceptsMouseMovedEvents];

    // But while we're dealing with menus we want to track the mouse...
    [[self window] setAcceptsMouseMovedEvents: YES];

    // Make sure the menu contents are up to date
    [[self menu] update];

    // And we, of course, are first on the stack
    [viewStack addObject: self];

    [event retain];

    int keyboardNavigationAction = kNSMenuKeyboardNavigationNone;

    BOOL cancelled = NO;
    NSTimer* delaySubmenu = nil;
    NSRect lastRect = NSMakeRect(0,0,0,0);

    MENUDEBUG(@"entering outer loop");

    // Start tracking the mouse movements and clicks
    do {
        // Lots of objects are going to come and go as we track the mouse
        // so a tactical autorelease pool keeps a lid on things
        NSAutoreleasePool *pool = [NSAutoreleasePool new];
        int count = [viewStack count];
        NSScreen *screen = [self
                _screenForPoint: [[event window] convertBaseToScreen: point]];

        point = [[event window] convertBaseToScreen: point];

        // We've not pushed any views yet so the screen is where our window is
        if (count == 1) {
            screen = [self _screenForPoint: point];
        }

        if (keyboardNavigationAction == kNSMenuKeyboardNavigationNone) {
            // We're not current dealing with a keyboard event
            // Take a look at the visible menu stack (we're within a big loop so
            // views can come and go and the mouse can wander all over) deepest
            // first
            while (--count >= 0) {

                // get the deepest one
                NSMenuView *checkView = [viewStack objectAtIndex: count];

                // And find out where the mouse is relative to it
                NSPoint checkPoint =
                        [[checkView window] convertScreenToBase: point];

                checkPoint = [checkView convertPoint: checkPoint fromView: nil];

                // If it's inside the menu view
                if (NSMouseInRect(checkPoint, [checkView bounds],
                                  [checkView isFlipped])) {

                    MENUDEBUG(@"found a menu: %@", checkView);

                    // Performance optimization - break if we're still in the same menu item rect as last time
                    if (NSMouseInRect(checkPoint, lastRect, [self isFlipped]))
                        break;

                    // Which item is the cursor on top of?
                    NSUInteger itemIndex =
                            [checkView itemIndexAtPoint: checkPoint rect: &lastRect];

                    MENUDEBUG(@"found an item index: %u", itemIndex);

                    // If it's not the currently selected item
                    if (itemIndex != [checkView selectedItemIndex]) {

                        // This looks like it's dealing with pushed cascading
                        // menu views that are no longer needed because the user
                        // has moved on - so pop them all off.
                        while (count + 1 < [viewStack count]) {
                            NSView *view = [viewStack lastObject];
                            MENUDEBUG(@"popping cascading view: %@", view);
                            [[view window] close];
                            [viewStack removeLastObject];
                        }

                        // And now select the new item
                        [checkView setSelectedItemIndex: itemIndex];

                        if (delaySubmenu) {
                            [delaySubmenu invalidate];
                            [delaySubmenu release];
                            delaySubmenu = nil;
                        }

                        // If it's got a cascading menu then push that on the
                        // stack
                        // Do this with a delay to improve performance - this is what toolkits commonly do
                        double delay = (count == 0) ? 0 : 0.5;
                        delaySubmenu = [[NSTimer timerWithTimeInterval: delay repeats: NO block: ^(NSTimer* timer){

                            NSMenuView *branch;

                            if ((branch = [checkView
                                        viewAtSelectedIndexPositionOnScreen:
                                                screen]) != nil) {
                                MENUDEBUG(@"adding a new cascading view: %@",
                                        branch);
                                [viewStack addObject: branch];
                            }
                        }] retain];
                        [[NSRunLoop currentRunLoop] addTimer: delaySubmenu
                                                     forMode: NSEventTrackingRunLoopMode];
                    }
                    // And bail out of the while loop - we're in the right place
                    break;
                } else {
                    if (delaySubmenu) {
                        [delaySubmenu invalidate];
                        [delaySubmenu release];
                        delaySubmenu = nil;
                    }

                    lastRect = NSMakeRect(0,0,0,0);
                    
                    // We've wandered off the menu so don't show anything
                    // selected if it's the deepest visible view
                    if (checkView == [viewStack lastObject]) {
                        MENUDEBUG(@"clearing selection in view: %@", checkView);
                        // The mouse is outside of the top menu - be sure no
                        // item is selected anymore
                        [checkView setSelectedItemIndex: NSNotFound];
                    }
                }
            }

            // Looks like we've popped everything so nothing can be selected
            if (count < 0) {
                MENUDEBUG(@"clearing all selection");
                [[viewStack lastObject] setSelectedItemIndex: NSNotFound];
            }
        }

        [event release];

        // Let's take a look at what's come in on the event queue
        event = [[self window]
                nextEventMatchingMask: NSLeftMouseUpMask | NSMouseMovedMask |
                                       NSLeftMouseDraggedMask | NSKeyDownMask |
                                       NSAppKitDefinedMask];
        [event retain];

        if (keyboardNavigationAction != kNSMenuKeyboardNavigationNone) {
            // We didn't enter the mouse handling loop that predecrements count
            // - so do it here...
            count--;
        }
        // Reset the keyboard navigation state
        keyboardNavigationAction = kNSMenuKeyboardNavigationNone;

        // Sometimes we can get key events with no characters (if the user
        // has invoked an accelerator while the menu is open for example)
        if ([event type] == NSKeyDown && [[event characters] length] > 0) {

            NSString *chars = [event characters];
            unichar ch = [chars characterAtIndex: 0];
            switch (ch) {
            case NSUpArrowFunctionKey:
                keyboardNavigationAction = kNSMenuKeyboardNavigationUp;
                break;
            case NSDownArrowFunctionKey:
                keyboardNavigationAction = kNSMenuKeyboardNavigationDown;
                break;
            case NSLeftArrowFunctionKey:
                keyboardNavigationAction = kNSMenuKeyboardNavigationLeft;
                break;
            case NSRightArrowFunctionKey:
                keyboardNavigationAction = kNSMenuKeyboardNavigationRight;
                break;

            case '\r': // Return = select the current item and exit the loop
                MENUDEBUG(@"Selecting current item and exit");
                state = STATE_EXIT;
                break;
            case 8:   // Backspace
            case 0x7f: // Delete, which is what a Mac keyboard sends
            {
                NSMenuView *typing = [viewStack lastObject];

                if ([typing _isApplicationHelpMenu] && [[typing _searchQuery] length] > 0) {
                    NSString *current = [typing _searchQuery];

                    [typing _setSearchQuery:
                            [current substringToIndex: [current length] - 1]];
                    [typing _resizeForCurrentItems];
                }
            } break;
            case 27: // Escape = pop unless we're done then it's cancel
            {
                /* A SEARCH IS WHAT ESCAPE CLEARS FIRST, before it closes anything. */
                NSMenuView *typing = [viewStack lastObject];

                if ([typing _isApplicationHelpMenu] && [[typing _searchQuery] length] > 0) {
                    [typing _setSearchQuery: nil];
                    [typing _resizeForCurrentItems];
                    break;
                }
                if ([viewStack count] > 1) {
                    NSView *view = [viewStack lastObject];
                    MENUDEBUG(@"popping cascading view: %@", view);
                    [[view window] close];
                    [viewStack removeLastObject];
                } else {
                    MENUDEBUG(@"Cancelling");
                    cancelled = YES;
                }
            } break;
            default:
                keyboardNavigationAction = kNSMenuKeyboardNavigationLetter;
                break;
            }

            NSMenuView *activeMenuView = [viewStack lastObject];

            BOOL ignoreEnabledState = NO;
            if ([viewStack count] == 1 &&
                [activeMenuView isKindOfClass: [NSMainMenuView class]]) {
                // For some reason main menu items are disabled - even though
                // they work fine...
                ignoreEnabledState = YES;
                // we're navigating the top menu which has opposite semantics
                // than a regular menu
                switch (keyboardNavigationAction) {
                case kNSMenuKeyboardNavigationDown:
                    keyboardNavigationAction = kNSMenuKeyboardNavigationRight;
                    break;
                case kNSMenuKeyboardNavigationUp:
                    keyboardNavigationAction = kNSMenuKeyboardNavigationLeft;
                    break;
                case kNSMenuKeyboardNavigationLeft:
                    keyboardNavigationAction = kNSMenuKeyboardNavigationUp;
                    break;
                case kNSMenuKeyboardNavigationRight:
                    keyboardNavigationAction = kNSMenuKeyboardNavigationDown;
                    break;
                }
            }

            switch (keyboardNavigationAction) {
            case kNSMenuKeyboardNavigationUp: {
                MENUDEBUG(@"Up...");

                NSUInteger oldIndex = [activeMenuView selectedItemIndex];
                NSArray *items = [activeMenuView itemArray];
                // Look for the next enabled item by search up and wrapping
                // around the bottom
                NSUInteger newIndex = 0;
                if (oldIndex != NSNotFound) {
                    newIndex = oldIndex == 0 ? [items count] - 1 : oldIndex - 1;
                }
                MENUDEBUG(@"oldIndex = %u", oldIndex);
                MENUDEBUG(@"newIndex = %u", newIndex);
                BOOL found = NO;
                while (!found && newIndex != oldIndex) {
                    // Make sure we stop eventually
                    if (oldIndex == NSNotFound) {
                        oldIndex = 0;
                    }
                    // Try and find a new item to select
                    NSMenuItem *item = [items objectAtIndex: newIndex];
                    if ([item isSeparatorItem] == NO &&
                        ((ignoreEnabledState || [item isEnabled]) ||
                         [item hasSubmenu])) {
                        MENUDEBUG(@"selecting item = %@", item);
                        [activeMenuView setSelectedItemIndex: newIndex];
                        found = YES;
                    } else {
                        MENUDEBUG(@"skipping item: %@", item);
                        if (newIndex == 0) {
                            newIndex = [items count] - 1;
                        } else {
                            newIndex--;
                        }
                    }
                }
            } break;
            case kNSMenuKeyboardNavigationDown: {
                MENUDEBUG(@"Down...");
                NSUInteger oldIndex = [activeMenuView selectedItemIndex];
                NSArray *items = [activeMenuView itemArray];
                // Look for the next enabled item by search down and wrapping
                // around to the top
                NSUInteger newIndex = 0;
                if (oldIndex != NSNotFound) {
                    newIndex = oldIndex == [items count] - 1 ? 0 : oldIndex + 1;
                }

                MENUDEBUG(@"oldIndex = %u", oldIndex);
                MENUDEBUG(@"newIndex = %u", newIndex);
                BOOL found = NO;
                while (!found && newIndex != oldIndex) {
                    // Make sure we stop eventually
                    if (oldIndex == NSNotFound) {
                        oldIndex = 0;
                    }
                    // Try and find a new item to select
                    NSMenuItem *item = [items objectAtIndex: newIndex];
                    if ([item isSeparatorItem] == NO &&
                        ((ignoreEnabledState || [item isEnabled]) ||
                         [item hasSubmenu])) {
                        MENUDEBUG(@"selecting item: %u", item);
                        [activeMenuView setSelectedItemIndex: newIndex];
                        found = YES;
                    } else {
                        MENUDEBUG(@"skipping item: %@", item);
                        if (newIndex == [items count] - 1) {
                            newIndex = 0;
                        } else {
                            newIndex++;
                        }
                    }
                }
            } break;
            case kNSMenuKeyboardNavigationLeft:
                MENUDEBUG(@"Left...");
                if ([viewStack count] > 1) {
                    NSView *view = [viewStack lastObject];
                    MENUDEBUG(@"popping cascading view: %@", view);
                    [[view window] close];
                    [viewStack removeLastObject];
                }
                break;
            case kNSMenuKeyboardNavigationRight: {
                MENUDEBUG(@"Right...");
                NSMenuView *branch = nil;
                // If there's a submenu at the current  selected index
                if ((branch = [activeMenuView
                             viewAtSelectedIndexPositionOnScreen: screen]) !=
                    nil) {
                    MENUDEBUG(@"adding a new cascading view: %@", branch);
                    [viewStack addObject: branch];
                } else {
                    // We'll pop it - they're trying to navigate to the next
                    // menu most likely
                    if ([viewStack count] > 1) {
                        NSView *view = [viewStack lastObject];
                        MENUDEBUG(@"popping cascading view: %@", view);
                        [[view window] close];
                        [viewStack removeLastObject];
                    }
                }
            } break;
            case kNSMenuKeyboardNavigationLetter: {
                /* WHICH VIEW IS BEING TYPED AT. Typing after a CLICK walked the menu bar instead of
                 * searching the open Help menu, and the only thing that can say why is what the
                 * stack holds at the moment the letter arrives. */
                if (getenv("CIDER_TRACE_MENU") != NULL) {
                    NSInteger si;

                    fprintf(stderr, "CIDER_MENU letter=%C stack=%ld", ch, (long) [viewStack count]);
                    for (si = 0; si < (NSInteger) [viewStack count]; si++) {
                        NSMenuView *v = [viewStack objectAtIndex: si];

                        fprintf(stderr, " [%ld]=%s menu=%s help=%d", (long) si,
                                object_getClassName(v),
                                [[[v menu] title] UTF8String] ?: "nil",
                                (int) [v _isApplicationHelpMenu]);
                    }
                    fprintf(stderr, "\n");
                    fflush(stderr);
                }
                /* TYPING IN THE HELP MENU IS A SEARCH, not a jump to the next item beginning with
                 * that letter. Everywhere else it is still the jump. */
                if ([activeMenuView _isApplicationHelpMenu]) {
                    NSString *current = [activeMenuView _searchQuery];
                    NSString *typed = [NSString stringWithCharacters: &ch length: 1];

                    [activeMenuView _setSearchQuery:
                            (current == nil) ? typed
                                             : [current stringByAppendingString: typed]];
                    [activeMenuView _resizeForCurrentItems];
                    break;
                }
                MENUDEBUG(@"Letter...");
                NSString *letterString =
                        [[NSString stringWithCharacters: &ch
                                                 length: 1] uppercaseString];
                NSUInteger oldIndex = [activeMenuView selectedItemIndex];
                NSArray *items = [activeMenuView itemArray];
                // Look for the next enabled item by search down and wrapping
                // around to the top
                NSUInteger newIndex = 0;
                if (oldIndex != NSNotFound) {
                    newIndex = oldIndex == [items count] - 1 ? 0 : oldIndex + 1;
                }

                MENUDEBUG(@"oldIndex = %u", oldIndex);
                MENUDEBUG(@"newIndex = %u", newIndex);
                BOOL found = NO;
                while (!found && newIndex != oldIndex) {
                    // Make sure we stop eventually
                    if (oldIndex == NSNotFound) {
                        oldIndex = 0;
                    }
                    // Try and find a new item to select
                    NSMenuItem *item = [items objectAtIndex: newIndex];
                    if ((ignoreEnabledState || [item isEnabled] == YES) ||
                        [item hasSubmenu] == YES) {
                        NSRange range =
                                [[item title] rangeOfString: letterString];
                        if (range.location != NSNotFound) {
                            MENUDEBUG(@"selecting item: %u", item);
                            [activeMenuView setSelectedItemIndex: newIndex];
                            found = YES;
                        }
                    }
                    if (!found) {
                        MENUDEBUG(@"skipping item: %@", item);
                        if (newIndex == [items count] - 1) {
                            newIndex = 0;
                        } else {
                            newIndex++;
                        }
                    }
                }
            } break;
            }
        }
        // We use this special AppKitDefined event to let the menu respond to
        // the app deactivation - it *has* to be passed through the event
        // system, unfortunately
        if ([event type] == NSAppKitDefined) {
            if ([event subtype] == NSApplicationDeactivated) {
                MENUDEBUG(@"NSApplicationDeactivated");
                cancelled = YES;
            }
        }

        if (cancelled == NO && [event type] != NSAppKitDefined &&
            [event type] != NSKeyDown) {

            // looks like we can keep rolling

            point = [event locationInWindow];
            // Don't test for "== 0." - we tend to receive some delta with some
            // .000000... values while the mouse doesn't move
            BOOL mouseMoved = ([event type] != NSAppKitDefined) &&
                              (fabs([event deltaX]) > kMouseMovementThreshold ||
                               fabs([event deltaY]) > kMouseMovementThreshold);

            NSMenuView *activeView = nil;

            // We may not have a menuview here - so be cautious - and we may
            // have added a cascading menu so lastObject is also not the right
            // thing to look at - we need to look at the menuview found in the
            // preceeding block (if there was one found - the user could have
            // moused somewhere else entirely remember)
            if (count >= 0) {
                activeView = [viewStack objectAtIndex: count];
            }

            switch (state) {
            case STATE_FIRSTMOUSEDOWN:
                // Let's take a look at the item under the cursor (if there is
                // one)
                item = [activeView itemAtSelectedIndex];

                if ([event type] == NSLeftMouseUp) {
                    // The menu is really active after a mouse up (which means
                    // the menu will stay sticky)... The timestamp is to avoid
                    // false clicks - make sure there's a delay so the user can
                    if ([event timestamp] - firstTimestamp >
                                kMenuInitialClickThreshold &&
                        [viewStack count] == 1 && [item isEnabled]) {
                        MENUDEBUG(@"Handling selected item - exiting");
                        state = STATE_EXIT;
                    } else {
                        MENUDEBUG(@"mouse up - continuing");
                        state = STATE_MOUSEUP;
                    }
                } else if ([event type] == NSLeftMouseDown || mouseMoved) {
                    // .. Or a mouse down (second click after the sticky menu)
                    // or a real move
                    state = STATE_MOUSEDOWN;
                }
                break;

            default:
                item = [activeView itemAtSelectedIndex];
                if ([event type] == NSLeftMouseUp) {
                    MENUDEBUG(@"mouseUp on item: %@", item);
                    if (item == nil || ([viewStack count] <= 2) ||
                        [item isEnabled]) {
                        MENUDEBUG(@"mouse up - exiting because of many "
                                  @"possible reasons...");
                        state = STATE_EXIT;
                    } else {
                        MENUDEBUG(@"mouse up");
                        state = STATE_MOUSEUP;
                    }
                }
                break;
            }
        }
        [pool release];
    } while (cancelled == NO && state != STATE_EXIT);
    [event release];

    if (delaySubmenu) {
        [delaySubmenu invalidate];
        [delaySubmenu release];
        delaySubmenu = nil;
    }

    MENUDEBUG(@"done with the event loop");

    /* AND THE STACK IT ENDED WITH. Which VIEW the item came from is the whole question: the deepest
     * open menu is the one the user was looking at, and an item taken from the menu bar instead is
     * the parent of the thing they chose. */
    if (getenv("CIDER_TRACE_MENU") != NULL) {
        fprintf(stderr, "CIDER_MENU stack depth=%lu", (unsigned long) [viewStack count]);
        for (NSUInteger i = 0; i < [viewStack count]; i++) {
            NSMenuView *v = [viewStack objectAtIndex: i];

            fprintf(stderr, " [%lu %s sel=%ld]", (unsigned long) i, object_getClassName(v),
                    (long) [v selectedItemIndex]);
        }
        fprintf(stderr, "\n");
        fflush(stderr);
    }


    /*
     * THE ITEM THE USER CHOSE IS THE ONE IN THE DEEPEST MENU, not the one that opened it.
     *
     * item is set the moment the mouse comes up on the MENU BAR, which is what opens a menu in the
     * first place, and after that nothing replaced it: choosing Character from the Format menu sent
     * the action of FORMAT. LibreOffice takes that as open the menu, so every menu item in the
     * application did nothing at all, by mouse and by keyboard alike, silently and with no
     * exception. The trace that named it:
     *
     *     CIDER_MENU stack depth=2 [0 NSMainMenuView sel=5] [1 NSSubmenuView sel=8]
     *     CIDER_MENU track item=Format action=menuItemTriggered:
     *
     * Selected index 8 of the submenu IS the chosen item and it was right there.
     *
     * A parent is skipped: an item that owns a submenu is not a command, and firing it would
     * re-open the menu that was just closed.
     */
    if ([viewStack count] > 1) {
        NSMenuItem *deepest = [[viewStack lastObject] itemAtSelectedIndex];

        if (deepest != nil && [deepest submenu] == nil) {
            item = deepest;
            MENUDEBUG(@"took the item from the deepest menu view: %@", item);
        }
    }

    // If we've got a menu still visible
    if (item == nil && [viewStack count] > 0) {
        // Get the selected item
        item = [[viewStack lastObject] itemAtSelectedIndex];
        MENUDEBUG(@"got the selected item at the top most menu view: %@", item);
    }

    MENUDEBUG(@"removing the visible menu views");
    while ([viewStack count] > 1) {
        [[(NSView *) [viewStack lastObject] window] close];
        [viewStack removeLastObject];
    }
    [viewStack removeLastObject];

    _selectedItemIndex = NSNotFound;
    [[self window] setAcceptsMouseMovedEvents: oldAcceptsMouseMovedEvents];
    [self setNeedsDisplay: YES];

    /* WHAT THE TRACK ENDED WITH, and whether it is about to be thrown away. Choosing a menu item
     * does nothing at all in this port, by mouse or by Return, and the whole difference between a
     * tracking loop that found no item and one that found a DISABLED item is this line. Cocotron
     * already notes above that main menu items report disabled even though they work. */
    if (getenv("CIDER_TRACE_MENU") != NULL) {
        fprintf(stderr, "CIDER_MENU track item=%s enabled=%d action=%s target=%s\n",
                (item != nil) ? [[item title] UTF8String] : "nil",
                (item != nil) ? (int) [item isEnabled] : -1,
                (item != nil && [item action] != NULL) ? sel_getName([item action]) : "none",
                (item != nil && [item target] != nil) ? object_getClassName([item target]) : "nil");
        fflush(stderr);
    }

    return ([item isEnabled]) ? item : (NSMenuItem *) nil;
}

- (void) mouseDown: (NSEvent *) event {
    BOOL didAccept = [[self window] acceptsMouseMovedEvents];
    NSMenuItem *item;

    [[self window] setAcceptsMouseMovedEvents: YES];
    item = [self trackForEvent: event];
    [[self window] setAcceptsMouseMovedEvents: didAccept];

    if (item != nil)
        [NSApp sendAction: [item action] to: [item target] from: item];
}

@end
