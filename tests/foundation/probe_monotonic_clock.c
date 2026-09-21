/* DOES CLOCK_MONOTONIC EVER GO BACKWARDS?
 *
 * It did. libc derives CLOCK_MONOTONIC as gettimeofday() minus kern.boottime, and boottime was
 * recomputed per call as now minus sysinfo().uptime, which reports WHOLE SECONDS. The two floors
 * stepped at different moments, so boottime alternated between two values one second apart and the
 * clock jumped with it: a timed loop measured a NEGATIVE elapsed time of -0.857 s for work that
 * took 0.156 s. Task #251.
 *
 * Sampling in a tight loop and counting BACKWARD STEPS is the direct question. Comparing two clocks
 * over an interval is not: a clock that jumps forward and back within that interval reads correct
 * at both ends.
 *
 * THE CONTROL FAILS BY CONSTRUCTION, because a zero from a detector nobody has seen fire is not
 * evidence. A synthetic sequence with ONE planted backward step is fed to the same counter, and it
 * must report exactly 1. CLOCK_REALTIME is sampled too, but only as an observation: it is normally
 * monotonic as well, so a zero from it proves nothing either way.
 *
 * Prints and always exits 0: a measurement, not a suite case.
 */
#include <stdio.h>
#include <time.h>

#define SAMPLES 300000

static long long nsec(struct timespec ts) {
	return (long long) ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

static void sweep(const char *label, clockid_t clk, int assertMonotonic) {
	struct timespec ts;
	long long prev, now, worst = 0;
	int back = 0, i;

	clock_gettime(clk, &ts);
	prev = nsec(ts);
	for (i = 1; i < SAMPLES; i++) {
		clock_gettime(clk, &ts);
		now = nsec(ts);
		if (now < prev) {
			back++;
			if (now - prev < worst) worst = now - prev;
		}
		prev = now;
	}
	printf("PROBE %-18s backward=%-6d of %d   worst=%lld ns   %s\n", label, back, SAMPLES - 1,
	       worst, assertMonotonic ? (back == 0 ? "ok" : "NOT MONOTONIC") : "(control, may step)");
	fflush(stdout);
}

/* The same counting rule as sweep(), over a sequence with one planted backward step. */
static void plantedStep(void) {
	long long seq[5] = {1000, 2000, 3000, 2500, 4000};
	long long prev = seq[0], worst = 0;
	int back = 0, i;

	for (i = 1; i < 5; i++) {
		if (seq[i] < prev) {
			back++;
			if (seq[i] - prev < worst) worst = seq[i] - prev;
		}
		prev = seq[i];
	}
	printf("PROBE %-18s backward=%-6d of %d        worst=%lld ns   %s\n", "CONTROL planted", back, 4,
	       worst, (back == 1 && worst == -500) ? "ok, the detector fires" : "BROKEN DETECTOR");
	fflush(stdout);
}

int main(void) {
	plantedStep();
	sweep("CLOCK_MONOTONIC", CLOCK_MONOTONIC, 1);
	sweep("CLOCK_REALTIME", CLOCK_REALTIME, 0);
	return 0;
}
