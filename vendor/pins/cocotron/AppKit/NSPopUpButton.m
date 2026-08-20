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
#include <dlfcn.h>

#import <objc/runtime.h>

#import <AppKit/NSApplication.h>
#import <AppKit/NSMenu.h>
#import <AppKit/NSObject+BindingSupport.h>
#import <AppKit/NSPopUpButton.h>
#import <AppKit/NSPopUpButtonCell.h>

NSString *const NSPopUpButtonWillPopUpNotification =
        @"NSPopUpButtonWillPopUpNotification";

static NSString *const NSPopUpButtonBindingObservationContext =
        @"NSPopUpButtonBindingObservationContext";


/* WHAT THE APPLICATION READS OFF A POP-UP after it is clicked. Swift Publisher's zoom action takes
 * the button as its sender and turns it into a number, and which accessor it asks decides which of
 * our answers has to be right. */
static void CiderPopUpRead(id button, const char *what, id answer, long number)
{
    if (getenv("CIDER_TRACE_MENU") == NULL || getenv("CIDER_TRACE_MENU")[0] == '\0')
        return;

    Dl_info info;
    void *ret = __builtin_return_address(1);
    int have = dladdr(ret, &info);

    fprintf(stderr, "CIDER_POPUPREAD %s -> %s / %ld from %s in %s +%#lx\n", what,
            answer != nil ? [[answer description] UTF8String] : "(nil)", number,
            (have != 0 && info.dli_sname != NULL) ? info.dli_sname : "?",
            (have != 0 && info.dli_fname != NULL) ? info.dli_fname : "?",
            (have != 0) ? (unsigned long) ((char *) ret - (char *) info.dli_fbase) : 0UL);
    fflush(stderr);
}

@implementation NSPopUpButton

+ (Class) cellClass {
    return [NSPopUpButtonCell class];
}

- initWithFrame: (NSRect) frame pullsDown: (BOOL) pullsDown {
    [super initWithFrame: frame];
    [self setPullsDown: pullsDown];
    return self;
}

- (void) dealloc {
    NS_DURING [self removeObserver: self forKeyPath: @"cell.selectedItem"];
    [self removeObserver: self forKeyPath: @"cell.menu.itemArray"];
    NS_HANDLER
    NS_ENDHANDLER

            [super dealloc];
}

- (BOOL) pullsDown {
    return [_cell pullsDown];
}

- (NSMenu *) menu {
    return [_cell menu];
}

- (BOOL) autoenablesItems {
    return [_cell autoenablesItems];
}

- (NSRectEdge) preferredEdge {
    return [_cell preferredEdge];
}

- (NSArray *) itemArray {
    return [_cell itemArray];
}

- (NSInteger) numberOfItems {
    return [_cell numberOfItems];
}

- (NSMenuItem *) itemAtIndex: (NSInteger) index {
    return [_cell itemAtIndex: index];
}

- (NSMenuItem *) itemWithTitle: (NSString *) title {
    return [_cell itemWithTitle: title];
}

- (NSMenuItem *) lastItem {
    return [_cell lastItem];
}

- (NSInteger) indexOfItem: (NSMenuItem *) item {
    return [_cell indexOfItem: item];
}

- (NSInteger) indexOfItemWithTitle: (NSString *) title {
    return [_cell indexOfItemWithTitle: title];
}

- (NSInteger) indexOfItemWithTag: (NSInteger) tag {
    return [_cell indexOfItemWithTag: tag];
}

- (NSInteger) indexOfItemWithRepresentedObject: object {
    return [_cell indexOfItemWithRepresentedObject: object];
}

- (NSInteger) indexOfItemWithTarget: target andAction: (SEL) action {
    return [_cell indexOfItemWithTarget: target andAction: action];
}

- (NSMenuItem *) selectedItem {
    NSMenuItem *item = [_cell selectedItem];
    CiderPopUpRead(self, "selectedItem", [item title], [item tag]);
    return item;
}

- (NSString *) titleOfSelectedItem {
    NSString *title = [_cell titleOfSelectedItem];
    CiderPopUpRead(self, "titleOfSelectedItem", title, 0);
    return title;
}

/* THE SELECTED ITEM'S TAG, not the cell's, which is a different number entirely. */
- (NSInteger) selectedTag {
    NSInteger tag = [[self selectedItem] tag];
    CiderPopUpRead(self, "selectedTag", nil, (long) tag);
    return tag;
}

- (NSInteger) indexOfSelectedItem {
    NSInteger index = [_cell indexOfSelectedItem];
    CiderPopUpRead(self, "indexOfSelectedItem", nil, (long) index);
    return index;
}

- (void) setPullsDown: (BOOL) flag {
    [_cell setPullsDown: flag];
    [self setNeedsDisplay: YES];
}

