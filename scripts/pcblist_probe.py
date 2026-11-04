#!/usr/bin/env python3
"""What sysctl net.inet.{udp,tcp}.pcblist_n gives this process (a measurement on
claude/measure-guard-link, never merged): its size, its header, every record's kind and length, the
sockets it lists (local port, remote, last and effective pid, flags) — with a UDP socket of this
process's own connected to 203.0.113.2:9 as the control that must be listed. Run as the user and
with sudo: on macOS 27.0.1 the app read 0 sockets where macOS 26.6.2 gave it a dozen."""
import ctypes
import os
import socket
import struct
import sys

libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
libc.sysctlbyname.argtypes = [ctypes.c_char_p, ctypes.c_void_p, ctypes.POINTER(ctypes.c_size_t), ctypes.c_void_p, ctypes.c_size_t]


def read(name):
    size = ctypes.c_size_t(0)
    if libc.sysctlbyname(name.encode(), None, ctypes.byref(size), None, 0) != 0:
        return None, ctypes.get_errno(), 0
    asked = size.value
    buffer = ctypes.create_string_buffer(asked + asked // 4 + 4096)
    size = ctypes.c_size_t(len(buffer))
    if libc.sysctlbyname(name.encode(), buffer, ctypes.byref(size), None, 0) != 0:
        return None, ctypes.get_errno(), asked
    return buffer.raw[:size.value], 0, asked


def main():
    own = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    own.connect(("203.0.113.2", 9))
    own_port = own.getsockname()[1]
    print(f"PCB uid {os.getuid()} pid {os.getpid()}, own UDP socket on port {own_port} → 203.0.113.2:9")
    for name in ("net.inet.udp.pcblist_n", "net.inet.tcp.pcblist_n", "net.inet.udp.pcblist", "net.inet.udp.pcblist64"):
        data, error, asked = read(name)
        if data is None:
            print(f"PCB {name}: refused, errno {error} ({os.strerror(error) if error else '?'}), size asked {asked}")
            continue
        print(f"PCB {name}: {len(data)} bytes (size answered first {asked})")
        if not name.endswith("_n"):
            if len(data) >= 24:
                print(f"PCB   header len {struct.unpack_from('<I', data, 0)[0]}, count {struct.unpack_from('<I', data, 4)[0]}")
            continue
        header_len, count = struct.unpack_from("<II", data, 0)
        print(f"PCB   header len {header_len}, count {count}; first 64 bytes {data[:64].hex()}")
        offset, kinds, listed, pcb = header_len, {}, [], None
        while offset + 8 <= len(data):
            length, kind = struct.unpack_from("<II", data, offset)
            if length < 8:
                print(f"PCB   a record of length {length} at {offset}: stopped")
                break
            kinds.setdefault((kind, length), 0)
            kinds[(kind, length)] += 1
            if kind == 0x10 and length >= 80:
                fport, lport = struct.unpack_from(">HH", data, offset + 16)
                pcb = (lport, fport, data[offset + 60:offset + 64], data[offset + 44])
            elif kind == 0x1 and length >= 88 and pcb:
                handle, = struct.unpack_from("<Q", data, offset + 8)
                last, effective = struct.unpack_from("<ii", data, offset + 68)
                flags, = struct.unpack_from("<I", data, offset + 84)
                listed.append((pcb[0], socket.inet_ntoa(pcb[2]), pcb[1], last, effective, hex(flags), handle != 0))
                pcb = None
            offset += (length + 7) & ~7
        print(f"PCB   records by (kind, length): {sorted(kinds.items())}")
        print(f"PCB   sockets listed: {len(listed)}; own port {own_port} {'LISTED' if any(s[0] == own_port for s in listed) else 'NOT listed'}")
        for entry in listed[:12]:
            print(f"PCB     local {entry[0]} remote {entry[1]}:{entry[2]} last {entry[3]} effective {entry[4]} flags {entry[5]} in kernel {entry[6]}")
    own.close()


if __name__ == "__main__":
    sys.exit(main())
