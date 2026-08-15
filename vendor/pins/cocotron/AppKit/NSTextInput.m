#include <AppKit/NSTextInput.h>
#import <AppKit/NSEvent.h>
#include <AppKit/NSTextInput_Internal.h>

NSString *const NSTextInputContextKeyboardSelectionDidChangeNotification = @"NSTextInputContextKeyboardSelectionDidChangeNotification";

NSString *const NSTextInputReplacementRangeAttributeName = @"NSTextInputReplacementRangeAttributeName";

@implementation NSTextInputContext

/*
 * The active context, which is what +currentInputContext answers.
 *
 * A file static rather than a lookup through the responder chain, because activation is explicit:
 * a view that wants text activates its context when it becomes first responder, and the last one
 * to do so is the current one. That is the same rule Cocoa uses and it does not need a key window
 * to be correct.
 */
static NSTextInputContext *_ciderCurrentInputContext = nil;

+ (NSTextInputContext *) currentInputContext {
    return _ciderCurrentInputContext;
}

- (instancetype) initWithClient: (id) client {
    self = [super init];
    if (self == nil) {
        return nil;
    }
    _client = client;
    return self;
}

- (id) client {
    return _client;
}

- (void) activate {
    _ciderCurrentInputContext = self;
}

- (void) deactivate {
    if (_ciderCurrentInputContext == self) {
        _ciderCurrentInputContext = nil;
    }
}

/*
 * Turn a key event into text for the client.
 *
 * WHAT IS FILTERED AND WHY. Control characters and the function key range are COMMANDS, not text:
 * inserting them puts a box or a stray glyph into the document for every arrow key press. Return
 * and tab are left in because applications expect them as text and handle them themselves.
 *
 * No marked text handling yet, so dead keys and input methods that compose over several keystrokes
 * are not supported. That is a real gap and it is a separate piece of work; plain typing does not
 * go through it.
 */
- (BOOL) handleEvent: (NSEvent *) event {
    if (event == nil || [event type] != NSKeyDown) {
        return NO;
    }
    NSString *characters = [event characters];
    if ([characters length] == 0) {
        return NO;
    }

    NSMutableString *text = [NSMutableString stringWithCapacity: [characters length]];
    NSUInteger i, length = [characters length];
    for (i = 0; i < length; i++) {
        unichar c = [characters characterAtIndex: i];
        if (c >= NSUpArrowFunctionKey && c <= NSModeSwitchFunctionKey) {
            continue;
        }
        if (c < ' ' && c != '\r' && c != '\n' && c != '\t') {
            continue;
        }
        [text appendFormat: @"%C", c];
    }
    if ([text length] == 0) {
        return NO;
    }

    if ([_client respondsToSelector: @selector(insertText:replacementRange:)]) {
        [_client insertText: text replacementRange: NSMakeRange(NSNotFound, 0)];
        return YES;
    }
    if ([_client respondsToSelector: @selector(insertText:)]) {
        [_client insertText: text];
        return YES;
    }
    return NO;
}

- (void) discardMarkedText {
    if ([_client respondsToSelector: @selector(unmarkText)]) {
        [_client unmarkText];
    }
}

- (void) invalidateCharacterCoordinates {
}

@end
