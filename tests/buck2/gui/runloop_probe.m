// Does -[NSRunLoop runMode:beforeDate:] honour its date when nothing is attached to the loop?
//
// It is the question underneath an application that draws its first frame and then never draws
// again. NSApplication redisplays windows BETWEEN events: -nextEventMatchingMask: calls
// -_displayAllWindowsIfNeeded and then asks the display for an event, and NSDisplay implements
// that wait as -[NSRunLoop runMode:beforeDate:]. If that call does not return when the date
// passes, the loop never comes back around, nothing is ever redisplayed, and the window keeps its
// first frame forever while the process stays perfectly alive.
//
// LibreOffice under this backend entered that method exactly ONCE and never returned, with an
// upper bound of 16 ms already applied to the date. This probe asks the same thing in three lines
// so the answer does not depend on an 800 MB application.
//
// A WATCHDOG THREAD, because the failure being tested for is a hang: a probe that simply calls the
// method would reproduce the hang rather than report it, and a hung probe and a crashed one look
// the same to a harness.
#import <Foundation/Foundation.h>
#import <pthread.h>
#import <stdio.h>
#import <stdlib.h>
#import <unistd.h>

static void *watchdog(void *arg)
{
	unsigned seconds = (unsigned) (uintptr_t) arg;
	sleep(seconds);
	printf("RUNLOOP_PROBE VERDICT=HUNG  runMode:beforeDate: did not return within %us\n", seconds);
	fflush(stdout);
	// _exit rather than exit: the point is to stop now, not to run atexit handlers through a
	// runtime that is currently wedged.
	_exit(2);
	return NULL;
}

int main(int argc, const char **argv)
{
	printf("RUNLOOP_PROBE start\n");
	fflush(stdout);

	pthread_t t;
	pthread_create(&t, NULL, watchdog, (void *) (uintptr_t) 20);
	pthread_detach(t);

	@autoreleasepool {
		NSRunLoop *loop = [NSRunLoop currentRunLoop];
		printf("RUNLOOP_PROBE loop=%p\n", loop);
		fflush(stdout);

		// Three waits of a tenth of a second. Three rather than one because a first call that
		// returns and a second that does not is a different bug from one that never returns, and
		// the elapsed times distinguish them.
		for (int i = 0; i < 3; i++) {
			NSDate *start = [NSDate date];
			NSDate *until = [NSDate dateWithTimeIntervalSinceNow: 0.1];
			[loop runMode: NSDefaultRunLoopMode beforeDate: until];
			double elapsed = -[start timeIntervalSinceNow];
			printf("RUNLOOP_PROBE wait=%d requested=0.100 elapsed=%.3f%s\n", i, elapsed,
				elapsed > 1.0 ? "   <-- OVERSHOT" : "");
			fflush(stdout);
		}

		// And the shape NSDisplay actually uses when the application is idle: a date far in the
		// future. This is the one that must NOT be reached in a working event loop, so it is
		// tested last and the watchdog is what reports it.
		printf("RUNLOOP_PROBE now trying distantFuture, watchdog will report a hang\n");
		fflush(stdout);
		NSDate *start = [NSDate date];
		[loop runMode: NSDefaultRunLoopMode beforeDate: [NSDate distantFuture]];
		printf("RUNLOOP_PROBE distantFuture returned after %.3f\n", -[start timeIntervalSinceNow]);
		fflush(stdout);
	}

	printf("RUNLOOP_PROBE_OK\n");
	fflush(stdout);
	return 0;
}
