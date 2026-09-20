/*
 * THE DISPLAY LINK IS A TIMER HERE, and until #239 it was not even that.
 *
 * SetOutputCallback discarded the callback, Start started nothing, and IsRunning answered YES: an
 * application that draws from the link was told registered, started and running, and its callback
 * was never called once. That is the worst shape a stub can take, because nothing reports an error
 * and the frame simply never arrives. iTerm2 3.5 draws its terminal that way and never marked the
 * text view dirty, so every keystroke reached the shell, the echo came back, and the window kept
 * showing whatever the first layout had painted.
 *
 * There is no vertical blank to follow here, so the link fires from its own thread at the nominal
 * refresh rate. It runs OFF THE MAIN THREAD, which is where macOS calls it and what callers expect.
 *
 * A PLAIN THREAD AND nanosleep, NOT a dispatch timer source: the first version used
 * DISPATCH_SOURCE_TYPE_TIMER, which this port creates and resumes happily and then never fires,
 * and src/darwin/kqueue-probe/displaylink.c caught it with verdict=NEVER-FIRED before it shipped.
 * A display link that silently never fires is the exact defect this file exists to remove.
 */
#include <CoreVideo/CVDisplayLink.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <memory>
#import <AppKit/NSApplication.h>
#import <AppKit/NSWindow.h>
#import <AppKit/NSScreen.h>
#import <Foundation/NSDictionary.h>
#include <CoreGraphics/CGWindow.h>
#include <CoreGraphics/CGDirectDisplay.h>

static const NSString* kDirectDisplayArray = @"CGDirectDisplay";
static const NSString* kCiderLinkState = @"CiderLinkState";

/*
 * The link's own state. It hangs off the dictionary the Ref already is, so CVDisplayLinkRelease
 * and CVDisplayLinkGetCurrentCGDisplay keep working unchanged.
 */
@interface CiderDisplayLinkState : NSObject
{
@public
	CVDisplayLinkOutputCallback callback;
	void *userInfo;
	pthread_t thread;
	/* The thread reads this every frame and exits when it clears, so Stop never has to kill a
	 * thread in the middle of a callback. */
	volatile int running;
	int64_t frame;
}
@end

@implementation CiderDisplayLinkState
- (void) dealloc
{
	running = 0;
	if (thread != NULL) {
		pthread_join(thread, NULL);
		thread = NULL;
	}
	[super dealloc];
}
@end

static CiderDisplayLinkState *cider_link_state(CVDisplayLinkRef displayLink, BOOL create)
{
	NSMutableDictionary *self = (NSMutableDictionary *) displayLink;
	CiderDisplayLinkState *state = [self objectForKey: kCiderLinkState];

	if (state == nil && create) {
		state = [[[CiderDisplayLinkState alloc] init] autorelease];
		[self setObject: state forKey: kCiderLinkState];
	}
	return state;
}

/* The refresh period as a duration, falling back to 60Hz when the display cannot say. */
static uint64_t cider_link_interval_ns(CVDisplayLinkRef displayLink)
{
	CVTime period = CVDisplayLinkGetNominalOutputVideoRefreshPeriod(displayLink);

	if ((period.flags & kCVTimeIsIndefinite) == 0 && period.timeScale > 0 && period.timeValue > 0)
		return (uint64_t) ((double) period.timeValue / (double) period.timeScale * 1000000000.0);
	return 1000000000ull / 60ull;
}

static void cider_link_fire(CVDisplayLinkRef displayLink)
{
	CiderDisplayLinkState *state = cider_link_state(displayLink, NO);
	if (state == nil || state->callback == NULL)
		return;

	uint64_t interval = cider_link_interval_ns(displayLink);
	CVTimeStamp now = { 0 };
	now.version = 0;
	now.videoTimeScale = 1000000000;
	now.videoTime = state->frame * (int64_t) interval;
	now.hostTime = mach_absolute_time();
	now.rateScalar = 1.0;
	now.videoRefreshPeriod = (int64_t) interval;
	now.flags = kCVTimeStampVideoTimeValid | kCVTimeStampHostTimeValid |
			kCVTimeStampVideoRefreshPeriodValid | kCVTimeStampRateScalarValid;

	/* The OUTPUT time is one frame ahead: it is when what is drawn now will be shown, and a caller
	 * that animates against it rather than against inNow is right to. */
	CVTimeStamp output = now;
	output.videoTime += (int64_t) interval;
	output.hostTime += interval;

	state->frame++;

	CVOptionFlags flagsOut = 0;
	if (state->frame == 1 && getenv("CIDER_TRACE_DISPLAY") != NULL)
		fprintf(stderr, "cider-displaylink first fire link=%p\n", displayLink);
	state->callback(displayLink, &now, &output, 0, &flagsOut, state->userInfo);
}

