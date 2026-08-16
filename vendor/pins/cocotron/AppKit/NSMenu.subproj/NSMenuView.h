/* Copyright (c) 2006-2007 Christopher J. W. Lloyd

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

#import <AppKit/AppKit.h>

/* THE TWO ROWS THE HELP SEARCH DRAWS DIFFERENTLY. macOS puts a real search FIELD at the top of that
 * menu and a grey section heading above the results; both are menu items here, marked by tag so the
 * drawing can tell them from a command. The values are far outside anything an application uses. */
enum {
    CiderMenuSearchFieldTag = -9911,
    CiderMenuSectionHeaderTag = -9912,
};

@interface NSMenuView : NSView {
    NSUInteger _selectedItemIndex;
    NSMutableArray *_visibleArray;
    /* THE HELP MENU SEARCH. Typing in an open Help menu filters every menu in the application, the
     * way macOS does. The query lives on the view rather than on the menu because it belongs to
     * this presentation of it and has to go when the menu closes. */
    NSString *_searchQuery;
    NSMutableArray *_searchResults;
}

- (NSUInteger) itemIndexAtPoint: (NSPoint) point;
- (NSUInteger) itemIndexAtPoint: (NSPoint) point rect: (NSRect*) rect;
- (NSUInteger) selectedItemIndex;
- (void) setSelectedItemIndex: (NSUInteger) itemIndex;

- (NSArray *) visibleItemArray;
- (BOOL) _isApplicationHelpMenu;
- (NSString *) _searchQuery;
- (void) _setSearchQuery: (NSString *) query;
- (NSMenuItem *) itemAtSelectedIndex;

- (NSMenuView *) viewAtSelectedIndexPositionOnScreen: (NSScreen *) screen;

- (NSMenuItem *) trackForEvent: (NSEvent *) event;

@end
