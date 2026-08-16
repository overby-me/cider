// Can the things the prefix installs actually be LOADED?
//
// The port's coverage numbers are all about building: 1452 of 1452 link edges, install
// UNMAPPED 0. What runs is a different question, and until now it was answered by a handful
// of probes that between them touch a few dozen artifacts out of the several hundred the
// prefix ships. Everything else was believed to work because it linked.
//
// This dlopens every path it is given and says which ones answer. A library that fails here
// is not necessarily broken -- some are meant to be loaded only by their framework, some are
// dev stubs with no code -- but a library that fails here CANNOT be working, and that is a
// fact about the port that no build-time number reports.
//
// Each dlopen happens in a FORKED CHILD, so an initializer that dies costs one result
// instead of the whole sweep. AppKit is why: with no display its initializer took the probe
// down, and the remaining 335 libraries went unmeasured. A crash is now its own category,
// which is more informative than a failure anyway.
//
// The name is still printed BEFORE the attempt, so a HANG -- which no exit status reports --
// still names the culprit. Learned from the JSC hang, where the failing artifact had to be
// found by bisection because nothing said what was being touched when it stopped.
//
// Usage:  loadall_probe <file containing one path per line>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>

int main(int argc, char **argv) {
	if (argc < 2) {
		fprintf(stderr, "usage: loadall_probe <list>\n");
		return 2;
	}
	FILE *f = fopen(argv[1], "r");
	if (!f) {
		fprintf(stderr, "cannot open %s\n", argv[1]);
		return 2;
	}

	char line[4096];
	int ok = 0, bad = 0, crashed = 0, hung = 0;
	while (fgets(line, sizeof line, f)) {
		size_t n = strlen(line);
		while (n && (line[n - 1] == '\n' || line[n - 1] == '\r'))
			line[--n] = 0;
		if (!n)
			continue;

		// Before, not after: if this one takes the process down, this line is the answer.
		printf("LOADALL try %s\n", line);
		fflush(stdout);

		// A CHILD per library, because an initializer that dies must not end the sweep.
		// AppKit is the case that forced this: dlopening it with no display took the whole
		// probe with it and the other 335 went unmeasured.
		pid_t kid = fork();
		if (kid == 0) {
			// A DEADLINE, because the first failure mode here was not a crash but a hang:
			// AppKit's initializer blocks trying to reach a display, waitpid blocks with
			// it, and the sweep stalls until the container timeout with 300 libraries
			// still unmeasured. SIGALRM turns that into a result.
			alarm(5);
			// LAZY and LOCAL: binding every symbol would fail on libraries that
			// legitimately resolve against their loader at use time, and GLOBAL would let
			// one library's symbols satisfy the next one's, making the count a lie.
			void *h = dlopen(line, RTLD_LAZY | RTLD_LOCAL);
			if (h)
				_exit(0);
			const char *e = dlerror();
			fprintf(stderr, "dlerror: %s\n", e ? e : "(none)");
			_exit(1);
		}
		if (kid < 0) {
			bad++;
			printf("LOADALL fail %s: fork failed\n", line);
			fflush(stdout);
			continue;
		}
		int st = 0;
		waitpid(kid, &st, 0);
		if (WIFEXITED(st) && WEXITSTATUS(st) == 0) {
			ok++;
			printf("LOADALL ok %s\n", line);
		} else if (WIFSIGNALED(st) && WTERMSIG(st) == SIGALRM) {
			hung++;
			printf("LOADALL hang %s: still in its initializer after 5s\n", line);
		} else if (WIFSIGNALED(st)) {
			crashed++;
			printf("LOADALL crash %s: signal %d\n", line, WTERMSIG(st));
		} else {
			bad++;
			printf("LOADALL fail %s: dlopen returned NULL\n", line);
		}
		fflush(stdout);
	}
	fclose(f);

	printf("LOADALL_DONE ok=%d fail=%d crash=%d hang=%d\n", ok, bad, crashed, hung);
	return 0;
}
