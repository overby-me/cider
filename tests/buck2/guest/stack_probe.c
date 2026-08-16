// What pthread tells a guest program about its own stack.
//
// WTF's StackBounds dies with both members null, which is the default-constructed value,
// and the two ways to get a StackBounds on Darwin both come from here:
//
//   currentThreadStackBoundsInternal() -> pthread_main_np() ? pthread_get_stackaddr_np +
//       getrlimit(RLIMIT_STACK) : newThreadStackBounds(pthread_self())
//   newThreadStackBounds(t)            -> pthread_get_stackaddr_np(t), pthread_get_stacksize_np(t)
//
// So this measures exactly those four, on the main thread and on a spawned one. A null
// stackaddr or a zero stacksize on either is the answer; both being sane means the problem
// is upstream of pthread and the theory needs replacing rather than refining.
//
// Plain C against libSystem, no Foundation, so nothing above the C library can be blamed.

#include <pthread.h>
#include <stdio.h>
#include <sys/resource.h>
#include <sys/sysctl.h>
#include <sys/types.h>

static void report(const char *who) {
	pthread_t self = pthread_self();
	void *addr = pthread_get_stackaddr_np(self);
	size_t size = pthread_get_stacksize_np(self);
	printf("STACK_PROBE %-6s main_np=%d stackaddr=%p stacksize=%zu bound=%p\n",
		who, pthread_main_np(), addr, size,
		addr ? (void *) ((char *) addr - size) : NULL);
	fflush(stdout);
}

static void *worker(void *arg) {
	(void) arg;
	report("worker");
	return NULL;
}

int main(int argc, char **argv, char **envp, char **apple) {
	// apple[] is the fourth argument to main in the Darwin ABI, and it is how the kernel
	// (here, mldr) hands libpthread the main thread's stack. Printing it says whether the
	// value survives the trip through dyld or is lost on the way.
	for (int i = 0; apple && apple[i]; i++)
		printf("STACK_PROBE apple[%d]=%s\n", i, apple[i]);
	fflush(stdout);

	struct rlimit rl;
	rl.rlim_cur = 0;
	int rc = getrlimit(RLIMIT_STACK, &rl);
	printf("STACK_PROBE rlimit rc=%d rlim_cur=%llu\n", rc, (unsigned long long) rl.rlim_cur);
	fflush(stdout);

	report("main");

	// The main thread's stackaddr comes from __pthread_init, which asks
	// parse_main_stack_params(apple) first and falls back to
	// sysctl(CTL_KERN, KERN_USRSTACK), and only if THAT fails to the USRSTACK64 constant.
	// A main stackaddr of 0 with a DFLSSIZ-sized stack says the fallback ran and the
	// sysctl answered, so what it answered WITH is the next thing to know.
	void *usrstack = (void *) -1;
	size_t len = sizeof(usrstack);
	int mib[] = {CTL_KERN, KERN_USRSTACK};
	int src = sysctl(mib, 2, &usrstack, &len, NULL, 0);
	printf("STACK_PROBE usrstack rc=%d len=%zu value=%p\n", src, len, usrstack);
	fflush(stdout);

	pthread_t t;
	if (pthread_create(&t, NULL, worker, NULL) == 0)
		pthread_join(t, NULL);
	else
		printf("STACK_PROBE worker pthread_create failed\n");

	printf("STACK_PROBE_DONE\n");
	fflush(stdout);
	return 0;
}
