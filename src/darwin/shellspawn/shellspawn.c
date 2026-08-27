/*
This file is part of Darling.

Copyright (C) 2017 Lubos Dolezel

Darling is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

Darling is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with Darling.  If not, see <http://www.gnu.org/licenses/>.
*/

#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdbool.h>
#include <string.h>
#include <stdio.h>
#include <errno.h>
#include <sys/poll.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <sys/event.h>
#include <sys/ioctl.h>
#include <signal.h>
#include "shellspawn.h"
#include "duct_signals.h"
#include <time.h>

// #11 spawn-hot-path timing (CIDER_TIMING=1 -> stderr, monotonic sec.us).
static void ts_mark(const char* label) {
	static int on = -1;
	if (on == -1) on = getenv("CIDER_TIMING") ? 1 : 0;
	if (!on) return;
	struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
	fprintf(stderr, "shellspawn-timing %s %lld.%06ld\n", label, (long long)t.tv_sec, t.tv_nsec/1000);
}

#define DBG 0

int g_serverSocket = -1;
struct sigaction sigchld_oldaction;

void setupSocket(void);
void listenForConnections(void);
void setupSigchild(void);
void reapAll(void);

int main(int argc, const char** argv)
{
	// #11 Pass 128: the daemon runs ONE central event loop and forks ONLY the target per
	// connection (no per-connection handler fork, whose ~5ms atfork Mach re-init sat on the
	// spawn hot path). SIGCHLD stays default so exited targets remain reapable via waitpid.
	setupSigchild();
	setupSocket();
	listenForConnections();

	if (g_serverSocket != -1)
		close(g_serverSocket);
	return 0;
}

void setupSocket(void)
{
	struct sockaddr_un addr = {
		.sun_family = AF_UNIX,
		.sun_path = SHELLSPAWN_SOCKPATH
	};

	g_serverSocket = socket(AF_UNIX, SOCK_STREAM, 0);
	if (g_serverSocket == -1)
	{
		perror("Creating unix socket");
		exit(EXIT_FAILURE);
	}

	fcntl(g_serverSocket, F_SETFD, FD_CLOEXEC);
	unlink(SHELLSPAWN_SOCKPATH);

	if (bind(g_serverSocket, (struct sockaddr*) &addr, sizeof(addr)) == -1)
	{
		perror("Binding the unix socket");
		exit(EXIT_FAILURE);
	}

	chmod(addr.sun_path, 0600);

	if (listen(g_serverSocket, 16384) == -1)
	{
		perror("Listening on unix socket");
		exit(EXIT_FAILURE);
	}
}

// One kqueue multiplexes the server socket, each live spawn's control fd, and each target's
// NOTE_EXIT. The daemon never blocks on a spawn's exit, so spawns stay concurrent.

#define MAX_SPAWNS 8192
struct spawn {
	int fd;             // control socket to the launcher; -1 marks a free slot
	pid_t pid;
	int shellfd[3];     // launcher stdio (daemon's copies, closed when the target exits)
};
static struct spawn g_spawns[MAX_SPAWNS];

static struct spawn* spawn_slot(void)
{
	for (int i = 0; i < MAX_SPAWNS; i++)
		if (g_spawns[i].fd == -1)
			return &g_spawns[i];
	return NULL;
}

// Per-process setup a connection requests, applied in the target CHILD (was the handler's job).
#define MAX_ENVS 1024
struct spawn_cfg {
	char** argv;
	char* alloc_exec;
	int shellfd[3];
	char* envs[MAX_ENVS];
	int n_envs;
	char* chdir_path;
	int uid, gid;       // -1 = unchanged
};

