/*
 * Do timers fire, and which layer loses them?
 *
 * WHY: a dispatch timer source is created, configured and resumed here without complaint and its
 * handler is never called. That was found while implementing CVDisplayLink, whose first version
 * used one; src/darwin/kqueue-probe/displaylink.c reported verdict=NEVER-FIRED. Task #240.
 *
 * TWO LAYERS IN ONE RUN, because that is the whole question. libkqueue implements EVFILT_TIMER over
 * timerfd and filter.c registers it, so the filter is present; libdispatch may or may not be the
 * thing that uses it. A probe that only tests dispatch cannot say which of the two is at fault, and
 * the fixes are in different code.
 *
 * THREE CASES, because the third is the one that actually failed. A source is documented to retain
 * its target queue, so releasing the queue right after creating the source is legal and common.
 * The CVDisplayLink version that never fired did exactly that; this probe, which held the queue
 * until the end, fired 20 of 20. If the port does not take that retain, the queue dies under the
 * source and the timer goes quiet with every call having reported success.
 *
 * A PROBE, NOT A TEST CASE: it prints what it saw and exits 0 either way.
 */

#include <dispatch/dispatch.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/event.h>
#include <sys/time.h>
#include <unistd.h>

#define INTERVAL_MS 100
#define WINDOW_SECONDS 2
/* At one fire per INTERVAL_MS, a WINDOW_SECONDS window should see about this many. Reported
 * alongside the count so a low number is visibly low rather than merely a number. */
#define EXPECTED ((WINDOW_SECONDS * 1000) / INTERVAL_MS)

static void kqueue_timer(void)
{
    int kq = kqueue();
    if (kq < 0) {
        printf("timers-probe kqueue open=FAILED errno=%d %s\n", errno, strerror(errno));
        return;
    }

    struct kevent change;
    EV_SET(&change, 1, EVFILT_TIMER, EV_ADD | EV_ENABLE, 0, INTERVAL_MS, NULL);
    if (kevent(kq, &change, 1, NULL, 0, NULL) < 0) {
        printf("timers-probe kqueue register=FAILED errno=%d %s\n", errno, strerror(errno));
        close(kq);
        return;
    }
    printf("timers-probe kqueue registered interval=%dms\n", INTERVAL_MS);

    int fires = 0;
    struct timespec deadline = { .tv_sec = WINDOW_SECONDS, .tv_nsec = 0 };
    struct timespec started, now;
    clock_gettime(CLOCK_MONOTONIC, &started);
    for (;;) {
        struct kevent event;
        int n = kevent(kq, NULL, 0, &event, 1, &deadline);
        if (n > 0)
            fires++;
        clock_gettime(CLOCK_MONOTONIC, &now);
        if (now.tv_sec - started.tv_sec >= WINDOW_SECONDS)
            break;
    }
    close(kq);
    printf("timers-probe kqueue fires=%d expected=%d verdict=%s\n", fires, EXPECTED,
        fires > 0 ? "FIRES" : "NEVER-FIRED");
}

static void dispatch_timer(void)
{
    dispatch_queue_t queue = dispatch_queue_create("org.darlinghq.cider.timerprobe", NULL);
    dispatch_source_t timer =
        dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    if (timer == NULL) {
        printf("timers-probe dispatch create=FAILED\n");
        return;
    }

    __block int fires = 0;
    uint64_t interval = (uint64_t) INTERVAL_MS * 1000000ull;
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t) interval),
        interval, interval / 10);
    dispatch_source_set_event_handler(timer, ^{ fires++; });
    dispatch_resume(timer);
    printf("timers-probe dispatch registered interval=%dms\n", INTERVAL_MS);

    sleep(WINDOW_SECONDS);
    dispatch_source_cancel(timer);
    printf("timers-probe dispatch fires=%d expected=%d verdict=%s\n", fires, EXPECTED,
        fires > 0 ? "FIRES" : "NEVER-FIRED");
    dispatch_release(timer);
    dispatch_release(queue);
}

/* The same dispatch timer, with the queue released as soon as the source exists. */
static void dispatch_timer_queue_released_early(void)
{
    dispatch_queue_t queue = dispatch_queue_create("org.darlinghq.cider.timerprobe2", NULL);
    dispatch_source_t timer =
        dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    dispatch_release(queue);
    if (timer == NULL) {
        printf("timers-probe dispatch-early create=FAILED\n");
        return;
    }

    __block int fires = 0;
    uint64_t interval = (uint64_t) INTERVAL_MS * 1000000ull;
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t) interval),
        interval, interval / 10);
    dispatch_source_set_event_handler(timer, ^{ fires++; });
    dispatch_resume(timer);
    printf("timers-probe dispatch-early registered interval=%dms queue released before resume\n",
        INTERVAL_MS);

    sleep(WINDOW_SECONDS);
    dispatch_source_cancel(timer);
    printf("timers-probe dispatch-early fires=%d expected=%d verdict=%s\n", fires, EXPECTED,
        fires > 0 ? "FIRES" : "NEVER-FIRED");
    dispatch_release(timer);
}

int main(void)
{
    setvbuf(stdout, NULL, _IOLBF, 0);
    kqueue_timer();
    dispatch_timer();
    dispatch_timer_queue_released_early();
    printf("timers-probe done\n");
    return 0;
}
