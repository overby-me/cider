/*
 * test_sandbox_api.c — Regression tests for Darling's sandbox API stubs
 *
 * Build (inside darling shell):
 *   cc -o test_sandbox_api test_sandbox_api.c -lsystem_sandbox
 *
 * Or with the system sandbox library:
 *   cc -o test_sandbox_api test_sandbox_api.c -lsandbox
 *
 * Run:
 *   ./test_sandbox_api
 *
 * Expected: all tests pass (exit 0).
 *
 * See: PLAN.md (Tasks 2.2, 2.3)
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <sys/types.h>

/* sandbox API declarations — these match the real macOS headers */
extern int sandbox_init(const char *profile, uint64_t flags, char **errorbuf);
extern int sandbox_init_with_parameters(const char *profile, uint64_t flags,
                                        const char *const parameters[],
                                        char **errorbuf);
extern int sandbox_init_with_extensions(const char *profile, uint64_t flags,
                                        const char *const extensions[],
                                        char **errorbuf);
extern void sandbox_free_error(char *errorbuf);
extern int sandbox_check(pid_t pid, const char *operation, int type, ...);
extern int sandbox_wakeup_daemon(char **errorbuf);

static int tests_run = 0;
static int tests_passed = 0;
static int tests_failed = 0;

#define TEST(name)                                       \
    do {                                                 \
        tests_run++;                                     \
        printf("  TEST %2d: %-50s ", tests_run, (name)); \
    } while (0)

#define PASS()                     \
    do {                           \
        tests_passed++;            \
        printf("\033[32mPASS\033[0m\n"); \
    } while (0)

#define FAIL(reason)                                          \
    do {                                                      \
        tests_failed++;                                       \
        printf("\033[31mFAIL\033[0m — %s\n", (reason));       \
    } while (0)

/* ── Tests ────────────────────────────────────────────────────────────────── */

static void test_sandbox_init_returns_zero(void)
{
    TEST("sandbox_init returns 0 (success)");
    char *err = (char *)0xDEADBEEF; /* sentinel */
    int ret = sandbox_init("no_network", 0, &err);
    if (ret != 0) {
        FAIL("returned non-zero");
    } else {
        PASS();
    }
}

static void test_sandbox_init_errorbuf_is_null(void)
{
    TEST("sandbox_init sets errorbuf to NULL");
    char *err = (char *)0xDEADBEEF;
    sandbox_init("no_network", 0, &err);
    if (err != NULL) {
        FAIL("errorbuf is not NULL — old bug where it was set to \"Not implemented\"");
    } else {
        PASS();
    }
}

static void test_sandbox_init_with_null_errorbuf(void)
{
    TEST("sandbox_init with NULL errorbuf does not crash");
    /* Some callers may pass NULL for errorbuf if they don't care about
     * the error message.  The stub must not dereference NULL. */
    int ret = sandbox_init("no_network", 0, NULL);
    if (ret != 0) {
        FAIL("returned non-zero");
    } else {
        PASS();
    }
}

static void test_sandbox_init_with_parameters_returns_zero(void)
{
    TEST("sandbox_init_with_parameters returns 0");
    char *err = (char *)0xDEADBEEF;
    const char *params[] = { "key", "value", NULL };
    int ret = sandbox_init_with_parameters("no_network", 0, params, &err);
    if (ret != 0) {
        FAIL("returned non-zero");
    } else {
        PASS();
    }
}

static void test_sandbox_init_with_parameters_errorbuf_is_null(void)
{
    TEST("sandbox_init_with_parameters sets errorbuf to NULL");
    char *err = (char *)0xDEADBEEF;
    const char *params[] = { NULL };
    sandbox_init_with_parameters("no_network", 0, params, &err);
    if (err != NULL) {
        FAIL("errorbuf is not NULL");
    } else {
        PASS();
    }
}

static void test_sandbox_init_with_extensions_returns_zero(void)
{
    TEST("sandbox_init_with_extensions returns 0");
    char *err = (char *)0xDEADBEEF;
    const char *exts[] = { NULL };
    int ret = sandbox_init_with_extensions("no_network", 0, exts, &err);
    if (ret != 0) {
        FAIL("returned non-zero");
    } else {
        PASS();
    }
}

static void test_sandbox_init_with_extensions_errorbuf_is_null(void)
{
    TEST("sandbox_init_with_extensions sets errorbuf to NULL");
    char *err = (char *)0xDEADBEEF;
    const char *exts[] = { NULL };
    sandbox_init_with_extensions("no_network", 0, exts, &err);
    if (err != NULL) {
        FAIL("errorbuf is not NULL");
    } else {
        PASS();
    }
}

