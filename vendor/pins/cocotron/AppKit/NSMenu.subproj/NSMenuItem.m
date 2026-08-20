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

// Original - Christopher Lloyd <cjwl@objc.net>
#include <dlfcn.h>
#import <AppKit/NSEvent.h>
#import <AppKit/NSImage.h>
#import <AppKit/NSMenu.h>
#include <stdio.h>
#include <stdlib.h>
#import <AppKit/NSMenuItem.h>
#import <objc/runtime.h>
#import <Foundation/NSKeyedArchiver.h>
#import <AppKit/NSButtonCell.h>

@interface NSMenuItemCell : NSButtonCell
@end

@implementation NSMenuItem

@synthesize alternate = _alternate;
@synthesize allowsKeyEquivalentWhenHidden = _allowsKeyEquivalentWhenHidden;
@synthesize identifier = _identifier;

+ (NSMenuItem *) separatorItem {
    return [[[self alloc] initWithTitle: nil action: NULL
                          keyEquivalent: nil] autorelease];
}

- (void) encodeWithCoder: (NSCoder *) coder {
    [coder encodeObject: _title forKey: @"NSTitle"];
    [coder encodeObject: _keyEquivalent forKey: @"NSKeyEquiv"];
    [coder encodeInt: _keyEquivalentModifierMask
              forKey: @"NSKeyEquivModMask"];
    [coder encodeObject: _submenu forKey: @"NSSubmenu"];
    [coder encodeInt: _tag forKey: @"NSTag"];
    [coder encodeObject: NSStringFromSelector(_action) forKey: @"NSAction"];
    [coder encodeObject: _target forKey: @"NSTarget"];
}

- initWithCoder: (NSCoder *) coder {
    if ([coder allowsKeyedCoding]) {
        NSKeyedUnarchiver *keyed = (NSKeyedUnarchiver *) coder;
        NSString *title = [keyed decodeObjectForKey: @"NSTitle"];
        NSString *keyEquivalent = [keyed decodeObjectForKey: @"NSKeyEquiv"];

        SEL action = NULL;
        NSString *actionString = [coder decodeObjectForKey: @"NSAction"];
        if (actionString) {
            action = NSSelectorFromString(actionString);
        }
        [self initWithTitle: title action: action keyEquivalent: keyEquivalent];
        id target = [coder decodeObjectForKey: @"NSTarget"];
        [self setTarget: target];

        [self setKeyEquivalentModifierMask:
                        [keyed decodeIntForKey: @"NSKeyEquivModMask"]];
        [self setSubmenu: [keyed decodeObjectForKey: @"NSSubmenu"]];
        _tag = [keyed decodeIntForKey: @"NSTag"];
        _hidden = [keyed decodeBoolForKey: @"NSIsHidden"];
        _image = [[coder decodeObjectForKey: @"NSImage"] retain];
        if ([keyed decodeBoolForKey: @"NSIsSeparator"]) {
            [_title release];
            _title = nil;
        }
    } else {
        NSInteger version = [coder versionForClassName: @"NSMenuItem"];

        if (version == NSNotFound) {
            version = [coder versionForClassName: @"NSMenuCell"];
        }

        _menu = [coder decodeObject];

        int flags;

        // TODO: Figure this out, encodeWithCoder is writing this as 0xffffffffffffffff
        unsigned int unused;

        [coder decodeValuesOfObjCTypes:"i@@IIi@@@@:i@", &flags, &_title, &_keyEquivalent, &_keyEquivalentModifierMask, &unused, &_state, &_image, &_onStateImage, &_mixedStateImage, &_offStateImage, &_action, &_tag, &_representedObject];


        // If we have an empty title, it is for a separator, discard it, see isSeparatorItem
        if (_title && [_title length] == 0) {
            [_title release];
            _title = nil;
        }

        if (version <= 320) {
            if (_action != @selector(submenuAction:)) {
                _target = [coder decodeObject];
            } else {
                _submenu = [[coder decodeObject] retain];
            }
        } else {
            _target = [coder decodeObject];
            _submenu = [[coder decodeObject] retain];
        }

        // Set other default values from [initWithTitle: action: keyEquivalent:]
        _mnemonic = @"";
        _enabled = YES;
    }

    return self;
}

