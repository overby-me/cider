/*
 * Does this backend hand out a Carbon uchr layout, and does UCKeyTranslate turn key codes into the
 * right characters with it? TISGetInputSourceProperty answered NULL for
 * kTISPropertyUnicodeKeyLayoutData, so UCKeyTranslate could only return paramErr. Task #239.
 *
 * RUN IT THROUGH scripts/app-drive.sh WITH A TYPE STEP. The compositor sends a keymap only once a
 * keyboard is on the seat, and the driver's virtual keyboard appears at that step, tens of seconds
 * after launch: without it there is nothing to measure, and asking once at startup reports the
 * empty case as the answer. It waits on a timer inside a running NSApplication because
 * -[NSRunLoop runUntilDate:] does not pump the platform event queue, so a probe that waits that
 * way never sees the seat change at all.
 *
 * A PROBE, NOT A TEST CASE: it prints what it saw and exits 0 either way.
 */

#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#include <stdio.h>

static const int kDeadlineSeconds = 45;

@interface UchrProbe : NSObject
@property (assign) int elapsed;
@end

@implementation UchrProbe

- (void) reportTranslation: (const UCKeyboardLayout *) layout
{
	/* Unshifted and shifted, by Carbon virtual key code. The shift bit is 0x02 because
	 * UCKeyTranslate takes the modifiers already shifted right by eight. */
	const struct { UInt16 code; const char *name; } keys[] = {
		{ kVK_ANSI_A, "A" }, { kVK_ANSI_S, "S" }, { kVK_ANSI_1, "1" }, { kVK_Space, "space" },
	};
	for (size_t i = 0; i < sizeof(keys) / sizeof(keys[0]); i++) {
		for (int shift = 0; shift <= 1; shift++) {
			UniChar out[8] = { 0 };
			UniCharCount len = 0;
			UInt32 dead = 0;
			OSStatus err = UCKeyTranslate(layout, keys[i].code, kUCKeyActionDown,
				shift ? 0x02 : 0x00, LMGetKbdType(), 0, &dead,
				sizeof(out) / sizeof(out[0]), &len, out);
			printf("uchr-probe key=%-5s shift=%d err=%d len=%lu char=U+%04X\n",
				keys[i].name, shift, (int) err, (unsigned long) len,
				len > 0 ? (unsigned) out[0] : 0u);
		}
	}
	fflush(stdout);
}

- (void) poll: (NSTimer *) timer
{
	TISInputSourceRef source = TISCopyCurrentKeyboardInputSource();
	CFDataRef data = source != NULL ? (CFDataRef) TISGetInputSourceProperty(
		source, kTISPropertyUnicodeKeyLayoutData) : NULL;
	printf("uchr-probe t=%ds source=%p layoutData=%p bytes=%ld\n", self.elapsed,
		(void *) source, (void *) data,
		data != NULL ? (long) CFDataGetLength(data) : -1L);
	fflush(stdout);

	if (data != NULL) {
		[self reportTranslation: (const UCKeyboardLayout *) CFDataGetBytePtr(data)];
		printf("uchr-probe done verdict=layout-present\n");
		fflush(stdout);
		if (source != NULL)
			CFRelease(source);
		[timer invalidate];
		exit(0);
	}
	if (source != NULL)
		CFRelease(source);

	self.elapsed = self.elapsed + 1;
	if (self.elapsed >= kDeadlineSeconds) {
		printf("uchr-probe done verdict=no-layout-within-deadline\n");
		fflush(stdout);
		[timer invalidate];
		exit(0);
	}
}

@end

int main(void)
{
	@autoreleasepool {
		NSApplication *app = [NSApplication sharedApplication];

		NSWindow *window = [[NSWindow alloc]
			initWithContentRect: NSMakeRect(80, 80, 360, 120)
					  styleMask: NSTitledWindowMask | NSClosableWindowMask | NSResizableWindowMask
						backing: NSBackingStoreBuffered
						  defer: NO];
		[window setTitle: @"uchr probe"];
		[window makeKeyAndOrderFront: nil];

		UchrProbe *probe = [[UchrProbe alloc] init];
		[NSTimer scheduledTimerWithTimeInterval: 1.0
										 target: probe
									   selector: @selector(poll:)
									   userInfo: nil
										repeats: YES];
		[app run];
	}
	return 0;
}
