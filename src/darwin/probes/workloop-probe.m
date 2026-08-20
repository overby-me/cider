/*
 * Does a dispatch WORKLOOP ever run a block?
 *
 * A running, checked-in trustd answers no request at all -- same pid across two pokes, so neither a
 * startup race nor the intermittent crash. Its listener is the ordinary XPC shape, with one thing in
 * it that nothing else in this container uses:
 *
 *     xpc_connection_set_target_queue(connection, SecTrustServerGetWorkloop());
 *
 * and that workloop is dispatch_workloop_create(). A workloop is not an ordinary serial queue: on
 * macOS it is backed by a kqueue workloop in the kernel (kqueue_workloop_ctl / KQ_WORKLOOP), which
 * our emulated kernel may well not have. If a workloop never gets a thread, then every message on
 * that connection is enqueued and never delivered -- which from the client side is exactly a daemon
 * that is up, checked in, and silent.
 *
 * So ask the small question directly rather than instrumenting trustd further. Three blocks, in
 * increasing order of what trustd needs:
 *
 *   1. a plain queue      -- the control, so a probe that prints nothing is known to be broken
 *   2. a workloop async   -- does a workloop run anything at all
 *   3. a source on it     -- what listen_for_sigterm does, since dispatch_activate is a third path
 *
 * The timer that ends the probe runs on the MAIN queue on purpose: if it ran on the workloop, a
 * dead workloop would hang the probe instead of reporting.
 */
#import <dispatch/dispatch.h>
#import <stdio.h>
#import <stdlib.h>
#import <signal.h>
#import <unistd.h>

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);

    dispatch_queue_t plain = dispatch_queue_create("com.cider.probe.plain", NULL);
    dispatch_async(plain, ^{
        printf("CIDER_WL 1 plain queue ran\n");
    });

    printf("CIDER_WL creating workloop\n");
    dispatch_workloop_t wl = dispatch_workloop_create("com.cider.probe.workloop");
    printf("CIDER_WL workloop = %p\n", (void *) wl);

    if (wl) {
        dispatch_async((dispatch_queue_t) wl, ^{
            printf("CIDER_WL 2 workloop block ran\n");
        });

        /*
         * A SOURCE on the workloop, activated rather than resumed -- the third path, and the one
         * that matters: an XPC connection is delivered by a dispatch_mach channel on its target
         * queue, not by a bare async block, so a workloop that runs blocks may still never arm a
         * source.
         *
         * A TIMER, not a signal. The first version of this probe used a SIGUSR1 source and learned
         * nothing, because our signal emulation failed the delivery outright
         * ("sigprocess failed internally while processing Linux signal 10: -14") and killed the
         * probe -- a broken instrument, not an answer. A timer needs nothing from the kernel that
         * the workloop does not already need.
         */
        static dispatch_source_t src;
        src = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, (dispatch_queue_t) wl);
        dispatch_source_set_timer(src, dispatch_time(DISPATCH_TIME_NOW, (int64_t) 2 * NSEC_PER_SEC),
                                  DISPATCH_TIME_FOREVER, 0);
        dispatch_source_set_event_handler(src, ^{
            printf("CIDER_WL 3 workloop TIMER SOURCE fired\n");
        });
        dispatch_activate(src);
    }

    /* The control for 3: the same source on an ordinary queue. If this one is silent too, the
     * finding is about sources, not about workloops. */
    static dispatch_source_t ctl;
    ctl = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, plain);
    dispatch_source_set_timer(ctl, dispatch_time(DISPATCH_TIME_NOW, (int64_t) 2 * NSEC_PER_SEC),
                              DISPATCH_TIME_FOREVER, 0);
    dispatch_source_set_event_handler(ctl, ^{
        printf("CIDER_WL 4 plain-queue timer source fired (control)\n");
    });
    dispatch_activate(ctl);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t) 8 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        printf("CIDER_WL done, 8 seconds elapsed\n");
        exit(0);
    });

    printf("CIDER_WL calling dispatch_main\n");
    dispatch_main();
}
