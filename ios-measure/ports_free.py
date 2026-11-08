#!/usr/bin/env python3
"""Are the harness's ports free? Checked before anything slow (the build, the install, sudo).

The owner's run on 8 November: a harness left over from a failed run still held 0.0.0.0:28310, and
the next run died with "OSError: [Errno 48] address already in use" — after the build, the install
and the sudo prompt. This binds each port the way the harness will and says who holds a busy one.

    python3 ios-measure/ports_free.py 28310 28380 ...   -> exit 0, or 1 naming the busy ports
"""
import socket
import subprocess
import sys


def busy(port, kind):
    s = socket.socket(socket.AF_INET, kind)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        s.bind(("0.0.0.0", port))
        return False
    except OSError:
        return True
    finally:
        s.close()


def holder(port):
    try:
        out = subprocess.run(["lsof", "-nP", f"-i:{port}"], capture_output=True, text=True, timeout=10).stdout.strip()
        return out.splitlines()[1] if len(out.splitlines()) > 1 else ""
    except (OSError, subprocess.TimeoutExpired):
        return ""


def main():
    taken = []
    for arg in sys.argv[1:]:
        kind = socket.SOCK_DGRAM if arg.endswith("/udp") else socket.SOCK_STREAM
        port = int(arg.split("/")[0])
        if busy(port, kind):
            taken.append((arg, holder(port)))
    if taken:
        print("PORTS IN USE — most likely a harness left from an earlier run:", file=sys.stderr)
        for port, who in taken:
            print(f"  {port}: {who or '(lsof shows no owner: try sudo lsof -nP -i:' + port.split('/')[0] + ')'}", file=sys.stderr)
        print("Stop it (pkill -f ios-measure/host/harness.py) and run again.", file=sys.stderr)
        sys.exit(1)
    print("ports free: " + " ".join(sys.argv[1:]))


if __name__ == "__main__":
    main()
