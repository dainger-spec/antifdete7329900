/*
 * Lumen's door into lwIP: see include/LumenLwIP.h.
 */
#include "LumenLwIP.h"

#include <string.h>
#include <time.h>
#if defined(__APPLE__)
#include <stdlib.h>
#else
#include <sys/random.h>
#endif

#include "lwip/init.h"
#include "lwip/ip.h"
#include "lwip/ip4.h"
#include "lwip/ip6.h"
#include "lwip/ip_addr.h"
#include "lwip/netif.h"
#include "lwip/pbuf.h"
#include "lwip/tcp.h"
#include "lwip/timeouts.h"
#include "lwip/udp.h"

/* ---- The platform: time and randomness ---- */

u32_t sys_now(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (u32_t)((uint64_t)now.tv_sec * 1000u + (uint64_t)now.tv_nsec / 1000000u);
}

uint32_t lumen_lwip_random(void) {
#if defined(__APPLE__)
    return arc4random();
#else
    uint32_t value = 0;
    while (getrandom(&value, sizeof value, 0) != (ssize_t)sizeof value) { }
    return value;
#endif
}

uint32_t lumen_lwip_isn(void) { return lumen_lwip_random(); }

uint32_t lumen_net_random(void) { return lumen_lwip_random(); }

/* ---- The interface ---- */

static struct netif interface;
static int started = 0;
static lumen_net_output output_function = NULL;
static void *output_context = NULL;
/* Room for one packet out: lwIP hands over a single pbuf (LWIP_NETIF_TX_SINGLE_PBUF), but its
 * chain is copied flat here all the same. */
static uint8_t output_buffer[65536];

static err_t send_out(struct pbuf *packet) {
    if (output_function == NULL) return ERR_IF;
    u16_t length = pbuf_copy_partial(packet, output_buffer, packet->tot_len, 0);
    output_function(output_context, output_buffer, length);
    return ERR_OK;
}

static err_t output_ipv4(struct netif *netif, struct pbuf *packet, const ip4_addr_t *next) {
    LWIP_UNUSED_ARG(netif);
    LWIP_UNUSED_ARG(next);
    return send_out(packet);
}

static err_t output_ipv6(struct netif *netif, struct pbuf *packet, const ip6_addr_t *next) {
    LWIP_UNUSED_ARG(netif);
    LWIP_UNUSED_ARG(next);
    return send_out(packet);
}

static err_t interface_init(struct netif *netif) {
    netif->name[0] = 't';
    netif->name[1] = 'n';
    netif->output = output_ipv4;
    netif->output_ip6 = output_ipv6;
    netif->linkoutput = NULL;
    netif->flags = 0; /* no broadcast, no ARP: a point-to-point tunnel */
    return ERR_OK;
}

/* ---- Bookkeeping of the handles, for a second start and for the counts ---- */

struct lumen_tcp {
    struct tcp_pcb *pcb;
    lumen_tcp_events events;
    void *context;
    struct lumen_tcp *next;
    struct lumen_tcp *previous;
};

struct lumen_udp {
    struct udp_pcb *pcb;
    lumen_udp_receive receive;
    void *context;
    struct lumen_udp *next;
    struct lumen_udp *previous;
};

static struct lumen_tcp *connections = NULL;
static struct lumen_udp *endpoints = NULL;

static void unlink_connection(struct lumen_tcp *connection) {
    if (connection->previous) connection->previous->next = connection->next; else connections = connection->next;
    if (connection->next) connection->next->previous = connection->previous;
    connection->next = connection->previous = NULL;
}

static void unlink_endpoint(struct lumen_udp *endpoint) {
    if (endpoint->previous) endpoint->previous->next = endpoint->next; else endpoints = endpoint->next;
    if (endpoint->next) endpoint->next->previous = endpoint->previous;
    endpoint->next = endpoint->previous = NULL;
}

/* Takes lwIP's pcb away from a handle without any callback, ending it with a reset. */
static void drop_pcb(struct lumen_tcp *connection) {
    struct tcp_pcb *pcb = connection->pcb;
    if (pcb == NULL) return;
    connection->pcb = NULL;
    tcp_arg(pcb, NULL);
    tcp_recv(pcb, NULL);
    tcp_sent(pcb, NULL);
    tcp_err(pcb, NULL);
    tcp_abort(pcb);
}

