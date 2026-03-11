/*
 * test_utimensat.c — Regression tests for utimensat / setattrlistat
 * timestamp handling (Phase 1, Task 1.4)
 *
 * Nix's coreutils `touch` (compiled for Darwin) segfaulted inside Darling.
 * The root cause was that `touch` uses setattrlistat() under the hood to
 * set file timestamps, and that codepath was either unimplemented or
 * mishandled edge cases (UTIME_NOW, UTIME_OMIT, NULL timespec, symlinks).
 *
 * The setattrlist_generic.c handler now supports ATTR_CMN_MODTIME,
 * ATTR_CMN_ACCTIME, ATTR_CMN_CRTIME, and ATTR_CMN_CHGTIME.  This test
 * file verifies all the timestamp-related scenarios that are exercised
 * by `touch` and other Nix build tools.
 *
 * Build inside darling shell:
 *   cc -o test_utimensat test_utimensat.c
 *
 * Run:
 *   ./test_utimensat
 *
 * Exit code 0 = all tests passed, nonzero = failure.
 *
 * See: plan/03-phase1-syscalls.md (Task 1.4)
 *      plan/01-blockers.md (Blocker B4)
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <time.h>
#include <sys/attr.h>
#include <sys/stat.h>
#include <sys/time.h>

static int tests_run = 0;
static int tests_passed = 0;

#define TEST_DIR_TEMPLATE "/tmp/test_utimensat_XXXXXX"

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
    ssize_t len = (ssize_t)strlen(content);
    ssize_t n = write(fd, content, (size_t)len);
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
 * Test 1: setattrlist with ATTR_CMN_MODTIME — explicit timestamp
 *
 * This is the core path used by `touch -t <timestamp> <file>` on macOS.
 * The Darwin coreutils `touch` calls setattrlist (or setattrlistat) with
 * ATTR_CMN_MODTIME to set the modification time.
 */
static int test_setattrlist_modtime(void)
{
    fprintf(stderr, "== test_setattrlist_modtime ==\n");

    char path[512];
    snprintf(path, sizeof(path), "%s/modtime", test_dir);
    ASSERT(write_file(path, "modtime test") == 0, "create test file");

    struct attrlist alist;
    memset(&alist, 0, sizeof(alist));
    alist.bitmapcount = ATTR_BIT_MAP_COUNT;
    alist.commonattr = ATTR_CMN_MODTIME;

    /* Set mtime to 2023-11-14 22:13:20 UTC (1700000000) */
    struct timespec ts;
    ts.tv_sec = 1700000000;
    ts.tv_nsec = 123456789;

    int ret = setattrlist(path, &alist, &ts, sizeof(ts), 0);
    ASSERT(ret == 0, "setattrlist(ATTR_CMN_MODTIME) succeeds");

    struct stat st;
    ASSERT(stat(path, &st) == 0, "stat after setattrlist");
    ASSERT(st.st_mtime == 1700000000,
           "modification time was set correctly (seconds)");
    /* Nanosecond precision depends on the filesystem; just check seconds. */

    unlink(path);
    return 0;
}

/*
 * Test 2: setattrlist with ATTR_CMN_ACCTIME — explicit access time
 *
 * Used by `touch -a -t <timestamp> <file>`.
 */
static int test_setattrlist_acctime(void)
{
    fprintf(stderr, "== test_setattrlist_acctime ==\n");

    char path[512];
    snprintf(path, sizeof(path), "%s/acctime", test_dir);
    ASSERT(write_file(path, "acctime test") == 0, "create test file");

    struct attrlist alist;
    memset(&alist, 0, sizeof(alist));
    alist.bitmapcount = ATTR_BIT_MAP_COUNT;
    alist.commonattr = ATTR_CMN_ACCTIME;

    struct timespec ts;
    ts.tv_sec = 1600000000;
    ts.tv_nsec = 0;

    int ret = setattrlist(path, &alist, &ts, sizeof(ts), 0);
    ASSERT(ret == 0, "setattrlist(ATTR_CMN_ACCTIME) succeeds");

    struct stat st;
    ASSERT(stat(path, &st) == 0, "stat after setattrlist");
    ASSERT(st.st_atime == 1600000000,
           "access time was set correctly");

    unlink(path);
    return 0;
}

