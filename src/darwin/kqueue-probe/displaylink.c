/*
 * Does a display link actually call back?
 *
 * WHY: CVDisplayLinkSetOutputCallback discarded the callback, CVDisplayLinkStart started nothing
 * and CVDisplayLinkIsRunning answered YES, so an application that draws from the link was told
 * registered, started and running and never got a frame. That is now implemented as a timer, and
 * an implementation nothing exercises is worth no more than the stub it replaced. Task #239.
 *
 * IT IS ALSO THE CONTROL FOR THE TRACE. CIDER_TRACE_DISPLAY printed nothing for iTerm2 and nothing
 * for MoneyMoney, and a silence with no control behind it says nothing at all. This probe makes the
 * calls, so if the trace stays silent here the trace is broken rather than the application innocent.
 *
 * A PROBE, NOT A TEST CASE: it prints what it saw and exits 0 either way.
 */

#include <CoreVideo/CVDisplayLink.h>
#include <stdio.h>
#include <unistd.h>

static volatile int g_fires;

static CVReturn on_frame(CVDisplayLinkRef link, const CVTimeStamp *now,
	const CVTimeStamp *output, CVOptionFlags flagsIn, CVOptionFlags *flagsOut, void *context)
{
	(void) link; (void) flagsIn; (void) flagsOut;
	if (g_fires == 0)
		printf("displaylink-probe first callback hostTime=%llu videoTime=%lld ahead=%lld context=%p\n",
			(unsigned long long) now->hostTime, (long long) now->videoTime,
			(long long) (output->videoTime - now->videoTime), context);
	g_fires++;
	return kCVReturnSuccess;
}

int main(void)
{
	setvbuf(stdout, NULL, _IOLBF, 0);

	CVDisplayLinkRef link = NULL;
	CVReturn err = CVDisplayLinkCreateWithActiveCGDisplays(&link);
	printf("displaylink-probe create err=%d link=%p\n", (int) err, (void *) link);
	if (err != kCVReturnSuccess || link == NULL) {
		printf("displaylink-probe done verdict=NO-LINK\n");
		return 0;
	}

	int marker = 0;
	err = CVDisplayLinkSetOutputCallback(link, on_frame, &marker);
	printf("displaylink-probe setcallback err=%d running_before_start=%d\n", (int) err,
		(int) CVDisplayLinkIsRunning(link));

	err = CVDisplayLinkStart(link);
	printf("displaylink-probe start err=%d running=%d\n", (int) err,
		(int) CVDisplayLinkIsRunning(link));

	sleep(2);

	int after_two_seconds = g_fires;
	CVDisplayLinkStop(link);
	printf("displaylink-probe stop running=%d\n", (int) CVDisplayLinkIsRunning(link));

	sleep(1);
	int after_stop = g_fires;

	/* A LINK THAT KEEPS FIRING AFTER STOP IS ALSO BROKEN, and the old stub would have passed a
	 * test that only counted callbacks. */
	printf("displaylink-probe fires_in_2s=%d fires_after_stop=%d verdict=%s\n",
		after_two_seconds, after_stop - after_two_seconds,
		after_two_seconds == 0 ? "NEVER-FIRED"
			: (after_stop != after_two_seconds ? "FIRED-AFTER-STOP" : "OK"));
	printf("displaylink-probe done\n");
	return 0;
}
