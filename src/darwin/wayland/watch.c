/*
 * A write watchpoint on the window backing store.
 *
 * WHY THIS EXISTS. Every attempt to find what fills a window buffer has had to GUESS WHICH LAYER
 * TO INSTRUMENT, and each guess produced a trace that printed nothing. Three independent filters
 * inside the Onyx2D span writers agree that the rasteriser never touches a window sized surface;
 * CGBitmapContextGetData is never called and CGLayer is never created. Something writes those
 * pages and none of the obvious candidates does.
 *
 * A watchpoint needs no hypothesis. The mapping is made read only after it is cleared, the first
 * write faults, and the handler reports the instruction that faulted. dladdr turns that address
 * into a symbol and an image name, which says WHICH LIBRARY is writing without knowing in advance
 * that it would be that one.
 *
 * WHAT IT COSTS. Every distinct writing instruction takes one fault, and the page is restored to
 * writable afterwards, so the process keeps running at close to normal speed once the handful of
 * writers have been seen. It is diagnostic only and does nothing unless CIDER_WAYLAND_WATCH is set.
 */
/* ucontext is behind _XOPEN_SOURCE on Darwin, and unistd is what declares sysconf. Both have to
 * come before any header that might pull in the guarded declarations. */
#define _XOPEN_SOURCE 700
#include <unistd.h>

#include <dlfcn.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <ucontext.h>

/* One region at a time, which is all a diagnostic needs: the window being looked at. */
static void *watch_base;
static size_t watch_len;
static int watch_reported;
static int watch_installed;

/* The page size is asked for once rather than assumed, because restoring protection on the wrong
 * range would either miss the next write or unprotect the whole mapping. */
static size_t watch_page_size(void)
{
	static size_t cached;
	if (cached == 0) {
		long value = sysconf(_SC_PAGESIZE);
		cached = (value > 0) ? (size_t) value : 4096;
	}
	return cached;
}

static void cider_watch_handler(int signo, siginfo_t *info, void *context)
{
	void *fault = info ? info->si_addr : NULL;
	int mine = watch_base != NULL && fault >= watch_base &&
		(char *) fault < (char *) watch_base + watch_len;

	if (!mine) {
		/* Not our page. Restore the default disposition and let it happen again, which turns a
		 * genuine crash back into a genuine crash rather than hiding it inside this handler. */
		signal(signo, SIG_DFL);
		return;
	}

	/*
	 * THE FAULTING INSTRUCTION, which is the whole point. On Darwin the mcontext is a POINTER
	 * inside the ucontext, unlike Linux, and __rip is the program counter of the instruction that
	 * faulted rather than the one after it.
	 */
	unsigned long long pc = 0;
	ucontext_t *uc = (ucontext_t *) context;
	if (uc != NULL && uc->uc_mcontext != NULL) {
		pc = (unsigned long long) uc->uc_mcontext->__ss.__rip;
	}

	if (watch_reported < 12) {
		watch_reported++;
		Dl_info dli;
		memset(&dli, 0, sizeof(dli));
		const char *image = "?";
		const char *symbol = "?";
		unsigned long long offset = 0;
		if (pc != 0 && dladdr((void *) (uintptr_t) pc, &dli) != 0) {
			if (dli.dli_fname != NULL) {
				const char *slash = strrchr(dli.dli_fname, '/');
				image = slash ? slash + 1 : dli.dli_fname;
			}
			if (dli.dli_sname != NULL) {
				symbol = dli.dli_sname;
				offset = (unsigned long long) ((char *) (uintptr_t) pc - (char *) dli.dli_saddr);
			}
		}
		fprintf(stderr, "CIDER_WATCH write offset=%ld pc=0x%llx image=%s symbol=%s+%llu\n",
			(long) ((char *) fault - (char *) watch_base), pc, image, symbol, offset);
		fflush(stderr);
	}

	/* Let the write through: restore the whole region rather than one page, because the interest
	 * is in WHO writes first, not in counting every page. */
	mprotect(watch_base, watch_len, PROT_READ | PROT_WRITE);
}

void cider_wayland_watch_begin(void *base, size_t len)
{
	if (getenv("CIDER_WAYLAND_WATCH") == NULL || base == NULL || len == 0) {
		return;
	}

	if (!watch_installed) {
		struct sigaction sa;
		memset(&sa, 0, sizeof(sa));
		sa.sa_sigaction = cider_watch_handler;
		sa.sa_flags = SA_SIGINFO;
		sigemptyset(&sa.sa_mask);
		if (sigaction(SIGSEGV, &sa, NULL) != 0) {
			fprintf(stderr, "CIDER_WATCH install=FAILED\n");
			fflush(stderr);
			return;
		}
		if (sigaction(SIGBUS, &sa, NULL) != 0) {
			/* Not fatal: some systems report a protection fault as SIGBUS and some as SIGSEGV,
			 * and taking whichever one installs is better than requiring both. */
		}
		watch_installed = 1;
	}

	watch_base = base;
	watch_len = len;
	watch_reported = 0;

	size_t page = watch_page_size();
	if (((uintptr_t) base % page) != 0) {
		fprintf(stderr, "CIDER_WATCH skipped reason=unaligned base=%p\n", base);
		fflush(stderr);
		watch_base = NULL;
		return;
	}

	if (mprotect(base, len, PROT_READ) != 0) {
		fprintf(stderr, "CIDER_WATCH mprotect=FAILED\n");
		fflush(stderr);
		watch_base = NULL;
		return;
	}
	fprintf(stderr, "CIDER_WATCH armed base=%p len=%zu\n", base, len);
	fflush(stderr);
}
