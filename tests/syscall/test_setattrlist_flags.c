/*
 * test_setattrlist_flags.c — Regression tests for setattrlist/getattrlist
 * with ATTR_CMN_FLAGS support.
 *
 * This is the core blocker for Nix inside Darling: nix-env calls
 * lchflags(path, 0) which decomposes into setattrlist() with
 * ATTR_CMN_FLAGS. Previously this returned EINVAL because the flag
 * was not in COMMON_SUPPORTED.
 *
 * Build inside cider shell:
 *   cc -o test_setattrlist_flags test_setattrlist_flags.c
 *
 * Run:
 *   ./test_setattrlist_flags
 *
 * Exit code 0 = all tests passed, nonzero = failure.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/attr.h>
#include <sys/stat.h>

static int tests_run = 0;
static int tests_passed = 0;

#define TEST_DIR_TEMPLATE "/tmp/test_setattrlist_XXXXXX"

static char test_dir[256];

static void cleanup(void)
{
    char cmd[512];
    snprintf(cmd, sizeof(cmd), "rm -rf %s", test_dir);
    system(cmd);
}

static int write_file(const char *path, const char *content)
{
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0)
        return -1;
    ssize_t len = strlen(content);
    ssize_t n = write(fd, content, len);
    close(fd);
    return (n == len) ? 0 : -1;
}

#define ASSERT(cond, msg)                                                      \
    do {                                                                        \
        tests_run++;                                                            \
        if (!(cond)) {                                                          \
            fprintf(stderr, "  FAIL [%d]: %s (errno=%d: %s)\n",                \
                    tests_run, msg, errno, strerror(errno));                    \
            return 1;                                                           \
        }                                                                       \
        tests_passed++;                                                         \
        fprintf(stderr, "  PASS [%d]: %s\n", tests_run, msg);                  \
    } while (0)

/* ------------------------------------------------------------------ */

/*
 * Test 1: setattrlist with ATTR_CMN_FLAGS = 0
 *
 * This is the exact pattern used by Nix's lchflags(path, 0):
 *
 *   struct attrlist alist = { .bitmapcount = ATTR_BIT_MAP_COUNT,
 *                             .commonattr  = ATTR_CMN_FLAGS };
 *   uint32_t flags = 0;
 *   setattrlist(path, &alist, &flags, sizeof(flags), FSOPT_NOFOLLOW);
 *
 * Before our fix this returned EINVAL; now it must return 0.
 */
static int test_setattrlist_clear_flags(void)
{
    fprintf(stderr, "== test_setattrlist_clear_flags ==\n");

    char path[512];
    snprintf(path, sizeof(path), "%s/clearflags", test_dir);
    ASSERT(write_file(path, "test") == 0, "create test file");

    struct attrlist alist;
    memset(&alist, 0, sizeof(alist));
    alist.bitmapcount = ATTR_BIT_MAP_COUNT;
    alist.commonattr = ATTR_CMN_FLAGS;

    uint32_t flags = 0;
    int ret = setattrlist(path, &alist, &flags, sizeof(flags), FSOPT_NOFOLLOW);
    ASSERT(ret == 0, "setattrlist(ATTR_CMN_FLAGS=0) returns 0 (clear flags)");

    unlink(path);
    return 0;
}

/*
 * Test 2: setattrlist with ATTR_CMN_FLAGS = nonzero
 *
 * Setting nonzero flags (e.g., UF_IMMUTABLE) should also succeed
 * (silently ignored) rather than crash or return EINVAL. The key
 * contract is that the syscall doesn't reject the attribute.
 */