void lumen_net_start(lumen_net_output output, void *context, uint16_t mtu) {
    if (!started) {
        lwip_init();
        ip4_addr_t none;
        ip4_addr_set_zero(&none);
        netif_add(&interface, &none, &none, &none, NULL, interface_init, ip_input);
        netif_set_default(&interface);
        started = 1;
    }
    /* A second start: whatever the first left open ends here (its callbacks are not called). */
    while (connections) {
        struct lumen_tcp *connection = connections;
        drop_pcb(connection);
        unlink_connection(connection);
        /* The handle itself belongs to the caller, who frees it; it is left without a pcb. */
    }
    while (endpoints) {
        struct lumen_udp *endpoint = endpoints;
        if (endpoint->pcb) { udp_remove(endpoint->pcb); endpoint->pcb = NULL; }
        unlink_endpoint(endpoint);
    }
    output_function = output;
    output_context = context;
    interface.mtu = mtu;
#if LWIP_IPV6 && LWIP_ND6_ALLOW_RA_UPDATES
    interface.mtu6 = mtu;
#endif
    netif_set_link_up(&interface);
    netif_set_up(&interface);
}

void lumen_net_set_ipv4(const uint8_t address[4]) {
    ip4_addr_t value, mask, gateway;
    memcpy(&value.addr, address, 4);
    ip4_addr_set_zero(&gateway);
    if (ip4_addr_isany_val(value)) {
        ip4_addr_set_zero(&mask);
    } else {
        IP4_ADDR(&mask, 255, 255, 255, 255);
    }
    netif_set_addr(&interface, &value, &mask, &gateway);
}

void lumen_net_set_ipv6(const uint8_t address[16]) {
    ip6_addr_t value;
    memcpy(value.addr, address, 16);
#if LWIP_IPV6_SCOPES
    ip6_addr_clear_zone(&value);
#endif
    if (ip6_addr_isany(&value)) {
        netif_ip6_addr_set_state(&interface, 0, IP6_ADDR_INVALID);
        return;
    }
    netif_ip6_addr_set(&interface, 0, &value);
    netif_ip6_addr_set_state(&interface, 0, IP6_ADDR_PREFERRED);
}

void lumen_net_input(const uint8_t *packet, size_t length) {
    if (!started || length == 0 || length > 0xFFFF) return;
    struct pbuf *buffer = pbuf_alloc(PBUF_RAW, (u16_t)length, PBUF_RAM);
    if (buffer == NULL) return;
    if (pbuf_take(buffer, packet, (u16_t)length) != ERR_OK) {
        pbuf_free(buffer);
        return;
    }
    if (interface.input(buffer, &interface) != ERR_OK) pbuf_free(buffer);
}

void lumen_net_poll_timers(void) {
    if (started) sys_check_timeouts();
}

uint32_t lumen_net_timer_wait(void) {
    if (!started) return 1000;
    u32_t wait = sys_timeouts_sleeptime();
    return wait > 1000 ? 1000 : wait;
}

/* ---- TCP ---- */

static err_t on_connected(void *argument, struct tcp_pcb *pcb, err_t error) {
    LWIP_UNUSED_ARG(pcb);
    LWIP_UNUSED_ARG(error); /* always ERR_OK: failures come through on_error */
    struct lumen_tcp *connection = argument;
    if (connection && connection->events.connected) connection->events.connected(connection->context);
    return ERR_OK;
}

static err_t on_received(void *argument, struct tcp_pcb *pcb, struct pbuf *buffer, err_t error) {
    struct lumen_tcp *connection = argument;
    if (connection == NULL) {
        if (buffer) { tcp_recved(pcb, buffer->tot_len); pbuf_free(buffer); }
        return ERR_OK;
    }
    if (buffer == NULL) {
        if (connection->events.received) connection->events.received(connection->context, NULL, 0);
        return ERR_OK;
    }
    LWIP_UNUSED_ARG(error);
    for (struct pbuf *part = buffer; part != NULL; part = part->next) {
        if (part->len > 0 && connection->events.received) {
            connection->events.received(connection->context, part->payload, part->len);
        }
    }
    pbuf_free(buffer);
    return ERR_OK;
}

static err_t on_sent(void *argument, struct tcp_pcb *pcb, u16_t length) {
    LWIP_UNUSED_ARG(pcb);
    struct lumen_tcp *connection = argument;
    if (connection && connection->events.acknowledged) connection->events.acknowledged(connection->context, length);
    return ERR_OK;
}

static void on_error(void *argument, err_t error) {
    struct lumen_tcp *connection = argument;
    if (connection == NULL) return;
    /* lwIP has freed the pcb already. */
    connection->pcb = NULL;
    unlink_connection(connection);
    if (connection->events.failed) connection->events.failed(connection->context, error);
}

