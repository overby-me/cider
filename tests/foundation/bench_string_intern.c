/* WHAT THIS COSTS. Interning short strings so they are immortal (task #249) puts a lock, a hash and
 * a set lookup into CFStringCreate, which is one of the hottest paths in the runtime. The memory
 * cost was measured on three applications; this measures the CPU cost that measurement did not
 * cover. Run it with CIDER_IMMORTAL_SHORT_STRINGS unset and again with 0, and compare.
 *
 * TWO CONTROLS, because a timing that cannot fail proves nothing:
 *   LONG    strings too long to qualify. Their number must NOT move between the two runs; if it
 *           does, the machine moved and the short number means nothing.
 *   SHARED  asks whether two equal short strings come back as ONE pointer. If interning is silently
 *           not running, both runs time the same and the honest conclusion would be "no cost",
 *           which is the wrong conclusion for the right-looking reason.
 *
 * Prints and always exits 0, so it is a measurement and not a suite case.
 */
#include <CoreFoundation/CoreFoundation.h>

#include <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <time.h>

#define ITERATIONS 400000
#define SHORT_WIDTH 16
#define LONG_WIDTH 80

/* THREE CLOCKS, because one of them lies here. CLOCK_MONOTONIC in this guest has returned a
 * SMALLER value later in the same thread, which showed up as a negative elapsed time. A number
 * from a clock that runs backwards is not a slow result or a fast one, it is no result, so read
 * all three and trust only what they agree on. */
static double monotonicNow(void) {
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (double) ts.tv_sec + (double) ts.tv_nsec / 1e9;
}

static double wallNow(void) {
	struct timeval tv;

	gettimeofday(&tv, NULL);
	return (double) tv.tv_sec + (double) tv.tv_usec / 1e6;
}

static double machNow(void) {
	static mach_timebase_info_data_t timebase = {0, 0};

	if (timebase.denom == 0) mach_timebase_info(&timebase);
	if (timebase.denom == 0) return 0.0;
	return (double) mach_absolute_time() * (double) timebase.numer / (double) timebase.denom / 1e9;
}

static void timeCreates(const char *label, const char *pool, size_t width, int distinct) {
	double startMono = monotonicNow();
	double startWall = wallNow();
	double startMach = machNow();
	clock_t startCpu = clock();
	int i;

	for (i = 0; i < ITERATIONS; i++) {
		CFStringRef s = CFStringCreateWithCString(kCFAllocatorDefault, pool + (size_t) (i % distinct) * width,
		                                          kCFStringEncodingASCII);

		if (s != NULL) CFRelease(s);
	}
	printf("BENCH %-12s distinct=%-8d mono %7.3f  wall %7.3f  mach %7.3f  cpu %7.3f s for %d\n", label, distinct,
	       monotonicNow() - startMono, wallNow() - startWall, machNow() - startMach,
	       (double) (clock() - startCpu) / (double) CLOCKS_PER_SEC, ITERATIONS);
	fflush(stdout);
}

int main(void) {
	char *shortPool = malloc((size_t) ITERATIONS * SHORT_WIDTH);
	char *longPool = malloc((size_t) ITERATIONS * LONG_WIDTH);
	CFStringRef a;
	CFStringRef b;
	int i;

	if (shortPool == NULL || longPool == NULL) {
		printf("BENCH out of memory\n");
		return 0;
	}
	for (i = 0; i < ITERATIONS; i++) {
		snprintf(shortPool + (size_t) i * SHORT_WIDTH, SHORT_WIDTH, "v%06d", i);
		snprintf(longPool + (size_t) i * LONG_WIDTH, LONG_WIDTH,
		         "a string far past any plausible intern limit, number %08d", i);
	}

	a = CFStringCreateWithCString(kCFAllocatorDefault, "value1", kCFStringEncodingASCII);
	b = CFStringCreateWithCString(kCFAllocatorDefault, "value1", kCFStringEncodingASCII);
	printf("BENCH SHARED                %s   a=%p b=%p\n", (a == b) ? "yes, interning is ON " : "no, interning is OFF", a, b);
	fflush(stdout);

	timeCreates("SHORT hit", shortPool, SHORT_WIDTH, 16);
	timeCreates("SHORT miss", shortPool, SHORT_WIDTH, ITERATIONS);
	timeCreates("LONG control", longPool, LONG_WIDTH, ITERATIONS);

	if (a != NULL) CFRelease(a);
	if (b != NULL) CFRelease(b);
	return 0;
}