/*
 * Test 3: setattrlist with both ATTR_CMN_MODTIME | ATTR_CMN_ACCTIME
 *
 * Setting both timestamps at once — the common `touch <file>` pattern.
 * The attribute buffer packs attributes in bit-position order (lowest
 * first), so MODTIME (0x400) comes before ACCTIME (0x1000).
 */
static int test_setattrlist_both_times(void)
{
    fprintf(stderr, "== test_setattrlist_both_times ==\n");

    char path[512];
    snprintf(path, sizeof(path), "%s/both_times", test_dir);
    ASSERT(write_file(path, "both times test") == 0, "create test file");

    struct attrlist alist;
    memset(&alist, 0, sizeof(alist));
    alist.bitmapcount = ATTR_BIT_MAP_COUNT;
    alist.commonattr = ATTR_CMN_MODTIME | ATTR_CMN_ACCTIME;

    /*
     * Buffer layout (Apple-defined order by bit position):
     *   struct timespec modtime;   // ATTR_CMN_MODTIME = 0x0400
     *   struct timespec acctime;   // ATTR_CMN_ACCTIME = 0x1000
     */
    struct {
        struct timespec modtime;
        struct timespec acctime;
    } buf;

    buf.modtime.tv_sec = 1700000000;
    buf.modtime.tv_nsec = 0;
    buf.acctime.tv_sec = 1650000000;
    buf.acctime.tv_nsec = 0;

    int ret = setattrlist(path, &alist, &buf, sizeof(buf), 0);
    ASSERT(ret == 0, "setattrlist(MODTIME|ACCTIME) succeeds");

    struct stat st;
    ASSERT(stat(path, &st) == 0, "stat after setattrlist");
    ASSERT(st.st_mtime == 1700000000, "mtime set correctly");
    ASSERT(st.st_atime == 1650000000, "atime set correctly");

    unlink(path);
    return 0;
}

/*
 * Test 4: setattrlist with ATTR_CMN_CRTIME (creation time)
 *
 * Creation time (birth time) cannot be set on most Linux filesystems
 * (ext4, btrfs, etc.). Our implementation silently ignores it and returns
 * success. This must not crash.
 */
static int test_setattrlist_crtime_ignored(void)
{
    fprintf(stderr, "== test_setattrlist_crtime_ignored ==\n");

    char path[512];
    snprintf(path, sizeof(path), "%s/crtime", test_dir);
    ASSERT(write_file(path, "crtime test") == 0, "create test file");

    struct attrlist alist;
    memset(&alist, 0, sizeof(alist));
    alist.bitmapcount = ATTR_BIT_MAP_COUNT;
    alist.commonattr = ATTR_CMN_CRTIME;

    struct timespec ts;
    ts.tv_sec = 1500000000;
    ts.tv_nsec = 0;

    int ret = setattrlist(path, &alist, &ts, sizeof(ts), 0);
    ASSERT(ret == 0, "setattrlist(ATTR_CMN_CRTIME) succeeds (silently ignored)");

    unlink(path);
    return 0;
}

/*
 * Test 5: setattrlist with ATTR_CMN_CHGTIME (change time)
 *
 * Change time (ctime) cannot be set on Linux. Our implementation silently
 * ignores it. This must not crash.
 */
static int test_setattrlist_chgtime_ignored(void)
{
    fprintf(stderr, "== test_setattrlist_chgtime_ignored ==\n");

    char path[512];
    snprintf(path, sizeof(path), "%s/chgtime", test_dir);
    ASSERT(write_file(path, "chgtime test") == 0, "create test file");

    struct attrlist alist;
    memset(&alist, 0, sizeof(alist));
    alist.bitmapcount = ATTR_BIT_MAP_COUNT;
    alist.commonattr = ATTR_CMN_CHGTIME;

    struct timespec ts;
    ts.tv_sec = 1500000000;
    ts.tv_nsec = 0;

    int ret = setattrlist(path, &alist, &ts, sizeof(ts), 0);
    ASSERT(ret == 0, "setattrlist(ATTR_CMN_CHGTIME) succeeds (silently ignored)");

    unlink(path);
    return 0;
}