static int to_ip(int family, const uint8_t *address, ip_addr_t *result) {
    if (family == 4) {
        IP_SET_TYPE_VAL(*result, IPADDR_TYPE_V4);
        memcpy(&ip_2_ip4(result)->addr, address, 4);
        return 1;
    }
    if (family == 6) {
        IP_SET_TYPE_VAL(*result, IPADDR_TYPE_V6);
        memcpy(ip_2_ip6(result)->addr, address, 16);
#if LWIP_IPV6_SCOPES
        ip6_addr_clear_zone(ip_2_ip6(result));
#endif
        return 1;
    }
    return 0;
}

lumen_tcp *lumen_tcp_connect(int family, const uint8_t *address, uint16_t port,
                             lumen_tcp_events events, void *context, int *error) {
    ip_addr_t remote;
    *error = ERR_OK;
    if (!started || !to_ip(family, address, &remote)) {
        *error = ERR_ARG;
        return NULL;
    }
    if (family == 4 && ip4_addr_isany_val(*netif_ip4_addr(&interface))) {
        *error = ERR_RTE;
        return NULL;
    }
    if (family == 6 && !ip6_addr_isvalid(netif_ip6_addr_state(&interface, 0))) {
        *error = ERR_RTE;
        return NULL;
    }
    struct lumen_tcp *connection = calloc(1, sizeof *connection);
    if (connection == NULL) {
        *error = ERR_MEM;
        return NULL;
    }
    struct tcp_pcb *pcb = tcp_new_ip_type(family == 4 ? IPADDR_TYPE_V4 : IPADDR_TYPE_V6);
    if (pcb == NULL) {
        free(connection);
        *error = ERR_MEM;
        return NULL;
    }
    connection->pcb = pcb;
    connection->events = events;
    connection->context = context;
    tcp_arg(pcb, connection);
    tcp_recv(pcb, on_received);
    tcp_sent(pcb, on_sent);
    tcp_err(pcb, on_error);
    tcp_nagle_disable(pcb);
    err_t result = tcp_connect(pcb, &remote, port, on_connected);
    if (result != ERR_OK) {
        tcp_arg(pcb, NULL);
        tcp_err(pcb, NULL);
        tcp_abort(pcb);
        free(connection);
        *error = result;
        return NULL;
    }
    connection->next = connections;
    if (connections) connections->previous = connection;
    connections = connection;
    return connection;
}

size_t lumen_tcp_room(lumen_tcp *connection) {
    if (connection == NULL || connection->pcb == NULL) return 0;
    if (connection->pcb->state != ESTABLISHED && connection->pcb->state != CLOSE_WAIT) return 0;
    size_t room = tcp_sndbuf(connection->pcb);
    /* Bounded by the segments lwIP may still queue as well as by bytes. */
    if (tcp_sndqueuelen(connection->pcb) >= TCP_SND_QUEUELEN - 4) return 0;
    return room;
}

size_t lumen_tcp_write(lumen_tcp *connection, const uint8_t *bytes, size_t length) {
    size_t taken = 0;
    while (taken < length) {
        size_t room = lumen_tcp_room(connection);
        if (room == 0) break;
        size_t chunk = length - taken;
        if (chunk > room) chunk = room;
        if (chunk > 0xFFFF) chunk = 0xFFFF;
        u8_t flags = TCP_WRITE_FLAG_COPY;
        if (taken + chunk < length) flags |= TCP_WRITE_FLAG_MORE;
        if (tcp_write(connection->pcb, bytes + taken, (u16_t)chunk, flags) != ERR_OK) break;
        taken += chunk;
    }
    if (taken > 0 && connection->pcb) tcp_output(connection->pcb);
    return taken;
}

void lumen_tcp_consumed(lumen_tcp *connection, size_t length) {
    if (connection == NULL || connection->pcb == NULL) return;
    while (length > 0) {
        u16_t chunk = length > 0xFFFF ? 0xFFFF : (u16_t)length;
        tcp_recved(connection->pcb, chunk);
        length -= chunk;
    }
}

void lumen_tcp_finish(lumen_tcp *connection) {
    if (connection == NULL || connection->pcb == NULL) return;
    if (tcp_shutdown(connection->pcb, 0, 1) == ERR_OK) tcp_output(connection->pcb);
}

void lumen_tcp_local(lumen_tcp *connection, int *family, uint8_t address[16], uint16_t *port) {
    memset(address, 0, 16);
    *family = 0;
    *port = 0;
    if (connection == NULL || connection->pcb == NULL) return;
    const ip_addr_t *local = &connection->pcb->local_ip;
    if (IP_IS_V6(local)) {
        *family = 6;
        memcpy(address, ip_2_ip6(local)->addr, 16);
    } else {
        *family = 4;
        memcpy(address, &ip_2_ip4(local)->addr, 4);
    }
    *port = connection->pcb->local_port;
}

