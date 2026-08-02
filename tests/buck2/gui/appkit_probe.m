// The smallest AppKit program that proves something.
//
// The GUI cone -- AppKit, cocotron, CoreGraphics and the sixteen src/native wrappers that
// bridge to the host's X11, cairo and OpenGL -- links cleanly and exports the right
// symbols, and had never executed an instruction. Everything here is deliberately
// step-by-step and prints as it goes, because the useful outcome of a first run is not
// "it worked" but "it got exactly this far".
//
// Run it with scripts/buck-appkit-check.sh, which supplies an X server.

#import <AppKit/AppKit.h>
#import <stdio.h>

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

		[win setTitle:@"darling buck2 probe"];
		[win makeKeyAndOrderFront:nil];
		printf("APPKIT_PROBE ordered-front\n");
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
	}

	printf("APPKIT_PROBE_OK\n");
	fflush(stdout);
	return 0;
}
