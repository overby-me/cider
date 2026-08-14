// What does a system colour turn into when an application reads it the way LibreOffice does?
//
// LibreOffice renders its whole chrome in colours that CHANGE FROM RUN TO RUN: a flat window came
// out magenta once and a toolbar came out (145,248,13) the next time. Values that move between
// runs are uninitialised memory being read, not a wrong constant, and the only question worth
// asking is which call leaves them uninitialised.
//
// THE SEQUENCE IS COPIED FROM libvclplug_osxlo, not invented: that binary's selector table
// contains exactly -colorUsingColorSpaceName:device: and -getRed:green:blue:alpha:, and nothing
// newer, so this is the pair to test. A message to nil is the specific failure being hunted,
// because it leaves the out-parameters untouched and says NOTHING: no exception, no log, no
// return value to check. The sentinel below is what makes that visible.
#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <stdio.h>

// A value no real colour component can hold, so "untouched" is distinguishable from "black".
static const CGFloat SENTINEL = -999.0;

static void probe(const char *label, NSColor *color)
{
	if (color == nil) {
		printf("COLOR_PROBE %-32s color=NIL\n", label);
		fflush(stdout);
		return;
	}

	// The conversion LibreOffice performs before reading components. device:nil rather than a
	// window's deviceDescription: the probe has no window, and a nil device is the case that
	// matters anyway since it is what a colour with no display attached gets.
	NSColor *rgb = [color colorUsingColorSpaceName: NSDeviceRGBColorSpace device: nil];
	if (rgb == nil) {
		printf("COLOR_PROBE %-32s space=%s converted=NIL  <-- getRed would leave garbage\n",
			label, [[color colorSpaceName] UTF8String] ?: "?");
		fflush(stdout);
		return;
	}

	CGFloat r = SENTINEL, g = SENTINEL, b = SENTINEL, a = SENTINEL;
	[rgb getRed: &r green: &g blue: &b alpha: &a];

	bool untouched = (r == SENTINEL && g == SENTINEL && b == SENTINEL);
	printf("COLOR_PROBE %-32s space=%-24s rgba=%.3f,%.3f,%.3f,%.3f%s\n", label,
		[[rgb colorSpaceName] UTF8String] ?: "?", (double) r, (double) g, (double) b, (double) a,
		untouched ? "   <-- UNTOUCHED, this is the bug" : "");
	fflush(stdout);
}

