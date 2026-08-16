/*
 * Does the run loop corrupt the heap on its own.
 *
 * LibreOffice dies about twenty seconds in with a heap the allocator refuses to walk, and the abort
 * always lands in the same place: a dispatch worker thread running CoreFoundation
 * __CFRunLoopTimeoutCancel, which is the cancel handler for the source CFRunLoopRunInMode creates
 * for its own timeout. That path runs once per run loop pass, and this backend pumps sixty times a
 * second, so the application hits it thousands of times before it dies.
 *
 * The application is not needed to ask the question. This does nothing but enter and leave the run
 * loop with a short timeout, which is exactly the create, cancel and free cycle above. If the heap
 * breaks here, a thirty line program reproduces a runtime bug that currently needs a word processor
 * and twenty seconds; if it does not, the corruption belongs to something LibreOffice does and this
 * says so just as clearly.
 *
 * Run it with MallocCheckHeapStart=1 MallocCheckHeapEach=20 MallocErrorAbort=1 so the allocator
 * checks itself, which is what turns silent damage into an abort at a known moment.
 */
#import <CoreFoundation/CoreFoundation.h>
#import <Foundation/Foundation.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>

#import <dispatch/dispatch.h>
#import <pthread.h>

/*
 * THE SAME CYCLE WITHOUT CoreFoundation.
 *
 * CFRunLoopRunInMode creates a dispatch timer source per pass, gives it a context, a cancel handler
 * that frees that context, then cancels and releases it. The crash lands in that free. This does
 * only that, so if the count of cancel handlers does not match the count of sources, or the free
 * faults, the fault belongs to libdispatch and not to the run loop or the application.
 */
static _Atomic unsigned long cancels;

struct probe_context {
	dispatch_source_t ds;
	unsigned long serial;
	unsigned char canary[16];
};

static void probe_cancel(void *arg)
{
	struct probe_context *context = (struct probe_context *) arg;

	/* A CANARY, so a second call on the same context is distinguishable from a first. */
	for (int i = 0; i < 16; i++) {
		if (context->canary[i] != 0x5A) {
			fprintf(stderr, "TIMEOUT_PROBE cancel serial=%lu canary=BROKEN  <-- freed already\n",
				context->serial);
			fflush(stderr);
			return;
		}
	}
	memset(context->canary, 0, sizeof(context->canary));
	cancels++;
	dispatch_release(context->ds);
	free(context);
}

static int run_source_cycle(int rounds)
{
	printf("TIMEOUT_PROBE sources rounds=%d\n", rounds);
	fflush(stdout);
	dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);

	for (int i = 0; i < rounds; i++) {
		struct probe_context *context = calloc(1, sizeof(*context));
		memset(context->canary, 0x5A, sizeof(context->canary));
		context->serial = (unsigned long) i;

		dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
		dispatch_retain(timer);
		context->ds = timer;
		dispatch_set_context(timer, context);
		dispatch_source_set_event_handler_f(timer, NULL);
		dispatch_source_set_cancel_handler_f(timer, probe_cancel);
		dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 16 * 1000 * 1000),
			DISPATCH_TIME_FOREVER, 1000ULL);
		dispatch_resume(timer);
		dispatch_source_cancel(timer);
		dispatch_release(timer);

		if ((i + 1) % 500 == 0) {
			printf("TIMEOUT_PROBE sources made=%d cancelled=%lu\n", i + 1, cancels);
			fflush(stdout);
		}
	}
	/* The cancel handlers run on a worker thread, so give them a moment before counting. */
	usleep(500 * 1000);
	printf("TIMEOUT_PROBE_SOURCES_OK made=%d cancelled=%lu\n", rounds, cancels);
	fflush(stdout);
	return 0;
}

/*
 * WHAT EACH THREAD BELIEVES ITS STACK IS.
 *
 * The malloc error path collects a backtrace before printing, and that walker validates every frame
 * against pthread_get_stackaddr_np and pthread_get_stacksize_np. On a thread whose stack was not
 * allocated by pthread, which is every guest thread here because mldr allocates the Darwin stack and
 * jumps to it, those bounds can be anything. If they are wrong the walker follows a chain into
 * unmapped memory and the process dies REPORTING an error instead of reporting it.
 */
static void report_stack_bounds(const char *who)
{
	pthread_t self = pthread_self();
	void *top = pthread_get_stackaddr_np(self);
	size_t size = pthread_get_stacksize_np(self);
	uintptr_t local = (uintptr_t) &self;
	int inside = (local <= (uintptr_t) top) && (local >= ((uintptr_t) top - size));

	fprintf(stderr, "TIMEOUT_PROBE stack %-10s top=%p size=%zu local=%p inside=%s\n", who, top,
		size, (void *) local, inside ? "yes" : "NO   <-- bounds are wrong for this thread");
	fflush(stderr);
}

int main(int argc, const char **argv)
{
	if (argc > 1 && strcmp(argv[1], "bounds") == 0) {
		report_stack_bounds("main");
		dispatch_semaphore_t done = dispatch_semaphore_create(0);
		dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
			report_stack_bounds("worker");
			dispatch_semaphore_signal(done);
		});
		dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5000000000ULL));
		printf("TIMEOUT_PROBE_BOUNDS_OK\n");
		fflush(stdout);
		return 0;
	}
	if (argc > 1 && strcmp(argv[1], "sources") == 0) {
		return run_source_cycle((argc > 2) ? atoi(argv[2]) : 2000);
	}
	int seconds = (argc > 1) ? atoi(argv[1]) : 30;
	double timeout = (argc > 2) ? atof(argv[2]) : 0.016;

	printf("TIMEOUT_PROBE start seconds=%d timeout=%.3f\n", seconds, timeout);
	fflush(stdout);

	CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + seconds;
	unsigned long passes = 0;

	while (CFAbsoluteTimeGetCurrent() < deadline) {
		@autoreleasepool {
			CFAbsoluteTime before = CFAbsoluteTimeGetCurrent();
			SInt32 result = CFRunLoopRunInMode(kCFRunLoopDefaultMode, timeout, true);
			CFAbsoluteTime spent = CFAbsoluteTimeGetCurrent() - before;
			passes++;
			/* THE FIRST FEW PASSES, unconditionally. A run loop that never returns prints nothing
			 * at all under a modulus, which reads exactly like a probe that failed to start. */
			if (passes <= 5) {
				printf("TIMEOUT_PROBE pass=%lu result=%d spent=%.3fs\n", passes, (int) result,
					(double) spent);
				fflush(stdout);
			}
			if (passes % 500 == 0) {
				printf("TIMEOUT_PROBE passes=%lu last=%d\n", passes, (int) result);
				fflush(stdout);
			}
		}
	}

	printf("TIMEOUT_PROBE_OK passes=%lu\n", passes);
	fflush(stdout);
	return 0;
}
