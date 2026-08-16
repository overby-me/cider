// The smallest AppKit program that proves something.
//
// The GUI cone -- AppKit, cocotron, CoreGraphics and the sixteen src/linux/native wrappers that
// bridge to the host's X11, cairo and OpenGL -- links cleanly and exports the right
// symbols, and had never executed an instruction. Everything here is deliberately
// step-by-step and prints as it goes, because the useful outcome of a first run is not
// "it worked" but "it got exactly this far".
//
// Run it with scripts/checks/buck-appkit-check.nu, which supplies an X server.

#import <AppKit/AppKit.h>
#import <stdio.h>

// A view that PAINTS SOMETHING NOTHING ELSE WOULD, so "did it render" is answerable by looking
// at the pixels rather than by trusting that a context was constructed. The colour is deliberately
// not a grey, a black or a white: those are what an uninitialised or cleared buffer looks like.
@interface CiderProbeView : NSView
@end

@implementation CiderProbeView
- (void) drawRect: (NSRect) dirty {
	[[NSColor colorWithCalibratedRed: 1.0 green: 0.0 blue: 0.5 alpha: 1.0] set];
	NSRectFill([self bounds]);
	printf("APPKIT_PROBE drew rect=%dx%d\n",
		(int) [self bounds].size.width, (int) [self bounds].size.height);
	fflush(stdout);

	// TEXT IS THE WHOLE FONT PATH IN ONE CALL: the display backend is asked for the family
	// list and the typefaces within a family, NSFont picks one, and Onyx2D rasterises glyphs
	// through FreeType into the same pages the compositor reads. A document application does
	// nothing else all day, so this is the rung that matters after a filled rectangle.
	@try {
		NSFont *font = [NSFont systemFontOfSize: 18];
		printf("APPKIT_PROBE font=%s\n", font ? [[font fontName] UTF8String] : "nil");
		fflush(stdout);
		if (font != nil) {
			NSDictionary *attrs = [NSDictionary
				dictionaryWithObjectsAndKeys: font, NSFontAttributeName,
				[NSColor blackColor], NSForegroundColorAttributeName, nil];
			[@"Cider on Wayland" drawAtPoint: NSMakePoint(12, 80) withAttributes: attrs];
			printf("APPKIT_PROBE text=drawn\n");
			fflush(stdout);
		}
	} @catch (NSException *e) {
		printf("APPKIT_PROBE text=FAILED name=%s reason=%s\n",
			[[e name] UTF8String], [[e reason] UTF8String]);
		fflush(stdout);
	}
}
@end

int main(int argc, const char **argv) {
	printf("APPKIT_PROBE start\n");
	fflush(stdout);
	// Is NSLog even visible here? cocotron reports several display failures through it
	// (CGSConnectionX11 logs "XOpenDisplay() failed"), so if this line does not appear,
	// every such report has been going into a void and the silence means nothing.
	NSString *probe = [NSString stringWithUTF8String:"x"];
	printf("APPKIT_PROBE objc=%s\n", probe ? [probe UTF8String] : "nil");
	fflush(stdout);
	NSLog(@"APPKIT_PROBE nslog-visible");
	printf("APPKIT_PROBE after-nslog\n");
	fflush(stdout);

	// CoreGraphics FIRST, on purpose. Its X11 backend is a separate bundle from AppKit's,
	// with its own principal class (CGSConnectionX11), and touching a CG display is what
	// forces it to load. Bracketing it here says whether NSApplication dies in its own
	// backend or in this one.
	printf("APPKIT_PROBE cg-begin\n");
	fflush(stdout);
	CGDirectDisplayID disp = CGMainDisplayID();
	printf("APPKIT_PROBE cg-display=%u\n", (unsigned) disp);
	fflush(stdout);

	@autoreleasepool {
		// Bringing NSApplication up is what pulls in the display connection: cocotron's
		// backend opens the X display here, so a missing or broken DISPLAY dies at this
		// line rather than at the window.
		//
		// @try, because the first run of this exited 1 after printing `start` and said
		// NOTHING about why. An uncaught ObjC exception on Darling terminates without a
		// message, so a probe that does not catch it reports "died somewhere in AppKit"
		// when the exception's own reason string is right there.
		NSApplication *app = nil;
		@try {
			app = [NSApplication sharedApplication];
		} @catch (NSException *e) {
			printf("APPKIT_PROBE exception name=%s reason=%s\n",
				[[e name] UTF8String] ?: "(none)",
				[[e reason] UTF8String] ?: "(none)");
			fflush(stdout);
			return 1;
		}
		printf("APPKIT_PROBE app=%s\n", app ? "yes" : "no");
		fflush(stdout);

		NSRect frame = NSMakeRect(0, 0, 320, 200);
		NSWindow *win = [[NSWindow alloc]
			initWithContentRect:frame
					  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
						backing:NSBackingStoreBuffered
						  defer:NO];
		printf("APPKIT_PROBE window=%s\n", win ? "yes" : "no");
		fflush(stdout);

		[win setTitle:@"cider buck2 probe"];

		// A CONTENT VIEW, so there is something to draw. Without one the window is created and
		// mapped and the buffer stays exactly as the backend cleared it, which proves the surface
		// exists but says nothing about whether drawing reaches it.
		CiderProbeView *view = [[CiderProbeView alloc] initWithFrame: frame];
		[win setContentView: view];

		[win makeKeyAndOrderFront:nil];
		printf("APPKIT_PROBE ordered-front\n");
		fflush(stdout);

		// FORCE THE DRAW rather than waiting for the run loop to decide. displayIfNeeded would
		// depend on whether anything marked the view dirty; -display always goes through
		// -drawRect:, which is the path being tested.
		[view display];
		[win flushWindow];
		printf("APPKIT_PROBE displayed\n");
		fflush(stdout);

		// One pass of the event loop with no wait, so the probe exercises the run loop
		// and the X round trip without ever blocking.
		// NSAnyEventMask, not NSEventMaskAny: this AppKit is cocotron-derived and predates
		// the 10.12 renaming of the event-mask constants.
		NSEvent *ev = [app nextEventMatchingMask:NSAnyEventMask
									   untilDate:[NSDate distantPast]
										  inMode:NSDefaultRunLoopMode
										 dequeue:YES];
		printf("APPKIT_PROBE pumped event=%s\n", ev ? "one" : "none");
		fflush(stdout);

		// A LOOP, BECAUSE ONE PASS PROVES NOTHING ABOUT BLOCKING. The backend services the
		// Wayland connection from this method, and the wrong pump there (a roundtrip, or a
		// read that waits) costs a whole iteration each time. An application spends its life
		// here, so the cost per idle pass is the number that matters, not whether it returns.
		NSDate *began = [NSDate date];
		int passes = 0;
		for (int i = 0; i < 200; i++) {
			[app nextEventMatchingMask:NSAnyEventMask
							 untilDate:[NSDate distantPast]
								inMode:NSDefaultRunLoopMode
							   dequeue:YES];
			passes++;
		}
		double ms = -[began timeIntervalSinceNow] * 1000.0;
		printf("APPKIT_PROBE pump passes=%d elapsed_ms=%.1f per_pass_ms=%.3f\n",
			passes, ms, ms / passes);
		fflush(stdout);
	}

	printf("APPKIT_PROBE_OK\n");
	fflush(stdout);
	return 0;
}
