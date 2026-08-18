#include <compression.h>
#include "../lzfse/lzfse.h"

/*
 * EVERY FUNCTION HERE RETURNED ZERO, and zero is a legal answer meaning nothing was written, so an
 * application that compressed or decompressed anything got silence rather than an error. The one
 * that matters first is LZFSE decoding: a compiled asset catalog stores its renditions as LZFSE, so
 * an application whose icons live in Assets.car cannot get them until this works, and Swift
 * Publisher draws the word Button on every toolbar item for exactly that reason.
 *
 * lzfse itself is Apples own implementation, BSD licensed, bundled beside this file because it is a
 * dead upstream (last release 2017), which is the same treatment launchd and libm get here.
 *
 * The other algorithms still answer zero and are still honest about it: zlib and lz4 are not wired
 * up, and the streaming interface is untouched.
 */

size_t
compression_encode_scratch_buffer_size(compression_algorithm algorithm) {
    if (algorithm == COMPRESSION_LZFSE)
        return lzfse_encode_scratch_size();

    return 0;
}

size_t
compression_encode_buffer(uint8_t * __restrict dst_buffer, size_t dst_size,
                          const uint8_t * __restrict src_buffer, size_t src_size,
                          void * __restrict __nullable scratch_buffer,
                          compression_algorithm algorithm) {
    if (algorithm == COMPRESSION_LZFSE)
        return lzfse_encode_buffer(dst_buffer, dst_size, src_buffer, src_size, scratch_buffer);

    return 0;
}

size_t
compression_decode_scratch_buffer_size(compression_algorithm algorithm) {
    if (algorithm == COMPRESSION_LZFSE)
        return lzfse_decode_scratch_size();

    return 0;
}

size_t
compression_decode_buffer(uint8_t * __restrict dst_buffer, size_t dst_size,
                          const uint8_t * __restrict src_buffer, size_t src_size,
                          void * __restrict __nullable scratch_buffer,
                          compression_algorithm algorithm) {
    if (algorithm == COMPRESSION_LZFSE)
        return lzfse_decode_buffer(dst_buffer, dst_size, src_buffer, src_size, scratch_buffer);

    return 0;
}

compression_status
compression_stream_init(compression_stream * stream,
                        compression_stream_operation operation,
                        compression_algorithm algorithm) {
    return COMPRESSION_STATUS_ERROR;
}

compression_status
compression_stream_process(compression_stream * stream,
                           int flags) {
    return COMPRESSION_STATUS_ERROR;
}

compression_status
compression_stream_destroy(compression_stream * stream) {
    return COMPRESSION_STATUS_ERROR;
}

