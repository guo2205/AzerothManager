#include <stddef.h>
#include <stdint.h>
int wow_inflate(const uint8_t *input, size_t input_size, uint8_t *output, size_t output_size);
uint32_t wow_crc(const uint8_t *data, size_t size);
