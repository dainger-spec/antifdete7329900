# CLwIP

lwIP 2.2.1 (`STABLE-2_2_1_RELEASE`, commit 77dcd25a72509eb83f72b033d219b1d40cd8eb95 of
https://github.com/lwip-tcpip/lwip), BSD-3-Clause (`lwip/COPYING`): the core (`src/core`, IPv4,
IPv6) and its headers, copied unchanged. Nothing else of lwIP is here.

Lumen's own files: `port/lwipopts.h` (the options), `port/arch/cc.h` (the platform),
`lumen_lwip.c` and `include/LumenLwIP.h` (the door the tunnel's Swift code uses). See docs/OPENVPN.md.

To check the copy against lwIP's: `git clone --branch STABLE-2_2_1_RELEASE https://github.com/lwip-tcpip/lwip`
and `diff -r` each copied file.
