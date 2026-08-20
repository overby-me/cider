/*
 * test_identity.c — Regression tests for the macOS version identity that
 * Darling reports to Nix and to nixpkgs builds (Phase A).
 *
 * nixpkgs >= 25.11 requires a macOS 14 (Sonoma) class host; official 26.05
 * x86_64-darwin binaries link the macOS 14.0 symbol surface. Darling must
 * therefore report a macOS-14 / Darwin-23 identity consistently across
 * uname(3) and the kern.* sysctls.
 *
 * Build inside darling shell:
 *   cc -o test_identity test_identity.c
 * Run:
 *   ./test_identity
 *
 * Exit code 0 = all tests passed, nonzero = failure. On the un-bumped
 * baseline (macOS 11.7.4 / Darwin 20.6.0) this test is expected to FAIL;
 * Phase A.2 turns it green.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <sys/utsname.h>
#include <sys/sysctl.h>

/* ── Target identity (macOS 14.4.1 / build 23E224 / Darwin 23.4.0) ──
 * Keep in sync with src/frameworks/CoreServices/SystemVersion.plist and the
 * xnu masquerade patch (patches/xnu/). See PLAN.md. */
#define EXPECT_PRODUCT_VERSION   "14.4.1"
#define EXPECT_BUILD_VERSION     "23E224"
#define EXPECT_KERNEL_MAJOR      23   /* Darwin 23.x == macOS 14 Sonoma */
#define EXPECT_PRODUCT_MAJOR     14

static int tests_run = 0;
static int tests_passed = 0;

#define ASSERT(cond, msg)                                              \
    do {                                                               \
        tests_run++;                                                   \
        if (cond) {                                                    \
            tests_passed++;                                            \
            fprintf(stderr, "  PASS [%d]: %s\n", tests_run, msg);      \
        } else {                                                       \
            fprintf(stderr, "  FAIL [%d]: %s\n", tests_run, msg);      \
        }                                                              \
    } while (0)

static int sysctl_str(const char *name, char *buf, size_t bufsz)
{
    size_t n = bufsz;
    if (sysctlbyname(name, buf, &n, NULL, 0) != 0)
        return -1;
    buf[bufsz - 1] = '\0';
    return 0;
}

/* Parse the leading integer of a dotted version string ("23.4.0" -> 23). */
static int major_of(const char *s)
{
    return (int) strtol(s, NULL, 10);
}

int main(void)
{
    char buf[256];
    struct utsname uts;

    fprintf(stderr, "== Darling macOS identity ==\n");

    /* uname(3) */
    if (uname(&uts) == 0) {
        fprintf(stderr, "  uname: sysname=%s release=%s version=%.40s...\n",
                uts.sysname, uts.release, uts.version);
        ASSERT(strcmp(uts.sysname, "Darwin") == 0, "uname sysname is Darwin");
        ASSERT(major_of(uts.release) == EXPECT_KERNEL_MAJOR,
               "uname release is Darwin 23.x (Sonoma)");
    } else {
        ASSERT(0, "uname(3) succeeds");
    }

    /* kern.osrelease — Darwin kernel version, e.g. 23.4.0 */
    if (sysctl_str("kern.osrelease", buf, sizeof(buf)) == 0) {
        fprintf(stderr, "  kern.osrelease = %s\n", buf);
        ASSERT(major_of(buf) == EXPECT_KERNEL_MAJOR,
               "kern.osrelease major is 23");
    } else {
        ASSERT(0, "sysctl kern.osrelease readable");
    }

    /* kern.osproductversion — macOS product version, e.g. 14.4.1 */
    if (sysctl_str("kern.osproductversion", buf, sizeof(buf)) == 0) {
        fprintf(stderr, "  kern.osproductversion = %s\n", buf);
        ASSERT(major_of(buf) == EXPECT_PRODUCT_MAJOR,
               "kern.osproductversion major is 14");
        ASSERT(strcmp(buf, EXPECT_PRODUCT_VERSION) == 0,
               "kern.osproductversion == " EXPECT_PRODUCT_VERSION);
    } else {
        ASSERT(0, "sysctl kern.osproductversion readable");
    }

    /* kern.osversion — macOS build id, e.g. 23E224 */
    if (sysctl_str("kern.osversion", buf, sizeof(buf)) == 0) {
        fprintf(stderr, "  kern.osversion = %s\n", buf);
        ASSERT(strcmp(buf, EXPECT_BUILD_VERSION) == 0,
               "kern.osversion == " EXPECT_BUILD_VERSION);
    } else {
        ASSERT(0, "sysctl kern.osversion readable");
    }

    fprintf(stderr, "Tests: %d/%d passed\n", tests_passed, tests_run);
    return (tests_passed == tests_run) ? 0 : 1;
}
