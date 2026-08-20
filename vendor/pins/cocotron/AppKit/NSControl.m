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

#import <AppKit/NSApplication.h>
#import <AppKit/NSCell.h>
#import <AppKit/NSClipView.h>
#import <AppKit/NSControl.h>
#import <AppKit/NSControlAuxiliary.h>
#import <AppKit/NSEvent.h>
#import <AppKit/NSFont.h>
#import <AppKit/NSRaise.h>
#import <AppKit/NSTextStorage.h>
#import <AppKit/NSTextView.h>
#import <AppKit/NSWindow.h>
#import <Foundation/NSKeyedArchiver.h>
//#import <AppKit/NSObject+BindingSupport.h>
#import <AppKit/NSKeyValueBinding.h>
#include <execinfo.h>
#include <dlfcn.h>
#include <string.h>
#include <stdio.h>
#import <objc/runtime.h>

NSString *const NSControlTextDidBeginEditingNotification =
        @"NSControlTextDidBeginEditingNotification";
NSString *const NSControlTextDidChangeNotification =
        @"NSControlTextDidChangeNotification";
NSString *const NSControlTextDidEndEditingNotification =
        @"NSControlTextDidEndEditingNotification";

@implementation NSControl

/*
 * STORED, AND NOTHING CONSULTS IT YET. MoneyMoney sends this to every button it builds and the
 * missing selector took the whole application down with an uncaught exception. The property is a
 * real one: what is set comes back out. The behaviour it gates, folding a double click into a
 * single one, needs click counting that this control does not do at all yet, so a button that is
 * told to ignore multi clicks still sees them; that is a smaller wrong than not launching.
 *
 * An associated object rather than an ivar, because applications subclass NSControl and an ivar
 * added here would move theirs.
 */
static const void *kCiderIgnoresMultiClickKey = &kCiderIgnoresMultiClickKey;

- (BOOL) ignoresMultiClick {
    return objc_getAssociatedObject(self, kCiderIgnoresMultiClickKey) != nil;
}

- (void) setIgnoresMultiClick: (BOOL) ignoresMultiClick {
    objc_setAssociatedObject(self, kCiderIgnoresMultiClickKey,
                             ignoresMultiClick ? self : nil, OBJC_ASSOCIATION_ASSIGN);
}

@synthesize allowsExpansionToolTips = _allowsExpansionToolTips;
@synthesize allowsLogicalLayoutDirection = _allowsLogicalLayoutDirection;

static NSMutableDictionary *cellClassDictionary = nil;

+ (void) initialize {
    if (cellClassDictionary == nil)
        cellClassDictionary = [[NSMutableDictionary alloc] init];
}

+ (Class) cellClass {
    return [cellClassDictionary objectForKey: [[self class] description]];
}

+ (void) setCellClass: (Class) aClass {
    [cellClassDictionary setObject: aClass forKey: [[self class] description]];
}

- (void) encodeWithCoder: (NSCoder *) coder {
    [super encodeWithCoder: coder];

    if (coder.allowsKeyedCoding) {
        [coder encodeObject: _cell forKey: @"NSCell"];
        [coder encodeInteger: _aux.tag forKey: @"NSTag"];
        [coder encodeObject: _aux.target forKey: @"NSControlTarget"];
        if (_aux.action != NULL) {
            [coder encodeObject: NSStringFromSelector(_aux.action)
                         forKey: @"NSControlAction"];
        }
    } else {
        [NSException raise: NSInvalidArchiveOperationException
                    format: @"TODO: support unkeyed encoding in NSControl"];
    }
}