// Read the command stream up to GO into cfg. Returns 0 on GO (cfg->shellfd valid), -1 on error.
static int read_commands(int fd, struct spawn_cfg* cfg)
{
	memset(cfg, 0, sizeof(*cfg));
	cfg->uid = -1;
	cfg->gid = -1;
	cfg->argv = (char**) malloc(sizeof(char*) * 3);
	cfg->argv[0] = strdup("/bin/bash");
	cfg->argv[1] = strdup("--login");
	int argc = 2;
	bool go = false;

	while (!go)
	{
		struct shellspawn_cmd cmd;
		char* param = NULL;
		struct msghdr msg;
		struct iovec iov;
		char cmsgbuf[CMSG_SPACE(sizeof(int)) * 3];

		memset(&msg, 0, sizeof(msg));
		msg.msg_control = cmsgbuf;
		msg.msg_controllen = sizeof(cmsgbuf);
		iov.iov_base = &cmd;
		iov.iov_len = sizeof(cmd);
		msg.msg_iov = &iov;
		msg.msg_iovlen = 1;

		if (recvmsg(fd, &msg, 0) != sizeof(cmd))
			return -1;

		if (cmd.data_length != 0)
		{
			param = (char*) malloc(cmd.data_length + 1);
			if (read(fd, param, cmd.data_length) != cmd.data_length)
				return -1;
			param[cmd.data_length] = '\0';
		}

		switch (cmd.cmd)
		{
			case SHELLSPAWN_ADDARG:
				if (param != NULL)
				{
					cfg->argv = (char**) realloc(cfg->argv, sizeof(char*) * (argc + 1));
					cfg->argv[argc++] = param;
				}
				break;
			case SHELLSPAWN_SETENV:
				// Deferred to the child (putenv in the daemon would leak into every spawn).
				if (param != NULL && cfg->n_envs < MAX_ENVS)
					cfg->envs[cfg->n_envs++] = param;
				break;
			case SHELLSPAWN_CHDIR:
				if (param != NULL)
					cfg->chdir_path = param;
				break;
			case SHELLSPAWN_SETUIDGID:
				if (param != NULL && cmd.data_length >= 2 * sizeof(int))
				{
					int* ids = (int*) param;
					cfg->uid = ids[0];
					cfg->gid = ids[1];
				}
				break;
			case SHELLSPAWN_SETEXEC:
				for (int i = 0; i < argc; i++)
					free(cfg->argv[i]);
				argc = 0;
				cfg->argv = (char**) realloc(cfg->argv, sizeof(char*));
				cfg->alloc_exec = param;
				break;
			case SHELLSPAWN_GO:
			{
				struct cmsghdr* c = CMSG_FIRSTHDR(&msg);
				if (c == NULL || c->cmsg_level != SOL_SOCKET || c->cmsg_type != SCM_RIGHTS
						|| c->cmsg_len != CMSG_LEN(sizeof(int) * 3))
				{
					free(param);
					return -1;
				}
				memcpy(cfg->shellfd, CMSG_DATA(c), sizeof(int) * 3);
				free(param);
				go = true;
				break;
			}
			default:
				free(param);
				break;
		}
	}

	cfg->argv = (char**) realloc(cfg->argv, sizeof(char*) * (argc + 1));
	cfg->argv[argc] = NULL;
	return 0;
}

// Free the malloc'd cfg after the child has forked (the child has its own COW copies).
static void free_cfg(struct spawn_cfg* cfg)
{
	if (cfg->argv)
	{
		for (int i = 0; cfg->argv[i] != NULL; i++)
			free(cfg->argv[i]);
		free(cfg->argv);
	}
	free(cfg->alloc_exec);
	for (int i = 0; i < cfg->n_envs; i++)
		free(cfg->envs[i]);
	free(cfg->chdir_path);
}

static void finish_spawn(int kq, struct spawn* s);

// Accept-time: read commands, fork the target (which applies env/uid/cwd/session/stdio/ctty then
// execs), report "started", and register the spawn in kq. Non-blocking for the daemon apart from
// the short exec-check read (the child execs in ~ms).
static void start_spawn(int kq, int fd)
{
	fcntl(fd, F_SETFD, FD_CLOEXEC);

	struct spawn_cfg cfg;
	if (read_commands(fd, &cfg) != 0)
	{
		free_cfg(&cfg);
		close(fd);
		return;
	}

	int pipefd[2];
	if (pipe(pipefd) == -1)
	{
		free_cfg(&cfg);
		close(fd);
		return;
	}

	ts_mark("pre-fork");
	pid_t pid = fork();
	if (pid == 0)
	{
		// target child: everything the old per-connection handler did in its own process
		close(pipefd[0]);
		if (cfg.chdir_path)
			chdir(cfg.chdir_path);
		for (int i = 0; i < cfg.n_envs; i++)
			putenv(cfg.envs[i]);
		if (cfg.gid != -1)
			setgid(cfg.gid);
		if (cfg.uid != -1)
			setuid(cfg.uid);
		setsid();
		setpgrp();
		dup2(cfg.shellfd[0], STDIN_FILENO);
		dup2(cfg.shellfd[1], STDOUT_FILENO);
		dup2(cfg.shellfd[2], STDERR_FILENO);
		ioctl(STDIN_FILENO, TIOCSCTTY, STDIN_FILENO);
		fcntl(pipefd[1], F_SETFD, FD_CLOEXEC);
		execv(cfg.alloc_exec ? cfg.alloc_exec : "/bin/bash", cfg.argv);
		// exec failed: signal the parent with one byte, then _exit
		write(pipefd[1], "x", 1);
		_exit(127);
	}

	close(pipefd[1]);
	// exec check: one byte from the child means execv failed (EOF via CLOEXEC means success)
	char c;
	ssize_t n = (pid < 0) ? -1 : read(pipefd[0], &c, 1);
	close(pipefd[0]);
	free_cfg(&cfg);

	if (pid < 0 || n == 1)
	{
		if (pid > 0)
		{
			kill(pid, SIGKILL);
			waitpid(pid, NULL, 0);
		}
		for (int i = 0; i < 3; i++)
			if (cfg.shellfd[i] != -1)
				close(cfg.shellfd[i]);
		close(fd);
		return;
	}

	// Tell the launcher the target started (so it drops its startup watchdog).
	unsigned char started = 1;
	if (write(fd, &started, 1) != 1)
	{
		kill(pid, SIGKILL);
		waitpid(pid, NULL, 0);
		for (int i = 0; i < 3; i++)
			if (cfg.shellfd[i] != -1)
				close(cfg.shellfd[i]);
		close(fd);
		return;
	}

	struct spawn* s = spawn_slot();
	if (s == NULL)
	{
		kill(pid, SIGKILL);
		waitpid(pid, NULL, 0);
		close(fd);
		return;
	}
	s->fd = fd;
	s->pid = pid;
	for (int i = 0; i < 3; i++)
		s->shellfd[i] = cfg.shellfd[i];

	struct kevent ch;
	EV_SET(&ch, fd, EVFILT_READ, EV_ADD | EV_ENABLE, 0, 0, s);
	kevent(kq, &ch, 1, NULL, 0, NULL);

	// Registered separately so its ESRCH (target already gone) surfaces as kevent()==-1 with
	// nevents=0; without this an instant-exit target would never deliver NOTE_EXIT and hang.
	EV_SET(&ch, pid, EVFILT_PROC, EV_ADD | EV_ENABLE, NOTE_EXIT, 0, s);
	if (kevent(kq, &ch, 1, NULL, 0, NULL) == -1)
		finish_spawn(kq, s);
}

