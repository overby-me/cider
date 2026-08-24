// cider #11 lever A: build a dyld shared cache for the guest arm64 prefix.
//
// A guest arm64-darwin tool (run under cider during the prefix build) that drives dyld's MRM shared-cache
// builder C API over the prefix's system dylibs, so a spawn maps ONE cache instead of open+mmap'ing ~77
// dylibs individually. Reads a manifest of guest dylib paths (install names, e.g. /usr/lib/libSystem.B.dylib),
// mmaps each from <root>, and writes the produced cache file(s) into <out-dir>.
//
// usage: cache_builder <out-dir> <root-prefix> <manifest>
#include "mrm_shared_cache_builder.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/stat.h>

static const char* basename_c(const char* p) {
    const char* s = strrchr(p, '/');
    return s ? s + 1 : p;
}

int main(int argc, char** argv) {
    if (argc < 4) {
        fprintf(stderr, "usage: %s <out-dir> <root-prefix> <manifest>\n", argv[0]);
        return 2;
    }
    const char* outDir   = argv[1];
    const char* root     = argv[2];
    const char* manifest = argv[3];

    struct BuildOptions_v1 opts;
    memset(&opts, 0, sizeof(opts));
    opts.version            = 1;
    opts.updateName         = "cider-1";
    opts.deviceName         = "cider";
    opts.disposition        = Customer;   // 2
    opts.platform           = macOS;      // 1
    const char* archs[1]    = { "arm64" };
    opts.archs              = archs;
    opts.numArchs           = 1;
    opts.verboseDiagnostics = true;
    opts.isLocallyBuiltCache = true;

    struct MRMSharedCacheBuilder* b = createSharedCacheBuilder(&opts);
    if (!b) { fprintf(stderr, "cache_builder: createSharedCacheBuilder failed\n"); return 1; }

    FILE* mf = fopen(manifest, "r");
    if (!mf) { perror("cache_builder: manifest"); return 1; }
    char line[4096];
    int added = 0;
    while (fgets(line, sizeof(line), mf)) {
        size_t n = strlen(line);
        while (n && (line[n-1] == '\n' || line[n-1] == '\r' || line[n-1] == ' ' || line[n-1] == '\t'))
            line[--n] = '\0';
        if (n == 0 || line[0] == '#') continue;

        char real[8192];
        snprintf(real, sizeof(real), "%s%s", root, line);   // <root><install-name>
        int fd = open(real, O_RDONLY);
        if (fd < 0) { fprintf(stderr, "cache_builder: skip (open) %s\n", real); continue; }
        struct stat st;
        if (fstat(fd, &st) != 0 || st.st_size <= 0) { close(fd); continue; }
        void* data = mmap(NULL, (size_t)st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
        close(fd);
        if (data == MAP_FAILED) { fprintf(stderr, "cache_builder: skip (mmap) %s\n", real); continue; }

        // path passed to the builder IS the install name (what dyld looks up by).
        if (!addFile(b, line, (uint8_t*)data, (uint64_t)st.st_size, NoFlags))
            fprintf(stderr, "cache_builder: addFile rejected %s\n", line);
        else
            added++;
    }
    fclose(mf);
    fprintf(stderr, "cache_builder: added %d dylibs\n", added);

    bool ok = runSharedCacheBuilder(b);

    uint64_t errCount = 0;
    const char* const* errs = getErrors(b, &errCount);
    for (uint64_t i = 0; i < errCount; i++)
        fprintf(stderr, "cache_builder: ERROR %s\n", errs[i]);
    if (!ok || errCount > 0) {
        fprintf(stderr, "cache_builder: build FAILED (ok=%d errs=%llu)\n", (int)ok, (unsigned long long)errCount);
        destroySharedCacheBuilder(b);
        return 1;
    }

    // The produced cache file(s) come back as FileResults with data+size; write each into outDir.
    uint64_t frCount = 0;
    const struct FileResult* const* frs = getFileResults(b, &frCount);
    int wrote = 0;
    for (uint64_t i = 0; i < frCount; i++) {
        const struct FileResult* r = frs[i];
        if (r == NULL || r->data == NULL || r->size == 0) continue;
        char dst[8192];
        snprintf(dst, sizeof(dst), "%s/%s", outDir, basename_c(r->path));
        int ofd = open(dst, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (ofd < 0) { fprintf(stderr, "cache_builder: open out %s: skip\n", dst); continue; }
        const uint8_t* p = r->data;
        uint64_t left = r->size;
        while (left > 0) {
            ssize_t w = write(ofd, p, left > (1u << 20) ? (1u << 20) : (size_t)left);
            if (w <= 0) { fprintf(stderr, "cache_builder: write %s failed\n", dst); break; }
            p += w; left -= (uint64_t)w;
        }
        close(ofd);
        if (left == 0) { fprintf(stderr, "cache_builder: wrote %s (%llu bytes)\n", dst, (unsigned long long)r->size); wrote++; }
    }
    destroySharedCacheBuilder(b);

    if (wrote == 0) { fprintf(stderr, "cache_builder: no cache file written\n"); return 1; }
    fprintf(stderr, "cache_builder: OK, %d cache file(s)\n", wrote);
    return 0;
}