- initWithCoder: (NSCoder *) coder {
    [super initWithCoder: coder];

    _aux = [[NSControlAuxiliary alloc] init];

    if ([coder allowsKeyedCoding]) {
        NSKeyedUnarchiver *keyed = (NSKeyedUnarchiver *) coder;
        [self setCell: [keyed decodeObjectForKey: @"NSCell"]];

        [_aux setTag: [keyed decodeIntegerForKey: @"NSTag"]];

        SEL sel = NSSelectorFromString(
                [keyed decodeObjectForKey: @"NSControlAction"]);
        if (sel)
            [_aux setAction: sel];
        [_aux setTarget: [keyed decodeObjectForKey: @"NSControlTarget"]];
    } else {
        NSInteger version = [coder versionForClassName: @"NSControl"];
        NSLog(@"NSControl version is %ld\n", (long) version);

        if (version <= 16) {
            NSInteger tag;
            id cell;
            unsigned short flags;

            [coder decodeValuesOfObjCTypes: "i@s", &tag, &cell, &flags];
            [_aux setTag: tag];
            [self setCell: cell];

            // TODO: flags
        } else if (version <= 40) {
            NSInteger tag;
            uint8_t flags1, flags2;

            [coder decodeValuesOfObjCTypes: "i", &tag];
            flags1 = [coder decodeByte];
            flags2 = [coder decodeByte];

            [_aux setTag: tag];
            [self setCell: [coder decodeObject]];

            // TODO: flags
        } else {
            NSInteger tag;
            uint8_t flags1, flags2;

            [coder decodeValuesOfObjCTypes: "icc@", &tag, &flags1, &flags2,
                                            &self->_cell];

            [_aux setTag: tag];

            // TODO: flags
        }
    }

    return self;
}

- initWithFrame: (NSRect) frame {
    [super initWithFrame: frame];
    // FIX, verify in subclasses
    _aux = [[NSControlAuxiliary alloc] init];
    Class cellClass = [[self class] cellClass];
    if (cellClass != nil) {
        NSCell *cell = [[[cellClass alloc] init] autorelease];
        [self setCell: cell];
    }
    return self;
}

- (void) dealloc {

    // Don't do anything with the cell until we've cleared the bindings!
    [self _unbindAllBindings];
    [_aux release];
    [_cell release];
    [super dealloc];
}

- cell {
    return _cell;
}

- (BOOL) _shouldDelegateTargetActionForSelector: (SEL) selector {
    if (_cell == nil) {
        return NO;
    }
    IMP baseImp = class_getMethodImplementation([NSCell class], selector);
    IMP cellImp = class_getMethodImplementation([_cell class], selector);

    return baseImp == nil || cellImp != baseImp;
}

- target {
    if ([self _shouldDelegateTargetActionForSelector: _cmd]) {
        return [_cell target];
    } else {
        return [_aux target];
    }
}

- (SEL) action {
    if ([self _shouldDelegateTargetActionForSelector: _cmd]) {
        return [_cell action];
    } else {
        return [_aux action];
    }
}

- (NSInteger) tag {
    return _tag;
}

- (NSFont *) font {
    return [_cell font];
}

- (NSImage *) image {
    return [[self cell] image];
}

- (NSTextAlignment) alignment {
    return [_cell alignment];
}

/*
 * CONTROL SIZE IS A CELL PROPERTY THE CONTROL ALSO ANSWERS FOR, since 10.10. MoneyMoney asks its
 * text fields for it while laying out the preferences window, and an unrecognized selector inside a
 * layout pass is caught by NSApplication, so the whole window silently never appeared.
 */
- (NSControlSize) controlSize {
    return [_cell controlSize];
}

- (BOOL) isEnabled {
    return [_cell isEnabled];
}

- (BOOL) isEditable {
    return [_cell isEditable];
}

- (BOOL) isSelectable {
    return [_cell isSelectable];
}

- (BOOL) isScrollable {
    return [_cell isScrollable];
}

- (BOOL) isBordered {
    return [_cell isBordered];
}

- (BOOL) isBezeled {
    return [_cell isBezeled];
}

- (BOOL) isContinuous {
    return [_cell isContinuous];
}

- (BOOL) needsPanelToBecomeKey {
    // The Apple way
    return [_cell isSelectable];
}

- (BOOL) refusesFirstResponder {
    return [_cell refusesFirstResponder];
}

- (id) formatter {
    return [_cell formatter];
}

- (NSLineBreakMode) lineBreakMode {
    return [_cell lineBreakMode];
}

- (BOOL) usesSingleLineMode {
    return [_cell usesSingleLineMode];
}

