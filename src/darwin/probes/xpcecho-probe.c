/*
 * Does ANY XPC listener in this container ever get handed a message?
 *
 * Everything poked so far times out: trustd, opendirectoryd's membership service, secd. Two of those
 * are explained -- trustd never creates a listener at all -- but opendirectoryd demonstrably has one:
 * it logs the listener object, logs a successful check-in, and parks in dispatch_main, and its event
 * handler still never fires while a client is blocked.
 *
 * What is missing from every one of those runs is a POSITIVE CONTROL. Without a service that is
 * known to answer, "nothing replied" cannot distinguish a broken delivery path from a container in
 * which no daemon would have answered anyway. So this is a service we own end to end, doing the
 * least a service can do.
 *
 * One binary, two modes, so both halves are built from the same source and cannot drift:
 *
 *   --server   create a mach service listener, accept, and reply to every dictionary
 *   (default)  connect and send one message, bounded, reporting REPLY, ERROR or TIMEOUT
 *
 * WHAT IT ANSWERED, and the first reading of it was too coarse. About half the runs reply, but
 * "did not reply" turned out to be TWO different failures, which the server's own stderr separates
 * at a glance. Of eleven runs kept with full logs:
 *
 *     5   replied
 *     4   the server NEVER STARTED -- no "server starting" line at all
 *     2   the server was up, listener resumed, and its event handler never fired
 *
 * Only the last two are a delivery failure. The commonest one is a launchd job that does not run,
 * which is the signature filed against securityd -- reproduced here on a first-party daemon that
 * does nothing but reply, so it is not securityd-specific.
 *
 * So this is not a Security problem at all; it is the substrate under every daemon in the container.
 */
#include <dispatch/dispatch.h>
#include <stdio.h>
#include <string.h>
#include <stdbool.h>
#include <unistd.h>
#include <xpc/xpc.h>
#include <xpc/private/pipe.h>
#include <pthread.h>

#define ECHO_SERVICE "com.cider.xpcecho"

static void run_server(bool concurrent) {
    fprintf(stderr, "CIDER_ECHO server starting, target queue = %s\n",
            concurrent ? "a concurrent queue" : "default");
    fflush(stderr);

    /*
     * A STRUCTURAL DIFFERENCE from opendirectoryd, which targets its listener at a CONCURRENT queue
     * where this one by default does not -- kept as a mode because mutating the suspect is how this
     * kind of question gets settled.
     *
     * IT IS NOT THE DISCRIMINATOR, and the first four runs said it was: 3 of 4 with the default
     * queue against 1 of 4 concurrent, which is exactly the shape of a finding. Nine runs each say
     * 5 of 9 and 3 of 9. The difference was noise, and a rate measured on four runs was not a rate.
     */
    dispatch_queue_t target = concurrent
            ? dispatch_queue_create("com.cider.xpcecho.concurrent", DISPATCH_QUEUE_CONCURRENT)
            : NULL;

    xpc_connection_t listener =
            xpc_connection_create_mach_service(ECHO_SERVICE, target, XPC_CONNECTION_MACH_SERVICE_LISTENER);

    if (listener == NULL) {
        fprintf(stderr, "CIDER_ECHO could not create the listener\n");
        fflush(stderr);
        return;
    }
    fprintf(stderr, "CIDER_ECHO listener = %p\n", (void *) listener);
    fflush(stderr);

    xpc_connection_set_event_handler(listener, ^(xpc_object_t peer) {
        fprintf(stderr, "CIDER_ECHO listener event, %sa connection\n",
                xpc_get_type(peer) == XPC_TYPE_CONNECTION ? "" : "NOT ");
        fflush(stderr);

        if (xpc_get_type(peer) != XPC_TYPE_CONNECTION) {
            return;
        }
        xpc_connection_set_event_handler(peer, ^(xpc_object_t event) {
            /*
             * NAME WHICH CLIENT. Both clients are served in the same run and the two log streams are
             * different files, so counting events cannot say which of them arrived -- and the whole
             * question is whether the CONNECTION client's message reaches the server at all or only
             * its reply goes missing. The payload string answers it.
             */
            fprintf(stderr, "CIDER_ECHO peer event, %sa dictionary, from=%s\n",
                    xpc_get_type(event) == XPC_TYPE_DICTIONARY ? "" : "NOT ",
                    xpc_get_type(event) == XPC_TYPE_DICTIONARY
                            ? (xpc_dictionary_get_string(event, "cider-probe") ?: "(no key)")
                            : "(not a dictionary)");
            fflush(stderr);

            if (xpc_get_type(event) != XPC_TYPE_DICTIONARY) {
                return;
            }
            xpc_object_t reply = xpc_dictionary_create_reply(event);

            if (reply == NULL) {
                fprintf(stderr, "CIDER_ECHO no reply object, the message expected none\n");
                fflush(stderr);
                return;
            }
            xpc_dictionary_set_bool(reply, "cider-echo", true);
            xpc_connection_send_message(xpc_dictionary_get_remote_connection(event), reply);
            xpc_release(reply);

            fprintf(stderr, "CIDER_ECHO replied to %s\n",
                    xpc_dictionary_get_string(event, "cider-probe") ?: "(no key)");
            fflush(stderr);
        });
        xpc_connection_resume(peer);
    });
    xpc_connection_resume(listener);

    fprintf(stderr, "CIDER_ECHO listener resumed, entering dispatch_main\n");
    fflush(stderr);
    dispatch_main();
}

