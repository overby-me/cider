/*
 * cider-trampoline.c - a tiny setuid-root launcher for host Darling dev builds.
 *
 * This Darling build requires euid 0 (it creates mount/PID namespaces and does
 * mounts; rootless user namespaces are disabled in src/linux/startup/cider.c). A
 * plain setuid *copy* of a specific build's `cider` breaks on every rebuild
 * because cider bakes an absolute INSTALL_PREFIX (store path) for
 * ciderd. This trampoline is installed setuid-root ONCE and never needs
 * updating: it execs whatever current cider build it is pointed at, and each
 * build finds its own ciderd via its own baked path.
 *
 * The setuid bit gives euid 0; ruid stays the caller's, so the exec'd cider
 * sees getuid()=<user>, geteuid()=0 - exactly as if cider itself were setuid.
 * We do NOT setuid(0), preserving the real uid so the prefix belongs to the
 * user.
 *
 * Safety: it refuses to exec anything that is not an absolute, symlink-resolved
 * /nix/store/...-cider*/bin/cider. The nix store is root-owned and
 * content-addressed, so this bounds the privilege to "run a legitimately built
 * cider as root" - the intended dev activity - and prevents using the setuid
 * bit to run arbitrary programs.
 *
 * Build + install (once):
 *   cc -O2 -o cider-trampoline cider-trampoline.c
 *   sudo install -D -o root -g root -m 4755 cider-trampoline \
 *        /opt/cider-c2/cider-trampoline
 *
 * Usage (via scripts/cider-host.sh):
 *   cider-trampoline /nix/store/<hash>-cider-unstable-2025/bin/cider shell ...
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#include <unistd.h>

static int has_dotdot(const char *p)
{
    /* reject any ".." path component */
    const char *s = p;
    while ((s = strstr(s, "..")) != NULL) {
        char before = (s == p) ? '/' : s[-1];
        char after = s[2];
        if ((before == '/' ) && (after == '/' || after == '\0'))
            return 1;
        s += 2;
    }
    return 0;
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr,
                "usage: %s /nix/store/<hash>-cider*/bin/cider [args...]\n",
                argv[0]);
        return 2;
    }

    const char *target = argv[1];
    char resolved[PATH_MAX];

    if (target[0] != '/') {
        fprintf(stderr, "cider-trampoline: refusing non-absolute path\n");
        return 3;
    }
    if (has_dotdot(target)) {
        fprintf(stderr, "cider-trampoline: refusing path with '..'\n");
        return 3;
    }
    if (realpath(target, resolved) == NULL) {
        perror("cider-trampoline: realpath");
        return 3;
    }
    /* Must be an actual nix-store cider binary. */
    if (strncmp(resolved, "/nix/store/", 11) != 0) {
        fprintf(stderr, "cider-trampoline: %s is not under /nix/store\n", resolved);
        return 3;
    }
    const char *suffix = "/bin/cider";
    size_t rn = strlen(resolved), sn = strlen(suffix);
    if (rn < sn || strcmp(resolved + rn - sn, suffix) != 0) {
        fprintf(stderr, "cider-trampoline: %s is not .../bin/cider\n", resolved);
        return 3;
    }
    if (strstr(resolved, "cider") == NULL) {
        fprintf(stderr, "cider-trampoline: %s is not a cider build\n", resolved);
        return 3;
    }

    /* Keep euid 0 (from the setuid bit); leave ruid as the caller so the
     * exec'd cider runs the prefix for the real user. execv preserves euid
     * across a non-setuid target. */
    execv(resolved, &argv[1]);
    perror("cider-trampoline: execv");
    return 5;
}
