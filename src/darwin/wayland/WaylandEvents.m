/*
 * Turning Wayland input into NSEvents.
 *
 * WHY THIS IS OBJECTIVE-C. The two constructors involved take ten and eight arguments, and reaching
 * a variadic objc_msgSend from Rust means one hand written declaration per signature that has to
 * agree with the method exactly. Getting one wrong does not fail at build time; it corrupts an
 * argument at the first call. The protocol handling stays in Rust, where the state machine lives,
 * and only the message sends are here.
 *
 * THE Y AXIS IS FLIPPED and this is the only place that knows it. Wayland puts a surface origin at
 * the TOP left with y increasing downwards; AppKit puts a window origin at the BOTTOM left with y
 * increasing upwards. A backend that forgets this produces an application where everything reacts
 * to the mirror image of the pointer, which reads as broken hit testing rather than as a
 * coordinate bug.
 */
#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <stdlib.h>
#import <objc/runtime.h>
#import "carbon_keys.h"

/* NSEvent_mouse declares the button number setter privately, and the X11 backend uses it for the
 * same reason: NSEvent has no public way to say WHICH button an other-mouse event was. */
@interface NSEvent (CiderWaylandButtonNumber)
- (void) _setButtonNumber: (NSInteger) number;
@end

/*
 * Post a mouse event.
 *
 * type is an NSEventType, already decided by the caller: the mapping from a Linux button code to
 * left, right or other belongs with the protocol, not here.
 */
void cider_wayland_post_mouse(int type, double x, double y, double windowHeight,
	unsigned long modifiers, id delegate, int clickCount, int buttonNumber, double deltaX,
	double deltaY)
{
	if (delegate == nil) {
		return;
	}
	NSPoint location = NSMakePoint(x, windowHeight - y);
	NSEvent *event = [NSEvent mouseEventWithType: (NSEventType) type
									   location: location
								  modifierFlags: (NSEventModifierFlags) modifiers
										 window: delegate
									 clickCount: clickCount
										 deltaX: deltaX
										 deltaY: deltaY];
	if (event == nil) {
		return;
	}
	if ([event respondsToSelector: @selector(_setButtonNumber:)]) {
		[event _setButtonNumber: buttonNumber];
	}
	[[NSDisplay currentDisplay] postEvent: event atStart: NO];
}

/*
 * Post a key event.
 *
 * characters is what the keymap produced for this key WITH the modifiers applied, and
 * charactersIgnoringModifiers is the same key without them. AppKit uses the second for key
 * equivalents, so passing the first for both makes every shortcut with shift in it miss.
 */
void cider_wayland_post_key(int isDown, unsigned long modifiers, long windowNumber,
	const char *characters, const char *charactersIgnoringModifiers, int isRepeat, int keyCode)
{
	@autoreleasepool {
		NSString *chars = characters != NULL
			? [NSString stringWithUTF8String: characters]
			: @"";
		NSString *bare = charactersIgnoringModifiers != NULL
			? [NSString stringWithUTF8String: charactersIgnoringModifiers]
			: chars;
		if (chars == nil) {
			chars = @"";
		}
		if (bare == nil) {
			bare = chars;
		}

		NSEvent *event = [NSEvent keyEventWithType: isDown ? NSKeyDown : NSKeyUp
										  location: NSZeroPoint
									 modifierFlags: (NSEventModifierFlags) modifiers
										 timestamp: 0.0
									  windowNumber: windowNumber
										   context: nil
										characters: chars
					   charactersIgnoringModifiers: bare
										 isARepeat: isRepeat ? YES : NO
										   keyCode: (unsigned short) keyCode];
		if (getenv("CIDER_TRACE_KEYS") != NULL) {
			NSLog(@"CIDER_POSTKEY built=%s type=%d windowNumber=%ld display=%p",
				event ? "yes" : "NIL", isDown ? 10 : 11, windowNumber,
				[NSDisplay currentDisplay]);
		}
		if (event != nil) {
			[[NSDisplay currentDisplay] postEvent: event atStart: NO];
		}
	}
}

/*
 * Post a flags-changed event, which is how AppKit learns that a modifier went down or up on its
 * own. Without it a held shift is invisible until the next key, and applications that track
 * modifier state directly never see it change.
 */