static void *cider_link_thread(void *context)
{
	CVDisplayLinkRef displayLink = (CVDisplayLinkRef) context;
	uint64_t interval = cider_link_interval_ns(displayLink);

	for (;;) {
		CiderDisplayLinkState *state = cider_link_state(displayLink, NO);
		if (state == nil || !state->running)
			break;

		struct timespec ts;
		ts.tv_sec = (time_t) (interval / 1000000000ull);
		ts.tv_nsec = (long) (interval % 1000000000ull);
		nanosleep(&ts, NULL);

		state = cider_link_state(displayLink, NO);
		if (state == nil || !state->running)
			break;
		cider_link_fire(displayLink);
	}
	return NULL;
}

CVReturn CVDisplayLinkCreateWithActiveCGDisplays(CVDisplayLinkRef* displayLinkOut)
{
	uint32_t displayCount;
	std::unique_ptr<CGDirectDisplayID[]> displays;

	CGError err = CGGetActiveDisplayList(0, nullptr, &displayCount);
	if (err != kCGErrorSuccess)
		return err;

	displays.reset(new CGDirectDisplayID[displayCount]);

	err = CGGetActiveDisplayList(displayCount, displays.get(), &displayCount);
	if (err != kCGErrorSuccess)
		return err;
	
	NSMutableDictionary* self = [[NSMutableDictionary alloc] init];
	NSMutableArray* array = [NSMutableArray arrayWithCapacity: displayCount];

	for (int i = 0; i < displayCount; i++)
		[array addObject: [NSNumber numberWithInt: displays[i]]];

	[self setObject: array
			forKey: kDirectDisplayArray];

	*displayLinkOut = (CVDisplayLinkRef) self;
	return kCVReturnSuccess;
}

CVReturn CVDisplayLinkStart(CVDisplayLinkRef displayLink)
{
	if (!displayLink)
		return kCVReturnInvalidArgument;

	CiderDisplayLinkState *state = cider_link_state(displayLink, YES);
	if (state->running)
		return kCVReturnSuccess;

	state->running = 1;
	if (pthread_create(&state->thread, NULL, cider_link_thread, displayLink) != 0) {
		state->running = 0;
		state->thread = NULL;
		return kCVReturnError;
	}
	if (getenv("CIDER_TRACE_DISPLAY") != NULL)
		fprintf(stderr, "cider-displaylink started link=%p interval=%lluns callback=%p\n",
				displayLink, (unsigned long long) cider_link_interval_ns(displayLink),
				(void *) state->callback);
	return kCVReturnSuccess;
}

CVReturn CVDisplayLinkStop(CVDisplayLinkRef displayLink)
{
	if (!displayLink)
		return kCVReturnInvalidArgument;

	CiderDisplayLinkState *state = cider_link_state(displayLink, NO);
	if (state == nil || !state->running)
		return kCVReturnSuccess;

	/* Join rather than detach: when Stop returns, no callback is in flight, which is what a caller
	 * tearing down the objects the callback touches is entitled to assume. */
	state->running = 0;
	pthread_join(state->thread, NULL);
	state->thread = NULL;
	return kCVReturnSuccess;
}

Boolean CVDisplayLinkIsRunning(CVDisplayLinkRef displayLink)
{
	if (!displayLink)
		return false;

	CiderDisplayLinkState *state = cider_link_state(displayLink, NO);
	return state != nil && state->running != 0;
}

void CVDisplayLinkRelease(CVDisplayLinkRef displayLink)
{
	NSMutableDictionary* self = (NSMutableDictionary*) displayLink;
	[self release];
}

