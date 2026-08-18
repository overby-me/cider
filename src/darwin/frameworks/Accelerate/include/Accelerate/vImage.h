/*
 This file is part of Cider.

 vImage, ENOUGH OF IT TO COMPILE AGAINST. The full framework is an image processing library with
 hundreds of entry points; what is declared here is the buffer type every one of them takes and the
 operations this port actually implements. Adding a declaration here without an implementation would
 be worse than leaving it out, because the link would succeed and the call would not.

 This program is free software: you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation, either version 3 of the License, or
 (at your option) any later version.
*/

#ifndef _VIMAGE_H
#define _VIMAGE_H

#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

typedef unsigned long vImagePixelCount;
typedef ssize_t vImage_Error;
typedef uint32_t vImage_Flags;

typedef struct vImage_Buffer {
    void *data;
    vImagePixelCount height;
    vImagePixelCount width;
    size_t rowBytes;
} vImage_Buffer;

enum {
    kvImageNoError = 0,
    // NOT Apple's numbering. Apple's vImage error codes are a documented set of specific negative
    // values; this port reproduces the one that matters (no error is zero) and reports every
    // failure as one negative code rather than inventing values it cannot verify.
    kvImageCiderError = -21772,
};

enum {
    kvImageNoFlags = 0,
    kvImageDoNotTile = 2,
};

#ifdef __cplusplus
extern "C" {
#endif

// Reorder the four bytes of every pixel. permuteMap[i] names which SOURCE channel goes to
// destination channel i, so {3,2,1,0} turns ARGB into BGRA.
vImage_Error vImagePermuteChannels_ARGB8888(const vImage_Buffer *src, const vImage_Buffer *dest,
                                            const uint8_t permuteMap[4], vImage_Flags flags);

#ifdef __cplusplus
}
#endif

#endif
