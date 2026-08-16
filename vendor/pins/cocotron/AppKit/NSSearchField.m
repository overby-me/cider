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

#import <AppKit/NSSearchField.h>
#import <AppKit/NSSearchFieldCell.h>

@implementation NSSearchField

/*
 * THE CELL CLASS, which decides what -cell answers and therefore what every method on this class
 * talks to. Without it NSTextField was inherited and a search field got a plain NSTextFieldCell, so
 * -setSearchMenuTemplate:, -setRecentSearches: and the rest went to a cell that has never heard of
 * them: an unrecognized selector for doing the ordinary thing with a search field. iTerm2 sets a
 * menu template on its search field while building the window.
 */
+ (Class) cellClass {
    return [NSSearchFieldCell class];
}

- (NSSearchFieldCell *) _searchCell {
    return [self cell];
}

- (NSArray *) recentSearches {
    return [[self _searchCell] recentSearches];
}

- (NSString *) recentsAutosaveName {
    return [[self _searchCell] recentsAutosaveName];
}

- (void) setRecentSearches: (NSArray *) searches {
    [[self _searchCell] setRecentSearches: searches];
}

- (void) setRecentsAutosaveName: (NSString *) name {
    [[self _searchCell] setRecentsAutosaveName: name];
}

@end
