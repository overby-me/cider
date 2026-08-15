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

#include <objc/runtime.h>

#import <AppKit/NSButtonCell.h>
#import <AppKit/NSComboBoxCell.h>
#import <AppKit/NSComboBoxWindow.h>
#import <AppKit/NSGraphicsStyle.h>
#import <AppKit/NSRaise.h>
#import <Foundation/NSKeyedArchiver.h>

@implementation NSComboBoxCell

- (void) encodeWithCoder: (NSCoder *) coder {
    NSUnimplementedMethod();
}

- initWithCoder: (NSCoder *) coder {
    [super initWithCoder: coder];

    if ([coder allowsKeyedCoding]) {
        NSKeyedUnarchiver *keyed = (NSKeyedUnarchiver *) coder;

        _dataSource = [keyed decodeObjectForKey: @"NSDataSource"];
        _objectValues = [[NSMutableArray alloc]
                initWithArray: [keyed decodeObjectForKey: @"NSPopUpListData"]];
        _numberOfVisibleItems = [keyed decodeIntForKey: @"NSVisibleItemCount"];
        _usesDataSource = [keyed decodeBoolForKey: @"NSUsesDataSource"];
        _hasVerticalScroller =
                [keyed decodeBoolForKey: @"NSHasVerticalScroller"];
        _completes = [keyed decodeBoolForKey: @"NSCompletes"];
        _isButtonBordered = YES;
        _buttonEnabled = YES;
        _buttonPressed = NO;
    } else {
        [NSException raise: NSInvalidArgumentException
                    format: @"-[%@ %s] is not implemented for coder %@",
                            [self class], sel_getName(_cmd), coder];
    }

    return self;
}

/*
 * A COMBO BOX MADE IN CODE HAS A LIVE BUTTON, the way one made in a nib always did.
 *
 * initWithCoder sets _buttonEnabled and _isButtonBordered explicitly; nothing set them for a cell
 * allocated and initialised by hand, so the button drew in its DISABLED colour for every
 * application that does not use nibs. LibreOffice is one, and every toolbar selector came out grey
 * instead of the system accent blue. The item count rule in the add and remove methods is left
 * alone: it still greys the button when an application empties the list itself.
 */
- initTextCell: (NSString *) string {
    self = [super initTextCell: string];
    _buttonEnabled = YES;
    _isButtonBordered = YES;
    return self;
}

- (void) dealloc {
    [_dataSource release];
    [_objectValues release];
    [super dealloc];
}

- copyWithZone: (NSZone *) zone {
    NSComboBoxCell *copy = [super copyWithZone: zone];

    copy->_objectValues = [_objectValues copy];

    return copy;
}

- dataSource {
    return _dataSource;
}

- (BOOL) usesDataSource {
    return _usesDataSource;
}

- (BOOL) isButtonBordered {
    return _isButtonBordered;
}

- (CGFloat) itemHeight {
    return _itemHeight;
}

- (BOOL) hasVerticalScroller {
    return _hasVerticalScroller;
}

- (NSSize) intercellSpacing {
    return _intercellSpacing;
}

- (BOOL) completes {
    return _completes;
}

- (NSInteger) numberOfVisibleItems {
    return _numberOfVisibleItems;
}

- (void) setDataSource: value {
    _dataSource = value;
}

- (void) setUsesDataSource: (BOOL) value {
    _usesDataSource = value;
}

- (void) setButtonBordered: (BOOL) value {
    _isButtonBordered = value;
}

- (void) setItemHeight: (CGFloat) value {
    _itemHeight = value;
}

- (void) setHasVerticalScroller: (BOOL) value {
    _hasVerticalScroller = value;
}

- (void) setIntercellSpacing: (NSSize) value {
    _intercellSpacing = value;
}

- (void) setCompletes: (BOOL) flag {
    _completes = flag;
}

- (void) setNumberOfVisibleItems: (NSInteger) value {
    _numberOfVisibleItems = value;
}

- (NSInteger) numberOfItems {
    return [_objectValues count];
}

- (NSArray *) objectValues {
    return _objectValues;
}

- itemObjectValueAtIndex: (NSInteger) index {
    return [_objectValues objectAtIndex: index];
}

- (NSInteger) indexOfItemWithObjectValue: (id) object {
    return [_objectValues indexOfObjectIdenticalTo: object];
}

