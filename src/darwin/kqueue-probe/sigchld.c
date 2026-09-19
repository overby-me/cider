/*
 * Does a SIGCHLD handler run when a posix_spawn child exits?
 *
 * WHY: libuv reaps children and completes a uv_process_t from its SIGCHLD handler. CMake's
 * execute_process hangs in the libuv loop with an active handle, and the signal-wrapper trace shows
 * no SIGCHLD ever reaching it, while the same trace shows bash receiving one. Task #235.
 *
 * TWO CHILDREN, because the two paths differ in our port: one by fork and exec, one by
 * posix_spawn. A probe that tested only one could not tell them apart.
 *
 * A PROBE, NOT A TEST CASE: it prints what it saw and exits 0 either way.
 */

#include <errno.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

extern char** environ;

static volatile sig_atomic_t chld_count = 0;

static void on_chld(int signo)
{
	(void) signo;
	chld_count++;
}

static int wait_for_signal(const char* what, int before)
{
	for (int i = 0; i < 40; i++)
	{
		if (chld_count > before)
		{
			printf("%s: SIGCHLD DELIVERED after %d ms\n", what, i * 100);
			return 1;
		}
		usleep(100 * 1000);
	}
	printf("%s: NO SIGCHLD in 4s  <-- the defect\n", what);
	return 0;
}

int main(void)
{
	struct sigaction sa;
	pid_t pid = -1;
	int status = 0, before;
	char* argv[] = { "/usr/bin/uname", "-r", NULL };

	memset(&sa, 0, sizeof(sa));
	sa.sa_handler = on_chld;
	sigemptyset(&sa.sa_mask);
	sa.sa_flags = SA_RESTART | SA_NOCLDSTOP;
	if (sigaction(SIGCHLD, &sa, NULL) != 0)
	{
		printf("sigaction failed errno=%d\n", errno);
		return 0;
	}

	before = chld_count;
	if (posix_spawn(&pid, argv[0], NULL, NULL, argv, environ) == 0)
	{
		printf("spawned pid=%d\n", (int) pid);
		wait_for_signal("posix_spawn", before);
		waitpid(pid, &status, 0);
	}
	else
		printf("posix_spawn failed errno=%d\n", errno);

	before = chld_count;
	pid = fork();
	if (pid == 0)
	{
		execv(argv[0], argv);
		_exit(127);
	}
	else if (pid > 0)
	{
		printf("forked pid=%d\n", (int) pid);
		wait_for_signal("fork+exec", before);
		waitpid(pid, &status, 0);
	}
	else
		printf("fork failed errno=%d\n", errno);

	printf("sigchld done count=%d\n", (int) chld_count);
	return 0;
}
