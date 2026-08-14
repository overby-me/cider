// Does input reach an AppKit application through this backend?
//
// It is the smallest artifact that can answer that. LibreOffice is 800 MB and a minute of startup
// before it will accept a click, and every failure in between looks like an input failure from the
// outside. This opens one window, runs the ordinary event loop, and PRINTS EVERY EVENT IT GETS.
//
// The window is deliberately plain. A control that reacts to a click proves more, but it also
// fails for reasons that have nothing to do with the backend, and the question here is only
// whether a button press on a compositor becomes an NSEvent in an application.
#import <AppKit/AppKit.h>
#import <stdio.h>
#import <stdlib.h>

static const char *nameForType(NSEventType type)
{
	switch ((int) type) {
	case NSLeftMouseDown: return "LeftMouseDown";
	case NSLeftMouseUp: return "LeftMouseUp";
	case NSRightMouseDown: return "RightMouseDown";
	case NSRightMouseUp: return "RightMouseUp";
	case NSMouseMoved: return "MouseMoved";
	case NSLeftMouseDragged: return "LeftMouseDragged";
	case NSRightMouseDragged: return "RightMouseDragged";
	case NSKeyDown: return "KeyDown";
	case NSKeyUp: return "KeyUp";
	case NSFlagsChanged: return "FlagsChanged";
	case NSScrollWheel: return "ScrollWheel";
	case NSOtherMouseDown: return "OtherMouseDown";
	case NSOtherMouseUp: return "OtherMouseUp";
	case NSAppKitSystem: return "AppKitSystem";
	default: return "other";
	}
}

int main(int argc, const char **argv)
{
	int seconds = (argc > 1) ? atoi(argv[1]) : 60;

	@autoreleasepool {
		NSApplication *app = [NSApplication sharedApplication];
		printf("INPUT_PROBE app=%p\n", app);
		fflush(stdout);

		// EACH STEP ANNOUNCES ITSELF, because the failure this probe first found was a silent
		// exit with no output at all: under one compositor the window appeared, under another the
		// process was simply gone, and nothing said which call had been reached.
		NSArray *screens = [NSScreen screens];
		printf("INPUT_PROBE screens=%ld\n", (long) [screens count]);
		fflush(stdout);
		NSScreen *main = [NSScreen mainScreen];
		NSRect frame = [main frame];
		printf("INPUT_PROBE mainScreen=%p frame=%.0fx%.0f\n", main, frame.size.width,
			frame.size.height);
		fflush(stdout);
		NSRect visible = [main visibleFrame];
		printf("INPUT_PROBE visibleFrame=%.0fx%.0f\n", visible.size.width, visible.size.height);
		fflush(stdout);

		printf("INPUT_PROBE creating the window\n");
		fflush(stdout);
		NSWindow *window = [[NSWindow alloc]
			initWithContentRect: NSMakeRect(0, 0, 640, 480)
					  styleMask: NSTitledWindowMask | NSClosableWindowMask | NSResizableWindowMask
						backing: NSBackingStoreBuffered
						  defer: NO];
		[window setTitle: @"cider input probe"];
		[window setBackgroundColor: [NSColor whiteColor]];
		[window makeKeyAndOrderFront: nil];
		printf("INPUT_PROBE window=%p number=%ld\n", window, (long) [window windowNumber]);
		fflush(stdout);

		// COUNTS, not just a log. A run that receives one stray event and a run that receives a
		// working stream both print lines; only the totals at the end distinguish them, and the
		// totals are what a harness can check.
		int mouseDowns = 0, mouseUps = 0, moves = 0, keyDowns = 0, keyUps = 0, flags = 0;
		NSMutableString *typed = [NSMutableString string];

		NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow: seconds];
		while ([deadline timeIntervalSinceNow] > 0) {
			@autoreleasepool {
				NSEvent *event = [app nextEventMatchingMask: NSAnyEventMask
												  untilDate: [NSDate dateWithTimeIntervalSinceNow: 0.05]
													 inMode: NSDefaultRunLoopMode
													dequeue: YES];
				if (event == nil) {
					continue;
				}
				NSEventType type = [event type];
				if (type == NSAppKitSystem) {
					// The idle event NSDisplay manufactures when nothing happened. Sending it on
					// is what keeps the application running, and printing it would bury the real
					// events under thousands of lines.
					[app sendEvent: event];
					continue;
				}

				switch ((int) type) {
				case NSLeftMouseDown:
				case NSRightMouseDown:
				case NSOtherMouseDown:
					mouseDowns++;
					break;
				case NSLeftMouseUp:
				case NSRightMouseUp:
				case NSOtherMouseUp:
					mouseUps++;
					break;
				case NSMouseMoved:
				case NSLeftMouseDragged:
				case NSRightMouseDragged:
					moves++;
					break;
				case NSKeyDown:
					keyDowns++;
					if ([[event characters] length] > 0) {
						[typed appendString: [event characters]];
					}
					break;
				case NSKeyUp:
					keyUps++;
					break;
				case NSFlagsChanged:
					flags++;
					break;
				default:
					break;
				}

				// Motion is reported every few pixels and would drown the log, so only the first
				// few are printed; the count carries the rest.
				if (type != NSMouseMoved || moves <= 3) {
					NSPoint where = [event locationInWindow];
					printf("INPUT_PROBE event=%s x=%.1f y=%.1f modifiers=%lx", nameForType(type),
						where.x, where.y, (unsigned long) [event modifierFlags]);
					if (type == NSKeyDown || type == NSKeyUp) {
						printf(" keyCode=%d characters=%s", (int) [event keyCode],
							[[event characters] UTF8String] ?: "");
					}
					printf("\n");
					fflush(stdout);
				}

				[app sendEvent: event];
			}
		}

		printf("INPUT_PROBE totals mouseDown=%d mouseUp=%d moved=%d keyDown=%d keyUp=%d flags=%d\n",
			mouseDowns, mouseUps, moves, keyDowns, keyUps, flags);
		printf("INPUT_PROBE typed=%s\n", [typed UTF8String] ?: "");
		fflush(stdout);

		// The verdict, so a harness does not have to interpret counts. Mouse and keyboard are
		// reported separately because they attach separately and one working says nothing about
		// the other.
		printf("INPUT_PROBE VERDICT mouse=%s keyboard=%s\n",
			(mouseDowns > 0) ? "WORKS" : "NONE",
			(keyDowns > 0) ? "WORKS" : "NONE");
		fflush(stdout);
	}

	printf("INPUT_PROBE_OK\n");
	fflush(stdout);
	return 0;
}