- (void) addItemWithObjectValue: (id) object {
    [_objectValues addObject: object];
    _buttonEnabled = ([_objectValues count] > 0) ? YES : NO;
}

- (void) addItemsWithObjectValues: (NSArray *) objects {
    [_objectValues addObjectsFromArray: objects];
    _buttonEnabled = ([_objectValues count] > 0) ? YES : NO;
}

- (void) removeAllItems {
    [_objectValues removeAllObjects];
    _buttonEnabled = ([_objectValues count] > 0) ? YES : NO;
}

- (void) removeItemAtIndex: (NSInteger) index {
    [_objectValues removeObjectAtIndex: index];
    _buttonEnabled = ([_objectValues count] > 0) ? YES : NO;
}

- (void) removeItemWithObjectValue: value {
    [_objectValues removeObject: value];
    _buttonEnabled = ([_objectValues count] > 0) ? YES : NO;
}

- (void) insertItemWithObjectValue: (id) object atIndex: (NSInteger) index {
    [_objectValues insertObject: object atIndex: index];
    _buttonEnabled = ([_objectValues count] > 0) ? YES : NO;
}

- (NSInteger) indexOfSelectedItem {
    NSInteger index = [_objectValues indexOfObject: [self objectValue]];
    return (index != NSNotFound) ? index : -1;
}

- objectValueOfSelectedItem {
    if (!_usesDataSource)
        return [self objectValue];
    else {
        NSLog(@"*** -[%@ %s] should not be called when usesDataSource is set "
              @"to YES",
              [self class], sel_getName(_cmd));
        return NULL;
    }
}

- (void) selectItemAtIndex: (NSInteger) index {
    if (index < 0 || index >= [_objectValues count])
        return;

    [self setObjectValue: [_objectValues objectAtIndex: index]];
}

- (void) selectItemWithObjectValue: value {
    if (!_usesDataSource) {
        NSInteger index = [_objectValues indexOfObject: value];
        [self selectItemAtIndex: (index != NSNotFound) ? index : -1];
    } else
        NSLog(@"*** -[%@ %s] should not be called when usesDataSource is set "
              @"to YES",
              [self class], sel_getName(_cmd));
}

- (void) deselectItemAtIndex: (NSInteger) index {
    NSUnimplementedMethod();
}

- (void) scrollItemAtIndexToTop: (NSInteger) index {
    NSUnimplementedMethod();
}

- (void) scrollItemAtIndexToVisible: (NSInteger) index {
    NSUnimplementedMethod();
}

- (void) noteNumberOfItemsChanged {
    NSUnimplementedMethod();
}

- (void) reloadData {
    NSUnimplementedMethod();
}

- (NSString *) completedString: (NSString *) string {
    NSInteger i, count = [_objectValues count];

    if (_usesDataSource == YES) // not supported yet, well...
        if ([_dataSource respondsToSelector: @selector(comboBoxCell:
                                                     completedString:)] == YES)
            return [_dataSource comboBoxCell: self completedString: string];

    for (i = 0; i < count; ++i) {
        NSString *stringValue;

        //        NSLog(@"checking %@",  [_objectValues objectAtIndex:i]);
        if ([[_objectValues objectAtIndex: i] isKindOfClass: [NSString class]])
            stringValue = [_objectValues objectAtIndex: i];
        else
            stringValue = [[_objectValues objectAtIndex: i] stringValue];

        if ([stringValue hasPrefix: string])
            return stringValue;
    }

    return nil;
}

- (NSSize) cellSize {
    NSSize size = [_controlView frame].size;
    size.width -= 3.0;
    size.height -= 2.0;
    return size;
}

- (NSRect) buttonRectForBounds: (NSRect) rect {
    rect.origin.x = (rect.origin.x + rect.size.width) - rect.size.height;
    rect.size.width = rect.size.height;
    return rect;
}

