/*
 * Lumen's door into lwIP (docs/OPENVPN.md): one interface of the tun kind and the raw API's TCP
 * client and UDP, in plain C types, for the tunnel's Swift code. lwIP's own headers stay inside
 * this target.
 *
 * One stack per process, driven from one thread: every function here, and every callback it
 * makes, runs on the thread that called lumen_net_start. Callbacks are made only from inside
 * lumen_net_input and lumen_net_poll_timers — never from a call that sends — and they must not
 * call back into this API: they note what happened, and the caller acts once lwIP has returned.
 */
#ifndef LUMEN_LWIP_H
#define LUMEN_LWIP_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Where the stack's packets go: the tunnel. One whole IPv4 or IPv6 packet per call. */
typedef void (*lumen_net_output)(void *context, const uint8_t *packet, size_t length);

/* Starts the stack (lwIP is initialized once per process) with its one interface up, `mtu` bytes,
 * no address yet. A second start replaces the output and aborts every connection of the first. */
void lumen_net_start(lumen_net_output output, void *context, uint16_t mtu);
/* The interface's IPv4 address (network byte order bytes); all zeros removes it. */
void lumen_net_set_ipv4(const uint8_t address[4]);
/* The interface's IPv6 address; all zeros removes it. */
void lumen_net_set_ipv6(const uint8_t address[16]);
/* A packet from the tunnel. Bad packets are dropped by lwIP. */
void lumen_net_input(const uint8_t *packet, size_t length);
/* Puts one packet the stack wrote into macOS's shape, in place (lumen_lwip.c: a SYN's options in
 * XNU's order, a timestamp clock of each connection's own, DF and random identifiers on IPv4, a
 * flow label on IPv6). Every packet out passes here; exposed for the tests. */
void lumen_net_shape(uint8_t *packet, size_t length);
/* Runs lwIP's timers that are due. */
void lumen_net_poll_timers(void);
/* Milliseconds until a timer is due (at most 1000). */
uint32_t lumen_net_timer_wait(void);

/* Error codes passed to callbacks, as lwIP's err_t. */
enum {
    LUMEN_NET_OK = 0,
    LUMEN_NET_ERR_MEMORY = -1,
    LUMEN_NET_ERR_TIMEOUT = -3,
    LUMEN_NET_ERR_ROUTE = -4,
    LUMEN_NET_ERR_ABORTED = -13,
    LUMEN_NET_ERR_RESET = -14,
    LUMEN_NET_ERR_CLOSED = -15
};

typedef struct lumen_tcp lumen_tcp;

typedef struct {
    /* The connection is established. */
    void (*connected)(void *context);
    /* Bytes from the far side; length 0: it finished sending (FIN). */
    void (*received)(void *context, const uint8_t *bytes, size_t length);
    /* `length` bytes sent earlier were acknowledged: room to send more. */
    void (*acknowledged)(void *context, uint32_t length);
    /* The connection is gone (reset, timed out, refused); nothing more comes, nothing can be sent.
     * The handle stays valid until lumen_tcp_free. */
    void (*failed)(void *context, int error);
} lumen_tcp_events;

/* Opens a connection to `address` (4 or 16 bytes, by `family` 4 or 6) port `port`. NULL when it
 * cannot even begin (no address of that family, no memory): `*error` says why. */
lumen_tcp *lumen_tcp_connect(int family, const uint8_t *address, uint16_t port,
                             lumen_tcp_events events, void *context, int *error);
/* How many bytes can be written now. */
size_t lumen_tcp_room(lumen_tcp *connection);
/* Queues up to `length` bytes (copied) and sends what it can; returns how many were taken. */
size_t lumen_tcp_write(lumen_tcp *connection, const uint8_t *bytes, size_t length);
/* `length` received bytes were passed on: the far side may send that much more. */
void lumen_tcp_consumed(lumen_tcp *connection, size_t length);
/* No more bytes will be written: a FIN goes after what is queued. */
void lumen_tcp_finish(lumen_tcp *connection);
/* The local end: family (4 or 6), address (16 bytes; an IPv4 one in the first 4) and port. */
void lumen_tcp_local(lumen_tcp *connection, int *family, uint8_t address[16], uint16_t *port);
/* Ends the connection (a FIN if it is open, a reset if `reset` or if that cannot be queued) and
 * frees the handle. No callback is made for it afterwards. */
void lumen_tcp_free(lumen_tcp *connection, int reset);

typedef struct lumen_udp lumen_udp;

/* A datagram that came: from `address` (by `family`) port `port`. */
typedef void (*lumen_udp_receive)(void *context, int family, const uint8_t *address, uint16_t port,
                                  const uint8_t *bytes, size_t length);

/* A UDP endpoint on the interface, at a port lwIP picks (random). NULL without memory. */
lumen_udp *lumen_udp_open(int family, lumen_udp_receive receive, void *context);
/* The endpoint's local port. */
uint16_t lumen_udp_port(lumen_udp *endpoint);
/* Sends one datagram; 0 when it was handed to the interface. */
int lumen_udp_send(lumen_udp *endpoint, int family, const uint8_t *address, uint16_t port,
                   const uint8_t *bytes, size_t length);
void lumen_udp_free(lumen_udp *endpoint);

/* 32 random bits from the system's generator. */
uint32_t lumen_net_random(void);

/* How many TCP connections and UDP endpoints are open (for tests and the helper's report). */
int lumen_net_open_connections(void);
int lumen_net_open_endpoints(void);

#ifdef __cplusplus
}
#endif

#endif /* LUMEN_LWIP_H */