// Control fd readable: a SIGNAL cmd to forward to the target, or EOF (launcher gone -> kill).
static void handle_control(struct spawn* s)
{
	struct shellspawn_cmd cmd;
	if (read(s->fd, &cmd, sizeof(cmd)) != sizeof(cmd))
	{
		kill(s->pid, SIGKILL); // NOTE_EXIT will finish the teardown
		return;
	}
	if (cmd.cmd == SHELLSPAWN_SIGNAL && cmd.data_length == sizeof(int))
	{
		int linux_signal;
		if (read(s->fd, &linux_signal, sizeof(int)) != sizeof(int))
			return;
		int darwin_signal = signum_linux_to_bsd(linux_signal);
		if (darwin_signal != 0)
		{
			int fg_pid = tcgetpgrp(s->shellfd[0]);
			if (fg_pid != -1)
				kill(fg_pid, darwin_signal);
			else
				kill(-s->pid, darwin_signal);
		}
	}
}

// Target exited: send its exit code back as the launcher's final wire message, then tear down.
static void finish_spawn(int kq, struct spawn* s)
{
	int wstatus = 0;
	if (waitpid(s->pid, &wstatus, 0) != s->pid)
		wstatus = 0;
	int code = WEXITSTATUS(wstatus);
	write(s->fd, &code, sizeof(int));

	// EVFILT_PROC self-clears on NOTE_EXIT; remove the control-fd filter explicitly.
	struct kevent ch;
	EV_SET(&ch, s->fd, EVFILT_READ, EV_DELETE, 0, 0, NULL);
	kevent(kq, &ch, 1, NULL, 0, NULL);

	close(s->fd);
	for (int i = 0; i < 3; i++)
		if (s->shellfd[i] != -1)
			close(s->shellfd[i]);
	s->fd = -1;
}

void listenForConnections(void)
{
	for (int i = 0; i < MAX_SPAWNS; i++)
		g_spawns[i].fd = -1;

	int kq = kqueue();
	fcntl(kq, F_SETFD, FD_CLOEXEC);

	struct kevent ch;
	EV_SET(&ch, g_serverSocket, EVFILT_READ, EV_ADD | EV_ENABLE, 0, 0, NULL);
	kevent(kq, &ch, 1, NULL, 0, NULL);

	while (true)
	{
		struct kevent ev;
		int n = kevent(kq, NULL, 0, &ev, 1, NULL);
		if (n <= 0)
		{
			if (errno == EINTR)
				continue;
			break;
		}

		if (ev.udata == NULL && ev.filter == EVFILT_READ)
		{
			// server socket: accept + start a new spawn
			struct sockaddr_un addr;
			socklen_t len = sizeof(addr);
			int sock = accept(g_serverSocket, (struct sockaddr*) &addr, &len);
			if (sock != -1)
				start_spawn(kq, sock);
		}
		else if (ev.filter == EVFILT_PROC && (ev.fflags & NOTE_EXIT))
		{
			finish_spawn(kq, (struct spawn*) ev.udata);
		}
		else if (ev.filter == EVFILT_READ)
		{
			handle_control((struct spawn*) ev.udata);
		}
	}
}

void setupSigchild(void)
{
	// Default SIGCHLD (no SA_NOCLDWAIT): exited targets stay reapable via waitpid in finish_spawn.
	struct sigaction sigchld_action = {
		.sa_handler = SIG_DFL,
		.sa_flags = 0
	};
	sigaction(SIGCHLD, &sigchld_action, &sigchld_oldaction);
}

void reapAll(void)
{
    while (waitpid((pid_t)(-1), 0, WNOHANG) > 0);
}
