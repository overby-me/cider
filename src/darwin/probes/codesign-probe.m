/*
 * What our Security framework answers about a signed bundle, in one line per call.
 *
 * MoneyMoney refuses to start and shows FatalError.CodeSign, its own message for a failed code
 * signature check, so the whole application is a blank window with an alert in it. The three calls
 * it makes are SecStaticCodeCreateWithPath, SecStaticCodeCheckValidity and
 * SecCodeCopySigningInformation, and nothing above them says WHICH of those failed or with what
 * OSStatus. Reading Apple's libsecurity_codesigning to guess is a day; asking it is a minute.
 *
 * The bundle itself is intact: its 497 sealed resources all hash to what CodeResources says, so
 * anything that fails here is ours.
 *
 * Usage: codesign-probe /Applications/Something.app
 */
#import <CoreFoundation/CoreFoundation.h>
#import <Security/SecCode.h>
#import <Security/SecStaticCode.h>
#import <Security/SecRequirement.h>
#import <errno.h>
#import <fts.h>
#import <fcntl.h>
#import <stdio.h>
#import <string.h>
#import <sys/attr.h>
#import <sys/stat.h>
#import <sys/xattr.h>
#import <unistd.h>

static void print_cfstring(const char *label, CFStringRef s) {
    char buffer[512];

    if (s == NULL) {
        printf("CIDER_CODESIGN %s=(null)\n", label);
        return;
    }
    if (CFStringGetCString(s, buffer, sizeof(buffer), kCFStringEncodingUTF8)) {
        printf("CIDER_CODESIGN %s=%s\n", label, buffer);
    } else {
        printf("CIDER_CODESIGN %s=(unprintable)\n", label);
    }
}

/*
 * WHICH FILESYSTEM CALL ANSWERS DIFFERENTLY, on a path that fails against one that works.
 *
 * The same universal binary opens as code when it sits in /tmp and fails with EOPNOTSUPP under
 * /Applications, so the difference is the path and not the file. These are the calls the
 * code-signing machinery makes on the way in; the one that answers 102 there and 0 in /tmp is the
 * gap.
 */
static void probe_fs(const char *path) {
    struct stat st;
    int fd;

    errno = 0;
    printf("CIDER_CODESIGN fs stat=%d errno=%d\n", stat(path, &st), errno);

    errno = 0;
    fd = open(path, O_RDONLY);
    printf("CIDER_CODESIGN fs open=%d errno=%d\n", fd, errno);
    if (fd >= 0) {
        char buf[64];

        errno = 0;
        printf("CIDER_CODESIGN fs pread=%zd errno=%d\n", pread(fd, buf, sizeof(buf), 0), errno);

        errno = 0;
        printf("CIDER_CODESIGN fs fstat=%d errno=%d size=%lld\n", fstat(fd, &st), errno,
               (long long) st.st_size);

        char resolved[1024];
        errno = 0;
        printf("CIDER_CODESIGN fs fcntl_getpath=%d errno=%d\n", fcntl(fd, F_GETPATH, resolved),
               errno);

        struct attrlist al;
        char attrbuf[512];
        memset(&al, 0, sizeof(al));
        al.bitmapcount = ATTR_BIT_MAP_COUNT;
        al.commonattr = ATTR_CMN_OBJTYPE;
        errno = 0;
        printf("CIDER_CODESIGN fs fgetattrlist=%d errno=%d\n",
               fgetattrlist(fd, &al, attrbuf, sizeof(attrbuf), 0), errno);

        errno = 0;
        printf("CIDER_CODESIGN fs flistxattr=%zd errno=%d\n", flistxattr(fd, NULL, 0, 0), errno);
        close(fd);
    }

    errno = 0;
    printf("CIDER_CODESIGN fs listxattr=%zd errno=%d\n", listxattr(path, NULL, 0, 0), errno);

    /*
     * getattrlistbulk IS HOW APPLE'S fts READS A DIRECTORY, and fts is how the code-signing
     * machinery walks a bundle root (DirValidator). If it is missing, fts_open fails, the wrapper
     * throws UnixError with the live errno and the whole SecStaticCodeCreateWithPath comes back as
     * that errno plus errSecErrnoBase. Ask it directly rather than inferring from a grep.
     */
    int dirfd = open(path, O_RDONLY);

    if (dirfd >= 0) {
        struct attrlist al;
        char buf[4096];

        memset(&al, 0, sizeof(al));
        al.bitmapcount = ATTR_BIT_MAP_COUNT;
        al.commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_NAME | ATTR_CMN_OBJTYPE;
        errno = 0;
        printf("CIDER_CODESIGN fs getattrlistbulk=%d errno=%d\n",
               getattrlistbulk(dirfd, &al, buf, sizeof(buf), 0), errno);
        close(dirfd);
    }

    char real[1024];
    errno = 0;
    printf("CIDER_CODESIGN fs realpath=%s errno=%d\n",
           realpath(path, real) != NULL ? real : "(null)", errno);

    /*
     * THE EXACT CALL BundleDiskRep::setup MAKES FIRST, and the one that decides everything.
     * checkFork in unix++.cpp treats only ENOATTR and EPERM as "no such attribute" and THROWS on
     * any other errno, so a filesystem that answers "extended attributes are not supported here"
     * fails the whole SecStaticCodeCreateWithPath before a single byte of the signature is read.
     */
    errno = 0;
    ssize_t finder = getxattr(path, "com.apple.FinderInfo", NULL, 0, 0, 0);

    printf("CIDER_CODESIGN fs getxattr_finderinfo=%zd errno=%d\n", finder, errno);

    /* THE EXACT CALL DirValidator MAKES, with the flags it passes. */
    char *paths[2] = {(char *) path, NULL};
    errno = 0;
    FTS *tree = fts_open(paths, FTS_PHYSICAL | FTS_COMFOLLOW | FTS_NOCHDIR, NULL);

    printf("CIDER_CODESIGN fs fts_open=%p errno=%d\n", (void *) tree, errno);
    if (tree != NULL) {
        FTSENT *ent;
        int count = 0;

        errno = 0;
        while ((ent = fts_read(tree)) != NULL) {
            count++;
        }
        printf("CIDER_CODESIGN fs fts_entries=%d errno=%d\n", count, errno);
        fts_close(tree);
    }
}