static int test_setattrlist_nonzero_flags(void)
{
    fprintf(stderr, "== test_setattrlist_nonzero_flags ==\n");

    char path[512];
    snprintf(path, sizeof(path), "%s/nonzeroflags", test_dir);
    ASSERT(write_file(path, "test") == 0, "create test file");

    struct attrlist alist;
    memset(&alist, 0, sizeof(alist));
    alist.bitmapcount = ATTR_BIT_MAP_COUNT;
    alist.commonattr = ATTR_CMN_FLAGS;

    /* UF_IMMUTABLE = 0x00000002 on macOS */
    uint32_t flags = 0x00000002;
    int ret = setattrlist(path, &alist, &flags, sizeof(flags), FSOPT_NOFOLLOW);
    /* We accept either success (silently ignored) or ENOTSUP (fs doesn't
     * support flags). Both are fine for Nix. The important thing is that
     * it does NOT return EINVAL. */
    ASSERT(ret == 0 || errno == ENOTSUP,
           "setattrlist(ATTR_CMN_FLAGS=UF_IMMUTABLE) does not return EINVAL");

    unlink(path);
    return 0;
}

/*
 * Test 3: getattrlist with ATTR_CMN_FLAGS
 *
 * Reading flags should return a buffer with flags == 0 (our stub
 * always returns 0 since Linux doesn't track macOS file flags).
 */
static int test_getattrlist_flags(void)
{
    fprintf(stderr, "== test_getattrlist_flags ==\n");

    char path[512];
    snprintf(path, sizeof(path), "%s/getflags", test_dir);
    ASSERT(write_file(path, "test") == 0, "create test file");

    struct attrlist alist;
    memset(&alist, 0, sizeof(alist));
    alist.bitmapcount = ATTR_BIT_MAP_COUNT;
    alist.commonattr = ATTR_CMN_FLAGS;

    /*
     * getattrlist returns:
     *   uint32_t length;    (total size of returned data)
     *   uint32_t flags;     (the ATTR_CMN_FLAGS value)
     */
    struct __attribute__((packed)) {
        uint32_t length;
        uint32_t flags;
    } buf;
    memset(&buf, 0xFF, sizeof(buf)); /* fill with sentinel */

    int ret = getattrlist(path, &alist, &buf, sizeof(buf), FSOPT_NOFOLLOW);
    ASSERT(ret == 0, "getattrlist(ATTR_CMN_FLAGS) returns 0");
    ASSERT(buf.flags == 0,
           "getattrlist reports flags == 0 (no macOS flags on Linux)");

    unlink(path);
    return 0;
}

/*
 * Test 4: Read-modify-write cycle (getattrlist then setattrlist)
 *
 * This is what many macOS programs do:
 *   1. Read current flags via getattrlist
 *   2. Modify a flag bit
 *   3. Write back via setattrlist
 *
 * Must not crash or return EINVAL at any step.
 */
static int test_read_modify_write(void)
{
    fprintf(stderr, "== test_read_modify_write ==\n");

    char path[512];
    snprintf(path, sizeof(path), "%s/rmw", test_dir);
    ASSERT(write_file(path, "test") == 0, "create test file");

    /* Step 1: Read flags */
    struct attrlist alist;
    memset(&alist, 0, sizeof(alist));
    alist.bitmapcount = ATTR_BIT_MAP_COUNT;
    alist.commonattr = ATTR_CMN_FLAGS;

    struct __attribute__((packed)) {
        uint32_t length;
        uint32_t flags;
    } buf;
    memset(&buf, 0, sizeof(buf));

    int ret = getattrlist(path, &alist, &buf, sizeof(buf), FSOPT_NOFOLLOW);
    ASSERT(ret == 0, "read: getattrlist succeeds");

    /* Step 2: Clear all flags (the Nix pattern) */
    uint32_t new_flags = buf.flags & ~0x00000002; /* clear UF_IMMUTABLE */
    ret = setattrlist(path, &alist, &new_flags, sizeof(new_flags), FSOPT_NOFOLLOW);
    ASSERT(ret == 0, "write: setattrlist with modified flags succeeds");

    /* Step 3: Verify by reading again */
    memset(&buf, 0xFF, sizeof(buf));
    ret = getattrlist(path, &alist, &buf, sizeof(buf), FSOPT_NOFOLLOW);
    ASSERT(ret == 0, "verify: getattrlist succeeds");
    ASSERT(buf.flags == 0, "verify: flags are still 0");

    unlink(path);
    return 0;
}

