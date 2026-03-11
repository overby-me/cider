/*
 * sandbox-exec stub for Darling
 *
 * This is a minimal replacement for macOS's /usr/bin/sandbox-exec.
 * It parses (and ignores) all sandbox-related arguments, then exec's
 * the remaining command.
 *
 * Darling already provides Linux-level isolation via namespaces and
 * darlingserver, so skipping the macOS sandbox is safe for build
 * isolation purposes.
 *
 * Usage (matches real sandbox-exec):
 *   sandbox-exec [-f <profile-path>] [-p <profile-string>]
 *                [-n <profile-name>] [-D <key>=<value>]...
 *                <command> [args...]
 *
 * See: plan/04-phase2-sandbox.md (Task 2.1)
 */

#include <unistd.h>
#include <string.h>
#include <stdio.h>
#include <errno.h>

static void usage(const char *progname)
{
    fprintf(stderr,
        "Usage: %s [-f profile_path] [-p profile_string] [-n profile_name]\n"
        "       %*s [-D key=value]... command [arguments ...]\n",
        progname, (int)strlen(progname) + 7, "");
}

int main(int argc, char *argv[])
{
    int i = 1;

    while (i < argc) {
        /*
         * -f <profile>   : sandbox profile file path
         * -p <string>    : inline sandbox profile string
         * -n <name>      : predefined profile name
         * -D <key=value> : parameter definition for the profile
         *
         * All of these take one argument after the flag (with a space),
         * except -D which may also appear as -Dkey=value (no space).
         */
        if ((strcmp(argv[i], "-f") == 0 ||
             strcmp(argv[i], "-p") == 0 ||
             strcmp(argv[i], "-n") == 0 ||
             strcmp(argv[i], "-D") == 0) && i + 1 < argc) {
            i += 2; /* skip flag + its argument */
        } else if (strncmp(argv[i], "-D", 2) == 0 && argv[i][2] != '\0') {
            i += 1; /* skip -Dkey=value (no space) */
        } else if (strcmp(argv[i], "--") == 0) {
            i += 1; /* skip -- separator */
            break;
        } else if (argv[i][0] == '-') {
            fprintf(stderr, "sandbox-exec: unknown option '%s'\n", argv[i]);
            usage(argv[0]);
            return 1;
        } else {
            break; /* first non-option argument is the command */
        }
    }

    if (i >= argc) {
        fprintf(stderr, "sandbox-exec: no command specified\n");
        usage(argv[0]);
        return 1;
    }

    execvp(argv[i], &argv[i]);

    /* If we get here, exec failed */
    fprintf(stderr, "sandbox-exec: exec '%s': %s\n",
            argv[i], strerror(errno));
    return 127;
}