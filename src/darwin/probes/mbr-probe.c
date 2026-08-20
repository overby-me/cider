/*
 * Does mbr_uid_to_uuid come back?
 *
 * trustd never gets past ExceptionsResetCounterUrl(), which is
 * SecCopyURLForFileInPrivateUserTrustdDirectory, and the first thing that does is
 * mbr_uid_to_uuid(geteuid(), ...). That is a membership lookup: libinfo asks opendirectoryd over an
 * XPC pipe, and xpc_pipe_routine has no timeout.
 *
 * That is a guess until it is measured, and the surrounding function also creates directories, so
 * this asks the one call on its own. Ten lines instead of a daemon that takes a container boot to
 * reach.
 *
 * WITH ITS OWN CONTROL. uid 0 is short-circuited inside libinfo and never leaves the process, so it
 * proves the probe can print an answer at all; a run where uid 0 is silent too is a broken
 * instrument, not a finding about opendirectoryd.
 */
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <uuid/uuid.h>
#include <membership.h>

static void try_uid(const char *what, uid_t uid) {
    uuid_t uu;
    char printable[37];

    printf("CIDER_MBR calling mbr_uid_to_uuid for %s (uid %d)\n", what, (int) uid);
    fflush(stdout);

    int rc = mbr_uid_to_uuid(uid, uu);
    if (rc != 0) {
        printf("CIDER_MBR %s returned rc=%d\n", what, rc);
        return;
    }
    uuid_unparse_lower(uu, printable);
    printf("CIDER_MBR %s returned rc=0 uuid=%s\n", what, printable);
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);

    try_uid("root, the control", 0);

    /*
     * A NON-ZERO uid, because zero is the short circuit. The first run of this probe asked for uid 0
     * twice -- once deliberately and once as our own euid, which in a container shell is also 0 --
     * so both answers came back instantly from inside the process and the run said nothing about
     * opendirectoryd. trustd runs as _trustd, uid 282, which is the case that matters.
     */
    uid_t uid = 282;
    if (argc > 1) {
        uid = (uid_t) atoi(argv[1]);
    }
    try_uid("a non-zero uid, asked as root", uid);

    /*
     * THE SAME QUESTION, ASKED AS _trustd. Asked as root the answer comes straight back as ENOSYS;
     * inside trustd, which launchd runs as uid 282, the identical call never returns. Since that is
     * the one difference between the two, drop to that uid and ask again -- libinfo looks the
     * membership service up with XPC_PIPE_FLAG_PRIVILEGED, so who is asking is not obviously
     * irrelevant.
     *
     * Irreversible, so it goes last.
     */
    if (setgid(uid) != 0 || setuid(uid) != 0) {
        printf("CIDER_MBR could not drop to uid %d, skipping the second half\n", (int) uid);
        return 0;
    }
    printf("CIDER_MBR dropped to euid %d\n", (int) geteuid());
    try_uid("the same uid, asked as itself", uid);

    printf("CIDER_MBR done\n");
    return 0;
}