void cider_wayland_post_flags_changed(unsigned long modifiers, long windowNumber)
{
	NSEvent *event = [NSEvent keyEventWithType: NSFlagsChanged
									  location: NSZeroPoint
								 modifierFlags: (NSEventModifierFlags) modifiers
									 timestamp: 0.0
								  windowNumber: windowNumber
									   context: nil
									characters: @""
				   charactersIgnoringModifiers: @""
									 isARepeat: NO
									   keyCode: 0];
	if (event != nil) {
		[[NSDisplay currentDisplay] postEvent: event atStart: NO];
	}
}

/*
 * Keyboard focus, delivered as AppKit window activation.
 *
 * A KEY EVENT IS NOT ENOUGH ON ITS OWN. AppKit routes text to the first responder of the KEY
 * window, and a window only becomes key when the platform says it was activated. Without this the
 * keystrokes arrive, are posted, are dispatched, and go nowhere: measured on LibreOffice, where
 * h e l l o were each delivered to window 2 and the document stayed empty.
 *
 * The previously focused window is deactivated first, in that order, because AppKit tracks a
 * single key window and activating a second while the first still believes it is key leaves two.
 */
static id cider_wayland_key_window = nil;

void cider_wayland_set_keyboard_focus(id delegate, id platformWindow)
{
	if (cider_wayland_key_window == delegate) {
		return;
	}
	if (cider_wayland_key_window != nil &&
		[cider_wayland_key_window respondsToSelector:
			@selector(platformWindowDeactivated:checkForAppDeactivation:)]) {
		[cider_wayland_key_window platformWindowDeactivated: nil
								   checkForAppDeactivation: NO];
	}
	cider_wayland_key_window = delegate;
	if (delegate != nil &&
		[delegate respondsToSelector: @selector(platformWindowActivated:displayIfNeeded:)]) {
		[delegate platformWindowActivated: platformWindow displayIfNeeded: YES];
	}
	/*
	 * DID IT ACTUALLY BECOME KEY. Activation only makes a window key if it says it can, and a
	 * window that cannot never gets a first responder, so every keystroke sent to it is delivered
	 * and dropped with nothing to show for it. Both facts are read back rather than assumed
	 * because the failing case looks exactly like the working one from outside.
	 */
	if (getenv("CIDER_TRACE_KEYS") != NULL && delegate != nil) {
		NSLog(@"CIDER_FOCUS window=%ld class=%s canBecomeKey=%d isKey=%d firstResponder=%s",
			(long) [delegate windowNumber], class_getName([delegate class]),
			(int) [delegate canBecomeKeyWindow], (int) [delegate isKeyWindow],
			[delegate firstResponder] ? class_getName([[delegate firstResponder] class]) : "nil");
	}
}

/*
 * The Carbon virtual key code for an evdev keycode, or 0 if there is no equivalent.
 *
 * Applications map keys through the virtual key code and their own layout, so this is not a
 * convenience: it is the difference between a keystroke that means something and one that means
 * whatever Carbon key shares its number.
 */
int cider_wayland_carbon_keycode(unsigned int evdevKeycode)
{
	if (evdevKeycode >= 256) {
		return 0;
	}
	return cider_evdev_to_carbon[evdevKeycode];
}

/*
 * Does the key window notification actually FIRE.
 *
 * -setDelegate: registering a selector and that selector being CALLED are different claims, and so
 * far only the first was checked. LibreOffice learns which frame has focus from
 * windowDidBecomeKey:, and it accepts key input only for a focused frame, so a notification that is
 * registered and never posted would explain characters arriving and being discarded exactly.
 *
 * An observer of this backend own answers it without touching the application: if this fires, the
 * notification works and the application observer fires too.
 */
@interface CiderWaylandFocusWatch : NSObject
+ (void) install;
@end

@implementation CiderWaylandFocusWatch

+ (void) becameKey: (NSNotification *) note
{
	id window = [note object];
	fprintf(stderr, "CIDER_NOTIFY windowDidBecomeKey window=%ld delegate=%s\n",
		[window respondsToSelector: @selector(windowNumber)] ? (long) [window windowNumber] : -1,
		[window respondsToSelector: @selector(delegate)] && [window delegate]
			? class_getName([[window delegate] class]) : "nil");
	fflush(stderr);
}

