/*
 * Does a kqueue report a readable descriptor, and then EOF, for a pipe and for a socketpair?
 *
 * WHY: CMake configure reaps its uname child cleanly (wait4 returns the pid and status 0) and then
 * sits in kevent forever. libuv reads the child's output through a descriptor and finishes the
 * process only when that descriptor reports end of file, so the question is whether our kqueue ever
 * says so. Task #235.
 *
 * A PROBE, NOT A TEST CASE: it prints what it saw and always exits 0, so it can report an absence
 * without becoming a red case in the gate.
 */

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/event.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

static void describe(const char* what, int kq, int fd)
{
	struct kevent ev;
	struct timespec ts = { 2, 0 };
	char buf[64];
	int n;

	EV_SET(&ev, fd, EVFILT_READ, EV_ADD | EV_ENABLE, 0, 0, NULL);
	if (kevent(kq, &ev, 1, NULL, 0, NULL) < 0)
	{
		printf("%s: EV_ADD failed errno=%d\n", what, errno);
		return;
	}

	for (int round = 0; round < 3; round++)
	{
		memset(&ev, 0, sizeof(ev));
		n = kevent(kq, NULL, 0, &ev, 1, &ts);
		if (n < 0)
		{
			printf("%s: round %d kevent failed errno=%d\n", what, round, errno);
			return;
		}
		if (n == 0)
		{
			printf("%s: round %d TIMED OUT, no event in 2s\n", what, round);
			return;
		}
		printf("%s: round %d n=%d filter=%d flags=0x%x data=%ld eof=%s\n", what, round, n,
			(int) ev.filter, (unsigned) ev.flags, (long) ev.data,
			(ev.flags & EV_EOF) ? "YES" : "no");
		if (ev.flags & EV_EOF)
			return;
		n = (int) read(fd, buf, sizeof(buf));
		printf("%s: round %d read returned %d\n", what, round, n);
		if (n == 0)
			return;
	}
}

int main(void)
{
	int fds[2];
	int kq = kqueue();

	if (kq < 0)
	{
		printf("kqueue failed errno=%d\n", errno);
		return 0;
	}

	if (pipe(fds) == 0)
	{
		write(fds[1], "x", 1);
		close(fds[1]);
		describe("pipe", kq, fds[0]);
		close(fds[0]);
	}
	else
		printf("pipe failed errno=%d\n", errno);

	/* libuv uses a socketpair, not a pipe, for a child's stdio, so both are the real question. */
	if (socketpair(AF_UNIX, SOCK_STREAM, 0, fds) == 0)
	{
		write(fds[1], "x", 1);
		close(fds[1]);
		describe("socketpair", kq, fds[0]);
		close(fds[0]);
	}
	else
		printf("socketpair failed errno=%d\n", errno);

	printf("kq_eof done\n");
	return 0;
}