- objectValue {
    return [[self selectedCell] objectValue];
}

- (NSString *) stringValue {
    return [[self selectedCell] stringValue];
}

- (NSAttributedString *) attributedStringValue {
    return [[self selectedCell] attributedStringValue];
}

- (int) intValue {
    return [[self selectedCell] intValue];
}

- (float) floatValue {
    return [[self selectedCell] floatValue];
}

- (double) doubleValue {
    return [[self selectedCell] doubleValue];
}

- (NSInteger) integerValue {
    return [[self selectedCell] integerValue];
}

- selectedCell {
    return _cell;
}

- (NSInteger) selectedTag {
    return [[self selectedCell] tag];
}

- (void) setCell: (NSCell *) cell {
    cell = [cell retain];
    [_cell release];
    _cell = cell;
}

- (void) setTarget: target {
    if ([self _shouldDelegateTargetActionForSelector: _cmd]) {
        [_cell setTarget: target];
    } else {
        [_aux setTarget: target];
    }
}

- (void) setAction: (SEL) action {
    if ([self _shouldDelegateTargetActionForSelector: _cmd]) {
        [_cell setAction: action];
    } else {
        [_aux setAction: action];
    }
}

- (void) setTag: (NSInteger) tag {
    _tag = tag;
}

- (void) setFont: (NSFont *) font {
    [_cell setFont: font];
    [self setNeedsDisplay: YES];
}

- (void) setImage: (NSImage *) image {
    [[self cell] setImage: image];
    [self setNeedsDisplay: YES];
}

- (void) setAlignment: (NSTextAlignment) alignment {
    [_cell setAlignment: alignment];
    [self setNeedsDisplay: YES];
}

- (void) setFloatingPointFormat: (BOOL) fpp
                           left: (NSUInteger) left
                          right: (NSUInteger) right
{
    [_cell setFloatingPointFormat: fpp left: left right: right];
}

- (void) setControlSize: (NSControlSize) size {
    [_cell setControlSize: size];
    [self setNeedsDisplay: YES];
}

- (void) setEnabled: (BOOL) flag {
    if (getenv("CIDER_TRACE_CONTROL") != NULL && getenv("CIDER_TRACE_CONTROL")[0] != '\0') {
        /* THE POINTER MATTERS. Four setEnabled:YES on something titled Choose and a click that
         * finds it disabled can be one button changing its mind or two different buttons, and the
         * title alone cannot tell them apart. */
        NSLog(@"CIDER_CONTROL setEnabled self=%p class=%s title=%@ flag=%d was=%d",
              (void *) self, object_getClassName(self),
              [self respondsToSelector: @selector(title)] ? [(id) self title] : @"(none)",
              (int) flag, (int) [self isEnabled]);

        /*
         * AND WHO TURNED IT OFF. A control that is enabled and then disabled again before the user
         * can click it is a decision made somewhere, and the count of calls cannot say where. Only
         * on the way DOWN, since an enable is not the puzzle, and symbols only, the same way
         * -[NSException raise] prints its frames.
         */
        if (!flag) {
            void *frames[16];
            int count = backtrace(frames, 16);

            for (int i = 1; i < count; i++) {
                Dl_info info;

                if (dladdr(frames[i], &info) != 0 && info.dli_sname != NULL) {
                    const char *image = info.dli_fname ? strrchr(info.dli_fname, '/') : NULL;

                    fprintf(stderr, "CIDER_CONTROL_OFF   %-26s %s\n",
                            image ? image + 1 : "?", info.dli_sname);
                }
            }
            fflush(stderr);
        }
    }

    [_cell setEnabled: flag];
    [self setNeedsDisplay: YES];
}

- (void) setEditable: (BOOL) flag {
    [_cell setEditable: flag];
}

- (void) setSelectable: (BOOL) flag {
    [_cell setSelectable: flag];
}

- (void) setScrollable: (BOOL) flag {
    [_cell setScrollable: flag];
}

- (void) setBordered: (BOOL) flag {
    [_cell setBordered: flag];
    [self setNeedsDisplay: YES];
}

