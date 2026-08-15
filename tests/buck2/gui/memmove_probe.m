// DOES memmove STILL COPY THE RIGHT BYTES, now that the large forward case is rep movsb.
//
// _platform_memmove is the most safety critical function in the system: everything that copies
// memory goes through it, and a wrong byte is not a crash, it is a document with the wrong content
// or a font with the wrong glyph, days later and nowhere near here. It was the Berkeley portable
// loop and is now rep movsb above a size floor, which is a real change of behaviour and deserves a
// test that could actually fail.
//
// WHAT IS CHECKED, against a reference copy done a byte at a time in a scratch buffer:
//   every length from 0 to 300, then a scattering of larger ones across the floor and the page size
//   every source and destination alignment from 0 to 15
//   OVERLAP IN BOTH DIRECTIONS, which is the whole reason memmove exists and the case rep movsb
//   cannot do: destination below source, destination above source, and exactly equal
//
// A pass prints one line. A failure prints the length, the offsets and the first byte that differs,
// because "memmove is broken" is not a debuggable statement.
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>

static unsigned char *scratch;
static unsigned char *reference;
static unsigned char *subject;

#define ARENA 8192

static void fill(unsigned char *p, size_t n, unsigned seed)
{
    for (size_t i = 0; i < n; i++) {
        seed = seed * 1103515245u + 12345u;
        p[i] = (unsigned char) (seed >> 16);
    }
}

/*
 * THE REFERENCE, AND WHY IT IS volatile.
 *
 * A byte at a time loop is exactly the shape a compiler recognises and REPLACES with a call to
 * memcpy, memmove or memset. When it does, the reference is no longer independent: it is the same
 * library function the probe is supposed to be checking, and the two sides agree because they are
 * the same code. That is not a hypothetical. A one byte overwrite planted in _platform_memset on
 * purpose was reported OK by 19472 cases of this probe, because clang had turned the reference fill
 * into a memset call and both sides got the same wrong answer. A dump of one case showed TEN bytes
 * of the fill value on BOTH sides where there should have been nine.
 *
 * volatile on the destination forbids that rewrite, so the reference stays a loop.
 */
static void reference_move(unsigned char *dst, const unsigned char *src, size_t n)
{
    volatile unsigned char *d = dst;

    if (dst < src) {
        for (size_t i = 0; i < n; i++) {
            d[i] = src[i];
        }
    } else if (dst > src) {
        for (size_t i = n; i > 0; i--) {
            d[i - 1] = src[i - 1];
        }
    }
}

static int check_move(size_t length, size_t srcOff, size_t dstOff)
{
    if (srcOff + length > ARENA || dstOff + length > ARENA) {
        return 0;
    }
    fill(scratch, ARENA, (unsigned) (length * 31 + srcOff * 7 + dstOff + 1));
    memcpy(reference, scratch, ARENA);
    memcpy(subject, scratch, ARENA);

    reference_move(reference + dstOff, reference + srcOff, length);
    memmove(subject + dstOff, subject + srcOff, length);

    for (size_t i = 0; i < ARENA; i++) {
        if (reference[i] != subject[i]) {
            printf("MEMMOVE_PROBE FAIL length=%zu src=%zu dst=%zu firstdiff=%zu want=%02x got=%02x\n",
                   length, srcOff, dstOff, i, reference[i], subject[i]);
            return 1;
        }
    }
    return 0;
}

/* THE SAME DISCIPLINE FOR memset, which was a function call per four bytes and is now rep stosb
 * with a written out small path. The arena is compared in FULL every time, so a write that runs
 * past the end of the region is caught as well as a wrong byte inside it. */
