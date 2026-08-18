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

int main(void) {
    fprintf(stderr, "FORK_PROBE start\n");
    fflush(stderr);

    fork_and_exec("single-threaded");

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

    fprintf(stderr, "FORK_PROBE done\n");
    fflush(stderr);

    return 0;
}
