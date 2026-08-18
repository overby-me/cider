/*
 * DOES FORK WORK ONCE THE PROCESS HAS THREADS.
 *
 * iTerm2 never creates a session process at all: through a whole run the only guest processes are
 * shellspawn and iTerm2 itself, with no login, no shell and no helper, and no core is written. Every
 * cheaper explanation is ruled out -- the shells and login exist, login runs when driven by hand,
 * user lookup answers, and the pty machinery allocates, forks and execs when a SHELL does it.
 *
 * The one difference left between that working case and the failing one is threads. A shell forks
 * single threaded; a Cocoa application forks with a dozen threads running. This probe does both, in
 * that order, and says which of them survives, so the answer stops being a hypothesis.
 */

#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <pthread.h>
#include <sys/wait.h>
#include <string.h>
#include <errno.h>
#include <spawn.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <fcntl.h>
#include <sys/uio.h>
#include <sys/stat.h>
#include <sys/event.h>
#include <sys/time.h>

extern char **environ;

static void *spin(void *arg) {
    /* Kept alive for the whole test, because a thread that has already exited does not reproduce
     * what a Cocoa application looks like at the moment it forks. */
    for (;;)
        usleep(50 * 1000);

    return arg;
}

static int fork_and_exec(const char *what) {
    pid_t pid = fork();

    if (pid < 0) {
        fprintf(stderr, "FORK_PROBE %s fork FAILED errno %d\n", what, errno);
        return 1;
    }

    if (pid == 0) {
        char *argv[] = { "/bin/echo", "child-ran", NULL };

        execv(argv[0], argv);
        /* Only reached if exec failed, and the parent still needs to hear about it. */
        fprintf(stderr, "FORK_PROBE %s exec FAILED errno %d\n", what, errno);
        _exit(97);
    }

    int status = 0;
    pid_t got = waitpid(pid, &status, 0);

    fprintf(stderr, "FORK_PROBE %s child %d waited %d exited %d status %d\n", what, (int) pid,
            (int) got, WIFEXITED(status), WIFEXITED(status) ? WEXITSTATUS(status) : -1);
    fflush(stderr);

    return 0;
}

/* posix_spawn is the other way a process gets made, and an application that uses it rather than
 * fork would fail with fork working perfectly. iTerm2 launches its session helper this way. */
static void spawn_and_wait(const char *what) {
    pid_t pid = 0;
    char *argv[] = { "/bin/echo", "spawn-ran", NULL };
    int rc = posix_spawn(&pid, argv[0], NULL, NULL, argv, environ);

    if (rc != 0) {
        fprintf(stderr, "FORK_PROBE %s posix_spawn FAILED rc %d\n", what, rc);
        fflush(stderr);
        return;
    }

    int status = 0;
    pid_t got = waitpid(pid, &status, 0);

    fprintf(stderr, "FORK_PROBE %s posix_spawn child %d waited %d exited %d status %d\n", what,
            (int) pid, (int) got, WIFEXITED(status), WIFEXITED(status) ? WEXITSTATUS(status) : -1);
    fflush(stderr);
}

/* A UNIX SOCKET WHERE THE APPLICATION PUTS ONE. iTerm2 creates iterm2-daemon-N.socket in its
 * Application Support directory, hands the descriptor to a helper, and talks to it over that. The
 * lock files are there after a run and the sockets never are, so this asks whether binding one in
 * that directory works at all. */
static void unix_socket_probe(const char *path) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);

    if (fd < 0) {
        fprintf(stderr, "FORK_PROBE socket() FAILED errno %d\n", errno);
        fflush(stderr);
        return;
    }

    struct sockaddr_un addr;

    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, path, sizeof(addr.sun_path) - 1);
    unlink(path);

    if (bind(fd, (struct sockaddr *) &addr, sizeof(addr)) != 0) {
        fprintf(stderr, "FORK_PROBE bind %s FAILED errno %d\n", path, errno);
        fflush(stderr);
        close(fd);
        return;
    }

    if (listen(fd, 5) != 0) {
        fprintf(stderr, "FORK_PROBE listen FAILED errno %d\n", errno);
        fflush(stderr);
        close(fd);
        return;
    }

    fprintf(stderr, "FORK_PROBE unix socket bound and listening at %s\n", path);
    fflush(stderr);
    close(fd);
    unlink(path);
}

/* PASSING A DESCRIPTOR OVER A SOCKET, which is how iTerm2 gets the pty back from its helper. If
 * SCM_RIGHTS does not survive the trip then the handshake fails and the session dies at once, which
 * is exactly what the application reports. */
