#include "ZipInflate.h"
#include <zlib.h>
#include <limits.h>
int wow_inflate(const uint8_t *input, size_t input_size, uint8_t *output, size_t output_size) {
    if (input_size > UINT_MAX || output_size > UINT_MAX) return 0;
    z_stream s = {0};
    s.next_in = (Bytef *)input; s.avail_in = (uInt)input_size;
    s.next_out = output; s.avail_out = (uInt)(output_size ? output_size : 1);
    if (inflateInit2(&s, -MAX_WBITS) != Z_OK) return 0;
    int result = inflate(&s, Z_FINISH);
    int ok = result == Z_STREAM_END && s.total_out == output_size && s.total_in == input_size;
    inflateEnd(&s); return ok;
}
uint32_t wow_crc(const uint8_t *data, size_t size) { return (uint32_t)crc32(0L, data, (uInt)size); }
