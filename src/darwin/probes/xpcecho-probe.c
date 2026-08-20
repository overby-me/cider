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
 * WHAT IT ANSWERED: 8 of 18 runs replied. A service that does nothing but reply gets its message
 * about half the time, and the failures are silent on both sides -- the client waits out its own
 * timeout and the listener's event handler simply never fires. So this is not a Security problem at
 * all; it is the substrate under every daemon in the container.
 */
#include <dispatch/dispatch.h>
#include <stdio.h>
#include <string.h>
#include <stdbool.h>
#include <xpc/xpc.h>

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
            fprintf(stderr, "CIDER_ECHO peer event, %sa dictionary\n",
                    xpc_get_type(event) == XPC_TYPE_DICTIONARY ? "" : "NOT ");
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

            fprintf(stderr, "CIDER_ECHO replied\n");
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
    printf("CIDER_ECHOPROBE " ECHO_SERVICE "=%s\n", ask(ECHO_SERVICE, 20));
    return 0;
}