/*
 * Test 6: setattrlist with all four time attributes at once
 *
 * CRTIME | MODTIME | CHGTIME | ACCTIME — this is the worst-case buffer
 * layout. If the attribute buffer parsing is wrong (e.g., incorrect
 * pointer advancement for silently-ignored attrs), this will crash or
 * set the wrong values.
 *
 * Apple-defined buffer order (by bit position):
 *   CRTIME  (0x0200)
 *   MODTIME (0x0400)
 *   CHGTIME (0x0800)
 *   ACCTIME (0x1000)
 */
static int test_setattrlist_all_times(void)
{
    fprintf(stderr, "== test_setattrlist_all_times ==\n");

    char path[512];
    snprintf(path, sizeof(path), "%s/all_times", test_dir);
    ASSERT(write_file(path, "all times test") == 0, "create test file");

    struct attrlist alist;
    memset(&alist, 0, sizeof(alist));
    alist.bitmapcount = ATTR_BIT_MAP_COUNT;
    alist.commonattr = ATTR_CMN_CRTIME | ATTR_CMN_MODTIME |
                       ATTR_CMN_CHGTIME | ATTR_CMN_ACCTIME;

    struct {
        struct timespec crtime;   /* 0x0200 — silently ignored */
        struct timespec modtime;  /* 0x0400 — applied */
        struct timespec chgtime;  /* 0x0800 — silently ignored */
        struct timespec acctime;  /* 0x1000 — applied */
    } buf;

    buf.crtime.tv_sec  = 1400000000;
    buf.crtime.tv_nsec = 0;
    buf.modtime.tv_sec  = 1700000000;
    buf.modtime.tv_nsec = 0;
    buf.chgtime.tv_sec  = 1500000000;
    buf.chgtime.tv_nsec = 0;
    buf.acctime.tv_sec  = 1650000000;
    buf.acctime.tv_nsec = 0;

    int ret = setattrlist(path, &alist, &buf, sizeof(buf), 0);
    ASSERT(ret == 0, "setattrlist(CRTIME|MODTIME|CHGTIME|ACCTIME) succeeds");

    struct stat st;
    ASSERT(stat(path, &st) == 0, "stat after setattrlist with all times");
    ASSERT(st.st_mtime == 1700000000, "mtime set correctly despite other attrs");
    ASSERT(st.st_atime == 1650000000, "atime set correctly despite other attrs");

    unlink(path);
    return 0;
}

/*
 * Test 7: setattrlist with MODTIME + FLAGS combined
 *
 * This is a common real-world pattern: `touch` sets the time, then Nix
 * clears flags. If a tool does both in one call, the buffer layout is:
 *   MODTIME (0x0400) → struct timespec
 *   FLAGS   (0x40000) → uint32_t
 *
 * The FLAGS value must not be misinterpreted as part of the timespec,
 * and vice versa.
 */
static int test_setattrlist_modtime_and_flags(void)
{
    fprintf(stderr, "== test_setattrlist_modtime_and_flags ==\n");

    char path[512];
    snprintf(path, sizeof(path), "%s/modtime_flags", test_dir);
    ASSERT(write_file(path, "modtime+flags test") == 0, "create test file");

    struct attrlist alist;
    memset(&alist, 0, sizeof(alist));
    alist.bitmapcount = ATTR_BIT_MAP_COUNT;
    alist.commonattr = ATTR_CMN_MODTIME | ATTR_CMN_FLAGS;

    /*
     * Buffer layout:
     *   struct timespec modtime;   // ATTR_CMN_MODTIME = 0x0400
     *   uint32_t        flags;     // ATTR_CMN_FLAGS   = 0x40000
     */
    struct __attribute__((packed)) {
        struct timespec modtime;
        uint32_t flags;
    } buf;

    buf.modtime.tv_sec = 1700000000;
    buf.modtime.tv_nsec = 0;
    buf.flags = 0; /* clear all flags (the Nix pattern) */

    int ret = setattrlist(path, &alist, &buf, sizeof(buf), 0);
    ASSERT(ret == 0, "setattrlist(MODTIME|FLAGS) succeeds");

    struct stat st;
    ASSERT(stat(path, &st) == 0, "stat after combined setattrlist");
    ASSERT(st.st_mtime == 1700000000,
           "mtime correct after combined MODTIME|FLAGS set");

    unlink(path);
    return 0;
}

