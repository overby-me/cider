// A Cocoa application made of the widgets a document suite is built from.
//
// appkit_probe.m answers "does a window exist and can it be drawn into". This answers the next
// question, which is the one that decides whether a real application can run: do AppKit's CONTROLS
// work. A suite is a menu bar, buttons, text fields and a scrolling text view, and every one of
// them reaches parts of the display backend a bare NSWindow never touches.
//
// EVERY STEP IS INDEPENDENT AND CATCHES ITS OWN EXCEPTION, on purpose. The point is a list of what
// works and what does not, in one run; stopping at the first failure would mean one round trip
// through a container per missing method, and the failures are usually independent of each other.
#import <AppKit/AppKit.h>
#import <stdio.h>

#define STEP(label, body)                                                            \
	do {                                                                             \
		@try {                                                                       \
			body;                                                                    \
			printf("WIDGET_PROBE %s=ok\n", label);                                   \
		} @catch (NSException *e) {                                                   \
			printf("WIDGET_PROBE %s=FAILED name=%s reason=%s\n", label,              \
				[[e name] UTF8String], [[e reason] UTF8String]);                      \
		}                                                                            \
		fflush(stdout);                                                              \
	} while (0)

int main(int argc, const char **argv)
{
	printf("WIDGET_PROBE start\n");
	fflush(stdout);

	@autoreleasepool {
		NSApplication *app = nil;
		STEP("app", { app = [NSApplication sharedApplication]; });
		if (app == nil) {
			printf("WIDGET_PROBE_ABORT no-application\n");
			return 1;
		}

		// A MENU BAR IS NOT DECORATION on macOS: it is where an application's commands live, and
		// AppKit builds one whether or not anything displays it.
		STEP("menu", {
			NSMenu *main = [[NSMenu alloc] initWithTitle: @"MainMenu"];
			NSMenuItem *appItem = [[NSMenuItem alloc] initWithTitle: @"Cider"
															 action: NULL
													  keyEquivalent: @""];
			NSMenu *appMenu = [[NSMenu alloc] initWithTitle: @"Cider"];
			[appMenu addItemWithTitle: @"Quit" action: @selector(terminate:) keyEquivalent: @"q"];
			[appItem setSubmenu: appMenu];
			[main addItem: appItem];
			[app setMainMenu: main];
		});

		NSWindow *win = nil;
		STEP("window", {
			win = [[NSWindow alloc]
				initWithContentRect: NSMakeRect(0, 0, 480, 360)
						  styleMask: NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
									 NSWindowStyleMaskResizable
							backing: NSBackingStoreBuffered
							  defer: NO];
			[win setTitle: @"cider widgets"];
		});
		if (win == nil) {
			printf("WIDGET_PROBE_ABORT no-window\n");
			return 1;
		}
		NSView *content = [win contentView];

		STEP("button", {
			NSButton *b = [[NSButton alloc] initWithFrame: NSMakeRect(16, 300, 140, 32)];
			[b setTitle: @"Press me"];
			[b setBezelStyle: NSRoundedBezelStyle];
			[b setTarget: app];
			[b setAction: @selector(terminate:)];
			[content addSubview: b];
		});

		STEP("textfield", {
			NSTextField *f = [[NSTextField alloc] initWithFrame: NSMakeRect(16, 260, 300, 24)];
			[f setStringValue: @"editable text field"];
			[content addSubview: f];
		});

		// THE SCROLLING TEXT VIEW IS THE DOCUMENT, in miniature: layout, a text container, a
		// clip view and a scroller, which is most of what a word processor's window is.
		STEP("scrolling-textview", {
			NSScrollView *scroll = [[NSScrollView alloc] initWithFrame: NSMakeRect(16, 40, 440, 200)];
			[scroll setHasVerticalScroller: YES];
			[scroll setBorderType: NSBezelBorder];
			NSTextView *text = [[NSTextView alloc] initWithFrame: [[scroll contentView] bounds]];
			[text setString: @"Cider runs macOS binaries on the Linux kernel.\n"
							  "This text view exists to make the layout machinery work: a text\n"
							  "container, a layout manager and a scroller are most of what a\n"
							  "document window is."];
			[scroll setDocumentView: text];
			[content addSubview: scroll];
		});

		STEP("order-front", { [win makeKeyAndOrderFront: nil]; });
		STEP("display", {
			[content display];
			[win flushWindow];
		});

		// A REAL RUN LOOP PASS, not a single poll: controls install tracking and timers when they
		// are added to a window, and those only run when the loop does.
		STEP("runloop", {
			NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow: 0.5];
			while ([deadline timeIntervalSinceNow] > 0) {
				NSEvent *ev = [app nextEventMatchingMask: NSAnyEventMask
											   untilDate: [NSDate dateWithTimeIntervalSinceNow: 0.02]
												  inMode: NSDefaultRunLoopMode
												 dequeue: YES];
				if (ev != nil) {
					[app sendEvent: ev];
				}
			}
		});

		STEP("redisplay", {
			[content setNeedsDisplay: YES];
			[content display];
			[win flushWindow];
		});
	}

	printf("WIDGET_PROBE_OK\n");
	fflush(stdout);
	return 0;
}
