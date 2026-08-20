/*
 * Does dispatch_main() kill the process on its way out?
 *
 * trustd checks in for its service and then dies with SIGSEGV, and the core says the fault is on the
 * NORMAL exit path of dispatch_main: it parks the main thread by pthread_exit()ing it, our
 * _pthread_tsd_cleanup runs objc's tls_dealloc, and draining that thread's autorelease pool
 * releases an object whose class pointer is already dead.
 *
 * That is a claim about dispatch_main and objc, not about trustd, so it should reproduce in twenty
 * lines. If it does, the whole Security daemon family has one bug and not three, and this is the
 * thing to iterate on rather than a daemon that takes a container boot to reach.
 *
 * Prints at every step, because the interesting outcome is the one that never gets there.
 */
#import <dispatch/dispatch.h>
#import <objc/NSObject.h>
#import <objc/objc.h>
#import <stdio.h>
#import <stdlib.h>

/* NO FOUNDATION ON PURPOSE. The fault is inside libobjc's autorelease pool, and NSObject comes from
 * libobjc itself, so Foundation would add a header chain (CFNetwork, Security) and a great deal of
 * start-up code without bringing the reproducer any closer to the crash. */
@interface NSObject (CiderAutorelease)
- (id)autorelease;
@end

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);

    /*
     * An object in the MAIN THREAD's autorelease pool, which is what tls_dealloc drains. Without
     * one the pool is empty and the probe would pass while saying nothing about the case that
     * crashes.
     */
    id held = [[[NSObject alloc] init] autorelease];

    printf("CIDER_DM autoreleased an NSObject at %p\n", (void *) held);

    dispatch_async(dispatch_get_main_queue(), ^{
        printf("CIDER_DM main queue block ran\n");
    });

    /*
     * DO NOT exit from the block. The first version of this probe did, and it therefore measured
     * NOTHING: the process ended before dispatch_main ever parked the main thread, which is the
     * only thing being tested. The crash under investigation happens DURING the parking, so the
     * probe has to survive long enough to be parked.
     *
     * A timer ends it instead, so a probe that does not crash still terminates.
     */
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t) 8 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        printf("CIDER_DM still alive 8 seconds after dispatch_main, no crash\n");
        exit(0);
    });

    printf("CIDER_DM calling dispatch_main\n");
    dispatch_main();

    /* dispatch_main is noreturn on macOS; reaching this at all is itself a finding. */
    printf("CIDER_DM dispatch_main RETURNED\n");
    return 0;
}