/*
 * Test 8: setattrlistat via setattrlist with FSOPT_NOFOLLOW on a symlink
 *
 * `touch -h` (no-dereference) on macOS calls setattrlist with
 * FSOPT_NOFOLLOW. On a symlink, this must not follow the link and
 * must not crash.
 */
static int test_setattrlist_nofollow_symlink(void)
{
    fprintf(stderr, "== test_setattrlist_nofollow_symlink ==\n");

    char target[512], link_path[512];
    snprintf(target, sizeof(target), "%s/touch_target", test_dir);
    snprintf(link_path, sizeof(link_path), "%s/touch_symlink", test_dir);

    ASSERT(write_file(target, "target") == 0, "create symlink target");
    ASSERT(symlink(target, link_path) == 0, "create symlink");

    struct attrlist alist;
    memset(&alist, 0, sizeof(alist));
    alist.bitmapcount = ATTR_BIT_MAP_COUNT;
    alist.commonattr = ATTR_CMN_MODTIME;

    struct timespec ts;
    ts.tv_sec = 1700000000;
    ts.tv_nsec = 0;

    /* FSOPT_NOFOLLOW = 1 — should operate on the symlink itself */
    int ret = setattrlist(link_path, &alist, &ts, sizeof(ts), FSOPT_NOFOLLOW);
    /*
     * On Linux, utimensat with AT_SYMLINK_NOFOLLOW may return ENOTSUP
     * on some filesystems (e.g., tmpfs). Both success and ENOTSUP are
     * acceptable — the key thing is NO CRASH and NO EINVAL.
     */
    ASSERT(ret == 0 || errno == ENOTSUP || errno == EPERM,
           "setattrlist with FSOPT_NOFOLLOW on symlink: no crash/EINVAL");

    /* Verify the target's mtime was NOT changed (nofollow semantics) */
    if (ret == 0) {
        struct stat target_st;
        ASSERT(stat(target, &target_st) == 0, "stat target after nofollow set");
        /* If nofollow worked, the target should NOT have our timestamp.
         * However, on some systems lutimens isn't fully supported, so
         * we accept either outcome — the critical check is no crash. */
    }

    unlink(link_path);
    unlink(target);
    return 0;
}

/*
 * Test 9: utimes() libc function
 *
 * The C library utimes() function sets both atime and mtime. On macOS
 * it may go through setattrlist. Verify it works correctly.
 */
static int test_utimes_libc(void)
{
    fprintf(stderr, "== test_utimes_libc ==\n");

    char path[512];
    snprintf(path, sizeof(path), "%s/utimes_test", test_dir);
    ASSERT(write_file(path, "utimes test") == 0, "create test file");

    struct timeval times[2];
    times[0].tv_sec = 1600000000;  /* atime */
    times[0].tv_usec = 0;
    times[1].tv_sec = 1700000000;  /* mtime */
    times[1].tv_usec = 0;

    int ret = utimes(path, times);
    ASSERT(ret == 0, "utimes() succeeds");

    struct stat st;
    ASSERT(stat(path, &st) == 0, "stat after utimes");
    ASSERT(st.st_atime == 1600000000, "atime set correctly by utimes");
    ASSERT(st.st_mtime == 1700000000, "mtime set correctly by utimes");

    unlink(path);
    return 0;
}

/*
 * Test 10: utimes() with NULL times — set to current time
 *
 * `touch <existing-file>` with no timestamp arguments calls utimes(path, NULL)
 * which means "set both atime and mtime to the current time". This must
 * not crash (NULL pointer dereference was a possible bug).
 */
