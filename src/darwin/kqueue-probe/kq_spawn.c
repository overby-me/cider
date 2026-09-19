/*
 * The libuv shape: a socketpair for the child's stdout, a spawn with file actions and
 * CLOEXEC_DEFAULT, then a kqueue loop that waits for the output to end and for the child to die.
 *
 * WHY: CMake configure spawns uname -r, is handed the data and the exit, reaps the child, and then
 * sits in kevent forever. Everything libuv asks for appears to arrive, so this runs the same
 * sequence with nothing else in the process. Task #235.
 *
 * A PROBE, NOT A TEST CASE: it prints what it saw and exits 0 either way.
 */

#include <errno.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <string.h>
#include <sys/event.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/wait.h>
#include <unistd.h>

#ifndef POSIX_SPAWN_CLOEXEC_DEFAULT
#define POSIX_SPAWN_CLOEXEC_DEFAULT 0x4000
#endif

extern char** environ;

int main(void)
{
	int sv[2];
	pid_t pid = -1;
	posix_spawn_file_actions_t fa;
	posix_spawnattr_t attr;
	sigset_t empty;
	struct kevent ev[2];
	int kq, rv, seen_eof = 0, seen_exit = 0;
	char* argv[] = { "/usr/bin/uname", "-r", NULL };

	if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) != 0)
	{
		printf("socketpair failed errno=%d\n", errno);
		return 0;
	}

	posix_spawn_file_actions_init(&fa);
	posix_spawn_file_actions_adddup2(&fa, sv[1], 1);
	posix_spawn_file_actions_addclose(&fa, sv[1]);

	posix_spawnattr_init(&attr);
	sigemptyset(&empty);
	posix_spawnattr_setsigmask(&attr, &empty);
	posix_spawnattr_setsigdefault(&attr, &empty);
	posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF
		| POSIX_SPAWN_CLOEXEC_DEFAULT);

	rv = posix_spawn(&pid, argv[0], &fa, &attr, argv, environ);
	printf("spawn rv=%d pid=%d\n", rv, (int) pid);
	if (rv != 0)
		return 0;

	close(sv[1]);

	kq = kqueue();
	EV_SET(&ev[0], sv[0], EVFILT_READ, EV_ADD | EV_ENABLE, 0, 0, NULL);
	EV_SET(&ev[1], pid, EVFILT_PROC, EV_ADD | EV_ONESHOT, NOTE_EXIT, 0, NULL);
	if (kevent(kq, ev, 2, NULL, 0, NULL) < 0)
		printf("EV_ADD failed errno=%d\n", errno);

	for (int round = 0; round < 8 && !(seen_eof && seen_exit); round++)
	{
		struct timespec ts = { 3, 0 };
		char buf[256];
		int n;

		memset(ev, 0, sizeof(ev));
		n = kevent(kq, NULL, 0, ev, 2, &ts);
		if (n < 0)
		{
			printf("round %d kevent errno=%d\n", round, errno);
			break;
		}
		if (n == 0)
		{
			printf("round %d TIMED OUT eof=%d exit=%d  <-- THE HANG\n", round, seen_eof, seen_exit);
			break;
		}
		for (int i = 0; i < n; i++)
		{
			printf("round %d event filter=%d ident=%d flags=0x%x data=%ld\n", round,
				(int) ev[i].filter, (int) ev[i].ident, (unsigned) ev[i].flags, (long) ev[i].data);
			if (ev[i].filter == EVFILT_PROC)
				seen_exit = 1;
			else if (ev[i].filter == EVFILT_READ)
			{
				int r = (int) read(sv[0], buf, sizeof(buf) - 1);
				if (r > 0)
				{
					buf[r] = 0;
					if (buf[r - 1] == '\n')
						buf[r - 1] = 0;
					printf("round %d read %d bytes: %s\n", round, r, buf);
				}
				else
					printf("round %d read returned %d errno=%d\n", round, r, errno);
				if (r == 0 || (ev[i].flags & EV_EOF))
					seen_eof = 1;
			}
		}
	}

	printf("waitpid...\n");
	int status = 0;
	pid_t w = waitpid(pid, &status, 0);
	printf("waitpid returned %d status=%x\n", (int) w, status);
	printf("kq_spawn done eof=%d exit=%d\n", seen_eof, seen_exit);
	return 0;
}
