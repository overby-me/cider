/*
 * test_renameatx_np.c — Regression tests for renameatx_np (macOS syscall 488)
 *
 * Build inside cider shell:
 *   cc -o test_renameatx_np test_renameatx_np.c
 *
 * Run:
 *   ./test_renameatx_np
 *
 * Exit code 0 = all tests passed, nonzero = failure.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>

/* macOS renameatx_np flags */
#ifndef RENAME_SWAP
#define RENAME_SWAP 0x00000002
#endif
#ifndef RENAME_EXCL
#define RENAME_EXCL 0x00000004
#endif

/* Forward declaration — on macOS this is in <stdio.h> */
extern int renameatx_np(int fromfd, const char *from, int tofd, const char *to,
                        unsigned int flags);

static int tests_run = 0;
static int tests_passed = 0;

#define TEST_DIR_TEMPLATE "/tmp/test_renameatx_XXXXXX"

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

static int read_file(const char *path, char *buf, size_t bufsz)
{
    int fd = open(path, O_RDONLY);
    if (fd < 0)
        return -1;
    ssize_t n = read(fd, buf, bufsz - 1);
    close(fd);
    if (n < 0)
        return -1;
    buf[n] = '\0';
    return 0;
}

static int file_exists(const char *path)
{
    struct stat st;
    return stat(path, &st) == 0;
}

#define ASSERT(cond, msg)                                                     \
    do {                                                                       \
        tests_run++;                                                           \
        if (!(cond)) {                                                         \
            fprintf(stderr, "  FAIL [%d]: %s\n", tests_run, msg);             \
            return 1;                                                          \
        }                                                                      \
        tests_passed++;                                                        \
        fprintf(stderr, "  PASS [%d]: %s\n", tests_run, msg);                 \
    } while (0)

/* ------------------------------------------------------------------ */

static int test_plain_rename(void)
{
    fprintf(stderr, "== test_plain_rename ==\n");

    char src[512], dst[512];
    snprintf(src, sizeof(src), "%s/plain_src", test_dir);
    snprintf(dst, sizeof(dst), "%s/plain_dst", test_dir);

    ASSERT(write_file(src, "hello") == 0, "create source file");
    ASSERT(!file_exists(dst), "destination does not exist yet");

    int ret = renameatx_np(AT_FDCWD, src, AT_FDCWD, dst, 0);
    ASSERT(ret == 0, "renameatx_np with flags=0 succeeds");
    ASSERT(!file_exists(src), "source is gone after rename");
    ASSERT(file_exists(dst), "destination exists after rename");

    char buf[64];
    ASSERT(read_file(dst, buf, sizeof(buf)) == 0, "can read destination");
    ASSERT(strcmp(buf, "hello") == 0, "destination has correct content");

    unlink(dst);
    return 0;
}

static int test_rename_swap(void)
{
    fprintf(stderr, "== test_rename_swap ==\n");

    char fileA[512], fileB[512];
    snprintf(fileA, sizeof(fileA), "%s/swap_a", test_dir);
    snprintf(fileB, sizeof(fileB), "%s/swap_b", test_dir);

    ASSERT(write_file(fileA, "content_A") == 0, "create file A");
    ASSERT(write_file(fileB, "content_B") == 0, "create file B");

    int ret = renameatx_np(AT_FDCWD, fileA, AT_FDCWD, fileB, RENAME_SWAP);
    ASSERT(ret == 0, "RENAME_SWAP succeeds");

    char buf[64];
    ASSERT(read_file(fileA, buf, sizeof(buf)) == 0, "read file A after swap");
    ASSERT(strcmp(buf, "content_B") == 0,
           "file A now has B's content after swap");

    ASSERT(read_file(fileB, buf, sizeof(buf)) == 0, "read file B after swap");
    ASSERT(strcmp(buf, "content_A") == 0,
           "file B now has A's content after swap");

    unlink(fileA);
    unlink(fileB);
    return 0;
}