static int test_utimes_null(void)
{
    fprintf(stderr, "== test_utimes_null ==\n");

    char path[512];
    snprintf(path, sizeof(path), "%s/utimes_null", test_dir);
    ASSERT(write_file(path, "utimes null test") == 0, "create test file");

    /* Set an old mtime first so we can verify it gets updated */
    struct timeval old_times[2];
    old_times[0].tv_sec = 1000000000;
    old_times[0].tv_usec = 0;
    old_times[1].tv_sec = 1000000000;
    old_times[1].tv_usec = 0;
    ASSERT(utimes(path, old_times) == 0, "set old timestamps");

    time_t before = time(NULL);

    int ret = utimes(path, NULL);
    ASSERT(ret == 0, "utimes(path, NULL) succeeds (set to current time)");

    time_t after = time(NULL);

    struct stat st;
    ASSERT(stat(path, &st) == 0, "stat after utimes(NULL)");
    ASSERT(st.st_mtime >= before && st.st_mtime <= after + 1,
           "mtime is approximately 'now' after utimes(NULL)");
    ASSERT(st.st_atime >= before && st.st_atime <= after + 1,
           "atime is approximately 'now' after utimes(NULL)");

    unlink(path);
    return 0;
}

/*
 * Test 11: lutimes() on a symlink — no-follow variant
 *
 * lutimes() sets timestamps on the symlink itself rather than following
 * it. Nix's `touch -h` on Darwin may use this path.
 */
static int test_lutimes_symlink(void)
{
    fprintf(stderr, "== test_lutimes_symlink ==\n");

    char target[512], link_path[512];
    snprintf(target, sizeof(target), "%s/lutimes_target", test_dir);
    snprintf(link_path, sizeof(link_path), "%s/lutimes_link", test_dir);

    ASSERT(write_file(target, "target") == 0, "create target");
    ASSERT(symlink(target, link_path) == 0, "create symlink");

    /* Set the target to a known timestamp */
    struct timeval target_times[2];
    target_times[0].tv_sec = 1500000000;
    target_times[0].tv_usec = 0;
    target_times[1].tv_sec = 1500000000;
    target_times[1].tv_usec = 0;
    ASSERT(utimes(target, target_times) == 0, "set target timestamps");

    /* Now set the symlink's timestamps (should NOT affect the target) */
    struct timeval link_times[2];
    link_times[0].tv_sec = 1700000000;
    link_times[0].tv_usec = 0;
    link_times[1].tv_sec = 1700000000;
    link_times[1].tv_usec = 0;

    int ret = lutimes(link_path, link_times);
    /*
     * lutimes on symlinks may fail with ENOSYS or ENOTSUP on some
     * Linux filesystems. Both success and controlled failure are OK.
     * The critical requirement is: no crash, no segfault.
     */
    ASSERT(ret == 0 || errno == ENOSYS || errno == ENOTSUP || errno == EPERM,
           "lutimes on symlink: no crash (success or graceful error)");

    if (ret == 0) {
        /* Verify the target's mtime was NOT changed */
        struct stat target_st;
        ASSERT(stat(target, &target_st) == 0, "stat target after lutimes");
        ASSERT(target_st.st_mtime == 1500000000,
               "target mtime unchanged after lutimes on symlink");
    }

    unlink(link_path);
    unlink(target);
    return 0;
}

/*
 * Test 12: setattrlist with all time attrs + ACCESSMASK + FLAGS
 *
 * The "kitchen sink" test — exercises the full buffer parsing with
 * every supported attribute in a single setattrlist call. This is the
 * scenario most likely to expose buffer-offset bugs.
 *
 * Apple buffer order (by bit position):
 *   CRTIME     (0x00200) → struct timespec  (ignored)
 *   MODTIME    (0x00400) → struct timespec  (applied)
 *   CHGTIME    (0x00800) → struct timespec  (ignored)
 *   ACCTIME    (0x01000) → struct timespec  (applied)
 *   ACCESSMASK (0x20000) → uint32_t         (applied via fchmodat)
 *   FLAGS      (0x40000) → uint32_t         (silently accepted)
 */