int main(int argc, char **argv) {
    /*
     * UNBUFFERED, because the interesting runs are the ones that do not finish. A probe that hangs
     * inside a call is killed by the harness timeout, and a block buffered stdout takes every line
     * it had already printed with it: the first run against a 17 MB Mach-O looked like it produced
     * nothing at all, which reads as "it never started" rather than "it never returned".
     */
    setvbuf(stdout, NULL, _IONBF, 0);

    const char *path = argc > 1 ? argv[1] : "/Applications/MoneyMoney.app";
    CFStringRef cfPath = CFStringCreateWithCString(NULL, path, kCFStringEncodingUTF8);
    CFURLRef url = CFURLCreateWithFileSystemPath(NULL, cfPath, kCFURLPOSIXPathStyle, true);
    SecStaticCodeRef code = NULL;
    OSStatus status;

    printf("CIDER_CODESIGN path=%s\n", path);
    probe_fs(path);

    status = SecStaticCodeCreateWithPath(url, kSecCSDefaultFlags, &code);
    printf("CIDER_CODESIGN SecStaticCodeCreateWithPath=%d code=%p\n", (int) status, (void *) code);
    if (status != 0 || code == NULL) {
        return 1;
    }

    /*
     * THE ERROR, NOT ONLY THE STATUS. CheckValidity fills a CFError when asked, and its description
     * says which stage refused where the OSStatus alone is a number that could be a dozen things.
     */
    CFErrorRef error = NULL;
    status = SecStaticCodeCheckValidity(code, kSecCSDefaultFlags, NULL);
    printf("CIDER_CODESIGN SecStaticCodeCheckValidity=%d\n", (int) status);

    status = SecStaticCodeCheckValidityWithErrors(code, kSecCSDefaultFlags, NULL, &error);
    printf("CIDER_CODESIGN SecStaticCodeCheckValidityWithErrors=%d error=%p\n", (int) status,
           (void *) error);
    if (error != NULL) {
        CFStringRef description = CFErrorCopyDescription(error);

        print_cfstring("errorDescription", description);
        printf("CIDER_CODESIGN errorCode=%ld\n", (long) CFErrorGetCode(error));
        if (description != NULL) {
            CFRelease(description);
        }
    }

    /* The flags MoneyMoney passes are not known, so try the two that change the answer most. */
    status = SecStaticCodeCheckValidity(code, kSecCSCheckAllArchitectures, NULL);
    printf("CIDER_CODESIGN checkValidity(AllArchitectures)=%d\n", (int) status);
    status = SecStaticCodeCheckValidity(code, kSecCSDoNotValidateResources, NULL);
    printf("CIDER_CODESIGN checkValidity(DoNotValidateResources)=%d\n", (int) status);

    CFDictionaryRef info = NULL;
    status = SecCodeCopySigningInformation(code, kSecCSSigningInformation, &info);
    printf("CIDER_CODESIGN SecCodeCopySigningInformation=%d info=%p count=%ld\n", (int) status,
           (void *) info, info != NULL ? (long) CFDictionaryGetCount(info) : -1L);
    if (info != NULL) {
        CFStringRef ident = CFDictionaryGetValue(info, kSecCodeInfoIdentifier);

        print_cfstring("identifier", ident);
    }
    return 0;
}