+ (void) install
{
	static BOOL installed = NO;
	if (installed || getenv("CIDER_TRACE_KEYS") == NULL) {
		return;
	}
	installed = YES;
	[[NSNotificationCenter defaultCenter] addObserver: self
											 selector: @selector(becameKey:)
												 name: NSWindowDidBecomeKeyNotification
											   object: nil];
}

@end

void cider_wayland_watch_focus_notifications(void)
{
	[CiderWaylandFocusWatch install];
}

/*
 * The Carbon virtual key code for an XKB KEYSYM, or -1 when there is no equivalent.
 *
 * WHY THE KEYSYM AND NOT THE KEYCODE. A physical keycode only means a letter if the layout says so.
 * Translating the raw evdev number through a fixed US table gives the right answer on a US
 * keyboard and the wrong one everywhere else, and the failure is silent: the character is correct
 * while the key code names an unrelated key. An application that reads the key code to decide what
 * a keystroke MEANS, which LibreOffice does, then discards perfectly good text.
 *
 * Measured before fixing: with a synthetic keymap the letter h arrived as Carbon 53, kVK_Escape,
 * and e arrived as Carbon 18, kVK_ANSI_1. A Danish layout has the same problem for real, since its
 * keycodes do not agree with the US table either.
 *
 * The keysym is what the keymap already resolved, so this is the layer that knows.
 */
int cider_wayland_carbon_for_keysym(unsigned int keysym)
{
	/* Letters. Upper and lower case resolve to the same physical key. */
	static const int letters[26] = {
		kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_E, kVK_ANSI_F,
		kVK_ANSI_G, kVK_ANSI_H, kVK_ANSI_I, kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L,
		kVK_ANSI_M, kVK_ANSI_N, kVK_ANSI_O, kVK_ANSI_P, kVK_ANSI_Q, kVK_ANSI_R,
		kVK_ANSI_S, kVK_ANSI_T, kVK_ANSI_U, kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X,
		kVK_ANSI_Y, kVK_ANSI_Z,
	};
	static const int digits[10] = {
		kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4,
		kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9,
	};

	if (keysym >= 'a' && keysym <= 'z') {
		return letters[keysym - 'a'];
	}
	if (keysym >= 'A' && keysym <= 'Z') {
		return letters[keysym - 'A'];
	}
	if (keysym >= '0' && keysym <= '9') {
		return digits[keysym - '0'];
	}

	switch (keysym) {
	case 0x0020: return kVK_Space;
	case 0x002d: return kVK_ANSI_Minus;
	case 0x003d: return kVK_ANSI_Equal;
	case 0x005b: return kVK_ANSI_LeftBracket;
	case 0x005d: return kVK_ANSI_RightBracket;
	case 0x005c: return kVK_ANSI_Backslash;
	case 0x003b: return kVK_ANSI_Semicolon;
	case 0x0027: return kVK_ANSI_Quote;
	case 0x002c: return kVK_ANSI_Comma;
	case 0x002e: return kVK_ANSI_Period;
	case 0x002f: return kVK_ANSI_Slash;
	case 0x0060: return kVK_ANSI_Grave;
	/* The XKB function key block. */
	case 0xff08: return kVK_Delete;
	case 0xff09: return kVK_Tab;
	case 0xff0d: return kVK_Return;
	case 0xff1b: return kVK_Escape;
	case 0xff50: return kVK_Home;
	case 0xff51: return kVK_LeftArrow;
	case 0xff52: return kVK_UpArrow;
	case 0xff53: return kVK_RightArrow;
	case 0xff54: return kVK_DownArrow;
	case 0xff55: return kVK_PageUp;
	case 0xff56: return kVK_PageDown;
	case 0xff57: return kVK_End;
	case 0xffff: return kVK_ForwardDelete;
	case 0xffbe: return kVK_F1;
	case 0xffbf: return kVK_F2;
	case 0xffc0: return kVK_F3;
	case 0xffc1: return kVK_F4;
	case 0xffc2: return kVK_F5;
	case 0xffc3: return kVK_F6;
	case 0xffc4: return kVK_F7;
	case 0xffc5: return kVK_F8;
	case 0xffc6: return kVK_F9;
	case 0xffc7: return kVK_F10;
	case 0xffc8: return kVK_F11;
	case 0xffc9: return kVK_F12;
	default: return -1;
	}
}
