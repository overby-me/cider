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