static void test_sandbox_check_allows_all(void)
{
    TEST("sandbox_check returns 0 (allowed) for any operation");
    /* sandbox_check returning 0 means the operation is permitted.
     * Our stub should always permit. */
    int ret = sandbox_check(getpid(), "file-read-data", 0);
    if (ret != 0) {
        FAIL("returned non-zero (operation denied)");
    } else {
        PASS();
    }
}

static void test_sandbox_check_network(void)
{
    TEST("sandbox_check allows network operations");
    int ret = sandbox_check(getpid(), "network-outbound", 0);
    if (ret != 0) {
        FAIL("returned non-zero");
    } else {
        PASS();
    }
}

static void test_sandbox_check_process_exec(void)
{
    TEST("sandbox_check allows process-exec");
    int ret = sandbox_check(getpid(), "process-exec", 0);
    if (ret != 0) {
        FAIL("returned non-zero");
    } else {
        PASS();
    }
}

static void test_sandbox_wakeup_daemon_returns_zero(void)
{
    TEST("sandbox_wakeup_daemon returns 0");
    char *err = (char *)0xDEADBEEF;
    int ret = sandbox_wakeup_daemon(&err);
    if (ret != 0) {
        FAIL("returned non-zero");
    } else {
        PASS();
    }
}

static void test_sandbox_wakeup_daemon_errorbuf_is_null(void)
{
    TEST("sandbox_wakeup_daemon sets errorbuf to NULL");
    char *err = (char *)0xDEADBEEF;
    sandbox_wakeup_daemon(&err);
    if (err != NULL) {
        FAIL("errorbuf is not NULL");
    } else {
        PASS();
    }
}

static void test_sandbox_free_error_null(void)
{
    TEST("sandbox_free_error(NULL) does not crash");
    /* sandbox_free_error calls free(), which should handle NULL. */
    sandbox_free_error(NULL);
    PASS();
}

static void test_sandbox_free_error_allocated(void)
{
    TEST("sandbox_free_error(strdup'd) does not crash");
    char *err = strdup("test error");
    sandbox_free_error(err);
    PASS();
}

static void test_sandbox_init_all_profiles(void)
{
    TEST("sandbox_init succeeds for all predefined profiles");
    const char *profiles[] = {
        "no_internet",
        "no_network",
        "no_write",
        "no_write_except_temporary",
        "pure_computation",
        NULL
    };

    int all_ok = 1;
    for (int i = 0; profiles[i] != NULL; i++) {
        char *err = NULL;
        int ret = sandbox_init(profiles[i], 0, &err);
        if (ret != 0 || err != NULL) {
            all_ok = 0;
            break;
        }
    }

    if (all_ok) {
        PASS();
    } else {
        FAIL("one or more predefined profiles failed");
    }
}

/* ── Main ─────────────────────────────────────────────────────────────────── */

int main(int argc, char *argv[])
{
    printf("\n");
    printf("═══════════════════════════════════════════════════════════════\n");
    printf("  Sandbox API regression tests (Phase 2)\n");
    printf("═══════════════════════════════════════════════════════════════\n");
    printf("\n");

    test_sandbox_init_returns_zero();
    test_sandbox_init_errorbuf_is_null();
    test_sandbox_init_with_null_errorbuf();
    test_sandbox_init_with_parameters_returns_zero();
    test_sandbox_init_with_parameters_errorbuf_is_null();
    test_sandbox_init_with_extensions_returns_zero();
    test_sandbox_init_with_extensions_errorbuf_is_null();
    test_sandbox_check_allows_all();
    test_sandbox_check_network();
    test_sandbox_check_process_exec();
    test_sandbox_wakeup_daemon_returns_zero();
    test_sandbox_wakeup_daemon_errorbuf_is_null();
    test_sandbox_free_error_null();
    test_sandbox_free_error_allocated();
    test_sandbox_init_all_profiles();

    printf("\n");
    printf("───────────────────────────────────────────────────────────────\n");
    printf("  Results: %d run, \033[32m%d passed\033[0m, \033[%sm%d failed\033[0m\n",
           tests_run, tests_passed,
           tests_failed > 0 ? "31" : "32",
           tests_failed);
    printf("───────────────────────────────────────────────────────────────\n");
    printf("\n");

    return tests_failed > 0 ? 1 : 0;
}