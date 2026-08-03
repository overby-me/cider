// Does libdispatch actually run work in the guest?
//
// libdispatch ships in the prefix as usr/lib/system/libdispatch.dylib and nothing had ever
// executed a line of it. It is worth its own probe rather than being taken on trust because
// it is the one system library whose whole job is to create threads and hand work between
// them, which is exactly the machinery this port has had the most trouble with: the guest
// runs on the daemon's microthreads, and getting multithreading up at all needed duct-tape's
// two-phase init, while a null pthread_list_mlock once showed up as a silent SIGSEGV that
// looked like a scheduler bug.
//
// Four steps, from the one that needs no thread to the one that needs several, so a failure
// says WHICH layer broke rather than that dispatch is broken:
//
//   dispatch_once        no queue, no thread: just the atomic and the block
//   dispatch_sync        a queue, still on the calling thread
//   dispatch_async       a real handoff, joined with a semaphore
//   dispatch_apply       concurrent iterations on the global queue
//
// Self-contained on purpose, like sec_probe.c: no files, no network, no clock.
#include <dispatch/dispatch.h>
#include <stdatomic.h>
#include <stdio.h>
#include <unistd.h>

static int once_ran = 0;
static dispatch_once_t once_token;

int main(void) {
	int failures = 0;

	dispatch_once(&once_token, ^{
		once_ran++;
	});
	dispatch_once(&once_token, ^{
		once_ran++;
	});
	printf("DISPATCH_PROBE once ran=%d (expected 1)\n", once_ran);
	if (once_ran != 1)
		failures++;

	dispatch_queue_t q = dispatch_queue_create("org.darling.probe", DISPATCH_QUEUE_SERIAL);
	if (q == NULL) {
		printf("DISPATCH_PROBE queue=NULL\n");
		return 1;
	}
	printf("DISPATCH_PROBE queue=created\n");

	__block int sync_val = 0;
	dispatch_sync(q, ^{
		sync_val = 42;
	});
	printf("DISPATCH_PROBE sync val=%d (expected 42)\n", sync_val);
	if (sync_val != 42)
		failures++;

	// The real handoff: the block runs on a thread libdispatch made, and the semaphore is
	// what proves this thread saw the result rather than racing past it.
	__block pid_t async_tid = 0;
	dispatch_semaphore_t sem = dispatch_semaphore_create(0);
	dispatch_async(q, ^{
		async_tid = (pid_t)(long)pthread_self();
		dispatch_semaphore_signal(sem);
	});
	long waited = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW,
	                                                         10LL * NSEC_PER_SEC));
	printf("DISPATCH_PROBE async wait=%ld ran=%d (expected wait=0)\n", waited, async_tid != 0);
	if (waited != 0 || async_tid == 0)
		failures++;

	// Concurrency proper: N iterations across the global queue, counted atomically. The
	// count is the assertion; which thread ran which iteration is libdispatch's business.
	static atomic_int applied;
	atomic_store(&applied, 0);
	dispatch_apply(64, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),
	               ^(size_t i) {
		(void)i;
		atomic_fetch_add(&applied, 1);
	});
	int n = atomic_load(&applied);
	printf("DISPATCH_PROBE apply count=%d (expected 64)\n", n);
	if (n != 64)
		failures++;

	dispatch_release(sem);
	dispatch_release(q);

	printf("DISPATCH_PROBE_DONE failures=%d\n", failures);
	return failures != 0;
}