static void fd_passing_probe(void) {
    int sv[2];

    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) != 0) {
        fprintf(stderr, "FORK_PROBE socketpair FAILED errno %d\n", errno);
        fflush(stderr);
        return;
    }

    int payload = open("/dev/null", O_RDONLY);

    if (payload < 0) {
        fprintf(stderr, "FORK_PROBE open /dev/null FAILED errno %d\n", errno);
        fflush(stderr);
        return;
    }

    char byte = 42;
    struct iovec iov = { .iov_base = &byte, .iov_len = 1 };
    char control[CMSG_SPACE(sizeof(int))];
    struct msghdr msg;

    memset(&msg, 0, sizeof(msg));
    memset(control, 0, sizeof(control));
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    msg.msg_control = control;
    msg.msg_controllen = sizeof(control);

    struct cmsghdr *cmsg = CMSG_FIRSTHDR(&msg);

    cmsg->cmsg_level = SOL_SOCKET;
    cmsg->cmsg_type = SCM_RIGHTS;
    cmsg->cmsg_len = CMSG_LEN(sizeof(int));
    memcpy(CMSG_DATA(cmsg), &payload, sizeof(int));

    if (sendmsg(sv[0], &msg, 0) < 0) {
        fprintf(stderr, "FORK_PROBE sendmsg with SCM_RIGHTS FAILED errno %d\n", errno);
        fflush(stderr);
        return;
    }

    char inbyte = 0;
    struct iovec riov = { .iov_base = &inbyte, .iov_len = 1 };
    char rcontrol[CMSG_SPACE(sizeof(int))];
    struct msghdr rmsg;

    memset(&rmsg, 0, sizeof(rmsg));
    memset(rcontrol, 0, sizeof(rcontrol));
    rmsg.msg_iov = &riov;
    rmsg.msg_iovlen = 1;
    rmsg.msg_control = rcontrol;
    rmsg.msg_controllen = sizeof(rcontrol);

    ssize_t got = recvmsg(sv[1], &rmsg, 0);

    if (got < 0) {
        fprintf(stderr, "FORK_PROBE recvmsg FAILED errno %d\n", errno);
        fflush(stderr);
        return;
    }

    struct cmsghdr *rcmsg = CMSG_FIRSTHDR(&rmsg);

    if (rcmsg == NULL || rcmsg->cmsg_type != SCM_RIGHTS) {
        fprintf(stderr, "FORK_PROBE recvmsg got %zd bytes but NO DESCRIPTOR (controllen %u)\n",
                got, (unsigned) rmsg.msg_controllen);
        fflush(stderr);
        return;
    }

    int received = -1;

    memcpy(&received, CMSG_DATA(rcmsg), sizeof(int));
    fprintf(stderr, "FORK_PROBE descriptor passed over the socket, byte %d fd %d\n", inbyte,
            received);
    fflush(stderr);
}

/* THE LOCK THAT DECIDES WHETHER A SERVER IS ALREADY RUNNING. iTerm2 opens
 * iterm2-daemon-N.socket.lock, takes an exclusive non blocking flock, and reads the result as
 * whether a server owns that number. A run leaves SIX of those locks and no sockets, which is what
 * trying number after number looks like, so this asks whether flock answers correctly: the first
 * take must succeed, a second take from another descriptor must fail with EWOULDBLOCK. */
static void flock_probe(const char *path) {
    int a = open(path, O_CREAT | O_RDWR, 0600);

    if (a < 0) {
        fprintf(stderr, "FORK_PROBE flock open FAILED errno %d\n", errno);
        fflush(stderr);
        return;
    }

    int first = flock(a, LOCK_EX | LOCK_NB);
    int b = open(path, O_CREAT | O_RDWR, 0600);
    int second = b >= 0 ? flock(b, LOCK_EX | LOCK_NB) : -1;

    fprintf(stderr, "FORK_PROBE flock first %d (errno %d), second %d (errno %d) -- expected 0 then -1/EWOULDBLOCK\n",
            first, first == 0 ? 0 : errno, second, second == 0 ? 0 : errno);
    fflush(stderr);

    if (b >= 0)
        close(b);
    close(a);
    unlink(path);
}

/* DOES A DESCRIPTOR SURVIVE EXEC. iTerm2 hands its helper a socket by NUMBER: it clears close on
 * exec, forks, and execs iTermServer with that number as its only argument. If the descriptor does
 * not survive the exec then the helper opens nothing, exits at once, and the application tries the
 * next number, which is exactly the six numbered locks and no socket that a run leaves behind.
 *
 * The child here is this same binary, re-executed with checkfd and the number, because a stock tool
 * cannot report what it inherited. */
/* The same question for a LOW descriptor. An application that hands a helper a socket usually
 * dup2s it to a small fixed number first, and a small number is exactly where a loader keeps its
 * own descriptors, so surviving as fd 24 says nothing about surviving as fd 3. */
