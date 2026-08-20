/*
 * Does nftw() call its callback for a plain file?
 *
 * MoneyMoney stops on "Could not delete the temporary database file ... check the file permissions
 * of the database directory". The directory is writable and `rm` removes that exact file from a
 * container shell, and a syscall-level trace shows the application NEVER ATTEMPTS the delete: the
 * only unlinks in a whole run are our own Wayland shm files.
 *
 * The reason it never attempts it is one layer up. -[NSFileManager removeItemAtPath:error:] hands
 * the job to NSFilesystemItemRemoveOperation, which does not call unlink itself -- it walks the path
 * with nftw() and calls remove() from the callback. If nftw never invokes the callback, nothing is
 * ever deleted and the caller is told the removal failed, with an errno that has nothing to do with
 * permissions.
 *
 * nftw is built around fts, which is a TREE walker, so the interesting case is the one the
 * application actually uses: a single ordinary FILE, not a directory.
 *
 * WITH BOTH CASES IN ONE RUN, because "nftw is broken" and "nftw does not like plain files" are
 * different findings and only the second explains why a directory-based instrument would have looked
 * healthy.
 */
#include <errno.h>
#include <ftw.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static int seen;

static int visit(const char *path, const struct stat *sb, int flag, struct FTW *info) {
    (void) sb;
    (void) info;
    seen++;
    printf("CIDER_NFTW   visited %s (flag %d)\n", path, flag);
    return 0;
}

static void try_path(const char *what, const char *path) {
    seen = 0;
    errno = 0;

    int rc = nftw(path, visit, 1, FTW_DEPTH);

    printf("CIDER_NFTW %s: nftw(%s) rc=%d errno=%d (%s), callback fired %d time(s)\n",
           what, path, rc, errno, rc == 0 ? "-" : strerror(errno), seen);
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);

    const char *dir = argc > 1 ? argv[1]
                               : "/Users/root/Library/Application Support/MoneyMoney/Database";
    char file[1024];

    snprintf(file, sizeof(file), "%s/cider-nftw-probe.tmp", dir);

    /* Make our own file, so the probe never depends on the application having left one behind. */
    FILE *f = fopen(file, "w");

    if (f == NULL) {
        printf("CIDER_NFTW could not create %s: %s\n", file, strerror(errno));
        return 1;
    }
    fclose(f);

    try_path("a plain FILE, which is what the application removes", file);
    try_path("a DIRECTORY, the control", dir);

    /* Leave nothing behind: unlink directly, which is the path already known to work. */
    if (unlink(file) != 0) {
        printf("CIDER_NFTW cleanup unlink failed: %s\n", strerror(errno));
    }
    return 0;
}
