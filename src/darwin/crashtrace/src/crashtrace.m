/*
 * A CRASH HANDLER THAT IS ALREADY THERE WHEN THE FIRST INITIALISER RUNS.
 *
 * CIDER_TRACE_CRASH in the Wayland backend cannot see a fault that happens before AppKit asks for a
 * display, and that is exactly where iTerm2 3.6.10 dies: SIGSEGV inside an image initialiser, with
 * the loader finished and the Objective-C runtime still starting up. Nothing was printed, because
 * the handler that would print it had not been loaded yet.
 *
 * This dylib exists to be inserted:
 *
 *     DYLD_INSERT_LIBRARIES=/usr/lib/cider-crashtrace.dylib CIDER_TRACE_CRASH=1 <app>
 *
 * An inserted library is initialised BEFORE the main executable and before every framework it
 * links, so the handler is in place for the whole of startup. It prints the signal, the fault
 * address and the frames, then restores the default and re-raises so the core is still written and
 * nothing downstream changes.
 *
 * The two details that make it work are the same ones the backend copy needed. It runs on an
 * ALTERNATE STACK, because a stack overflow leaves no room for a handler on the faulting thread.
 * And the frames come from the FAULT CONTEXT rather than from backtrace(), which walks the handler
 * stack: the frame pointer chain is walked by hand from the interrupted register state, and the
 * word at the stack pointer is included first, because a function that has not pushed a frame
 * pointer yet (objc_msgSend, most of libc) would otherwise be missing from the chain.
 */

#include <execinfo.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ucontext.h>
#include <unistd.h>
#include <mach-o/dyld.h>

/* The handler that was there before this one, per signal, so a runtime that USES a signal keeps
 * working. Darling delivers some faults through SIGSEGV on purpose. */
static struct sigaction cider_previous[NSIG];

static void cider_crashtrace_handler(int sig, siginfo_t *info, void *uap)
{
	void *frames[64];
	int count = 0;
	ucontext_t *uc = (ucontext_t *) uap;
	uint64_t rip = 0, rbp = 0, rsp = 0;

	if (uc != NULL && uc->uc_mcontext != NULL) {
		rip = uc->uc_mcontext->__ss.__rip;
		rbp = uc->uc_mcontext->__ss.__rbp;
		rsp = uc->uc_mcontext->__ss.__rsp;
	}
	if (rip != 0) {
		frames[count++] = (void *) rip;
	}
	if (rsp != 0 && (rsp & 7) == 0) {
		uint64_t top = *(uint64_t *) rsp;

		if (top > 0x1000 && top != rip) {
			frames[count++] = (void *) top;
		}
	}

	uint64_t previous = 0;

	while (count < 64 && rbp != 0 && rbp > previous && (rbp & 7) == 0) {
		uint64_t next = ((uint64_t *) rbp)[0];
		uint64_t ret = ((uint64_t *) rbp)[1];

		if (ret == 0) {
			break;
		}
		frames[count++] = (void *) ret;
		previous = rbp;
		rbp = next;
	}

	char head[220];
	int len = snprintf(head, sizeof head,
		"\ncider CRASHTRACE signal=%d code=%d addr=%p rip=%p rsp=%p frames=%d\n", sig,
		info != NULL ? info->si_code : 0, info != NULL ? info->si_addr : NULL, (void *) rip,
		(void *) rsp, count);

	write(2, head, (size_t) len);
	backtrace_symbols_fd(frames, count, 2);

	/*
	 * CHAIN, DO NOT SWALLOW AND DO NOT FORCE THE DEFAULT.
	 *
	 * Darling delivers some faults through SIGSEGV deliberately, and a handler that restores the
	 * default and re-raises turns a signal the runtime was going to handle into a kill. The first
	 * version of this file did exactly that and killed the shell helper mid syscall. So the
	 * previous handler runs after the print, and the default is only taken when there was none.
	 */
	struct sigaction *prev = &cider_previous[sig];

	if ((prev->sa_flags & SA_SIGINFO) && prev->sa_sigaction != NULL) {
		prev->sa_sigaction(sig, info, uap);
		return;
	}
	if (prev->sa_handler != NULL && prev->sa_handler != SIG_DFL && prev->sa_handler != SIG_IGN) {
		prev->sa_handler(sig);
		return;
	}

	struct sigaction dfl;

	memset(&dfl, 0, sizeof dfl);
	dfl.sa_handler = SIG_DFL;
	sigaction(sig, &dfl, NULL);
	raise(sig);
}

__attribute__((constructor)) static void cider_crashtrace_install(void)
{
	const char *want = getenv("CIDER_TRACE_CRASH");

	if (want == NULL) {
		return;
	}

	/*
	 * ONE PROCESS, NOT EVERY PROCESS. An inserted library is inserted into everything the prefix
	 * runs, and the shell helper that starts the application is one of them. CIDER_TRACE_CRASH can
	 * name a substring of the executable path; 1 means every process, which is what it used to do.
	 */
	char path[4096];
	uint32_t size = sizeof path;
	int have_path = (_NSGetExecutablePath(path, &size) == 0);

	if (!have_path) {
		path[0] = 0;
	}
	fprintf(stderr, "cider-crashtrace considering %s\n", path[0] != 0 ? path : "(unknown)");
	fflush(stderr);
	if (strcmp(want, "1") != 0 && have_path && strstr(path, want) == NULL) {
		return;
	}

	static char alt[SIGSTKSZ * 4];
	stack_t ss;

	memset(&ss, 0, sizeof ss);
	ss.ss_sp = alt;
	ss.ss_size = sizeof alt;
	sigaltstack(&ss, NULL);

	struct sigaction sa;

	memset(&sa, 0, sizeof sa);
	sa.sa_sigaction = cider_crashtrace_handler;
	sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
	sigemptyset(&sa.sa_mask);
	sigaction(SIGSEGV, &sa, &cider_previous[SIGSEGV]);
	sigaction(SIGBUS, &sa, &cider_previous[SIGBUS]);
	sigaction(SIGILL, &sa, &cider_previous[SIGILL]);
	sigaction(SIGFPE, &sa, &cider_previous[SIGFPE]);
	sigaction(SIGTRAP, &sa, &cider_previous[SIGTRAP]);
	/* ABORT TOO, because an application that calls abort leaves exactly the same trace as one that
	 * was killed from outside: no message, no exception, and a shell status that says nothing about
	 * which of the two it was. The frames say it in one line. */
	sigaction(SIGABRT, &sa, &cider_previous[SIGABRT]);

	char me[4096];
	uint32_t mysize = sizeof me;

	if (_NSGetExecutablePath(me, &mysize) != 0) {
		me[0] = 0;
	}
	fprintf(stderr, "cider-crashtrace installed in %s\n", me);
	fflush(stderr);
}
