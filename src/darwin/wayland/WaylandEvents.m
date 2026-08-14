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
void cider_wayland_trace_vcl(void);

void cider_wayland_post_mouse(int type, double x, double y, double windowHeight,
	unsigned long modifiers, id delegate, int clickCount, int buttonNumber, double deltaX,
	double deltaY)
{
	if (delegate == nil) {
		return;
	}
	cider_wayland_trace_vcl();
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
	cider_wayland_trace_vcl();
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
		/*
		 * EVERY PIECE OF STATE AN APPLICATION CAN CHECK before deciding a key event is for it.
		 * Each was a plausible gate on the keyboard and each is reported correct, so they are
		 * printed together rather than rediscovered one at a time.
		 */
		NSLog(@"CIDER_FOCUS window=%ld class=%s canBecomeKey=%d isKey=%d isMain=%d canBeMain=%d "
			  @"appActive=%d firstResponder=%s",
			(long) [delegate windowNumber], class_getName([delegate class]),
			(int) [delegate canBecomeKeyWindow], (int) [delegate isKeyWindow],
			(int) [delegate isMainWindow], (int) [delegate canBecomeMainWindow],
			(int) [NSApp isActive],
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
	/* THE SETTINGS ARE READ BEFORE THE FIRST EVENT. Installing the traces from the first keystroke
	 * is far too late for anything that happens during startup, and the colours are read there. */
	cider_wayland_trace_vcl();
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

/*
 * WHAT THE APPLICATION DOES WITH A KEYSTROKE, measured INSIDE the application.
 *
 * WHY THIS INSTRUMENT EXISTS. Every link on this side of the boundary has been checked and each one
 * is correct: the keymap resolves the letter, the Carbon code is right, the NSEvent is built, the
 * key window is key, its first responder is the application own view, and Cocotron calls that view
 * insertText:replacementRange: exactly once per keystroke. Nothing appears in the document. From
 * outside, "the application discards it" and "the application never gets that far" look identical,
 * and no amount of further tracing on this side separates them.
 *
 * The application is Objective-C, so its own methods can be wrapped from here without patching it:
 * the boundary that matters, -sendKeyInputAndReleaseToFrame:character:modifiers:, is the exact point
 * where the text stops being AppKit and becomes an application key event. If that fires, everything
 * this backend is responsible for is done and the loss is inside the application own C++. If it does
 * not, the branch that swallowed the character is named by what the trace DOES show.
 *
 * The selectors are enumerated rather than assumed, because guessing a selector that this build does
 * not have produces a trace that stays silent for the wrong reason.
 */
#import <objc/message.h>

typedef void (*CiderInsertIMP)(id, SEL, id, NSRange);
typedef void (*CiderSendKeyIMP)(id, SEL, unsigned short, unsigned short, unsigned int);
typedef BOOL (*CiderBoolIMP)(id, SEL);
typedef void (*CiderIdIMP)(id, SEL, id);
typedef void (*CiderSelIMP)(id, SEL, SEL);

static CiderInsertIMP cider_vcl_insert_range;
static CiderIdIMP cider_vcl_insert_plain;
static CiderSendKeyIMP cider_vcl_send_key;
static CiderBoolIMP cider_vcl_has_marked;
static CiderIdIMP cider_vcl_key_down;
static CiderSelIMP cider_vcl_do_command;
static CiderIdIMP cider_vcl_became_key;
static CiderIdIMP cider_vcl_mouse_down;
static CiderIdIMP cider_vcl_mouse_up;
static CiderIdIMP cider_vcl_mouse_dragged;
typedef void (*CiderRectIMP)(id, SEL, NSRect);
static CiderRectIMP cider_vcl_draw_rect;
typedef void (*CiderGetRGBAIMP)(id, SEL, CGFloat *, CGFloat *, CGFloat *, CGFloat *);

static const char *cider_vcl_text(id string)
{
	id str = string;
	if (str != nil && ![str isKindOfClass: [NSString class]] &&
		[str respondsToSelector: @selector(string)]) {
		str = [str string];
	}
	if (str != nil && [str respondsToSelector: @selector(UTF8String)]) {
		const char *text = [str UTF8String];
		return text ? text : "(nil utf8)";
	}
	return "(not a string)";
}

static void cider_vcl_trace_insert_range(id self, SEL _cmd, id string, NSRange range)
{
	fprintf(stderr, "CIDER_VCL insertText:replacementRange: text=[%s]\n", cider_vcl_text(string));
	fflush(stderr);
	if (cider_vcl_insert_range != NULL) {
		cider_vcl_insert_range(self, _cmd, string, range);
	}
	fprintf(stderr, "CIDER_VCL insertText:replacementRange: returned\n");
	fflush(stderr);
}

static void cider_vcl_trace_insert_plain(id self, SEL _cmd, id string)
{
	fprintf(stderr, "CIDER_VCL insertText: text=[%s]\n", cider_vcl_text(string));
	fflush(stderr);
	if (cider_vcl_insert_plain != NULL) {
		cider_vcl_insert_plain(self, _cmd, string);
	}
}

/* THE BOUNDARY. Past this call the character is an application key event and no longer AppKit. */
static void cider_vcl_trace_send_key(id self, SEL _cmd, unsigned short code, unsigned short ch,
	unsigned int mods)
{
	fprintf(stderr, "CIDER_VCL sendKeyInputAndReleaseToFrame code=%u char=%u mods=0x%x\n",
		(unsigned) code, (unsigned) ch, mods);
	fflush(stderr);
	if (cider_vcl_send_key != NULL) {
		cider_vcl_send_key(self, _cmd, code, ch, mods);
	}
	fprintf(stderr, "CIDER_VCL sendKeyInputAndReleaseToFrame returned\n");
	fflush(stderr);
}

static BOOL cider_vcl_trace_has_marked(id self, SEL _cmd)
{
	BOOL answer = NO;
	if (cider_vcl_has_marked != NULL) {
		answer = cider_vcl_has_marked(self, _cmd);
	}
	static int printed;
	if (printed < 12) {
		printed++;
		fprintf(stderr, "CIDER_VCL hasMarkedText=%d\n", (int) answer);
		fflush(stderr);
	}
	return answer;
}

static void cider_vcl_trace_key_down(id self, SEL _cmd, id event)
{
	id window = [self respondsToSelector: @selector(window)] ? [(NSView *) self window] : nil;
	fprintf(stderr, "CIDER_VCL keyDown view=%s window=%ld isKey=%d firstResponder=%s\n",
		class_getName([self class]),
		window ? (long) [(NSWindow *) window windowNumber] : -1,
		window ? (int) [(NSWindow *) window isKeyWindow] : -1,
		(window && [(NSWindow *) window firstResponder])
			? class_getName([[(NSWindow *) window firstResponder] class]) : "nil");
	fflush(stderr);
	if (cider_vcl_key_down != NULL) {
		cider_vcl_key_down(self, _cmd, event);
	}
	fprintf(stderr, "CIDER_VCL keyDown returned\n");
	fflush(stderr);
}

static void cider_vcl_trace_do_command(id self, SEL _cmd, SEL command)
{
	fprintf(stderr, "CIDER_VCL doCommandBySelector=%s\n", sel_getName(command));
	fflush(stderr);
	if (cider_vcl_do_command != NULL) {
		cider_vcl_do_command(self, _cmd, command);
	}
}

static void cider_vcl_trace_became_key(id self, SEL _cmd, id note)
{
	fprintf(stderr, "CIDER_VCL windowDidBecomeKey window=%ld\n",
		[self respondsToSelector: @selector(windowNumber)]
			? (long) [(NSWindow *) self windowNumber] : -1);
	fflush(stderr);
	if (cider_vcl_became_key != NULL) {
		cider_vcl_became_key(self, _cmd, note);
	}
	fprintf(stderr, "CIDER_VCL windowDidBecomeKey returned\n");
	fflush(stderr);
}

/*
 * THE MOUSE BUTTON, both halves.
 *
 * VCL swallows key input while it is TRACKING, which is the state a mouse down puts it in and a
 * mouse up takes it out of. So a button press that arrives without its release is not a lost click:
 * it is a keyboard that stops working from that moment on, which is exactly the observed behaviour.
 * Measured: three characters typed before the click appear in the document and every character
 * after it is discarded, with the AppKit side of both identical.
 */
static void cider_vcl_trace_mouse(id self, SEL _cmd, id event)
{
	fprintf(stderr, "CIDER_VCL %s clickCount=%ld buttonNumber=%ld\n", sel_getName(_cmd),
		(event != nil && [event respondsToSelector: @selector(clickCount)])
			? (long) [(NSEvent *) event clickCount] : -1,
		(event != nil && [event respondsToSelector: @selector(buttonNumber)])
			? (long) [(NSEvent *) event buttonNumber] : -1);
	fflush(stderr);
	CiderIdIMP original = nil;
	if (_cmd == sel_registerName("mouseDown:")) {
		original = cider_vcl_mouse_down;
	} else if (_cmd == sel_registerName("mouseUp:")) {
		original = cider_vcl_mouse_up;
	} else {
		original = cider_vcl_mouse_dragged;
	}
	if (original != NULL) {
		original(self, _cmd, event);
	}
}

/*
 * WHAT COLOUR THE APPLICATION IS ACTUALLY HANDED.
 *
 * ONE WRAP PER CLASS, and this is not defensive coding: -getRed:green:blue:alpha: is overridden by
 * the concrete colour classes, so wrapping it on NSColor catches nothing an application actually
 * calls. Measured the wrong way first, and the trace stayed silent through a whole run while the
 * application was reading colours the entire time, which reads exactly like "it never asks".
 *
 * Wrapping a class that INHERITS the method would install over the same Method twice and make the
 * saved implementation our own trampoline, which recurses until the stack ends, so a class whose
 * implementation is already ours is skipped.
 */
static void cider_vcl_report_rgba(id self, CGFloat *red, CGFloat *green, CGFloat *blue,
	CGFloat *alpha)
{
	static int printed;
	if (printed >= 4000) {
		return;
	}
	printed++;
	fprintf(stderr, "CIDER_VCL getRed class=%s rgba=%.3f,%.3f,%.3f,%.3f\n",
		class_getName([self class]), red ? (double) *red : -1.0, green ? (double) *green : -1.0,
		blue ? (double) *blue : -1.0, alpha ? (double) *alpha : -1.0);
	fflush(stderr);
}

#define CIDER_RGBA_WRAP(N) \
	static CiderGetRGBAIMP cider_vcl_get_rgba_##N; \
	static void cider_vcl_trace_get_rgba_##N(id self, SEL _cmd, CGFloat *red, CGFloat *green, \
		CGFloat *blue, CGFloat *alpha) \
	{ \
		if (cider_vcl_get_rgba_##N != NULL) { \
			cider_vcl_get_rgba_##N(self, _cmd, red, green, blue, alpha); \
		} \
		cider_vcl_report_rgba(self, red, green, blue, alpha); \
	}

CIDER_RGBA_WRAP(0)
CIDER_RGBA_WRAP(1)
CIDER_RGBA_WRAP(2)

/*
 * IS THE APPLICATION EVEN ASKED TO DRAW.
 *
 * -[NSWindow display] is called and no flush follows, which has two very different explanations:
 * AppKit never reaches the view, or the view is reached and decides it has nothing to do. Only the
 * application can answer the second, so the question is put to its own drawRect.
 */
static void cider_vcl_trace_draw_rect(id self, SEL _cmd, NSRect rect)
{
	static int printed;
	if (printed < 20) {
		printed++;
		fprintf(stderr, "CIDER_VCL drawRect x=%.0f y=%.0f w=%.0f h=%.0f\n", (double) rect.origin.x,
			(double) rect.origin.y, (double) rect.size.width, (double) rect.size.height);
		fflush(stderr);
	}
	if (cider_vcl_draw_rect != NULL) {
		cider_vcl_draw_rect(self, _cmd, rect);
	}
}

static void cider_vcl_wrap(Class cls, const char *name, IMP replacement, void **saved)
{
	if (cls == Nil) {
		return;
	}
	SEL sel = sel_registerName(name);
	Method method = class_getInstanceMethod(cls, sel);
	if (method == NULL) {
		fprintf(stderr, "CIDER_VCL absent class=%s selector=%s\n", class_getName(cls), name);
		fflush(stderr);
		return;
	}
	*saved = (void *) method_setImplementation(method, replacement);
	fprintf(stderr, "CIDER_VCL wrapped class=%s selector=%s\n", class_getName(cls), name);
	fflush(stderr);
}

/* Print what the class really has, so a wrap that never fires is distinguishable from a selector
 * this build spells differently. */
static void cider_vcl_list(Class cls, const char *needle)
{
	if (cls == Nil) {
		return;
	}
	unsigned int count = 0;
	Method *methods = class_copyMethodList(cls, &count);
	if (methods == NULL) {
		return;
	}
	for (unsigned int i = 0; i < count; i++) {
		const char *name = sel_getName(method_getName(methods[i]));
		if (needle == NULL || strstr(name, needle) != NULL) {
			fprintf(stderr, "CIDER_VCL has class=%s selector=%s\n", class_getName(cls), name);
		}
	}
	fflush(stderr);
	free(methods);
}

void cider_wayland_trace_vcl(void)
{
	if (getenv("CIDER_TRACE_VCL") == NULL) {
		return;
	}
	/*
	 * TWO GUARDS, NOT ONE. NSColor exists from the moment AppKit loads and the application classes
	 * appear only when its plug-in is loaded, so a single guard means either the colours are missed
	 * (waiting for the plug-in) or the wrap is attempted again and again. Wrapping twice is not
	 * harmless either: the second wrap saves the first trampoline as the original and calling it
	 * recurses forever.
	 */
	static BOOL colorDone = NO;
	if (!colorDone) {
		colorDone = YES;
		const char *classes[3] = { "NSColor", "NSColor_CGColor", "NSColor_catalog" };
		IMP trampolines[3] = { (IMP) cider_vcl_trace_get_rgba_0, (IMP) cider_vcl_trace_get_rgba_1,
			(IMP) cider_vcl_trace_get_rgba_2 };
		void *saved[3] = { &cider_vcl_get_rgba_0, &cider_vcl_get_rgba_1, &cider_vcl_get_rgba_2 };
		for (int i = 0; i < 3; i++) {
			Class cls = objc_getClass(classes[i]);
			if (cls == Nil) {
				continue;
			}
			Method method = class_getInstanceMethod(cls, @selector(getRed:green:blue:alpha:));
			if (method == NULL) {
				continue;
			}
			IMP current = method_getImplementation(method);
			if (current == trampolines[0] || current == trampolines[1] ||
				current == trampolines[2]) {
				continue;
			}
			cider_vcl_wrap(cls, "getRed:green:blue:alpha:", trampolines[i], saved[i]);
		}
	}

	/*
	 * WHICH COLOUR CLASSES EXIST AND WHICH ONE ANSWERS NOTHING.
	 *
	 * The application reads a colour into locals it does not initialise (its own code, not ours), so
	 * a -getRed:green:blue:alpha: that returns without writing hands it whatever was on the stack.
	 * That produces a colour with three arbitrary components and an alpha of exactly one, which is
	 * what the window fill has been every run. Listing the classes and their implementations says
	 * whether such a class exists at all, which reading one class at a time cannot.
	 */
	static BOOL listed = NO;
	if (!listed) {
		listed = YES;
		int count = objc_getClassList(NULL, 0);
		Class *classes = (Class *) calloc((unsigned) count, sizeof(Class));
		if (classes != NULL) {
			count = objc_getClassList(classes, count);
			for (int i = 0; i < count; i++) {
				const char *name = class_getName(classes[i]);
				if (strncmp(name, "NSColor", 7) != 0) {
					continue;
				}
				Method rgba = class_getInstanceMethod(classes[i],
					@selector(getRed:green:blue:alpha:));
				Method conv = class_getInstanceMethod(classes[i],
					@selector(colorUsingColorSpaceName:device:));
				fprintf(stderr, "CIDER_VCL colorclass=%s getRed=%s own=%d convert=%s\n", name,
					rgba ? "yes" : "NO",
					rgba && class_getMethodImplementation(classes[i],
						@selector(getRed:green:blue:alpha:)) !=
						class_getMethodImplementation(class_getSuperclass(classes[i]),
							@selector(getRed:green:blue:alpha:)) ? 1 : 0,
					conv ? "yes" : "NO");
			}
			free(classes);
			fflush(stderr);
		}
	}

	static BOOL done = NO;
	if (done) {
		return;
	}
	Class view = objc_getClass("SalFrameView");
	Class window = objc_getClass("SalFrameWindow");
	if (view == Nil) {
		/* The plug-in has not been loaded yet. Not an error: try again at the next keystroke. */
		return;
	}
	done = YES;
	cider_vcl_list(view, "nsert");
	cider_vcl_list(view, "Key");
	cider_vcl_list(view, "arked");
	cider_vcl_wrap(view, "insertText:replacementRange:", (IMP) cider_vcl_trace_insert_range,
		(void **) &cider_vcl_insert_range);
	cider_vcl_wrap(view, "insertText:", (IMP) cider_vcl_trace_insert_plain,
		(void **) &cider_vcl_insert_plain);
	cider_vcl_wrap(view, "sendKeyInputAndReleaseToFrame:character:modifiers:",
		(IMP) cider_vcl_trace_send_key, (void **) &cider_vcl_send_key);
	cider_vcl_wrap(view, "hasMarkedText", (IMP) cider_vcl_trace_has_marked,
		(void **) &cider_vcl_has_marked);
	cider_vcl_wrap(view, "keyDown:", (IMP) cider_vcl_trace_key_down,
		(void **) &cider_vcl_key_down);
	cider_vcl_wrap(view, "doCommandBySelector:", (IMP) cider_vcl_trace_do_command,
		(void **) &cider_vcl_do_command);
	cider_vcl_wrap(window, "windowDidBecomeKey:", (IMP) cider_vcl_trace_became_key,
		(void **) &cider_vcl_became_key);
	cider_vcl_wrap(view, "mouseDown:", (IMP) cider_vcl_trace_mouse, (void **) &cider_vcl_mouse_down);
	cider_vcl_wrap(view, "mouseUp:", (IMP) cider_vcl_trace_mouse, (void **) &cider_vcl_mouse_up);
	cider_vcl_wrap(view, "mouseDragged:", (IMP) cider_vcl_trace_mouse,
		(void **) &cider_vcl_mouse_dragged);
	cider_vcl_wrap(view, "drawRect:", (IMP) cider_vcl_trace_draw_rect,
		(void **) &cider_vcl_draw_rect);
}

/*
 * WAKE THE MAIN THREAD.
 *
 * WHY THIS IS NEEDED AT ALL. The Wayland connection is a file descriptor and nothing in this
 * application waits on it: the main thread parks inside the Darwin runtime, in a Mach receive under
 * libdispatch, and comes back only when the runtime has some reason of its own. Measured, the
 * application asked this backend for events 200 times in the first five seconds and then went quiet
 * for the rest of the run. What that looks like on screen is an application that draws its window,
 * never repaints it, never blinks its caret and shows typed text only if something else happens to
 * force a redraw.
 *
 * The eventual design is to make the connection fd a run loop source. This is the small version of
 * the same thing: something has to touch the main thread from outside, and both mechanisms the
 * runtime offers are used because which of them is live depends on what the main thread parked in.
 * An empty block on the main queue is not a no-op: DELIVERING it is the point.
 */
#import <dispatch/dispatch.h>
#import <CoreFoundation/CoreFoundation.h>

/*
 * THE RUN LOOP IS LOOKED UP ONCE, ON THE MAIN THREAD.
 *
 * CFRunLoopGetMain() creates the main run loop on its first call, and calling it from the waker
 * thread means that creation can race the main thread using CoreFoundation for anything else.
 * Measured while it did: two runs, two different memory corruptions, one an abort inside
 * os_unfair_lock for taking a lock recursively and one a fault inside free(), both about eighteen
 * seconds in and neither reproducible in the same place twice. Racy corruption looks exactly like
 * that, and it is not what a wakeup should ever be able to cause.
 */
static CFRunLoopRef cider_wayland_main_runloop;

void cider_wayland_wake_prepare(void)
{
	if (cider_wayland_main_runloop == NULL) {
		cider_wayland_main_runloop = CFRunLoopGetMain();
	}
}

void cider_wayland_wake_main(void)
{
	/*
	 * NOT dispatch_async. The first version of this posted an empty block to the main queue, which
	 * woke the application exactly as intended and then crashed it: the fault was inside libdispatch
	 * itself, at _dispatch_source_wakeup with _dispatch_continuation_pop on the stack, on a worker
	 * thread rather than the main one. Waking a run loop needs no queue, so the queue is not used.
	 */
	CFRunLoopRef main = cider_wayland_main_runloop;
	if (main != NULL) {
		CFRunLoopWakeUp(main);
	}
}

/*
 * DRAIN THE MAIN QUEUE, which is what CoreFoundation does on macOS and nothing does here.
 *
 * LibreOffice wakes its own event loop with dispatch_async(dispatch_get_main_queue(), ...): that is
 * the ONLY dispatch call it makes, and everything it defers depends on the block arriving. Blocks on
 * the main queue run when the main thread drains it, and on macOS the main run loop does that by
 * calling _dispatch_main_queue_callback_4CF from its main queue port handler. The run loop here is
 * Cocotron own, so that call never happened and every block queued for the main thread sat there
 * forever.
 *
 * The callback returns immediately when the queue is empty, and it crashes with a clear message if
 * it is called from the wrong thread, so calling it once per pass through the event pump is both
 * cheap and self checking.
 */
void _dispatch_main_queue_callback_4CF(void *msg);

void cider_wayland_drain_main_queue(void)
{
	_dispatch_main_queue_callback_4CF(NULL);
}