/*
 * Test 5: lchflags(path, 0) — the actual libc function
 *
 * On macOS, lchflags is defined as:
 *   struct attrlist a = { ATTR_BIT_MAP_COUNT, 0, ATTR_CMN_FLAGS, ... };
 *   return setattrlist(path, &a, &flags, sizeof(flags), FSOPT_NOFOLLOW);
 *
 * This test calls the libc wrapper directly.
 */
static int test_lchflags_zero(void)
{
    fprintf(stderr, "== test_lchflags_zero ==\n");

    char path[512];
    snprintf(path, sizeof(path), "%s/lchflags_test", test_dir);
    ASSERT(write_file(path, "test") == 0, "create test file");

    int ret = lchflags(path, 0);
    ASSERT(ret == 0, "lchflags(path, 0) returns 0");

    unlink(path);
    return 0;
}

/*
 * Test 6: chflags(path, 0) — follows symlinks variant
 */
static int test_chflags_zero(void)
{
    fprintf(stderr, "== test_chflags_zero ==\n");

    char path[512];
    snprintf(path, sizeof(path), "%s/chflags_test", test_dir);
    ASSERT(write_file(path, "test") == 0, "create test file");

    int ret = chflags(path, 0);
    ASSERT(ret == 0, "chflags(path, 0) returns 0");

    unlink(path);
    return 0;
}

/*
 * Test 7: setattrlist with ATTR_CMN_FLAGS on a symlink (FSOPT_NOFOLLOW)
 *
 * Nix commonly calls lchflags on symlinks too. This must not crash.
 */
static int test_setattrlist_flags_on_symlink(void)
{
    fprintf(stderr, "== test_setattrlist_flags_on_symlink ==\n");

    char target[512], link_path[512];
    snprintf(target, sizeof(target), "%s/symtarget", test_dir);
    snprintf(link_path, sizeof(link_path), "%s/symlink", test_dir);

    ASSERT(write_file(target, "target") == 0, "create symlink target");
    ASSERT(symlink(target, link_path) == 0, "create symlink");

    struct attrlist alist;
    memset(&alist, 0, sizeof(alist));
    alist.bitmapcount = ATTR_BIT_MAP_COUNT;
    alist.commonattr = ATTR_CMN_FLAGS;

    uint32_t flags = 0;
    int ret = setattrlist(link_path, &alist, &flags, sizeof(flags), FSOPT_NOFOLLOW);
    ASSERT(ret == 0, "setattrlist(ATTR_CMN_FLAGS=0) on symlink with NOFOLLOW succeeds");

    unlink(link_path);
    unlink(target);
    return 0;
}

/*
 * Test 8: setattrlist with multiple attributes including ATTR_CMN_FLAGS
 *
 * When ATTR_CMN_FLAGS is combined with other attrs (e.g., ATTR_CMN_MODTIME),
 * the buffer layout must be parsed correctly. The flags value comes after
 * the time values in the attribute buffer.
 */
static int test_setattrlist_combined_attrs(void)
{
    fprintf(stderr, "== test_setattrlist_combined_attrs ==\n");

    char path[512];
    snprintf(path, sizeof(path), "%s/combined", test_dir);
    ASSERT(write_file(path, "combined") == 0, "create test file");

    struct attrlist alist;
    memset(&alist, 0, sizeof(alist));
    alist.bitmapcount = ATTR_BIT_MAP_COUNT;
    alist.commonattr = ATTR_CMN_MODTIME | ATTR_CMN_FLAGS;

    /*
     * Buffer layout for ATTR_CMN_MODTIME | ATTR_CMN_FLAGS:
     *   struct timespec modtime;
     *   uint32_t        flags;
     */
    struct __attribute__((packed)) {
        struct timespec modtime;
        uint32_t flags;
    } buf;

    buf.modtime.tv_sec = 1700000000; /* some timestamp */
    buf.modtime.tv_nsec = 0;
    buf.flags = 0;

    int ret = setattrlist(path, &alist, &buf, sizeof(buf), 0);
    ASSERT(ret == 0,
           "setattrlist(MODTIME|FLAGS) with combined attrs succeeds");

    /* Verify the modtime was actually set */
    struct stat st;
    ASSERT(stat(path, &st) == 0, "stat after setattrlist succeeds");
    ASSERT(st.st_mtime == 1700000000,
           "modification time was set correctly");

    unlink(path);
    return 0;
}