- (void) setMenu: (NSMenu *) menu {
    [_cell setMenu: menu];
    [self setNeedsDisplay: YES];
}

- (void) setAutoenablesItems: (BOOL) value {
    [_cell setAutoenablesItems: value];
}

- (void) setPreferredEdge: (NSRectEdge) edge {
    [_cell setPreferredEdge: edge];
}

- (void) addItemWithTitle: (NSString *) title {
    [_cell addItemWithTitle: title];
    [self setNeedsDisplay: YES];
}

- (void) addItemsWithTitles: (NSArray *) titles {
    [_cell addItemsWithTitles: titles];
    [self setNeedsDisplay: YES];
}

- (void) removeAllItems {
    [_cell removeAllItems];
    [self setNeedsDisplay: YES];
}

- (void) removeItemAtIndex: (NSInteger) index {
    [_cell removeItemAtIndex: index];
    [self setNeedsDisplay: YES];
}

- (void) removeItemWithTitle: (NSString *) title {
    [_cell removeItemWithTitle: title];
    [self setNeedsDisplay: YES];
}

- (void) insertItemWithTitle: (NSString *) title atIndex: (NSInteger) index {
    [_cell insertItemWithTitle: title atIndex: index];
    [self setNeedsDisplay: YES];
}

/*
 * THE FOUR KEYS THIS CLASS ALREADY PROMISES, and only one of which it answered.
 *
 * The KVO block below posts willChange and didChange for selectedIndex, selectedValue,
 * selectedObject and selectedTag whenever the selection moves, so the class advertises all four as
 * observable. Three of them had no accessor at all, which means the class is not key value coding
 * compliant for a key it is actively notifying about, and binding to any of them raises:
 *
 *   NSUnknownKeyException: <NSPopUpButton ...> is not key value coding compliant for the key
 *   selectedObject
 *
 * Swift Publisher binds exactly that, six times, while building its inspector.
 *
 * selectedObject is the represented object of the selected item, which is what the Cocoa binding of
 * that name means; setting it selects the item carrying that object, and an object no item carries
 * clears the selection rather than inventing one. selectedValue is the title, the string form used
 * by the content values binding. Identity is tried before isEqual: so an item whose represented
 * object does not implement equality still matches itself.
 */
- (id) selectedObject {
    return [[self selectedItem] representedObject];
}

- (void) setSelectedObject: (id) object {
    NSInteger i, count = [self numberOfItems];

    for (i = 0; i < count; i++) {
        NSMenuItem *item = [self itemAtIndex: i];
        id represented = [item representedObject];

        if (represented == object || [represented isEqual: object]) {
            [self selectItem: item];
            return;
        }
    }

    [self selectItem: nil];
}

- (id) selectedValue {
    return [[self selectedItem] title];
}

- (void) setSelectedValue: (id) value {
    [self selectItemWithTitle: value];
}

- (NSInteger) selectedIndex {
    return [self indexOfSelectedItem];
}

- (void) setSelectedIndex: (NSInteger) index {
    [self selectItemAtIndex: index];
}

- (void) selectItem: (NSMenuItem *) item {
    [_cell selectItem: item];
    [self setNeedsDisplay: YES];
}

- (void) selectItemAtIndex: (NSInteger) index {
    [_cell selectItemAtIndex: index];
    [self setNeedsDisplay: YES];
}

- (void) selectItemWithTitle: (NSString *) title {
    [_cell selectItemWithTitle: title];
    [self setNeedsDisplay: YES];
}

- (BOOL) selectItemWithTag: (NSInteger) tag {
    [self setNeedsDisplay: YES];
    return [_cell selectItemWithTag: tag];
}

- (NSString *) itemTitleAtIndex: (NSInteger) index {
    return [_cell itemTitleAtIndex: index];
}

- (NSArray *) itemTitles {
    return [_cell itemTitles];
}