CVReturn CVDisplayLinkSetOutputCallback(CVDisplayLinkRef displayLink, CVDisplayLinkOutputCallback callback, void *userInfo)
{
	if (!displayLink)
		return kCVReturnInvalidArgument;

	CiderDisplayLinkState *state = cider_link_state(displayLink, YES);
	state->callback = callback;
	state->userInfo = userInfo;
	if (getenv("CIDER_TRACE_DISPLAY") != NULL)
		fprintf(stderr, "cider-displaylink callback set link=%p fn=%p\n", displayLink,
				(void *) callback);
	return kCVReturnSuccess;
}

/*
 * WHICH DISPLAY THE LINK FOLLOWS. There is one display here and the link is a timer rather than a
 * real vertical blank, so the answer is success and nothing else. An application that asks for a
 * display link at all needs this to LINK: MoneyMoney does, and dyld stops the process for it.
 */
CVReturn CVDisplayLinkSetCurrentCGDisplay(CVDisplayLinkRef displayLink, CGDirectDisplayID displayID)
{
	if (!displayLink)
		return kCVReturnInvalidArgument;
	return kCVReturnSuccess;
}

CVReturn CVDisplayLinkSetCurrentCGDisplayFromOpenGLContext(CVDisplayLinkRef displayLink, CGLContextObj cglContext, CGLPixelFormatObj cglPixelFormat)
{
	if (!displayLink)
		return kCVReturnInvalidArgument;

	NSArray *windowArray = [[NSClassFromString(@"NSApplication") sharedApplication] windows];
	if (!windowArray)
		return kCVReturnError;

	for (NSWindow* window in windowArray)
	{
		CGWindow* cgw = [window cider_platformWindow];
		CGLContextObj ctxt = [cgw cglContext];
		if (ctxt == cglContext)
		{
			CGDirectDisplayID displayID = [window.screen cgDirectDisplayID];
			NSMutableDictionary* self = (NSMutableDictionary*) displayLink;

			[self setObject: @[[NSNumber numberWithInt: displayID]]
					forKey: kDirectDisplayArray];
			return kCVReturnSuccess;
		}
	}
	
	return kCVReturnError;
}

CGDirectDisplayID CVDisplayLinkGetCurrentCGDisplay( CVDisplayLinkRef CV_NONNULL displayLink )
{
	if (!displayLink)
		return kCVReturnInvalidArgument;

	NSMutableDictionary* self = (NSMutableDictionary*) displayLink;
	NSArray* ids = self[kDirectDisplayArray];

	if ([ids count] > 0)
		return (CGDirectDisplayID) [[ids firstObject] intValue];
	return kCGNullDirectDisplay;
}

CVReturn CVDisplayLinkCreateWithCGDisplay(
    CGDirectDisplayID displayID,
    CV_RETURNS_RETAINED_PARAMETER CVDisplayLinkRef CV_NULLABLE * CV_NONNULL displayLinkOut )
{
	if (displayID == kCGNullDirectDisplay)
		return kCVReturnInvalidArgument;

	NSMutableDictionary* self = [[NSMutableDictionary alloc] init];
	[self setObject: @[ [NSNumber numberWithInt: displayID] ]
			forKey: @"CGDirectDisplay"];

	*displayLinkOut = (CVDisplayLinkRef) self;
	return kCVReturnSuccess;
}

CVTime CVDisplayLinkGetNominalOutputVideoRefreshPeriod( CVDisplayLinkRef CV_NONNULL displayLink )
{
	CVTime time = { 0, 0, kCVTimeIsIndefinite };
	CGDirectDisplayID displayId = CVDisplayLinkGetCurrentCGDisplay(displayLink);
	if (displayId == kCGNullDirectDisplay)
		return time;

	CGDisplayModeRef mode = CGDisplayCopyDisplayMode(displayId);
	if (!mode)
		return time;

	double rate = CGDisplayModeGetRefreshRate(mode);
	if (rate < 1.0)
		rate = 60.0;

	time.flags = 0;
	time.timeValue = 1.0;
	time.timeScale = rate;

	CGDisplayModeRelease(mode);
	return time;
}
