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

#include <dlfcn.h>
#include <execinfo.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <sys/ucontext.h>
#include <unistd.h>
#include <mach-o/dyld.h>

/* The handler that was there before this one, per signal, so a runtime that USES a signal keeps
 * working. Darling delivers some faults through SIGSEGV on purpose. */
static struct sigaction cider_previous[NSIG];

/*
 * WHO CALLED EXIT, which a crash handler never sees.
 *
 * A process that leaves with status 0 has not crashed, so no signal handler fires and the log ends
 * mid sentence. Swift Publisher does exactly that a few seconds after Choose, and the two AppKit
 * ways out were both ruled out by tracing them: -[NSApplication terminate:] and -stop: are in the
 * deployed binary with prints at the top and neither ever printed.
 *
 * atexit runs on exit() and on a normal return from main, and NOT on _exit or abort, so a silent
 * exit after this is registered narrows to those two. The frames name the caller either way.
 */
/*
 * A STACK FROM INSIDE THE WAIT, on demand, without killing anything.
 *
 * The crash handler answers where a process DIED and the atexit handler answers who asked it to
 * leave. Neither can answer the question left over from Swift Publisher: a method that has not
 * returned after a minute, on a thread that is parked in recvmsg rather than spinning, with no
 * exception escaping and no service lookup outstanding. For that the only honest instrument is the
 * stack of the thread while it is still stuck.
 *
 * SIGUSR1 is handled and RESUMED, unlike every other signal here, so the process carries on and can
 * be sampled again a second later. Two samples a few seconds apart separate a slow walk through a
 * long list from a wait that will never end, which no single sample can do.
 */
static void cider_crashtrace_sample(int sig, siginfo_t *info, void *uap)
{
	/*
	 * A STACK FROM INSIDE THE WAIT, on demand, without killing anything.
	 *
	 * The crash handler answers where a process DIED and the atexit handler answers who asked it
	 * to leave. Neither can answer where a thread IS while it is still running, which is the
	 * question left by Swift Publisher: -[CCMainWindowController awakeFromNib] does not return and
	 * nothing crashes.
	 *
	 * IT WALKS RBP RATHER THAN CALLING backtrace(), for a measured reason: backtrace() answers 64
	 * frames from a libdispatch worker here and ZERO from the main thread, so the first version of
	 * this handler printed frames=0 three times and said nothing. The frame pointer walk below is
	 * the same one the crash handler uses, and that one has been producing correct stacks all
	 * along.
	 *
	 * SIGUSR1 is handled and RESUMED, unlike every other signal here, so the process carries on
	 * and can be sampled again. Two samples a few seconds apart separate a slow walk through a
	 * long list from a wait that will never end.
	 */
	void *frames[64];
	int count = 0;
	ucontext_t *uc = (ucontext_t *) uap;
	uint64_t rip = 0, rbp = 0, rsp = 0;

	(void) sig;
	(void) info;

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

	char head[160];
	int len = snprintf(head, sizeof head, "\ncider SAMPLE rip=%p rsp=%p frames=%d\n",
		(void *) rip, (void *) rsp, count);

	write(2, head, (size_t) len);
	backtrace_symbols_fd(frames, count, 2);
}

