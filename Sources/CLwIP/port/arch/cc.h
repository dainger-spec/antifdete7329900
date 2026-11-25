/*
 * lwIP's platform for Lumen's OpenVPN tunnel: macOS and Linux, 64-bit, little-endian.
 */
#ifndef LUMEN_LWIP_ARCH_CC_H
#define LUMEN_LWIP_ARCH_CC_H

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#ifndef BYTE_ORDER
#define LITTLE_ENDIAN 1234
#define BIG_ENDIAN 4321
#define BYTE_ORDER LITTLE_ENDIAN
#endif

/* Random numbers from the system's generator (local ports, sequence numbers, IP identifiers). */
uint32_t lumen_lwip_random(void);
#define LWIP_RAND() lumen_lwip_random()

/* An assertion that fails ends the helper: the profile's SOCKS port then answers nothing. */
#define LWIP_PLATFORM_ASSERT(message) do { \
    fprintf(stderr, "lwIP assertion failed: %s (%s:%d)\n", message, __FILE_NAME__, __LINE__); \
    fflush(stderr); abort(); } while (0)
#define LWIP_PLATFORM_DIAG(x) do { } while (0)

#endif /* LUMEN_LWIP_ARCH_CC_H */