- (void) setTitle: (NSString *) title {
    /* WHO ASKS FOR THE TITLE A POP-UP ENDS UP WEARING. Swift Publisher's zoom button reads 35% after
     * any pick, and 35% is not the title of any item in its menu, so the name of the caller decides
     * whether the application chose it or we did. */
    if (getenv("CIDER_TRACE_MENU") != NULL && getenv("CIDER_TRACE_MENU")[0] != '\0') {
        Dl_info info;
        void *ret = __builtin_return_address(0);
        int have = dladdr(ret, &info);

        fprintf(stderr, "CIDER_POPUPTITLE %s pullsDown=%d from %s in %s +%#lx\n",
                [title UTF8String] ?: "(nil)", (int) [self pullsDown],
                (have != 0 && info.dli_sname != NULL) ? info.dli_sname : "?",
                (have != 0 && info.dli_fname != NULL) ? info.dli_fname : "?",
                (have != 0) ? (unsigned long) ((char *) ret - (char *) info.dli_fbase) : 0UL);
        fflush(stderr);
    }
    if ([self pullsDown]) {
        // The title gets stored in the zero index item in the menu - it made
        // sense to Apple at some point...
        //
        // AND THERE MAY BE NO ITEM YET, which used to be an NSRangeException from
        // -[NSArray objectAtIndex:] with nothing in the message to say which array. A pull down
        // button that is given its title before it is given its menu is ordinary: iTerm2 builds the
        // overflow button of its tab bar that way, and the raise took the whole terminal window
        // with it. The title item is created here instead, which is the item this line is reading
        // when there IS one.
        if ([_cell numberOfItems] == 0) {
            [_cell addItemWithTitle: title != nil ? title : @""];
        } else {
            [[_cell itemAtIndex: 0] setTitle: title];
        }
        [self synchronizeTitleAndSelectedItem];
    } else {
        [super setTitle: title];
    }
}

- (void) synchronizeTitleAndSelectedItem {
    [_cell synchronizeTitleAndSelectedItem];
    [self setNeedsDisplay: YES];
}

- (void) performClick: sender {

    if ([_cell trackMouse: [NSApp currentEvent]
                      inRect: [self bounds]
                      ofView: self
                untilMouseUp: NO]) {
        NSMenuItem *item = [self selectedItem];
        SEL action = [item action];
        id target = [item target];

        /* WHAT THE GESTURE ACTUALLY SENDS, and to whom. A pull down sends the ITEM's action and a
         * pop up sends the button's, so this line is where a wrong pullsDown becomes a wrong
         * message to the application. */
        if (getenv("CIDER_TRACE_MENU") != NULL && getenv("CIDER_TRACE_MENU")[0] != '\0') {
            fprintf(stderr,
                    "CIDER_POPUPSEND item=%s action=%s itemTarget=%s tag=%ld represented=%s "
                    "pullsDown=%d buttonAction=%s buttonTarget=%s\n",
                    [[item title] UTF8String] ?: "(nil)", action ? sel_getName(action) : "(nil)",
                    [item target] ? object_getClassName([item target]) : "(nil)", (long) [item tag],
                    [item representedObject] ? object_getClassName([item representedObject]) : "(nil)",
                    (int) [self pullsDown],
                    [self action] ? sel_getName([self action]) : "(nil)",
                    [self target] ? object_getClassName([self target]) : "(nil)");
            fflush(stderr);
        }

        if (action != NULL) {
            // The item has an explicit action - so it's going to be the sender
            sender = item;
        }

        [_cell setState: ![_cell state]];
        [self setNeedsDisplay: YES];

        if (action == NULL) {
            action = [self action];
            target = [self target];
        } else if (target == nil) {
            target = [self target];
        }

        [NSApp sendAction: action to: target from: sender];
    }
}

- (void) mouseDown: (NSEvent *) event {
    if (![self isEnabled])
        return;

#if 1
    [self performClick: self];
#else
    if ([_cell trackMouse: event
                      inRect: [self bounds]
                      ofView: self
                untilMouseUp: NO]) {
        NSMenuItem *item = [self selectedItem];
        SEL action = [item action];
        id target = [item target];

        [_cell setState: ![_cell state]];
        [self setNeedsDisplay: YES];

        if (action == NULL) {
            action = [self action];
            target = [self target];
        } else if (target == nil) {
            target = [self target];
        }

        [self sendAction: action to: target];
    }
#endif
}

- (void) keyDown: (NSEvent *) event {
    [self interpretKeyEvents: [NSArray arrayWithObject: event]];
}

// this gets us arrow keys to select items in the menu w/o popping it up.
- (void) moveUp: (id) sender {
    [_cell moveUp: sender];
    [self setNeedsDisplay: YES];
}

- (void) moveDown: (id) sender {
    [_cell moveDown: sender];
    [self setNeedsDisplay: YES];
}

- (void) insertNewline: (id) sender {
    [self mouseDown: nil];
}

@end

@implementation NSPopUpButton (BindingSupport)