static void cider_crashtrace_atexit(void)
{
    void *frames[64];
    int count = backtrace(frames, 64);

    fprintf(stderr, "\ncider CRASHTRACE exit frames=%d\n", count);
    for (int i = 0; i < count; i++) {
        Dl_info info;

        if (dladdr(frames[i], &info) != 0 && info.dli_sname != NULL) {
            const char *image = info.dli_fname ? strrchr(info.dli_fname, '/') : NULL;

            fprintf(stderr, "%-3d %-34s %s\n", i, image ? image + 1 : "?", info.dli_sname);
        } else {
            fprintf(stderr, "%-3d %-34s %p\n", i, "???", frames[i]);
        }
    }
    fflush(stderr);
}

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

	/*
	 * THE ARGUMENT REGISTERS, AND ANY STRING THEY POINT AT. A fault inside a runtime helper says
	 * nothing about WHICH request faulted: Swift's type instantiation takes a mangled name as its
	 * first argument, and that name is the whole answer. Probed with write() to /dev/null first,
	 * which answers EFAULT for a bad pointer instead of faulting again inside the handler.
	 */
	if (uc != NULL && uc->uc_mcontext != NULL) {
		const uint64_t args[6] = {
			uc->uc_mcontext->__ss.__rdi, uc->uc_mcontext->__ss.__rsi,
			uc->uc_mcontext->__ss.__rdx, uc->uc_mcontext->__ss.__rcx,
			uc->uc_mcontext->__ss.__r8, uc->uc_mcontext->__ss.__r9,
		};
		static const char *const names[6] = {"rdi", "rsi", "rdx", "rcx", "r8", "r9"};
		int null_fd = open("/dev/null", O_WRONLY);

		for (int i = 0; i < 6; i++) {
			char line[192];
			int n = snprintf(line, sizeof line, "  %s=%#llx", names[i],
				(unsigned long long) args[i]);

			if (null_fd >= 0 && args[i] > 0x1000) {
				const char *text = (const char *) args[i];

				if (write(null_fd, text, 32) == 32) {
					n += snprintf(line + n, sizeof line - (size_t) n, " \"");
					for (int c = 0; c < 48 && text[c] != 0 && n < (int) sizeof line - 4; c++) {
						line[n++] = (text[c] >= 32 && text[c] < 127) ? text[c] : '.';
					}
					n += snprintf(line + n, sizeof line - (size_t) n, "\"");
				}
			}
			n += snprintf(line + n, sizeof line - (size_t) n, "\n");
			write(2, line, (size_t) n);
		}
		if (null_fd >= 0) {
			close(null_fd);
		}
	}

	/*
	 * PEEK AT SLOTS OF THE FAULTING IMAGE, named as offsets from ITS load address.
	 *
	 * A crash that dereferences a null says nothing about WHERE the null came from. When the
	 * suspect is a specific __DATA slot, a bind target or a cached metadata pointer, the value at
	 * the moment of the fault settles it, and the faulting rip already identifies the image:
	 * dladdr gives its base. CIDER_CRASH_PEEK is a comma separated list of hex offsets.
	 */
	const char *peek = getenv("CIDER_CRASH_PEEK");

	if (peek != NULL && peek[0] != '\0' && rip != 0) {
		Dl_info info;
		int have = dladdr((void *) rip, &info);
		char head2[160];
		int n2 = snprintf(head2, sizeof head2, "  peek request=%.40s dladdr=%d fbase=%p\n", peek,
			have, have != 0 ? info.dli_fbase : NULL);

		write(2, head2, (size_t) n2);
		if (have != 0 && info.dli_fbase != NULL) {
			int null_fd = open("/dev/null", O_WRONLY);
			const char *at = peek;

			while (*at != '\0') {
				char *stop = NULL;
				unsigned long long delta = strtoull(at, &stop, 16);
				char line[160];
				int n;

				if (stop == at) {
					break;
				}
				const unsigned long long *slot =
					(const unsigned long long *) ((char *) info.dli_fbase + delta);
				int readable = (null_fd >= 0 && write(null_fd, slot, 8) == 8);

				n = snprintf(line, sizeof line, "  peek %s +%#llx = %s%llx\n",
					info.dli_fname != NULL ? info.dli_fname : "?", delta,
					readable ? "0x" : "(unreadable) 0x", readable ? *slot : 0ull);
				write(2, line, (size_t) n);
				at = (*stop == ',') ? stop + 1 : stop;
			}
			if (null_fd >= 0) {
				close(null_fd);
			}
		}
	}

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

	atexit(cider_crashtrace_atexit);

	{
		struct sigaction sample = { 0 };

		sample.sa_sigaction = cider_crashtrace_sample;
		sample.sa_flags = SA_SIGINFO | SA_RESTART;
		sigemptyset(&sample.sa_mask);
		sigaction(SIGUSR1, &sample, NULL);
	}
}