/*
 * Test 9: fsetattrlist with ATTR_CMN_FLAGS via file descriptor
 */
static int test_fsetattrlist_flags(void)
{
    fprintf(stderr, "== test_fsetattrlist_flags ==\n");

    char path[512];
    snprintf(path, sizeof(path), "%s/fset_flags", test_dir);
    ASSERT(write_file(path, "test") == 0, "create test file");

    int fd = open(path, O_RDONLY);
    ASSERT(fd >= 0, "open test file");

    struct attrlist alist;
    memset(&alist, 0, sizeof(alist));
    alist.bitmapcount = ATTR_BIT_MAP_COUNT;
    alist.commonattr = ATTR_CMN_FLAGS;

    uint32_t flags = 0;
    int ret = fsetattrlist(fd, &alist, &flags, sizeof(flags), 0);
    ASSERT(ret == 0, "fsetattrlist(ATTR_CMN_FLAGS=0) returns 0");

    close(fd);
    unlink(path);
    return 0;
}

/*
 * Test 10: Verify setattrlist rejects truly unsupported attributes
 *
 * Sanity check that we haven't accidentally accepted everything — attrs
 * that are genuinely not supported should still return EINVAL.
 */
static int test_setattrlist_rejects_unsupported(void)
{
    fprintf(stderr, "== test_setattrlist_rejects_unsupported ==\n");

    char path[512];
    snprintf(path, sizeof(path), "%s/unsupported", test_dir);
    ASSERT(write_file(path, "test") == 0, "create test file");

    struct attrlist alist;
    memset(&alist, 0, sizeof(alist));
    alist.bitmapcount = ATTR_BIT_MAP_COUNT;
    /* ATTR_CMN_NAME = 0x00000001 — should not be settable */
    alist.commonattr = 0x00000001;

    uint32_t dummy = 0;
    int ret = setattrlist(path, &alist, &dummy, sizeof(dummy), 0);
    ASSERT(ret != 0, "setattrlist rejects unsupported ATTR_CMN_NAME");
    ASSERT(errno == EINVAL, "errno is EINVAL for unsupported attribute");

    unlink(path);
    return 0;
}

/* ------------------------------------------------------------------ */

int main(void)
{
    /* Create temporary directory */
    strncpy(test_dir, TEST_DIR_TEMPLATE, sizeof(test_dir));
    if (!mkdtemp(test_dir)) {
        perror("mkdtemp");
        return 1;
    }

    fprintf(stderr, "Test dir: %s\n\n", test_dir);

    int failures = 0;
    failures += test_setattrlist_clear_flags();
    failures += test_setattrlist_nonzero_flags();
    failures += test_getattrlist_flags();
    failures += test_read_modify_write();
    failures += test_lchflags_zero();
    failures += test_chflags_zero();
    failures += test_setattrlist_flags_on_symlink();
    failures += test_setattrlist_combined_attrs();
    failures += test_fsetattrlist_flags();
    failures += test_setattrlist_rejects_unsupported();

    cleanup();

    fprintf(stderr, "\n%d/%d tests passed\n", tests_passed, tests_run);
    if (failures > 0) {
        fprintf(stderr, "SOME TESTS FAILED\n");
        return 1;
    }
    fprintf(stderr, "ALL TESTS PASSED\n");
    return 0;
}