int main(int argc, const char **argv)
{
	printf("COLOR_PROBE start\n");
	fflush(stdout);

	@autoreleasepool {
		// The class methods LibreOffice reads for its StyleSettings. Named individually rather
		// than looped, because each one is a different path through the colour classes and a
		// loop over strings would hide which of them is the broken one.
		probe("windowBackgroundColor", [NSColor windowBackgroundColor]);
		probe("controlColor", [NSColor controlColor]);
		probe("controlTextColor", [NSColor controlTextColor]);
		probe("textColor", [NSColor textColor]);
		probe("textBackgroundColor", [NSColor textBackgroundColor]);
		probe("selectedControlColor", [NSColor selectedControlColor]);
		probe("selectedTextBackgroundColor", [NSColor selectedTextBackgroundColor]);
		probe("headerColor", [NSColor headerColor]);
		probe("gridColor", [NSColor gridColor]);
		probe("keyboardFocusIndicatorColor", [NSColor keyboardFocusIndicatorColor]);

		// The two constructors the table in colors.rs actually uses, tested directly. If a
		// calibrated white survives the conversion and a catalog colour does not, the fault is in
		// the catalog wrapper rather than in the colour itself.
		probe("literal calibratedWhite 0.93", [NSColor colorWithCalibratedWhite: 0.93 alpha: 1.0]);
		probe("literal blueColor", [NSColor blueColor]);
		probe("literal deviceRed", [NSColor colorWithDeviceRed: 0.25 green: 0.5 blue: 0.75
														alpha: 1.0]);
	}

	/*
	 * DARK MODE, which decides the whole palette before any individual colour matters. LibreOffice
	 * paints its chrome a dark slate here while every colour this backend hands out is light, and
	 * an application that believes it is in dark mode does exactly that: it stops using the light
	 * values and computes its own dark ones.
	 *
	 * Both of the things it can read are printed, because they are different questions: the user
	 * default is what macOS applications traditionally test, and the effective appearance is the
	 * modern one.
	 */
	@autoreleasepool {
		NSString *style = [[NSUserDefaults standardUserDefaults]
			stringForKey: @"AppleInterfaceStyle"];
		printf("COLOR_PROBE AppleInterfaceStyle=%s class=%s\n",
			style ? [style UTF8String] : "(nil)",
			style ? class_getName([style class]) : "-");
		fflush(stdout);

		NSApplication *app = [NSApplication sharedApplication];
		NSAppearance *effective = nil;
		if ([app respondsToSelector: @selector(effectiveAppearance)]) {
			effective = [app effectiveAppearance];
		}
		printf("COLOR_PROBE effectiveAppearance=%s name=%s\n", effective ? "yes" : "(nil)",
			(effective && [effective respondsToSelector: @selector(name)])
				? [[effective name] UTF8String] : "-");
		fflush(stdout);
	}

	/*
	 * THE NSSTRING TO UNICHAR PATH, which is how VCL turns the string handed to
	 * insertText:replacementRange: into its own OUString. If getCharacters answers nothing, the
	 * character code it derives is zero, its own guard rejects the keystroke as a non character,
	 * and the text is discarded with everything upstream looking correct. That is exactly the
	 * observed failure, and it is testable without LibreOffice.
	 */
	@autoreleasepool {
		NSString *made = [NSString stringWithUTF8String: "h"];
		printf("COLOR_PROBE string=%p length=%lu class=%s\n", made, (unsigned long) [made length],
			class_getName([made class]));
		fflush(stdout);

		unichar buffer[8];
		memset(buffer, 0, sizeof(buffer));
		[made getCharacters: buffer range: NSMakeRange(0, [made length])];
		printf("COLOR_PROBE getCharacters-range=%u expected=%u\n", (unsigned) buffer[0],
			(unsigned) 'h');
		fflush(stdout);

		unichar single = [made characterAtIndex: 0];
		printf("COLOR_PROBE characterAtIndex=%u\n", (unsigned) single);
		fflush(stdout);

		memset(buffer, 0, sizeof(buffer));
		[made getCharacters: buffer];
		printf("COLOR_PROBE getCharacters-norange=%u\n", (unsigned) buffer[0]);
		fflush(stdout);

		/* And through CoreFoundation, which is the other way VCL might do it. */
		UniChar cfbuf[8];
		memset(cfbuf, 0, sizeof(cfbuf));
		CFStringGetCharacters((CFStringRef) made, CFRangeMake(0, 1), cfbuf);
		printf("COLOR_PROBE CFStringGetCharacters=%u\n", (unsigned) cfbuf[0]);
		fflush(stdout);
	}


	/*
	 * THE CONVERSION THE APPLICATION REALLY PERFORMS, which is not the one tested above.
	 *
	 * LibreOffice getColor passes [pWin deviceDescription] as the device, never nil, and that is a
	 * different path through the colour classes: a device dictionary selects a colour space, and a
	 * conversion that cannot find one has to answer something. The chrome colour CHANGES BETWEEN
	 * RUNS, purple one run and green the next, which is uninitialised memory being read rather than
	 * a wrong constant, so the question is which of these calls leaves a component untouched.
	 *
	 * The components are printed as LibreOffice would store them, scaled to bytes, because that is
	 * what ends up on screen and a float that reads plausibly can still scale to nonsense.
	 */
	@autoreleasepool {
		NSWindow *window = [[NSWindow alloc] initWithContentRect: NSMakeRect(0, 0, 320, 200)
													  styleMask: NSTitledWindowMask
														backing: NSBackingStoreBuffered
														  defer: NO];
		NSDictionary *device = [window deviceDescription];
		printf("COLOR_PROBE deviceDescription=%s count=%lu\n", device ? "yes" : "(nil)",
			device ? (unsigned long) [device count] : 0UL);
		for (NSString *key in [device allKeys]) {
			printf("COLOR_PROBE   device[%s]=%s\n", [[key description] UTF8String],
				[[[device objectForKey: key] description] UTF8String]);
		}
		fflush(stdout);

		const char *names[] = { "windowBackgroundColor", "controlColor", "textColor",
								"controlTextColor", NULL };
		for (int i = 0; names[i] != NULL; i++) {
			SEL sel = sel_registerName(names[i]);
			NSColor *color = [NSColor performSelector: sel];
			NSColor *rgb = [color colorUsingColorSpaceName: NSDeviceRGBColorSpace device: device];
			CGFloat r = SENTINEL, g = SENTINEL, b = SENTINEL, a = SENTINEL;
			if (rgb != nil) {
				[rgb getRed: &r green: &g blue: &b alpha: &a];
			}
			printf("COLOR_PROBE withdevice %-24s converted=%s rgb=%.3f,%.3f,%.3f bytes=%d,%d,%d%s\n",
				names[i], rgb ? "yes" : "NIL", (double) r, (double) g, (double) b,
				(int) (r * 255.0), (int) (g * 255.0), (int) (b * 255.0),
				(r == SENTINEL) ? "   <-- UNTOUCHED, this is the bug" : "");
			fflush(stdout);
		}
	}


	/*
	 * IS A FRESH BITMAP ZEROED. This is a contract, not a detail: CGBitmapContextCreate with a NULL
	 * data pointer allocates the memory itself and Apple documents it as zeroed, and Onyx2D relies
	 * on exactly that, with a comment saying so, by allocating through NSMutableData dataWithLength.
	 *
	 * The chrome of this application renders a FLAT colour that is DIFFERENT ON EVERY RUN: purple
	 * once, green the next, pale cyan the next. A wrong constant cannot do that and neither can a
	 * wrong palette entry, both of which would be wrong the same way every time. Recycled heap that
	 * nobody cleared can, and it is the only candidate left that behaves like this.
	 *
	 * The heap is DIRTIED FIRST, which is the whole point of the test: a zeroing bug is invisible
	 * against fresh pages from the kernel, because those are already zero. Freeing a dirty block of
	 * the same size makes the allocator hand that block back.
	 */
	@autoreleasepool {
		const size_t bytes = 4 * 1024 * 1024;
		void *dirty = malloc(bytes);
		memset(dirty, 0xAB, bytes);
		free(dirty);

		NSMutableData *data = [NSMutableData dataWithLength: bytes];
		const unsigned char *raw = [data bytes];
		size_t nonzero = 0;
		for (size_t i = 0; i < bytes; i++) {
			if (raw[i] != 0) nonzero++;
		}
		printf("COLOR_PROBE NSMutableData dataWithLength nonzero=%zu of %zu%s\n", nonzero, bytes,
			nonzero ? "   <-- NOT ZEROED, this is the bug" : "");
		fflush(stdout);

		void *dirty2 = malloc(bytes);
		memset(dirty2, 0xCD, bytes);
		free(dirty2);

		CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
		CGContextRef ctx = CGBitmapContextCreate(NULL, 512, 512, 8, 512 * 4, space,
			kCGImageAlphaNoneSkipFirst);
		const unsigned char *pixels = CGBitmapContextGetData(ctx);
		size_t pixelNonzero = 0;
		if (pixels != NULL) {
			for (size_t i = 0; i < 512 * 512 * 4; i++) {
				if (pixels[i] != 0) pixelNonzero++;
			}
		}
		printf("COLOR_PROBE CGBitmapContextCreate data=%p nonzero=%zu of %d%s\n", pixels,
			pixelNonzero, 512 * 512 * 4,
			pixelNonzero ? "   <-- NOT ZEROED, this is the bug" : "");
		fflush(stdout);
		CGContextRelease(ctx);
		CGColorSpaceRelease(space);
	}

	printf("COLOR_PROBE_OK\n");
	fflush(stdout);
	return 0;
}
