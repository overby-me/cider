/*
 * Does a byte written to a pty MASTER reach the program reading the SLAVE?
 *
 * WHY: iTerm2 3.5.14 draws its shell prompt, so the slave-to-master direction works. It then hands
 * the first typed byte to PTYTask, the shell never echoes it, and every later keystroke is dropped
 * because the session has concluded its task died. That accuses the other direction, which nothing
 * in the tree tests. Task #239.
 *
 * A PROBE, NOT A TEST CASE: it prints what it saw and exits 0 either way, so it can be run in a
 * prefix without a verdict being read into a rig failure.
 *
 * TWO CASES, because they fail differently. The FIRST is a bare pty pair with no child at all: the
 * master write and the slave read are then the only things under test. The SECOND runs a real
 * child on the slave, which is what an application does, and is the one that can also fail on
 * process setup rather than on the descriptor.
 *
 * IT SENDS A NEWLINE, AND THAT IS NOT COSMETIC. A pty starts in CANONICAL mode, where the line
 * discipline holds input until a line is complete, so a lone "e" is correctly not readable and a
 * probe that sends one measures POSIX and reports it as a broken port. I wrote exactly that probe
 * first. Each case also reports the canonical and echo flags, so the reading can be checked
 * against the mode it was taken in rather than assumed.
 */

#define _DARWIN_C_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <termios.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/select.h>
#include <sys/wait.h>
#include <util.h>

/* A read that waits, so a slow answer is not reported as no answer. */
static int read_with_deadline(int fd, char *buf, size_t n, int seconds)
{
	fd_set set;
	struct timeval tv = { .tv_sec = seconds, .tv_usec = 0 };

	FD_ZERO(&set);
	FD_SET(fd, &set);
	if (select(fd + 1, &set, NULL, NULL, &tv) <= 0)
		return -1;
	return (int) read(fd, buf, n);
}

static void bare_pair(void)
{
	int master = -1, slave = -1;
	char buf[64] = { 0 };

	if (openpty(&master, &slave, NULL, NULL, NULL) < 0) {
		printf("pty-probe bare openpty=FAILED errno=%d %s\n", errno, strerror(errno));
		return;
	}
	struct termios t;
	if (tcgetattr(slave, &t) == 0)
		printf("pty-probe bare master=%d slave=%d icanon=%d echo=%d\n", master, slave,
			(t.c_lflag & ICANON) != 0, (t.c_lflag & ECHO) != 0);
	else
		printf("pty-probe bare master=%d slave=%d tcgetattr=FAILED errno=%d\n", master, slave, errno);

	ssize_t written = write(master, "e\n", 2);
	printf("pty-probe bare write=%zd errno=%d\n", written, written < 0 ? errno : 0);

	int got = read_with_deadline(slave, buf, sizeof(buf) - 1, 3);
	if (got > 0)
		printf("pty-probe bare slave read %d bytes first=0x%02x verdict=%s\n", got,
			(unsigned char) buf[0], buf[0] == 'e' ? "DELIVERED" : "WRONG-BYTE");
	else
		printf("pty-probe bare slave read=%d errno=%d verdict=NOTHING-ARRIVED\n", got, errno);

	close(master);
	close(slave);
}

static void with_child(void)
{
	int master = -1, slave = -1;
	char buf[128] = { 0 };

	if (openpty(&master, &slave, NULL, NULL, NULL) < 0) {
		printf("pty-probe child openpty=FAILED errno=%d %s\n", errno, strerror(errno));
		return;
	}

	pid_t pid = fork();
	if (pid < 0) {
		printf("pty-probe child fork=FAILED errno=%d\n", errno);
		close(master);
		close(slave);
		return;
	}
	if (pid == 0) {
		/* THE CHILD IS THE READER, and it must own the slave as its controlling terminal the way
		 * a shell does, or the test is about something else. */
		close(master);
		setsid();
		ioctl(slave, TIOCSCTTY, 0);
		dup2(slave, 0);
		dup2(slave, 1);
		if (slave > 2)
			close(slave);
		char c = 0;
		if (read(0, &c, 1) == 1)
			printf("CHILD-GOT-0x%02x\n", (unsigned char) c);
		else
			printf("CHILD-READ-FAILED-%d\n", errno);
		fflush(stdout);
		_exit(0);
	}

	close(slave);
	/* The child has to be reading before the byte is sent, or the pty line discipline buffers it
	 * and the timing rather than the plumbing decides the answer. */
	sleep(1);
	ssize_t written = write(master, "e\n", 2);
	printf("pty-probe child write=%zd errno=%d\n", written, written < 0 ? errno : 0);

	int got = read_with_deadline(master, buf, sizeof(buf) - 1, 5);
	if (got > 0) {
		buf[got] = '\0';
		printf("pty-probe child master read %d bytes: %s", got, buf);
		printf("pty-probe child verdict=%s\n",
			strstr(buf, "CHILD-GOT-0x65") != NULL ? "DELIVERED" : "ECHO-ONLY-OR-WRONG");
	} else {
		printf("pty-probe child master read=%d errno=%d verdict=NOTHING-CAME-BACK\n", got, errno);
	}

	int status = 0;
	kill(pid, SIGKILL);
	waitpid(pid, &status, 0);
	close(master);
}

int main(void)
{
	setvbuf(stdout, NULL, _IOLBF, 0);
	bare_pair();
	with_child();
	printf("pty-probe done\n");
	return 0;
}
