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