static void inherit_low_probe(int want) {
    int fd = open("/dev/null", O_RDONLY);

    if (fd < 0)
        return;

    if (dup2(fd, want) < 0) {
        fprintf(stderr, "FORK_PROBE dup2 to %d FAILED errno %d\n", want, errno);
        fflush(stderr);
        close(fd);
        return;
    }
    close(fd);
    fcntl(want, F_SETFD, fcntl(want, F_GETFD) & ~FD_CLOEXEC);

    char number[16];

    snprintf(number, sizeof(number), "%d", want);

    pid_t pid = fork();

    if (pid == 0) {
        char *argv[] = { "/fork_probe", "checkfd", number, NULL };

        execv(argv[0], argv);
        _exit(96);
    }

    int status = 0;

    waitpid(pid, &status, 0);
    fprintf(stderr, "FORK_PROBE low fd %d inherited across exec: %s\n", want,
            (WIFEXITED(status) && WEXITSTATUS(status) == 0) ? "YES" : "NO");
    fflush(stderr);
    close(want);
}

static void inherit_probe(void) {
    int fd = open("/dev/null", O_RDONLY);

    if (fd < 0) {
        fprintf(stderr, "FORK_PROBE inherit open FAILED errno %d\n", errno);
        fflush(stderr);
        return;
    }

    /* Explicitly clear close on exec, which is what the application does before handing it over. */
    fcntl(fd, F_SETFD, fcntl(fd, F_GETFD) & ~FD_CLOEXEC);

    char number[16];

    snprintf(number, sizeof(number), "%d", fd);

    pid_t pid = fork();

    if (pid == 0) {
        char *argv[] = { "/fork_probe", "checkfd", number, NULL };

        execv(argv[0], argv);
        fprintf(stderr, "FORK_PROBE inherit exec FAILED errno %d\n", errno);
        _exit(96);
    }

    int status = 0;

    waitpid(pid, &status, 0);
    fprintf(stderr, "FORK_PROBE inherit child exited %d\n",
            WIFEXITED(status) ? WEXITSTATUS(status) : -1);
    fflush(stderr);
    close(fd);
}

/* KQUEUE, which is what a serve loop waits on. A helper that cannot wait exits at once and says
 * nothing, which is what iTermServer does here. */
static void kqueue_probe(void) {
    int kq = kqueue();

    if (kq < 0) {
        fprintf(stderr, "FORK_PROBE kqueue FAILED errno %d\n", errno);
        fflush(stderr);
        return;
    }

    int fds[2];

    if (pipe(fds) != 0) {
        fprintf(stderr, "FORK_PROBE pipe FAILED errno %d\n", errno);
        fflush(stderr);
        close(kq);
        return;
    }

    struct kevent change;

    EV_SET(&change, fds[0], EVFILT_READ, EV_ADD | EV_ENABLE, 0, 0, NULL);

    if (kevent(kq, &change, 1, NULL, 0, NULL) < 0) {
        fprintf(stderr, "FORK_PROBE kevent register FAILED errno %d\n", errno);
        fflush(stderr);
        close(kq);
        return;
    }

    if (write(fds[1], "x", 1) != 1) {
        fprintf(stderr, "FORK_PROBE pipe write FAILED errno %d\n", errno);
        fflush(stderr);
        close(kq);
        return;
    }

    struct kevent event;
    struct timespec timeout = { .tv_sec = 2, .tv_nsec = 0 };
    int n = kevent(kq, NULL, 0, &event, 1, &timeout);

    fprintf(stderr, "FORK_PROBE kqueue woke with %d event(s) (errno %d)\n", n, n < 0 ? errno : 0);
    fflush(stderr);

    close(fds[0]);
    close(fds[1]);
    close(kq);
}

int main(int argc, char **argv) {
    if (argc == 3 && strcmp(argv[1], "checkfd") == 0) {
        int fd = atoi(argv[2]);
        struct stat st;
        int ok = fstat(fd, &st) == 0;

        fprintf(stderr, "FORK_PROBE checkfd %d inherited=%s (errno %d)\n", fd, ok ? "YES" : "NO",
                ok ? 0 : errno);
        fflush(stderr);
        return ok ? 0 : 1;
    }

    fprintf(stderr, "FORK_PROBE start\n");
    fflush(stderr);

    fork_and_exec("single-threaded");
    spawn_and_wait("single-threaded");

    pthread_t threads[8];

    for (int i = 0; i < 8; i++) {
        if (pthread_create(&threads[i], NULL, spin, NULL) != 0) {
            fprintf(stderr, "FORK_PROBE could not create thread %d\n", i);
            fflush(stderr);
        }
    }

    usleep(300 * 1000);
    fprintf(stderr, "FORK_PROBE now multithreaded\n");
    fflush(stderr);

    fork_and_exec("multithreaded");
    spawn_and_wait("multithreaded");

    unix_socket_probe("/Users/root/Library/Application Support/iTerm2/probe-test.socket");
    unix_socket_probe("/tmp/probe-test.socket");
    fd_passing_probe();
    flock_probe("/tmp/probe-flock.lock");
    inherit_probe();
    kqueue_probe();
    inherit_low_probe(3);
    inherit_low_probe(4);
    inherit_low_probe(5);

    fprintf(stderr, "FORK_PROBE done\n");
    fflush(stderr);

    return 0;
}
