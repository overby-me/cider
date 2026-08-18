/*
 This file is part of Cider.

 A REAL CHANNEL PERMUTE, because this one is arithmetic and nothing else. An application that swaps
 ARGB for BGRA before handing pixels to a texture or a codec gets the wrong colours from a stub and
 no error to explain them, so this does the work: four bytes per pixel, moved as the map says.

 This program is free software: you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation, either version 3 of the License, or
 (at your option) any later version.
*/

#include <Accelerate/vImage.h>

vImage_Error vImagePermuteChannels_ARGB8888(const vImage_Buffer *src, const vImage_Buffer *dest,
                                            const uint8_t permuteMap[4], vImage_Flags flags)
{
    if (src == NULL || dest == NULL || permuteMap == NULL ||
        src->data == NULL || dest->data == NULL) {
        return kvImageCiderError;
    }

    for (int i = 0; i < 4; i++) {
        if (permuteMap[i] > 3) {
            return kvImageCiderError;
        }
    }

    // The destination decides the extent, and it must fit inside the source: vImage treats a
    // destination larger than the source as an error rather than reading past the end.
    if (dest->width > src->width || dest->height > src->height) {
        return kvImageCiderError;
    }

    const uint8_t m0 = permuteMap[0], m1 = permuteMap[1];
    const uint8_t m2 = permuteMap[2], m3 = permuteMap[3];

    for (vImagePixelCount y = 0; y < dest->height; y++) {
        const uint8_t *in = (const uint8_t *)src->data + y * src->rowBytes;
        uint8_t *out = (uint8_t *)dest->data + y * dest->rowBytes;

        for (vImagePixelCount x = 0; x < dest->width; x++) {
            // Read all four first: source and destination are allowed to be the same buffer, and a
            // map like {1,0,3,2} would otherwise overwrite a channel it still has to read.
            const uint8_t c0 = in[0], c1 = in[1], c2 = in[2], c3 = in[3];
            const uint8_t channels[4] = { c0, c1, c2, c3 };

            out[0] = channels[m0];
            out[1] = channels[m1];
            out[2] = channels[m2];
            out[3] = channels[m3];

            in += 4;
            out += 4;
        }
    }

    return kvImageNoError;
}
