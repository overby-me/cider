// DOES A BLOCK ON THE MAIN QUEUE COST MEMORY THAT IS NEVER GIVEN BACK.
//
// An idle LibreOffice grows about 7 MB/s under this backend after the event pump was given an
// autorelease pool, and everything visible has been ruled out: not the view cache, not the buffer
// dumps, not our surfaces, not the brk heap, and NOT the main queue drain itself -- turning the
// drain off makes it worse, because the blocks pile up unrun.
//
// That leaves two suspects and they need separating: the blocks LibreOffice queues, or this fork of
// libdispatch leaking the CONTINUATION of every block it runs. This program is the second one on
// its own. It has no window, no application object and no LibreOffice: it queues trivial blocks on
// the main queue and drains them exactly the way the backend does, and prints its own resident size
// as it goes.
//
// If resident size climbs here, the leak is in libdispatch or the allocator under it, and every
// application that uses dispatch_async pays it. If it does not, the blocks LibreOffice queues are
// where to look next.
#import <Foundation/Foundation.h>
#include <dispatch/dispatch.h>
#include <stdio.h>

// The same entry point the Wayland backend calls once per pass through the event pump.
void _dispatch_main_queue_callback_4CF(void *msg);

static long resident_kb(void)
{
	FILE *status = fopen("/proc/self/status", "r");

	if (status == NULL) {
		return -1;
	}

	char line[256];
	long kb = -1;

	while (fgets(line, sizeof(line), status) != NULL) {
		if (sscanf(line, "VmRSS: %ld kB", &kb) == 1) {
			break;
		}
	}
	fclose(status);
	return kb;
}

int main(int argc, const char **argv)
{
	const int rounds = (argc > 1) ? atoi(argv[1]) : 20;
	const int per_round = (argc > 2) ? atoi(argv[2]) : 20000;

	printf("DISPATCH_PROBE start rounds=%d per_round=%d rss_kb=%ld\n", rounds, per_round,
	       resident_kb());
	fflush(stdout);

	for (int round = 1; round <= rounds; round++) {
		@autoreleasepool {
			for (int i = 0; i < per_round; i++) {
				dispatch_async(dispatch_get_main_queue(), ^{
					// Deliberately trivial. Anything allocated in here would be the
					// program's own leak and would tell us nothing about the queue.
				});
				// DRAIN OFTEN, the way the pump does: once per pass, with a handful of
				// blocks queued between passes. Queueing twenty thousand and draining once
				// would measure the QUEUE rather than the machinery that runs it.
				if ((i % 16) == 0) {
					_dispatch_main_queue_callback_4CF(NULL);
				}
			}
			_dispatch_main_queue_callback_4CF(NULL);
		}
		printf("DISPATCH_PROBE round=%d blocks=%d rss_kb=%ld\n", round, round * per_round,
		       resident_kb());
		fflush(stdout);
	}

	printf("DISPATCH_PROBE_OK\n");
	return 0;
}