- (void) _setItemValues: (NSArray *) values forKey: (NSString *) key {
    /*
     * A MENU ITEM TITLE IS A STRING, whatever the content binding is bound to.
     *
     * The content and contentValues bindings hand over whatever the controller holds, and that is
     * routinely not a string: Swift Publisher binds arrays of dictionaries and of numbers. Those
     * went straight into addItemsWithTitles:, and the first thing -[NSMenu itemWithTitle:] does is
     * send isEqualToString: to compare against the existing items, so every one of them raised
     *
     *   -[__NSCFDictionary isEqualToString:]: unrecognized selector
     *
     * out of -[_NSKVOBinder bind] and through the application binding helper. Cocoa shows
     * description for a value that is not already a string, which is exactly what a popup bound to
     * a list of arbitrary objects displays when no display key or value transformer is set.
     *
     * nil becomes an empty string rather than being dropped, so the item count still matches the
     * content array and selectedIndex keeps meaning what the binding thinks it means.
     */
    NSMutableArray *titles = [NSMutableArray arrayWithCapacity: [values count]];
    NSInteger i, count = [values count];

    for (i = 0; i < count; i++) {
        id value = [values objectAtIndex: i];

        if (value == nil || value == [NSNull null]) {
            [titles addObject: @""];
        } else if ([value isKindOfClass: [NSString class]]) {
            [titles addObject: value];
        } else {
            [titles addObject: [value description]];
        }
    }

    [_cell removeAllItems];
    [_cell addItemsWithTitles: titles];

    if ([self indexOfSelectedItem] >= values.count) {
        [self selectItem: nil];
    }
    [self synchronizeTitleAndSelectedItem];
}

- (id) _contentValues {
    return [self valueForKeyPath: @"itemArray.title"];
}

// FIXME: is it contentValues or contentObjects, or both?
- (void) _setContentValues: (NSArray *) values {
    [self _setItemValues: values forKey: @"title"];
}

- (id) _contentObjects {
    return [self valueForKeyPath: @"itemArray.title"];
}

- (void) _setContentObjects: (NSArray *) objects {
    [self _setItemValues: objects forKey: @"title"];
}

- (id) _content {
    return [self valueForKeyPath: @"itemArray.representedObject"];
}

- (void) _setContent: (NSArray *) values {
    [self _setItemValues: values forKey: @"representedObject"];
    if (![self _binderForBinding: @"contentValues"]) {
        [self _setItemValues: [values valueForKey: @"description"]
                      forKey: @"title"];
    }
}

- (NSInteger) _selectedTag {
    return [[_cell selectedItem] tag];
}

- (void) _setSelectedTag: (NSInteger) tag {
    int index = [_cell indexOfItemWithTag: tag];

    if (index >= 0)
        [_cell selectItemAtIndex: index];
}

- (NSUInteger) _selectedIndex {
    return [self indexOfSelectedItem];
}

- (void) _setSelectedIndex: (NSUInteger) idx {
    [self selectItemAtIndex: idx];
}

- (id) _selectedValue {
    return [self titleOfSelectedItem];
}

- (void) _setSelectedValue: (id) value {
    if (value && ![value isKindOfClass: [NSString class]]) {
        // Cocoa actually accepts non string values
        value = [NSString stringWithFormat: @"%@", value];
    }
    [self selectItemWithTitle: value];
}

- (void) bind: (NSString *) binding
           toObject: (id) observable
        withKeyPath: (NSString *) keyPath
            options: (NSDictionary *) options
{
    // No need to observe the same thing many times when we have several
    // bindings
    if (!_observerAdded) {
        _observerAdded = YES;
        [self addObserver: self
                forKeyPath: @"cell.menu.itemArray"
                   options: NSKeyValueObservingOptionPrior
                   context: NSPopUpButtonBindingObservationContext];

        [self addObserver: self
                forKeyPath: @"cell.selectedItem"
                   options: NSKeyValueObservingOptionPrior
                   context: NSPopUpButtonBindingObservationContext];
    }
    [super bind: binding
               toObject: observable
            withKeyPath: keyPath
                options: options];
}

- (void) observeValueForKeyPath: (NSString *) keyPath
                       ofObject: (id) object
                         change: (NSDictionary *) change
                        context: (void *) context
{
    if (context == NSPopUpButtonBindingObservationContext) {
        if ([keyPath isEqualToString: @"cell.selectedItem"]) {
            if ([[change objectForKey: NSKeyValueChangeNotificationIsPriorKey]
                        boolValue]) {
                [self willChangeValueForKey: @"selectedIndex"];
                [self willChangeValueForKey: @"selectedValue"];
                [self willChangeValueForKey: @"selectedObject"];
                [self willChangeValueForKey: @"selectedTag"];

            } else {
                [self didChangeValueForKey: @"selectedObject"];
                [self didChangeValueForKey: @"selectedValue"];
                [self didChangeValueForKey: @"selectedIndex"];
                [self didChangeValueForKey: @"selectedTag"];
            }
        } else {
            if ([[change objectForKey: NSKeyValueChangeNotificationIsPriorKey]
                        boolValue]) {
                [self willChangeValueForKey: @"contentValues"];
            } else {
                [self didChangeValueForKey: @"contentValues"];
            }
        }
    } else {
        [super observeValueForKeyPath: keyPath
                             ofObject: object
                               change: change
                              context: context];
    }
}
@end