- (void) setBezeled: (BOOL) flag {
    [_cell setBezeled: flag];
    [self setNeedsDisplay: YES];
}

- (void) setContinuous: (BOOL) flag {
    [_cell setContinuous: flag];
}

- (void) setRefusesFirstResponder: (BOOL) flag {
    [_cell setRefusesFirstResponder: flag];
}

- (void) setFormatter: (NSFormatter *) formatter {
    [_cell setFormatter: formatter];
    [self setNeedsDisplay: YES];
}

- (void) setLineBreakMode: (NSLineBreakMode) lineBreakMode {
    [_cell setLineBreakMode: lineBreakMode];
}

- (void) setUsesSingleLineMode: (BOOL) flag {
    [_cell setUsesSingleLineMode: flag];
}

- (void) setObjectValue: (id<NSCopying>) object {
    [self abortEditing];
    [(NSCell *) [self selectedCell] setObjectValue: object];
    [self setNeedsDisplay: YES];
}

- (void) setStringValue: (NSString *) value {
    [self abortEditing];
    [[self selectedCell] setStringValue: value];
    [self setNeedsDisplay: YES];
}

- (void) setIntValue: (int) value {
    [self abortEditing];
    [[self selectedCell] setIntValue: value];
    [self setNeedsDisplay: YES];
}

- (void) setFloatValue: (float) value {
    [self abortEditing];
    [[self selectedCell] setFloatValue: value];
    [self setNeedsDisplay: YES];
}

- (void) setDoubleValue: (double) value {
    [self abortEditing];
    [[self selectedCell] setDoubleValue: value];
    [self setNeedsDisplay: YES];
}

- (void) setIntegerValue: (NSInteger) value {
    [self abortEditing];
    [[self selectedCell] setIntegerValue: value];
    [self setNeedsDisplay: YES];
}

- (void) setAttributedStringValue: (NSAttributedString *) value {
    [self abortEditing];
    [[self selectedCell] setAttributedStringValue: value];
    [self setNeedsDisplay: YES];
}

- (void) takeObjectValueFrom: sender {
    [self abortEditing];
    [[self selectedCell] takeObjectValueFrom: sender];
    [self setNeedsDisplay: YES];
}

- (void) takeStringValueFrom: sender {
    [self abortEditing];
    [[self selectedCell] takeStringValueFrom: sender];
    [self setNeedsDisplay: YES];
}

- (void) takeIntValueFrom: sender {
    [self abortEditing];
    [[self selectedCell] takeIntValueFrom: sender];
    [self setNeedsDisplay: YES];
}

- (void) takeFloatValueFrom: sender {
    [self abortEditing];
    [[self selectedCell] takeFloatValueFrom: sender];
    [self setNeedsDisplay: YES];
}

- (void) takeDoubleValueFrom: sender {
    [self abortEditing];
    [[self selectedCell] takeDoubleValueFrom: sender];
    [self setNeedsDisplay: YES];
}

- (void) takeIntegerValueFrom: sender {
    [self abortEditing];
    [[self selectedCell] takeIntegerValueFrom: sender];
    [self setNeedsDisplay: YES];
}

- (void) selectCell: (NSCell *) cell {
    if (_cell == cell) {
        [_cell setState: YES];
        [self setNeedsDisplay: YES];
    }
}

- (void) drawCell: (NSCell *) cell {
    if (_cell == cell) {
        [_cell setControlView: self];
        [_cell drawWithFrame: _bounds inView: self];
    }
}

- (void) drawCellInside: (NSCell *) cell {
    if (_cell == cell)
        [_cell drawInteriorWithFrame: _bounds inView: self];
}

- (void) updateCell: (NSCell *) cell {
    if (_cell == cell) {
        [self setNeedsDisplay: YES];
    }
}

- (void) updateCellInside: (NSCell *) cell {
    if (_cell == cell)
        [self setNeedsDisplay: YES];
}

// Hmm, shouldn't this just noop?
- (void) performClick: sender {
    //   NSUnimplementedMethod();
}

