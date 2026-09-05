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

#import "NSTextStorage_concrete.h"
#import <AppKit/NSAttributedString.h>
#import <AppKit/NSLayoutManager.h>
#import <AppKit/NSTextStorage.h>
#import <objc/runtime.h>
#import <Foundation/NSKeyedArchiver.h>

NSString *const NSTextStorageWillProcessEditingNotification =
        @"NSTextStorageWillProcessEditingNotification";
NSString *const NSTextStorageDidProcessEditingNotification =
        @"NSTextStorageDidProcessEditingNotification";

@implementation NSTextStorage

/*
 * INITIALISING FROM ANOTHER ATTRIBUTED STRING, which every text system caller does.
 *
 * -initWithAttributedString: is a primitive of NSMutableAttributedString and Foundation implements
 * it on the PLACEHOLDER class, so an ordinary subclass allocated for real, which is what a text
 * storage is, never inherits it: iTerm2 raised an unrecognized selector on
 * -[NSTextStorage_concrete initWithAttributedString:] while building a window. It is written in
 * terms of the two primitives every concrete text storage has.
 */
- initWithAttributedString: (NSAttributedString *) other {
    self = [self initWithString: @""];

    if (self != nil && other != nil) {
        [self setAttributedString: other];
    }
    return self;
}


+ allocWithZone: (NSZone *) zone {
    if (self == [NSTextStorage class])
        return NSAllocateObject([NSTextStorage_concrete class], 0, NULL);

    return NSAllocateObject(self, 0, zone);
}

- init {
    /* A SUBCLASS GETS HERE AND USED TO GET NOTHING. NSTextStorage is meant to be subclassed, and a
     * subclass that supplies its own primitives calls [super init] rather than -initWithString:.
     * There was no -init on this class, so that call fell through to NSObject and left
     * _layoutManagers nil. Nothing complained: -addLayoutManager: then sent addObject: to nil and
     * -layoutManagers answered nil, so the layout manager was silently dropped and every text
     * container the application wired through [[storage layoutManagers] objectAtIndexedSubscript: 0]
     * was joined to nothing. */
    if (_layoutManagers == nil) {
        _layoutManagers = [NSMutableArray new];
    }
    return self;
}

- initWithCoder: (NSCoder *) coder {
    _layoutManagers = [NSMutableArray new];
    return self;
}

- (void) encodeWithCoder: (NSCoder *) coder {
}

- initWithString: (NSString *) string {
    _layoutManagers = [NSMutableArray new];
    return self;
}

- (void) dealloc {
    [_layoutManagers release];
    [super dealloc];
}

- delegate {
    return _delegate;
}

- (NSArray *) layoutManagers {
    /* IS THE STORAGE THERE AT ALL. CDDTextBlock wires its container to
     * [[textStorage layoutManagers] objectAtIndexedSubscript: 0], so a nil storage makes that whole
     * chain a silent nil and the container is never joined to anything. This line firing says the
     * storage exists and gives the count; it staying silent says the storage was nil. */
    if (getenv("CIDER_TRACE_CONTROL") != NULL) {
        fprintf(stderr, "CIDER_LM storage=%p layoutManagers count=%lu\n", self,
                (unsigned long) [_layoutManagers count]);
        fflush(stderr);
    }
    if (_layoutManagers == nil) {
        _layoutManagers = [NSMutableArray new];
    }
    return _layoutManagers;
}

- (int) changeInLength {
    return _changeInLength;
}

- (unsigned) editedMask {
    return _editedMask;
}

- (NSRange) editedRange {
    return _editedRange;
}

- (void) setDelegate: delegate {
    _delegate = delegate;
}

- (void) addLayoutManager: (NSLayoutManager *) layoutManager {
    if (getenv("CIDER_TRACE_CONTROL") != NULL) {
        fprintf(stderr, "CIDER_LM storage=%p class=%s addLayoutManager=%p\n", self,
                object_getClassName(self), layoutManager);
        fflush(stderr);
    }
    /* BELT AND BRACES. Any initialiser that skipped the array would otherwise drop this on the
     * floor without a word, which is the failure this whole trail was chasing. */
    if (_layoutManagers == nil) {
        _layoutManagers = [NSMutableArray new];
    }
    [_layoutManagers addObject: layoutManager];
    [layoutManager setTextStorage: self];
}

- (void) removeLayoutManager: (NSLayoutManager *) layoutManager {
    [_layoutManagers removeObjectIdenticalTo: layoutManager];
}

- (void) beginEditing {

    if (_beginEditing == 0) {
        _editedMask = 0;
        _editedRange = NSMakeRange(-1, -1);
        _changeInLength = 0;
    }

    _beginEditing++;
}

- (void) endEditing {
    _beginEditing--;
    if (_beginEditing == 0) {
        // Prevent any change to trigger more notification
        _beginEditing++;
        [self processEditing];
        _beginEditing--;
    }
}

- (NSRange) invalidatedRange {
    return _editedRange;
}

/* iA Writer hooks this with Aspects on its text storage, and the base method did not exist, so
 * the very first edit raised and AppKit swallowed it per event. macOS records the range for a
 * later lazy fix; fixing eagerly is the same contract kept immediately. */
- (void) invalidateAttributesInRange: (NSRange) range {
    [self fixAttributesInRange: range];
}

- (void) processEditing {
    int i, count;

    if ([_delegate respondsToSelector: @selector
                   (textStorageWillProcessEditing:)]) {
        NSNotification *note = [NSNotification
                notificationWithName:
                        NSTextStorageWillProcessEditingNotification
                              object: self
                            userInfo: nil];
        [_delegate textStorageWillProcessEditing: note];
    }

    [[NSNotificationCenter defaultCenter]
            postNotificationName: NSTextStorageWillProcessEditingNotification
                          object: self];

    [self fixAttributesInRange: _editedRange];

    if ([_delegate
                respondsToSelector: @selector(textStorageDidProcessEditing:)]) {
        NSNotification *note = [NSNotification
                notificationWithName: NSTextStorageDidProcessEditingNotification
                              object: self
                            userInfo: nil];
        [_delegate textStorageDidProcessEditing: note];
    }

    [[NSNotificationCenter defaultCenter]
            postNotificationName: NSTextStorageDidProcessEditingNotification
                          object: self];

    count = [_layoutManagers count];
    for (i = 0; i < count; i++) {
        NSLayoutManager *layout = [_layoutManagers objectAtIndex: i];

        [layout textStorage: self
                          edited: [self editedMask]
                           range: [self editedRange]
                  changeInLength: [self changeInLength]
                invalidatedRange: [self invalidatedRange]];
    }
}

- (void) edited: (unsigned) editedMask
                 range: (NSRange) range
        changeInLength: (int) delta
{

    if (_beginEditing == 0) {
        _editedMask = editedMask;
        _changeInLength = delta;
        range.length += delta;
        _editedRange = range;

        // Prevent any change to trigger more notification
        _beginEditing++;
        [self processEditing];
        _beginEditing--;
    } else {
        _editedMask |= editedMask;
        _changeInLength += delta;
        range.length += delta;

        if (_editedRange.location == -1 && _editedRange.length == -1)
            _editedRange = range;
        else
            _editedRange = NSUnionRange(_editedRange, range);
    }
}

- (void) setFont: (NSFont *) font {
    [self addAttribute: NSFontAttributeName
                 value: font
                 range: NSMakeRange(0, [self length])];
}

@end