- (BOOL) trackMouse: (NSEvent *) event
              inRect: (NSRect) cellFrame
              ofView: (NSView *) controlView
        untilMouseUp: (BOOL) flag
{
    NSComboBoxWindow *window;
    NSPoint origin = [controlView bounds].origin;
    NSSize size = [self cellSize];
    NSPoint check = [controlView convertPoint: [event locationInWindow]
                                     fromView: nil];
    NSUInteger selectedIndex =
            [_objectValues indexOfObject: [self objectValue]];

    if ([_objectValues count] == 0)
        return NO;

    if (!NSMouseInRect(check, [self buttonRectForBounds: cellFrame],
                       [controlView isFlipped]))
        return NO;

    origin.y += size.height;
    origin = [controlView convertPoint: origin toView: nil];
    origin = [[controlView window] convertBaseToScreen: origin];
    size.width += 1.0;

    window = [[NSComboBoxWindow alloc] initWithFrame: (NSRect){origin, size}];

    [window setObjectArray: _objectValues];
    [window setSelectedIndex: selectedIndex];
    if ([self font] != nil)
        [window setFont: [self font]];

    _buttonPressed = YES;
    [window makeKeyAndOrderFront: self];
    selectedIndex = [window runTrackingWithEvent: event];
    [window close]; // release when closed=YES
    _buttonPressed = NO;

    if (selectedIndex != NSNotFound) {
        NSTextView *editor = nil;
        if ([[controlView currentEditor] isKindOfClass:[NSTextView class]]) {
            editor = (NSTextView*)[controlView currentEditor];
        }
        
        NSObject *object = [_objectValues objectAtIndex: selectedIndex];
        if (editor && object) {
            NSString *string = nil;
            NSAttributedString *attstr = nil;

            if (_formatter)
                string = [_formatter stringForObjectValue: object];

            if (!string)
                if ([object isKindOfClass: [NSString class]])
                    string = (NSString*)object;
                else if ([object isKindOfClass: [NSAttributedString class]])
                    if ([editor isRichText])
                        attstr = (NSAttributedString*)object;
                    else
                        string = [object string];
                else if ([object respondsToSelector: @selector
                                 (descriptionWithLocale:)])
                    string = [object
                            descriptionWithLocale: [NSLocale currentLocale]];
                else if ([object respondsToSelector: @selector(description)])
                    string = [object description];
                else
                    string = @"";

            if (attstr)
                [[(NSTextView *) editor textStorage]
                        setAttributedString: attstr];
            else
                [editor setString: string];

            [editor setSelectedRange: NSMakeRange(0, [[editor string] length])];
            [self endEditing: editor];
            if (_sendsActionOnEndEditing)
                [(NSControl *) controlView
                        sendAction: [(NSControl *) controlView action]
                                to: [(NSControl *) controlView target]];
        }
    }

    return YES;
}

- (NSRect) titleRectForBounds: (NSRect) rect {
    // Keep some room for the button
    NSRect buttonFrame = [self buttonRectForBounds: rect];
    rect.size.width = NSMinX(buttonFrame) - rect.origin.x;
    rect = [super titleRectForBounds: rect];

    return rect;
}

/*
 * DRAW IN THE RECT THE CALLER GAVE, which is what AppKit does and what this class used not to do.
 *
 * Both of these began with frame.size = [self cellSize], and cellSize here is not an intrinsic
 * size at all: it is [_controlView frame].size minus three by two. That works only when the cell
 * owns its view, one NSComboBox per combo box. An application that draws MANY controls with ONE
 * cell into ONE shared view -- which is how LibreOffice renders its toolbar -- got the size of the
 * WHOLE WINDOW instead: asked for a field of about 200 by 22, the cell drew itself 1021 by 638 and
 * put its button at x=383 width 638, entirely outside the small context it had been handed. That
 * is why the dropdown button was missing, and why the missing thing was the entire native control
 * rather than just the arrow.
 */
- (void) drawInteriorWithFrame: (NSRect) frame inView: (NSView *) controlView {
    [super drawInteriorWithFrame: frame inView: controlView];
}

- (void) drawWithFrame: (NSRect) frame inView: (NSView *) controlView {
    if (getenv("CIDER_TRACE_CELLS") != NULL) {
        NSRect button = [self buttonRectForBounds: frame];

        NSLog(@"CIDER_COMBO asked=%gx%g+%g+%g cellSize=%gx%g button=%gx%g+%g+%g view=%s",
              frame.size.width, frame.size.height, frame.origin.x, frame.origin.y,
              [self cellSize].width, [self cellSize].height, button.size.width,
              button.size.height, button.origin.x, button.origin.y,
              (controlView != nil) ? object_getClassName(controlView) : "nil");
    }

    [super drawWithFrame: frame inView: controlView];

    [NSGraphicsStyleForView(controlView)
            drawComboBoxButtonInRect: [self buttonRectForBounds: frame]
                             enabled: _buttonEnabled
                            bordered: _isButtonBordered
                             pressed: _buttonPressed];
}

@end