- (BOOL) sendAction: (SEL) action to: target {
    /* DID THE CLICK REACH A CONTROL AT ALL, which a screenshot cannot answer. A button that is
     * disabled never gets here, and a click that misses never gets here either, so this separates
     * the two. */
    if (getenv("CIDER_TRACE_CONTROL") != NULL && getenv("CIDER_TRACE_CONTROL")[0] != '\0') {
        NSLog(@"CIDER_CONTROL send class=%s action=%s target=%s enabled=%d",
              object_getClassName(self), action ? sel_getName(action) : "(nil)",
              target ? object_getClassName(target) : "(nil)", (int) [self isEnabled]);
    }

    return [NSApp sendAction: action to: target from: self];
}

- (NSText *) currentEditor {
    return _currentEditor;
}

- (void) validateEditing {
    if (_currentEditor) {
        NSString *string = [_currentEditor string];
        BOOL acceptsString = YES;
        NSFormatter *formatter = [self formatter];
        if (formatter) {
            acceptsString = NO;

            id objectValue = nil;
            NSString *error = nil;
            if ([formatter getObjectValue: &objectValue
                                forString: string
                         errorDescription: &error] == YES) {
                [[self selectedCell] setObjectValue: objectValue];
            }
        }
        if (acceptsString) {
            if ([_currentEditor isRichText]) {
                if ([_currentEditor isKindOfClass: [NSTextView class]]) {
                    NSTextView *textview = (NSTextView *) _currentEditor;
                    NSAttributedString *text = [textview textStorage];
                    NSAttributedString *string = [[[NSAttributedString alloc]
                            initWithAttributedString: text] autorelease];
                    [[self selectedCell] setAttributedStringValue: string];
                } else {
                    [[self selectedCell] setStringValue: string];
                }
            } else {
                [[self selectedCell] setStringValue: string];
            }
        }
    }
}

- (BOOL) abortEditing {
    if (_currentEditor != nil) {
        // this may be invalid after endEditingFor: if we dont retain it
        NSView *superview = [[[_currentEditor superview] retain] autorelease];

        // we don't want delegate messages when aborting
        [_currentEditor setDelegate: nil];

        [[self window] endEditingFor: self];

        if ([superview isKindOfClass: [NSClipView class]])
            [superview removeFromSuperview];

        [_currentEditor release];
        _currentEditor = nil;
    }
    return NO;
}

- (void) calcSize {
    // do nothing
}

- (void) sizeToFit {
    NSSize cellSize = [[self cell] cellSize];

    [self setFrameSize: cellSize];
}

- (void) setNeedsDisplay {
    [self setNeedsDisplay: YES];
}

- (BOOL) acceptsFirstResponder {
    return ![self refusesFirstResponder];
}

- (BOOL) resignFirstResponder {
    if (_currentEditor) {
        return [[self selectedCell] hasValidObjectValue];
    }
    return YES;
}

- (void) lockFocus {
    [self calcSize];
    [super lockFocus];
}

- (void) textDidBeginEditing: (NSNotification *) note {
    if ([note object] != _currentEditor)
        return;

    [[NSNotificationCenter defaultCenter]
            postNotificationName: NSControlTextDidBeginEditingNotification
                          object: self
                        userInfo: [NSDictionary
                                          dictionaryWithObject: [note object]
                                                        forKey: @"NSFieldEdito"
                                                                @"r"]];

    // If this control's value is bound to an object that conforms to
    // NSEditorRegistration, register as an editor.
    NSDictionary *bindingInfo = nil; // [self infoForBinding:@"value"];
    if (bindingInfo) {
        id observedObject = [bindingInfo objectForKey: NSObservedObjectKey];
        if ([observedObject
                    respondsToSelector: @selector(objectDidBeginEditing:)])
            [observedObject objectDidBeginEditing: self];
    }
}

- (void) textDidChange: (NSNotification *) note {
    if ([note object] != _currentEditor)
        return;

    // FIX, Add formatter logic here
    [[self selectedCell] setStringValue: [[note object] string]];

    [[NSNotificationCenter defaultCenter]
            postNotificationName: NSControlTextDidChangeNotification
                          object: self
                        userInfo: [NSDictionary
                                          dictionaryWithObject: [note object]
                                                        forKey: @"NSFieldEdito"
                                                                @"r"]];
}

