/*
 * lwIP's options for Lumen's OpenVPN tunnel (docs/OPENVPN.md): one interface of the tun kind
 * (raw IPv4 and IPv6 packets, no link layer), the TCP client and UDP that the tunnel's SOCKS5
 * server opens through it, and nothing else. Driven from one thread (NO_SYS: the raw API and the
 * timers, called by lumen_lwip.c only), memory from the C library.
 */
#ifndef LUMEN_LWIPOPTS_H
#define LUMEN_LWIPOPTS_H

/* One thread, no OS layer: the tunnel's loop calls lwIP and its timers. */
#define NO_SYS                          1
#define SYS_LIGHTWEIGHT_PROT            0
#define LWIP_TIMERS                     1
#define LWIP_SOCKET                     0
#define LWIP_NETCONN                    0
#define LWIP_NETIF_API                  0
#define LWIP_ALTCP                      0

/* Memory: the C library's, no fixed pools (a pool's size would be a limit on connections). */
#define MEM_LIBC_MALLOC                 1
#define MEMP_MEM_MALLOC                 1
#define MEM_ALIGNMENT                   8
#define MEMP_NUM_TCP_PCB                1024
#define MEMP_NUM_UDP_PCB                256
#define MEMP_NUM_TCP_SEG                TCP_SND_QUEUELEN
#define MEMP_NUM_REASSDATA              64
#define MEMP_NUM_FRAG_PBUF              64
#define PBUF_POOL_SIZE                  256

/* The interface: one, of the tun kind. No ARP, no Ethernet, no DHCP, no autoconfiguration. */
#define LWIP_SINGLE_NETIF               1
#define LWIP_ARP                        0
#define LWIP_ETHERNET                   0
#define LWIP_DHCP                       0
#define LWIP_AUTOIP                     0
#define LWIP_ACD                        0
#define LWIP_IGMP                       0
#define LWIP_DNS                        0
#define LWIP_RAW                        0
#define LWIP_HAVE_LOOPIF                0
#define LWIP_NETIF_LOOPBACK             0
#define LWIP_NETIF_TX_SINGLE_PBUF       1
#define LWIP_NETIF_STATUS_CALLBACK      0
#define LWIP_NETIF_LINK_CALLBACK        0
#define LWIP_NUM_NETIF_CLIENT_DATA      0

/* IPv4, with fragments taken apart and put together. */
#define LWIP_IPV4                       1
#define LWIP_ICMP                       1
#define LWIP_BROADCAST_PING             0
#define LWIP_MULTICAST_PING             0
#define IP_REASSEMBLY                   1
#define IP_FRAG                         1
#define IP_REASS_MAX_PBUFS              128
#define IP_DEFAULT_TTL                  64
#define IP_FORWARD                      0

/* IPv6, when the tunnel gives an address: no neighbour discovery or autoconfiguration on a tun. */
#define LWIP_IPV6                       1
#define LWIP_ICMP6                      1
#define LWIP_IPV6_MLD                   0
#define LWIP_IPV6_AUTOCONFIG            0
#define LWIP_IPV6_DHCP6                 0
#define LWIP_IPV6_SEND_ROUTER_SOLICIT   0
#define LWIP_IPV6_DUP_DETECT_ATTEMPTS   0
#define LWIP_IPV6_REASS                 1
#define LWIP_IPV6_FRAG                  1
/* 64-bit pointers do not fit in the fragment header lwIP would reuse. */
#define IPV6_FRAG_COPYHEADER            1
#define LWIP_ND6_QUEUEING               0
#define LWIP_IPV6_NUM_ADDRESSES         3
#define LWIP_IPV6_SCOPES                0

/* UDP: the resolver's questions and the SOCKS5 server's UDP associations. */
#define LWIP_UDP                        1
#define LWIP_UDPLITE                    0

/* TCP: a client over a path with real loss (mobile networks): windows of 256 KiB with scaling,
 * selective acknowledgements to the far side, timestamps, segments ahead of a gap kept. The window
 * scale is macOS's (6): a SYN out of the tunnel says what a Mac's says (lumen_net_shape). */
#define LWIP_TCP                        1
#define TCP_MSS                         1460
#define LWIP_WND_SCALE                  1
#define TCP_RCV_SCALE                   6
#define TCP_WND                         (256 * 1024)
#define TCP_SND_BUF                     (256 * 1024)
#define TCP_SND_QUEUELEN                ((4 * TCP_SND_BUF + (TCP_MSS - 1)) / TCP_MSS)
/* The raw API does not use the low-water mark; lwIP's check wants it below 64 KiB - 4 segments. */
#define TCP_SNDLOWAT                    (32 * 1024)
#define TCP_QUEUE_OOSEQ                 1
#define LWIP_TCP_SACK_OUT               1
#define LWIP_TCP_MAX_SACK_NUM           4
#define LWIP_TCP_TIMESTAMPS             1
#define LWIP_TCP_KEEPALIVE              1
#define TCP_LISTEN_BACKLOG              0
#define LWIP_CALLBACK_API               1
#define LWIP_EVENT_API                  0
#define TCP_OVERSIZE                    TCP_MSS
#define LWIP_TCP_PCB_NUM_EXT_ARGS       0

/* The initial sequence number of each connection is random (RFC 6528), not lwIP's counter. */
#include <stdint.h>
struct ip_addr;
uint32_t lumen_lwip_isn(void);
#define LWIP_HOOK_TCP_ISN(local_ip, local_port, remote_ip, remote_port) lumen_lwip_isn()

/* Checksums: computed and checked in software, every packet. */
#define LWIP_CHKSUM_ALGORITHM           3
#define CHECKSUM_GEN_IP                 1
#define CHECKSUM_GEN_UDP                1
#define CHECKSUM_GEN_TCP                1
#define CHECKSUM_GEN_ICMP               1
#define CHECKSUM_GEN_ICMP6              1
#define CHECKSUM_CHECK_IP               1
#define CHECKSUM_CHECK_UDP              1
#define CHECKSUM_CHECK_TCP              1
#define CHECKSUM_CHECK_ICMP             1
#define CHECKSUM_CHECK_ICMP6            1

/* No statistics, no debug output. Assertions stay: a broken invariant ends the helper (fail closed). */
#define LWIP_STATS                      0
#define LWIP_STATS_DISPLAY              0
/* LWIP_DEBUG stays undefined: lwIP tests it with #ifdef. */
#define LWIP_PERF                       0

#define LWIP_RANDOMIZE_INITIAL_LOCAL_PORTS 1

#endif /* LUMEN_LWIPOPTS_H */