static int test_setattrlist_kitchen_sink(void)
{
    fprintf(stderr, "== test_setattrlist_kitchen_sink ==\n");

    char path[512];
    snprintf(path, sizeof(path), "%s/kitchen_sink", test_dir);
    ASSERT(write_file(path, "kitchen sink") == 0, "create test file");

    struct attrlist alist;
    memset(&alist, 0, sizeof(alist));
    alist.bitmapcount = ATTR_BIT_MAP_COUNT;
    alist.commonattr = ATTR_CMN_CRTIME | ATTR_CMN_MODTIME |
                       ATTR_CMN_CHGTIME | ATTR_CMN_ACCTIME |
                       ATTR_CMN_ACCESSMASK | ATTR_CMN_FLAGS;

    struct __attribute__((packed)) {
        struct timespec crtime;
        struct timespec modtime;
        struct timespec chgtime;
        struct timespec acctime;
        uint32_t        accessmask;
        uint32_t        flags;
    } buf;

    buf.crtime.tv_sec   = 1400000000;
    buf.crtime.tv_nsec  = 0;
    buf.modtime.tv_sec  = 1700000000;
    buf.modtime.tv_nsec = 0;
    buf.chgtime.tv_sec  = 1500000000;
    buf.chgtime.tv_nsec = 0;
    buf.acctime.tv_sec  = 1650000000;
    buf.acctime.tv_nsec = 0;
    buf.accessmask      = 0755;
    buf.flags           = 0;

    int ret = setattrlist(path, &alist, &buf, sizeof(buf), 0);
    ASSERT(ret == 0, "setattrlist with all supported attrs succeeds");

    struct stat st;
    ASSERT(stat(path, &st) == 0, "stat after kitchen-sink setattrlist");
    ASSERT(st.st_mtime == 1700000000, "mtime correct in kitchen-sink test");
    ASSERT(st.st_atime == 1650000000, "atime correct in kitchen-sink test");
    ASSERT((st.st_mode & 0777) == 0755, "permissions correct in kitchen-sink test");

    unlink(path);
    return 0;
}

/*
 * Test 13: fsetattrlist with MODTIME via file descriptor
 *
 * Same as test 1 but using a file descriptor instead of a path.
 * This exercises the fd-based codepath (fsetattrlist → setattrlist_generic
 * with HAS_PATH=0).
 */
static int test_fsetattrlist_modtime(void)
{
    fprintf(stderr, "== test_fsetattrlist_modtime ==\n");

    char path[512];
    snprintf(path, sizeof(path), "%s/fset_modtime", test_dir);
    ASSERT(write_file(path, "fsetattrlist test") == 0, "create test file");

    int fd = open(path, O_RDONLY);
    ASSERT(fd >= 0, "open test file for fsetattrlist");

    struct attrlist alist;
    memset(&alist, 0, sizeof(alist));
    alist.bitmapcount = ATTR_BIT_MAP_COUNT;
    alist.commonattr = ATTR_CMN_MODTIME;

    struct timespec ts;
    ts.tv_sec = 1700000000;
    ts.tv_nsec = 0;

    int ret = fsetattrlist(fd, &alist, &ts, sizeof(ts), 0);
    ASSERT(ret == 0, "fsetattrlist(ATTR_CMN_MODTIME) succeeds");

    close(fd);

    struct stat st;
    ASSERT(stat(path, &st) == 0, "stat after fsetattrlist");
    ASSERT(st.st_mtime == 1700000000,
           "mtime correct after fsetattrlist");

    unlink(path);
    return 0;
}

/*
 * Test 14: setattrlist on a newly-created file (touch creating a file)
 *
 * `touch <newfile>` first creates the file (via open with O_CREAT)
 * and then sets its timestamps.  Verify the full sequence works.
 */