static const char *ask(const char *name, int seconds) {
    xpc_connection_t conn = xpc_connection_create_mach_service(name, NULL, 0);

    if (conn == NULL) {
        return "NO-CONNECTION";
    }
    xpc_connection_set_event_handler(conn, ^(xpc_object_t event) {
        (void) event; /* Required, even though the reply block below reports the outcome. */
    });
    xpc_connection_resume(conn);

    xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);

    xpc_dictionary_set_string(message, "cider-probe", "ping");

    static char detail[256];
    __block const char *outcome = "TIMEOUT";
    dispatch_semaphore_t done = dispatch_semaphore_create(0);

    xpc_connection_send_message_with_reply(
            conn, message, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),
            ^(xpc_object_t reply) {
                if (xpc_get_type(reply) == XPC_TYPE_ERROR) {
                    const char *why = xpc_dictionary_get_string(reply, XPC_ERROR_KEY_DESCRIPTION);

                    snprintf(detail, sizeof(detail), "ERROR(%s)", why ? why : "no description");
                    outcome = detail;
                } else {
                    outcome = "REPLY";
                }
                dispatch_semaphore_signal(done);
            });

    dispatch_semaphore_wait(done,
                            dispatch_time(DISPATCH_TIME_NOW, (int64_t) seconds * NSEC_PER_SEC));
    return outcome;
}

/*
 * THE SAME SERVICE, ASKED THE OTHER WAY.
 *
 * libinfo does not use an xpc_connection to reach opendirectoryd; it uses a raw xpc_pipe, and a pipe
 * sends a plain XPC_MSGH_ID_MESSAGE where a connection first sends XPC_MSGH_ID_CHECKIN. A libxpc
 * LISTENER drops anything that is not a check-in. If that is what happens, then a pipe client can
 * never reach a connection listener, which would explain why every membership lookup hangs while an
 * echo reached by a connection answers most of the time.
 *
 * The connection client is the control: same binary, same service, same run.
 *
 * WHAT IT ANSWERED SO FAR, AND IT IS NOT AN ANSWER YET. Two runs had the pipe client get rc=0 with a
 * reply while the connection client timed out in the same run, which looked like exactly the split
 * described above. Three runs after that, BOTH timed out, and in two of those the server was up with
 * no listener event at all. Two runs is not a rate -- the same mistake a concurrent target queue
 * already produced once in this file. The pipe/connection difference is UNESTABLISHED; what is
 * established is that the service is flaky in at least two independent ways.
 *
 * xpc_pipe_routine has NO timeout, which is the whole problem being investigated, so it is called on
 * a detached thread and given a deadline here rather than being allowed to hang the probe.
 */
static void *pipe_thread(void *ctx) {
    xpc_object_t *slot = (xpc_object_t *) ctx;
    xpc_pipe_t pipe = xpc_pipe_create(ECHO_SERVICE, 0);

    if (pipe == NULL) {
        printf("CIDER_ECHOPROBE pipe create FAILED\n");
        return NULL;
    }
    xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);

    xpc_dictionary_set_string(message, "cider-probe", "ping-by-pipe");

    xpc_object_t reply = NULL;
    int rc = xpc_pipe_routine(pipe, message, &reply);

    printf("CIDER_ECHOPROBE pipe routine returned rc=%d reply=%s\n", rc, reply ? "yes" : "no");
    *slot = reply;
    return NULL;
}

static const char *ask_by_pipe(int seconds) {
    static xpc_object_t slot;
    pthread_t th;

    slot = NULL;
    if (pthread_create(&th, NULL, pipe_thread, &slot) != 0) {
        return "THREAD-FAILED";
    }
    for (int i = 0; i < seconds * 10; i++) {
        if (slot != NULL) {
            return "REPLY";
        }
        usleep(100000);
    }
    return "TIMEOUT";
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);

    if (argc > 1 && strcmp(argv[1], "--server") == 0) {
        run_server(false);
        return 0;
    }
    if (argc > 1 && strcmp(argv[1], "--server-concurrent") == 0) {
        run_server(true);
        return 0;
    }

    /* The known-negative, so a run whose control is not ERROR says nothing about the rest. */
    printf("CIDER_ECHOPROBE control=%s (a name nothing can serve)\n",
           ask("com.cider.probe.no.such.service.exists", 10));
    printf("CIDER_ECHOPROBE connection " ECHO_SERVICE "=%s\n", ask(ECHO_SERVICE, 20));
    printf("CIDER_ECHOPROBE pipe " ECHO_SERVICE "=%s\n", ask_by_pipe(20));
    return 0;
}