void lumen_tcp_free(lumen_tcp *connection, int reset) {
    if (connection == NULL) return;
    struct tcp_pcb *pcb = connection->pcb;
    if (pcb != NULL) {
        unlink_connection(connection);
        connection->pcb = NULL;
        tcp_arg(pcb, NULL);
        tcp_sent(pcb, NULL);
        tcp_err(pcb, NULL);
        /* lwIP's own receiver from here on: it acknowledges and drops what still comes. */
        tcp_recv(pcb, NULL);
        if (reset || pcb->state == SYN_SENT || tcp_close(pcb) != ERR_OK) tcp_abort(pcb);
    }
    free(connection);
}

/* ---- UDP ---- */

static void on_datagram(void *argument, struct udp_pcb *pcb, struct pbuf *buffer, const ip_addr_t *from, u16_t port) {
    LWIP_UNUSED_ARG(pcb);
    struct lumen_udp *endpoint = argument;
    if (endpoint == NULL || endpoint->receive == NULL) {
        pbuf_free(buffer);
        return;
    }
    static uint8_t datagram[65536];
    u16_t length = pbuf_copy_partial(buffer, datagram, buffer->tot_len, 0);
    pbuf_free(buffer);
    uint8_t address[16] = { 0 };
    int family;
    if (IP_IS_V6(from)) {
        family = 6;
        memcpy(address, ip_2_ip6(from)->addr, 16);
    } else {
        family = 4;
        memcpy(address, &ip_2_ip4(from)->addr, 4);
    }
    endpoint->receive(endpoint->context, family, address, port, datagram, length);
}

lumen_udp *lumen_udp_open(int family, lumen_udp_receive receive, void *context) {
    if (!started || (family != 4 && family != 6)) return NULL;
    struct lumen_udp *endpoint = calloc(1, sizeof *endpoint);
    if (endpoint == NULL) return NULL;
    struct udp_pcb *pcb = udp_new_ip_type(family == 4 ? IPADDR_TYPE_V4 : IPADDR_TYPE_V6);
    if (pcb == NULL) {
        free(endpoint);
        return NULL;
    }
    if (udp_bind(pcb, family == 4 ? IP4_ADDR_ANY : IP6_ADDR_ANY, 0) != ERR_OK) {
        udp_remove(pcb);
        free(endpoint);
        return NULL;
    }
    endpoint->pcb = pcb;
    endpoint->receive = receive;
    endpoint->context = context;
    udp_recv(pcb, on_datagram, endpoint);
    endpoint->next = endpoints;
    if (endpoints) endpoints->previous = endpoint;
    endpoints = endpoint;
    return endpoint;
}

uint16_t lumen_udp_port(lumen_udp *endpoint) {
    return (endpoint && endpoint->pcb) ? endpoint->pcb->local_port : 0;
}

int lumen_udp_send(lumen_udp *endpoint, int family, const uint8_t *address, uint16_t port,
                   const uint8_t *bytes, size_t length) {
    ip_addr_t remote;
    if (endpoint == NULL || endpoint->pcb == NULL || length > 0xFFFF - 48 || !to_ip(family, address, &remote)) return ERR_ARG;
    struct pbuf *buffer = pbuf_alloc(PBUF_TRANSPORT, (u16_t)length, PBUF_RAM);
    if (buffer == NULL) return ERR_MEM;
    if (length > 0 && pbuf_take(buffer, bytes, (u16_t)length) != ERR_OK) {
        pbuf_free(buffer);
        return ERR_MEM;
    }
    err_t result = udp_sendto(endpoint->pcb, buffer, &remote, port);
    pbuf_free(buffer);
    return result;
}

void lumen_udp_free(lumen_udp *endpoint) {
    if (endpoint == NULL) return;
    if (endpoint->pcb) {
        unlink_endpoint(endpoint);
        udp_remove(endpoint->pcb);
        endpoint->pcb = NULL;
    }
    free(endpoint);
}

int lumen_net_open_connections(void) {
    int count = 0;
    for (struct lumen_tcp *connection = connections; connection; connection = connection->next) count += 1;
    return count;
}

int lumen_net_open_endpoints(void) {
    int count = 0;
    for (struct lumen_udp *endpoint = endpoints; endpoint; endpoint = endpoint->next) count += 1;
    return count;
}
