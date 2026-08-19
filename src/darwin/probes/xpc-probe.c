/*
 * Did a SERVER answer, or did the client answer for itself?
 *
 * The keychain probe could not tell those apart: its errSecParam came back in runs where secd was
 * not running at all, so "it returned" proved nothing. This asks the question directly, at the XPC
 * layer, where the three outcomes are distinguishable:
 *
 *   REPLY    a reply object came back, so something is listening AND answering
 *   ERROR    XPC itself failed the connection (no such service, invalid), which is an answer too
 *   TIMEOUT  the connection exists and nothing ever replies, which is the shape of the hang
 *
 * IT CARRIES ITS OWN CONTROL. The second name is one nothing can possibly serve, so a run where the
 * control does not come back ERROR is a run whose other results mean nothing. A probe without a
 * control is how the previous one lied for two rungs.
 *
 * Usage: xpc-probe [service-name]   (default com.apple.securityd.general, one of secd's)
 */
#include <dispatch/dispatch.h>
#include <stdio.h>
#include <string.h>
#include <xpc/xpc.h>

static const char *ask(const char *name, int seconds) {
    xpc_connection_t conn = xpc_connection_create_mach_service(name, NULL, 0);

    if (conn == NULL) {
        return "NO-CONNECTION";
    }
    xpc_connection_set_event_handler(conn, ^(xpc_object_t event) {
        (void) event; /* Errors arrive on the reply below as well; this handler is required. */
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
                    /* WHICH error, because they mean opposite things: CONNECTION_INVALID is XPC
                     * saying there is no such service, which is a correct answer; INTERRUPTED
                     * means the server was there and went away. */
                    const char *why = xpc_dictionary_get_string(reply, XPC_ERROR_KEY_DESCRIPTION);

                    snprintf(detail, sizeof(detail), "ERROR(%s)", why ? why : "no description");
                    outcome = detail;
                } else {
                    outcome = "REPLY";
                }
                dispatch_semaphore_signal(done);
            });

    /* BOUNDED ON PURPOSE: the interesting outcome is the one that never comes back, and a probe
     * that blocks forever to observe a block is useless. */
    dispatch_semaphore_wait(done,
                            dispatch_time(DISPATCH_TIME_NOW, (int64_t) seconds * NSEC_PER_SEC));
    return outcome;
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);

    const char *name = argc > 1 ? argv[1] : "com.apple.securityd.general";

    printf("CIDER_XPCPROBE control=%s (a name nothing can serve)\n",
           ask("com.cider.probe.no.such.service.exists", 10));
    printf("CIDER_XPCPROBE %s=%s\n", name, ask(name, 20));
    return 0;
}
