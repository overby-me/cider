/*
 * What bootstrap_register answers, and whether there is a bootstrap port at all.
 *
 * securityd aborts at startup with an uncaught Security::MachPlusPlus::Error thrown from
 * Bootstrap::registerAs, which is one line: check(::bootstrap_register(mPort, name, port)). The
 * exception carries the kern_return_t and nothing prints it, so this does the same three calls a
 * ReceivePort constructor does and prints each result. Without securityd every keychain call blocks
 * forever, which is where MoneyMoney stops.
 *
 * It registers a name of its own under com.cider.probe so it cannot collide with a real service.
 */
#import <mach/mach.h>
#import <servers/bootstrap.h>
#import <stdio.h>

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);

    printf("CIDER_BOOTSTRAP bootstrap_port=0x%x\n", (unsigned) bootstrap_port);

    mach_port_t port = MACH_PORT_NULL;
    kern_return_t kr = mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &port);

    printf("CIDER_BOOTSTRAP mach_port_allocate=%d port=0x%x\n", (int) kr, (unsigned) port);
    if (kr != KERN_SUCCESS) {
        return 1;
    }

    kr = mach_port_insert_right(mach_task_self(), port, port, MACH_MSG_TYPE_MAKE_SEND);
    printf("CIDER_BOOTSTRAP mach_port_insert_right=%d\n", (int) kr);

    /*
     * THE NAME IS THE VARIABLE. A name of this probe's own registers fine; the question is what
     * happens for a name launchd already declares for a job, which is what securityd does with
     * com.apple.SecurityServer.
     */
    const char *name = argc > 1 ? argv[1] : "com.cider.probe.receiveport";

    /*
     * CHECK IN FIRST, which is what Security's ReceivePort does: it only falls back to registering
     * when checkInOptional answers nothing, and checkInOptional swallows SERVICE_ACTIVE,
     * UNKNOWN_SERVICE and NOT_PRIVILEGED into that nothing. So the number this prints is the one
     * that decides whether securityd lives, and it is invisible from inside Security.
     */
    mach_port_t checked = MACH_PORT_NULL;
    kern_return_t ckr = bootstrap_check_in(bootstrap_port, (char *) name, &checked);

    printf("CIDER_BOOTSTRAP bootstrap_check_in(%s)=%d port=0x%x\n", name, (int) ckr,
           (unsigned) checked);

    kr = bootstrap_register(bootstrap_port, (char *) name, port);
    printf("CIDER_BOOTSTRAP bootstrap_register(%s)=%d\n", name, (int) kr);

    mach_port_t found = MACH_PORT_NULL;
    kr = bootstrap_look_up(bootstrap_port, (char *) name, &found);
    printf("CIDER_BOOTSTRAP bootstrap_look_up=%d port=0x%x\n", (int) kr, (unsigned) found);
    return 0;
}