/* Every default lives below, so alloc/init left _enabled at zero and an item made in code was born
 * disabled. Apple documents -init as initWithTitle: @"" action: NULL keyEquivalent: @"". */
- init {
    return [self initWithTitle: @"" action: NULL keyEquivalent: @""];
}

- initWithTitle: (NSString *) title
               action: (SEL) action
        keyEquivalent: (NSString *) keyEquivalent
{
    _title = [title copy];
    _target = nil;
    _action = action;
    _keyEquivalent = [keyEquivalent copy];
    /* COMMAND IS THE DEFAULT, as it is on Apple systems. An application that writes
     * setKeyEquivalent: @"h" means Command H and does not say so; LibreOffice sets Hide, Hide
     * Others and Quit exactly that way, and with a mask of zero they were drawn as a bare H, H and
     * Q with no symbol in front of them. */
    _keyEquivalentModifierMask = NSCommandKeyMask;
    _mnemonic = @"";
    _mnemonicLocation = 0;
    _submenu = nil;
    _tag = -1;
    _indentationLevel = 0;
    _enabled = YES;
    _hidden = NO;

    return self;
}

- (void) dealloc {
    [_title release];
    [_atitle release];
    [_keyEquivalent release];
    [_submenu release];
    [_image release];
    [_onStateImage release];
    [_mixedStateImage release];
    [_offStateImage release];
    [_representedObject release];
    [_identifier release];
    [super dealloc];
}

- copyWithZone: (NSZone *) zone {
    NSMenuItem *copy = NSCopyObject(self, 0, zone);

    copy->_title = [_title copyWithZone: zone];
    copy->_atitle = [_atitle copyWithZone: zone];
    copy->_submenu = [_submenu copyWithZone: zone];
    copy->_keyEquivalent = [_keyEquivalent copyWithZone: zone];
    ;
    copy->_image = [_image retain];
    copy->_onStateImage = [_onStateImage retain];
    copy->_mixedStateImage = [_mixedStateImage retain];
    copy->_offStateImage = [_offStateImage retain];
    copy->_representedObject = [_representedObject retain];
    return copy;
}

- (NSMenu *) menu {
    return _menu;
}

- (void) _setMenu: (NSMenu *) menu {
    _menu = menu;
    _submenu.supermenu = menu;
}

- (NSString *) title {
    return _title;
}

- (NSAttributedString *) attributedTitle {
    return _atitle;
}

- (NSString *) mnemonic {
    return _mnemonic;
}

- (unsigned) mnemonicLocation {
    return _mnemonicLocation;
}

- (id) target {
    return _target;
}

- (SEL) action {
    return _action;
}

- (NSInteger) indentationLevel {
    return _indentationLevel;
}

- (NSInteger) tag {
    return _tag;
}

- (NSControlStateValue) state {
    return _state;
}

- (NSString *) keyEquivalent {
    return _keyEquivalent;
}

- (unsigned) keyEquivalentModifierMask {
    return _keyEquivalentModifierMask;
}

- (NSImage *) image {
    return _image;
}

- (NSImage *) onStateImage {
    return _onStateImage;
}

- (NSImage *) offStateImage {
    return _offStateImage;
}

- (NSImage *) mixedStateImage {
    return _mixedStateImage;
}

/*
 * objectValue, WHICH THIS CLASS NEVER HAD AND APPLICATIONS BIND TO ANYWAY.
 *
 * Swift Publisher builds its whole main menu through a helper that binds each item, and the binder
 * reads the bound object with valueForKeyPath: at bind time. NSMenuItem answered nothing for
 * objectValue, so every item raised
 *
 *     NSUnknownKeyException: <NSMenuItem: title: Delete ...> is not key value coding compliant
 *     for the key objectValue
 *
 * 219 of them in one launch, and createMainMenu never finished, which is why the menu bar carried
 * the application name and nothing else. macOS answers this key, so ours does now.
 *
 * AN ASSOCIATED OBJECT RATHER THAN AN IVAR, deliberately: NSMenuItem is a public class in a public
 * header and applications here are PREBUILT, so leaving the ivar layout exactly as it is removes
 * the question of what a compiled subclass expects to find and where.
 */