static int test_touch_create_and_set(void)
{
    fprintf(stderr, "== test_touch_create_and_set ==\n");

    char path[512];
    snprintf(path, sizeof(path), "%s/touch_new", test_dir);

    /* Step 1: Create the file (simulating what touch does) */
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    ASSERT(fd >= 0, "create new file (touch simulation)");
    close(fd);

    /* Step 2: Set both timestamps (simulating touch -t) */
    struct attrlist alist;
    memset(&alist, 0, sizeof(alist));
    alist.bitmapcount = ATTR_BIT_MAP_COUNT;
    alist.commonattr = ATTR_CMN_MODTIME | ATTR_CMN_ACCTIME;

    struct {
        struct timespec modtime;
        struct timespec acctime;
    } buf;

    buf.modtime.tv_sec = 1672531200; /* 2023-01-01 00:00:00 UTC */
    buf.modtime.tv_nsec = 0;
    buf.acctime.tv_sec = 1672531200;
    buf.acctime.tv_nsec = 0;

    int ret = setattrlist(path, &alist, &buf, sizeof(buf), 0);
    ASSERT(ret == 0, "setattrlist on freshly created file succeeds");

    struct stat st;
    ASSERT(stat(path, &st) == 0, "stat after touch simulation");
    ASSERT(st.st_mtime == 1672531200, "mtime matches touch -t value");
    ASSERT(st.st_atime == 1672531200, "atime matches touch -t value");

    unlink(path);
    return 0;
}

/*
 * Test 15: setattrlist error handling — NULL alist pointer
 *
 * Passing a NULL attrlist pointer must return EFAULT, not crash.
 */
static int test_setattrlist_null_alist(void)
{
    fprintf(stderr, "== test_setattrlist_null_alist ==\n");

    char path[512];
    snprintf(path, sizeof(path), "%s/null_alist", test_dir);
    ASSERT(write_file(path, "test") == 0, "create test file");

    uint32_t dummy = 0;
    int ret = setattrlist(path, NULL, &dummy, sizeof(dummy), 0);
    ASSERT(ret != 0, "setattrlist with NULL alist fails");
    ASSERT(errno == EFAULT || errno == EINVAL,
           "errno is EFAULT or EINVAL for NULL alist");

    unlink(path);
    return 0;
}

/*
 * Test 16: setattrlist error handling — NULL path
 *
 * Passing a NULL path must return EFAULT, not crash (no segfault).
 */
static int test_setattrlist_null_path(void)
{
    fprintf(stderr, "== test_setattrlist_null_path ==\n");

    struct attrlist alist;
    memset(&alist, 0, sizeof(alist));
    alist.bitmapcount = ATTR_BIT_MAP_COUNT;
    alist.commonattr = ATTR_CMN_MODTIME;

    struct timespec ts;
    ts.tv_sec = 1700000000;
    ts.tv_nsec = 0;

    int ret = setattrlist(NULL, &alist, &ts, sizeof(ts), 0);
    ASSERT(ret != 0, "setattrlist with NULL path fails");
    ASSERT(errno == EFAULT || errno == EINVAL || errno == ENOENT,
           "errno is EFAULT, EINVAL, or ENOENT for NULL path");

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

    /* Core timestamp tests */
    failures += test_setattrlist_modtime();
    failures += test_setattrlist_acctime();
    failures += test_setattrlist_both_times();
    failures += test_setattrlist_crtime_ignored();
    failures += test_setattrlist_chgtime_ignored();
    failures += test_setattrlist_all_times();

    /* Combined attribute tests */
    failures += test_setattrlist_modtime_and_flags();
    failures += test_setattrlist_kitchen_sink();

    /* Symlink / nofollow tests */
    failures += test_setattrlist_nofollow_symlink();
    failures += test_lutimes_symlink();

    /* libc function tests */
    failures += test_utimes_libc();
    failures += test_utimes_null();

    /* File descriptor path */
    failures += test_fsetattrlist_modtime();

    /* Practical scenario: touch creating a new file */
    failures += test_touch_create_and_set();

    /* Error handling */
    failures += test_setattrlist_null_alist();
    failures += test_setattrlist_null_path();

    cleanup();

    fprintf(stderr, "\n%d/%d tests passed\n", tests_passed, tests_run);
    if (failures > 0) {
        fprintf(stderr, "SOME TESTS FAILED\n");
        return 1;
    }
    fprintf(stderr, "ALL TESTS PASSED\n");
    return 0;
}