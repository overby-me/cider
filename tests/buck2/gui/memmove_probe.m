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

/* The reference: a byte at a time, in the direction that makes overlap safe. */
static void reference_move(unsigned char *dst, const unsigned char *src, size_t n)
{
    if (dst < src) {
        for (size_t i = 0; i < n; i++) {
            dst[i] = src[i];
        }
    } else if (dst > src) {
        for (size_t i = n; i > 0; i--) {
            dst[i - 1] = src[i - 1];
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
    return (failures == 0) ? 0 : 1;
}