- (void) textDidEndEditing: (NSNotification *) note {
    // It is possible for an NSControl subclass to be the delegate of another
    // text view
    if ([note object] != _currentEditor)
        return;

    [self validateEditing];
    [self abortEditing];

    [[NSNotificationCenter defaultCenter]
            postNotificationName: NSControlTextDidEndEditingNotification
                          object: self
                        userInfo: [NSDictionary
                                          dictionaryWithObject: [note object]
                                                        forKey: @"NSFieldEdito"
                                                                @"r"]];

    // If this control's value is bound to an object that conforms to
    // NSEditorRegistration, unregister as an editor.
    NSDictionary *bindingInfo = nil; // [self infoForBinding:@"value"];
    if (bindingInfo) {
        id observedObject = [bindingInfo objectForKey: NSObservedObjectKey];
        if ([observedObject
                    respondsToSelector: @selector(objectDidEndEditing:)])
            [observedObject objectDidEndEditing: self];
    }

    [self setNeedsDisplay: YES];
}

- (void) drawRect: (NSRect) rect {
    [_cell setControlView: self];
    [_cell drawWithFrame: _bounds inView: self];
}

- (void) mouseDown: (NSEvent *) event {
    /* DID THIS CONTROL SEE THE CLICK. sendAction: is the wrong place to ask, as an earlier run
     * proved: the Close button worked and printed nothing there, so buttons do not fire through
     * -[NSControl sendAction:to:] here. mouseDown IS the entry point, so a control that never
     * prints never got the click, and one that prints but does nothing is a different bug. */
    if (getenv("CIDER_TRACE_CONTROL") != NULL && getenv("CIDER_TRACE_CONTROL")[0] != '\0') {
        NSLog(@"CIDER_CONTROL mouseDown self=%p class=%s title=%@ enabled=%d frame=%@",
              (void *) self, object_getClassName(self),
              [self respondsToSelector: @selector(title)] ? [(id) self title] : @"(none)",
              (int) [self isEnabled], NSStringFromRect([self frame]));
    }

    BOOL sendAction = NO;

    if (![self isEnabled])
        return;

    [self lockFocus];

    do {
        NSPoint point = [self convertPoint: [event locationInWindow]
                                  fromView: nil];

        if (NSMouseInRect(point, [self bounds], [self isFlipped])) {
            [_cell highlight: YES withFrame: [self bounds] inView: self];
            [self setNeedsDisplay: YES];

            if ([_cell trackMouse: event
                              inRect: [self bounds]
                              ofView: self
                        untilMouseUp:
                                [[_cell class] prefersTrackingUntilMouseUp]]) {
                [_cell setState: ![_cell state]];
                [self setNeedsDisplay: YES];
                sendAction = YES;
                break;
            }

            [_cell highlight: NO withFrame: [self bounds] inView: self];
            [self setNeedsDisplay: YES];
        }

        [[self window] flushWindow];
        event = [[self window] nextEventMatchingMask: NSLeftMouseUpMask |
                                                      NSLeftMouseDraggedMask];
    } while ([event type] != NSLeftMouseUp);

    [self unlockFocus];

    if (sendAction) {
        [self sendAction: [self action] to: [self target]];
        [self lockFocus];
        [_cell highlight: NO withFrame: [self bounds] inView: self];
        [self unlockFocus];
        [self setNeedsDisplay: YES];
    }
}

- (BOOL) _setsMaxLayoutWidthAtFirstLayout {
    return _setsMaxLayoutWidthAtFirstLayout;
}

- (void) _setSetsMaxLayoutWidthAtFirstLayout: (BOOL) setsMaxLayoutWidthAtFirstLayout {
    _setsMaxLayoutWidthAtFirstLayout = setsMaxLayoutWidthAtFirstLayout;
}

// NSEditor methods

- (BOOL) commitEditing {
    [self validateEditing];
    return YES;
}

- (void) discardEditing {
    [self abortEditing];
}

@end