static int test_rename_excl(void)
{
    fprintf(stderr, "== test_rename_excl ==\n");

    char src[512], dst[512];
    snprintf(src, sizeof(src), "%s/excl_src", test_dir);
    snprintf(dst, sizeof(dst), "%s/excl_dst", test_dir);

    ASSERT(write_file(src, "exclusive") == 0, "create source file");

    /* Destination does not exist — should succeed */
    int ret = renameatx_np(AT_FDCWD, src, AT_FDCWD, dst, RENAME_EXCL);
    ASSERT(ret == 0, "RENAME_EXCL succeeds when dest does not exist");
    ASSERT(!file_exists(src), "source is gone");
    ASSERT(file_exists(dst), "destination exists");

    char buf[64];
    ASSERT(read_file(dst, buf, sizeof(buf)) == 0, "read destination");
    ASSERT(strcmp(buf, "exclusive") == 0, "destination content is correct");

    /* Now create source again and try with existing destination — must fail */
    ASSERT(write_file(src, "second") == 0, "create source again");

    ret = renameatx_np(AT_FDCWD, src, AT_FDCWD, dst, RENAME_EXCL);
    ASSERT(ret != 0, "RENAME_EXCL fails when dest already exists");
    ASSERT(errno == EEXIST, "errno is EEXIST");

    /* Both files should still exist unchanged */
    ASSERT(file_exists(src), "source still exists after failed EXCL");
    ASSERT(read_file(dst, buf, sizeof(buf)) == 0, "dest still readable");
    ASSERT(strcmp(buf, "exclusive") == 0,
           "destination content unchanged after failed EXCL");

    unlink(src);
    unlink(dst);
    return 0;
}

static int test_invalid_flags(void)
{
    fprintf(stderr, "== test_invalid_flags ==\n");

    char src[512], dst[512];
    snprintf(src, sizeof(src), "%s/inv_src", test_dir);
    snprintf(dst, sizeof(dst), "%s/inv_dst", test_dir);

    ASSERT(write_file(src, "data") == 0, "create source file");
    ASSERT(write_file(dst, "data2") == 0, "create dest file");

    /* RENAME_SWAP | RENAME_EXCL together is invalid */
    int ret = renameatx_np(AT_FDCWD, src, AT_FDCWD, dst,
                           RENAME_SWAP | RENAME_EXCL);
    ASSERT(ret != 0, "SWAP|EXCL together fails");
    ASSERT(errno == EINVAL, "errno is EINVAL for SWAP|EXCL");

    /* Unknown flag bits should be rejected */
    ret = renameatx_np(AT_FDCWD, src, AT_FDCWD, dst, 0x80000000);
    ASSERT(ret != 0, "unknown flags fail");
    ASSERT(errno == EINVAL, "errno is EINVAL for unknown flags");

    unlink(src);
    unlink(dst);
    return 0;
}

static int test_swap_nonexistent(void)
{
    fprintf(stderr, "== test_swap_nonexistent ==\n");

    char fileA[512], fileB[512];
    snprintf(fileA, sizeof(fileA), "%s/swap_exist", test_dir);
    snprintf(fileB, sizeof(fileB), "%s/swap_noexist", test_dir);

    ASSERT(write_file(fileA, "exists") == 0, "create file A");
    unlink(fileB); /* ensure B does not exist */

    int ret = renameatx_np(AT_FDCWD, fileA, AT_FDCWD, fileB, RENAME_SWAP);
    ASSERT(ret != 0,
           "RENAME_SWAP fails when one file does not exist");
    ASSERT(errno == ENOENT, "errno is ENOENT");

    /* A should be unchanged */
    char buf[64];
    ASSERT(read_file(fileA, buf, sizeof(buf)) == 0,
           "file A still readable after failed swap");
    ASSERT(strcmp(buf, "exists") == 0,
           "file A content unchanged after failed swap");

    unlink(fileA);
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
    failures += test_plain_rename();
    failures += test_rename_swap();
    failures += test_rename_excl();
    failures += test_invalid_flags();
    failures += test_swap_nonexistent();

    cleanup();

    fprintf(stderr, "\n%d/%d tests passed\n", tests_passed, tests_run);
    if (failures > 0) {
        fprintf(stderr, "SOME TESTS FAILED\n");
        return 1;
    }
    fprintf(stderr, "ALL TESTS PASSED\n");
    return 0;
}