static int check_set(size_t length, size_t off, int value)
{
    if (off + length > ARENA) {
        return 0;
    }
    fill(scratch, ARENA, (unsigned) (length * 17 + off * 5 + (unsigned) value + 1));
    memcpy(reference, scratch, ARENA);
    memcpy(subject, scratch, ARENA);

    /* volatile for the same reason as reference_move: without it this loop BECOMES a memset. */
    volatile unsigned char *ref = reference;

    for (size_t i = 0; i < length; i++) {
        ref[off + i] = (unsigned char) value;
    }
    /* THROUGH A POINTER FOUND AT RUN TIME, because a direct call is not a test of the library.
     * A one byte overwrite deliberately planted in _platform_memset did NOT show up here until this
     * changed: the compiler recognises memset with a constant-ish shape and emits its own inline
     * store sequence, so the probe was measuring clang and reporting on libplatform. dlsym cannot
     * be constant folded. */
    static void *(*real_memset)(void *, int, size_t);
    if (real_memset == NULL) {
        real_memset = dlsym(RTLD_DEFAULT, "memset");
        if (real_memset == NULL) {
            printf("MEMSET_PROBE FAIL no memset symbol\n");
            return 1;
        }
        /* AND SAY WHICH IMAGE IT CAME FROM. A probe that reports on the wrong implementation is
         * worse than no probe, and the only way to know which one answered is to ask. */
        Dl_info info;
        if (dladdr((void *) real_memset, &info) != 0) {
            printf("MEMSET_PROBE symbol=%s image=%s\n",
                   info.dli_sname ? info.dli_sname : "?",
                   info.dli_fname ? info.dli_fname : "?");
        }
    }
    real_memset(subject + off, value, length);

    for (size_t i = 0; i < ARENA; i++) {
        if (reference[i] != subject[i]) {
            printf("MEMSET_PROBE FAIL length=%zu off=%zu value=%d firstdiff=%zu want=%02x got=%02x\n",
                   length, off, value, i, reference[i], subject[i]);
            return 1;
        }
    }
    return 0;
}

int main(void)
{
    scratch = malloc(ARENA);
    reference = malloc(ARENA);
    subject = malloc(ARENA);
    if (scratch == NULL || reference == NULL || subject == NULL) {
        printf("MEMMOVE_PROBE FAIL allocation\n");
        return 1;
    }

    size_t failures = 0;
    size_t cases = 0;

    /* Every short length, every alignment pair, no overlap. */
    for (size_t length = 0; length <= 300; length++) {
        for (size_t srcOff = 0; srcOff < 16; srcOff++) {
            for (size_t dstOff = 4000; dstOff < 4016; dstOff++) {
                failures += (size_t) check_move(length, srcOff, dstOff);
                cases++;
            }
        }
    }

    /* Lengths around the rep movsb floor and around a page, both overlap directions and equal. */
    const size_t lengths[] = { 1, 15, 16, 31, 32, 63, 64, 65, 127, 128, 255, 256, 511, 512,
                               1023, 1024, 2047, 2048, 3000, 4095, 4096 };
    for (size_t li = 0; li < sizeof(lengths) / sizeof(*lengths); li++) {
        size_t length = lengths[li];

        for (size_t shift = 0; shift <= 64; shift += 1) {
            /* destination BELOW source, overlapping: the direction rep movsb can do */
            failures += (size_t) check_move(length, 1024 + shift, 1024);
            /* destination ABOVE source, overlapping: the direction it cannot */
            failures += (size_t) check_move(length, 1024, 1024 + shift);
            cases += 2;
        }
        /* Exactly equal, which must be a no-op rather than a copy onto itself. */
        failures += (size_t) check_move(length, 2048, 2048);
        cases++;
    }

    printf("MEMMOVE_PROBE cases=%zu failures=%zu %s\n", cases, failures,
           (failures == 0) ? "OK" : "BROKEN");

    size_t setFailures = 0;
    size_t setCases = 0;
    const int values[] = { 0, 1, 0x5a, 0xff };

    for (size_t length = 0; length <= 300; length++) {
        for (size_t off = 1000; off < 1016; off++) {
            for (size_t vi = 0; vi < sizeof(values) / sizeof(*values); vi++) {
                setFailures += (size_t) check_set(length, off, values[vi]);
                setCases++;
            }
        }
    }
    const size_t setLengths[] = { 31, 32, 33, 63, 64, 127, 128, 255, 256, 1023, 1024, 4095, 4096 };
    for (size_t li = 0; li < sizeof(setLengths) / sizeof(*setLengths); li++) {
        for (size_t off = 0; off < 16; off++) {
            setFailures += (size_t) check_set(setLengths[li], off, 0xa5);
            setCases++;
        }
    }
    printf("MEMSET_PROBE cases=%zu failures=%zu %s\n", setCases, setFailures,
           (setFailures == 0) ? "OK" : "BROKEN");

    return (failures == 0 && setFailures == 0) ? 0 : 1;
}