static char CiderMenuItemObjectValueKey;

- (id) objectValue {
    return objc_getAssociatedObject(self, &CiderMenuItemObjectValueKey);
}

- (void) setObjectValue: (id) value {
    objc_setAssociatedObject(self, &CiderMenuItemObjectValueKey, value,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (id) representedObject {
    return _representedObject;
}

- (BOOL) hasSubmenu {
    return (_submenu != nil) ? YES : NO;
}

- (NSMenu *) submenu {
    return _submenu;
}

- (BOOL) isSeparatorItem {
    return _title == nil;
}

- (BOOL) isEnabled {
    return _enabled;
}

- (BOOL) isHidden {
    return _hidden;
}

- (void) setTitle: (NSString *) title {
    /*
     * WHO NAMES A MENU ITEM, AND WITH WHAT. MoneyMoney's toolbar menu reads "New stand" and an
     * ellipsis where its own Localizable.strings holds "New standing order", and the ellipsis is
     * U+2026 while the only truncation in this AppKit appends three ASCII dots. So either the
     * application arrives here with a short string, which makes the truncation ITS decision and
     * probably taken from a width we reported, or it arrives long and something later shortens it.
     * Those are different bugs and one line of caller tells them apart.
     */
    if (getenv("CIDER_TRACE_MENU") != NULL && getenv("CIDER_TRACE_MENU")[0] != (char) 0) {
        Dl_info info;
        void *ret = __builtin_return_address(0);

        /* THE OFFSET AS WELL AS THE NAME. An application binary has no symbol for an ordinary
         * method, so dladdr answers "?" and the only way on is the address: base plus offset is
         * what scripts/machodis.py disassembles. */
        int have = dladdr(ret, &info);

        fprintf(stderr, "CIDER_MENUTITLE set %s from %s in %s +%#lx\n", [title UTF8String] ?: "(nil)",
                (have != 0 && info.dli_sname != NULL) ? info.dli_sname : "?",
                (have != 0 && info.dli_fname != NULL) ? info.dli_fname : "?",
                (have != 0) ? (unsigned long) ((char *) ret - (char *) info.dli_fbase) : 0UL);
        fflush(stderr);
    }
    title = [title copy];
    [_title release];
    _title = title;
}

- (void) setAttributedTitle: (NSAttributedString *) title {
    title = [title copy];
    [_atitle release];
    _atitle = title;
    [self setTitle: [title string]];
}

- (void) setTitleWithMnemonic: (NSString *) mnemonic {
    mnemonic = [mnemonic copy];
    [_mnemonic release];
    _mnemonic = mnemonic;
}

- (void) setMnemonicLocation: (unsigned) location {
    _mnemonicLocation = location;
}

- (void) setTarget: (id) target {
    _target = target;
}

- (void) setAction: (SEL) action {
    _action = action;
}

- (void) setIndentationLevel: (NSInteger) indentationLevel {
    _indentationLevel = indentationLevel;
}

- (void) setTag: (NSInteger) tag {
    _tag = tag;
}

- (void) setState: (NSControlStateValue) state {
    _state = state;
}

- (void) setKeyEquivalent: (NSString *) keyEquivalent {
    keyEquivalent = [keyEquivalent copy];
    [_keyEquivalent release];
    _keyEquivalent = keyEquivalent;
}

- (void) setKeyEquivalentModifierMask: (unsigned) mask {
    _keyEquivalentModifierMask = mask;
}

- (void) setImage: (NSImage *) image {
    image = [image retain];
    [_image release];
    _image = image;
}

/*
 * A MENU ITEM CAN HOST A VIEW, and this one could not even be asked.
 *
 * setView: is how a menu item carries a custom view instead of a title and image, and it is set
 * long before anything draws. It did not exist at all here, so Swift Publisher raised
 *
 *   -[NSMenuItem setView:]: unrecognized selector
 *
 * from -[ImagePopUpButton menu] on an NSOperation worker thread, and an ObjC exception that reaches
 * the top of an operation is caught by nobody: _objc_terminate aborts the entire process.
 *
 * STORED AND ANSWERED, WITH THE DRAWING STILL TO COME. The menu drawing code here lays out a title,
 * an image and a key equivalent and knows nothing about a hosted view, so an item with a view set
 * will still draw as an empty item. That is a gap and it is written here rather than left for
 * someone to discover; what this fixes is the process dying for asking.
 */
- (NSView *) view {
    return _view;
}

- (void) setView: (NSView *) view {
    view = [view retain];
    [_view release];
    _view = view;
}

- (void) setOnStateImage: (NSImage *) image {
    [_onStateImage release];
    _onStateImage = [image retain];
}

- (void) setOffStateImage: (NSImage *) image {
    [_offStateImage release];
    _offStateImage = [image retain];
}

- (void) setMixedStateImage: (NSImage *) image {
    [_mixedStateImage release];
    _mixedStateImage = [image retain];
}

- (void) setRepresentedObject: (id) object {
    [_representedObject release];
    _representedObject = [object retain];
}

- (void) setSubmenu: (NSMenu *) submenu {
    submenu = [submenu retain];
    [_submenu release];
    _submenu = submenu;
    [submenu setSupermenu: _menu];
}

- (void) setEnabled: (BOOL) flag {
    /*
     * WHO DISABLES A POP-UP ITEM. With autoenabling off and NSMenu update no longer force-disabling
     * an item with a NULL action, every item of Swift Publisher's zoom menu is still disabled, so
     * somebody else says so. The caller, not the count, is the answer; cf. CIDER_MENUTITLE above.
     */
    if (getenv("CIDER_TRACE_MENU") != NULL && getenv("CIDER_TRACE_MENU")[0] != (char) 0) {
        Dl_info info;
        void *ret = __builtin_return_address(0);
        int have = dladdr(ret, &info);

        fprintf(stderr, "CIDER_MENUENABLE %s <- %d (was %d) from %s in %s +%#lx\n",
                [_title UTF8String] ?: "(nil)", (int) flag, (int) _enabled,
                (have != 0 && info.dli_sname != NULL) ? info.dli_sname : "?",
                (have != 0 && info.dli_fname != NULL) ? info.dli_fname : "?",
                (have != 0) ? (unsigned long) ((char *) ret - (char *) info.dli_fbase) : 0UL);
        fflush(stderr);
    }
    _enabled = flag;
}

- (void) setHidden: (BOOL) flag {
    _hidden = flag;
}

+ (NSDictionary *) keyNames {
    static NSDictionary *shared = nil;

    if (shared == nil) {
        NSBundle *bundle = [NSBundle bundleForClass: self];
        NSString *path = [bundle pathForResource: @"NSMenu" ofType: @"plist"];

        shared = [[NSDictionary alloc] initWithContentsOfFile: path];
    }

    return shared;
}

- (NSString *) _scanModifierMapFor: (NSString *) key longForm: (BOOL) longForm {
    NSDictionary *modmap = [[NSUserDefaults standardUserDefaults]
            dictionaryForKey: @"NSModifierFlagMapping"];

    if ([[modmap objectForKey: @"LeftControl"] isEqual: key])
        return longForm ? @"LCtrl+" : @"Ctrl+";
    else if ([[modmap objectForKey: @"LeftAlt"] isEqual: key])
        return longForm ? @"LAlt+" : @"Alt+";
    else if ([[modmap objectForKey: @"RightAlt"] isEqual: key])
        return longForm ? @"RAlt+" : @"Alt+";
    else if ([[modmap objectForKey: @"RightControl"] isEqual: key])
        return longForm ? @"RCtrl+" : @"Ctrl+";
    else {
        if ([key isEqualToString: @"Alt"]) {
            if ([[modmap objectForKey: @"LeftAlt"] length] == 0)
                return longForm ? @"LAlt+" : @"Alt+";

            if ([[modmap objectForKey: @"RightAlt"] length] == 0)
                return longForm ? @"RAlt+" : @"Alt+";
        }
        return nil;
    }
}

/*
 * A KEY EQUIVALENT LOOKS LIKE A MAC ONE: the symbols, in Apple order, and a NAME for the keys that
 * have no printable character.
 *
 * What was here spelled the Command modifier as Ctrl+ through the Windows modifier map, so every
 * shortcut in every menu read Ctrl+O where a Mac shows Command O. And the key itself came from a
 * plist keyed by character: a function key is a character in the private use area, no entry
 * matches, and the raw character was appended, which draws as nothing at all. That is why Insert
 * Table showed Ctrl+ with nothing after it.
 *
 * Order is control, option, shift, command, then the key, which is what macOS uses.
 */
static NSString *cider_key_equivalent_name(NSString *key, NSDictionary *keyNames) {
    if ([key length] == 0) {
        return @"";
    }

    unichar c = [key characterAtIndex: 0];

    /* The function key range, which is where the arrows and the editing keys live too. */
    if (c >= 0xF704 && c <= 0xF726) {
        return [NSString stringWithFormat: @"F%d", (int) (c - 0xF704 + 1)];
    }
    switch (c) {
    case 0xF700: return @"\u2191";  /* up */
    case 0xF701: return @"\u2193";  /* down */
    case 0xF702: return @"\u2190";  /* left */
    case 0xF703: return @"\u2192";  /* right */
    case 0xF727: return @"Ins";
    case 0xF728: return @"\u2326";  /* forward delete */
    case 0xF729: return @"\u2196";  /* home */
    case 0xF72B: return @"\u2198";  /* end */
    case 0xF72C: return @"\u21DE";  /* page up */
    case 0xF72D: return @"\u21DF";  /* page down */
    case 0x0003:
    case 0x000D: return @"\u21A9";  /* return */
    case 0x0009: return @"\u21E5";  /* tab */
    case 0x001B: return @"\u238B";  /* escape */
    case 0x0020: return @"Space";
    case 0x007F:
    case 0x0008: return @"\u232B";  /* delete */
    default: break;
    }

    NSString *named = [keyNames objectForKey: key];

    if (named != nil) {
        return named;
    }
    return [key uppercaseString];
}

- (NSString *) _keyEquivalentDescription {
    if ([_keyEquivalent length] == 0) {
        return @"";
    }

    NSMutableString *result = [NSMutableString string];
    NSUInteger mask = _keyEquivalentModifierMask;

    if (mask & NSControlKeyMask) {
        [result appendString: @"\u2303"];
    }
    if (mask & NSAlternateKeyMask) {
        [result appendString: @"\u2325"];
    }
    /* An uppercase letter in the equivalent IS shift on Apple systems, which is how an application
     * writes Shift Command S without setting the flag. */
    if ((mask & NSShiftKeyMask) ||
        (![_keyEquivalent isEqualToString: [_keyEquivalent lowercaseString]] &&
         [_keyEquivalent length] == 1)) {
        [result appendString: @"\u21E7"];
    }
    if (mask & NSCommandKeyMask) {
        [result appendString: @"\u2318"];
    }
    [result appendString: cider_key_equivalent_name(_keyEquivalent, [[self class] keyNames])];

    return result;
}

- (NSString *) description {
    return [NSString stringWithFormat:
                             @"<%@[0x%x]: title: %@ action: %@ hasSubmenu: %@>",
                             [self class], self, [self title],
                             NSStringFromSelector(_action),
                             ([self hasSubmenu] ? @"YES" : @"NO")];
}

@end
