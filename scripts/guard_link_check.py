#!/usr/bin/env python3
"""Can WebKit's network process be tied, by what the kernel keeps, to the profile process it works for?
(a measurement on claude/measure-guard-link, never merged)

    sudo -n true && python3 scripts/guard_link_check.py --app build/unsandboxed/Lumen.app --out build/guard-link

The owner's Mac, 0.1.2 (3), macOS 27.0.1, `Lumen --guard-diagnose`: the probe's UDP to 203.0.113.1:3478
was counted for com.apple.WebKit.Networking (pid 1152) and opened by it — not for the probe (pid 1146)
— so the guard, which holds the probe's pid, let it through. Whether the guard can hold what WebKit's
network process does for a profile depends on whether the kernel ties the two.

Two probes (`LumenProfile --guard-probe`, each a profile's process as the app starts one, each with
WebKit processes of its own) run at once. While they run, every WebKit process of the machine is read
for what the kernel says of its origin, and each tie is looked up among the probes' pids:

  - its parent (ppid), process group (pgid), session (sid): from ps;
  - its responsible process: responsibility_get_pid_responsible_for_pid (libSystem; what TCC and
    Activity Monitor use to count an XPC service for the app it works for);
  - its coalitions (resource and jetsam): proc_pidinfo PROC_PIDCOALITIONINFO, and the probes';
  - launchd's own account: `sudo launchctl procinfo <pid>`, its lines about responsibility, parents
    and coalitions.

A pktap capture of 203.0.113.1 says, for each of the probes' STUN packets, the process that sent it
(proc) and the one the system counts it for (eproc). One network process killed while its probe runs
shows whether a new one comes, and whether it is tied the same way.

A tie is reliable only if, for both probes at once, every network process that sent a probe's packet
names exactly that probe and never the other. The verdict says which ties did, which did not, and
which could not be read (a call refused, a field missing).
"""
import argparse
import ctypes
import ctypes.util
import os
import re
import subprocess
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import egress_check  # noqa: E402

STUN_ADDRESS = "203.0.113.1"
PROC_PIDCOALITIONINFO = 20  # sys/proc_info.h: struct proc_pidcoalitioninfo { uint64_t coalition_id[2]; uint64_t reserved[3]; }


def libsystem():
    return ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)


LIB = libsystem()
try:
    RESPONSIBLE = LIB.responsibility_get_pid_responsible_for_pid
    RESPONSIBLE.argtypes = [ctypes.c_int]
    RESPONSIBLE.restype = ctypes.c_int
except AttributeError:
    RESPONSIBLE = None
PROC_PIDINFO = LIB.proc_pidinfo
PROC_PIDINFO.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
PROC_PIDINFO.restype = ctypes.c_int


def responsible(pid):
    if RESPONSIBLE is None:
        return "no such call in libSystem"
    value = RESPONSIBLE(pid)
    return value if value > 0 else f"answered {value} (errno {ctypes.get_errno()})"


def coalitions(pid):
    buffer = (ctypes.c_uint64 * 5)()
    size = PROC_PIDINFO(pid, PROC_PIDCOALITIONINFO, 0, ctypes.byref(buffer), ctypes.sizeof(buffer))
    if size <= 0:
        return f"refused (errno {ctypes.get_errno()})"
    return (int(buffer[0]), int(buffer[1]))


def table():
    """{pid: (ppid, pgid, sid, command)} of every process."""
    out = subprocess.run(["ps", "-axo", "pid=,ppid=,pgid=,sess=,comm="], capture_output=True, text=True).stdout
    found = {}
    for line in out.splitlines():
        fields = line.split(None, 4)
        if len(fields) == 5 and all(f.lstrip("-").isdigit() for f in fields[:4]):
            found[int(fields[0])] = (int(fields[1]), int(fields[2]), int(fields[3]), fields[4])
    return found


def launchd_lines(pid):
    result = subprocess.run(["sudo", "-n", "launchctl", "procinfo", str(pid)], capture_output=True, text=True, timeout=20)
    keep = [line.strip() for line in (result.stdout or result.stderr).splitlines()
            if re.search(r"responsib|parent|coalition|origin|spawn|xpc service|program", line, re.I)]
    return keep[:12] or [f"(exit {result.returncode}, nothing about responsibility, parents or coalitions)"]


def webkit_processes(snapshot):
    return {pid: row for pid, row in snapshot.items() if "com.apple.WebKit" in row[3]}


def describe(pid, row, probes):
    ppid, pgid, sid, command = row
    name = os.path.basename(command)
    resp = responsible(pid)
    coal = coalitions(pid)
    ties = {
        "parent": ppid if ppid in probes else None,
        "pgid": pgid if pgid in probes else None,
        "sid": sid if sid in probes else None,
        "responsible": resp if isinstance(resp, int) and resp in probes else None,
        "resource coalition": next((p for p in probes if isinstance(coal, tuple) and isinstance(probes[p], tuple)
                                    and coal[0] == probes[p][0]), None),
        "jetsam coalition": next((p for p in probes if isinstance(coal, tuple) and isinstance(probes[p], tuple)
                                  and coal[1] == probes[p][1]), None),
    }
    return name, resp, coal, ties


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    os.makedirs(args.out, exist_ok=True)
    binary = os.path.join(os.path.abspath(args.app), "Contents", "MacOS", "LumenProfile")
    print(f"LINK machine: {subprocess.run(['sw_vers', '-productVersion'], capture_output=True, text=True).stdout.strip()}, "
          f"responsibility_get_pid_responsible_for_pid {'found' if RESPONSIBLE else 'NOT FOUND'} in libSystem", flush=True)
    before = set(webkit_processes(table()))

    capture_path = os.path.join(args.out, "capture.txt")
    capture = open(capture_path, "w")
    errors = open(capture_path + ".err", "w")
    tcpdump = subprocess.Popen(["sudo", "-n", "tcpdump", "-i", "pktap,all", "-k", "NP", "-n", "-tt", "-l", f"host {STUN_ADDRESS}"],
                               stdout=capture, stderr=errors)
    time.sleep(3)

    probes = []
    for index in range(2):
        process = subprocess.Popen([binary, "--guard-probe"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, text=True)
        first = process.stdout.readline()
        match = re.match(r"GUARD-PROBE pid (\d+)", first)
        print(f"LINK probe {index}: {first.strip()}", flush=True)
        probes.append((process, int(match.group(1)) if match else process.pid))
    probe_pids = {pid: coalitions(pid) for _, pid in probes}
    for pid, coal in probe_pids.items():
        print(f"LINK probe pid {pid}: responsible {responsible(pid)}, coalitions {coal}", flush=True)

    outputs = {}

    def read(process, pid):
        outputs[pid] = process.communicate()[0]

    for process, _ in probes:
        process.stdin.write("go\n")
        process.stdin.flush()
        process.stdin.close()
    readers = [threading.Thread(target=read, args=(process, pid), daemon=True) for process, pid in probes]
    for reader in readers:
        reader.start()

    seen = {}
    sockets_header, sockets_seen = [], set()
    killed = None
    started = time.time()
    while any(process.poll() is None for process, _ in probes) and time.time() - started < 60:
        snapshot = table()
        for pid, row in webkit_processes(snapshot).items():
            if pid in before or pid in seen:
                continue
            name, resp, coal, ties = describe(pid, row, probe_pids)
            seen[pid] = (name, resp, coal, ties)
            named = ", ".join(f"{k} {v}" for k, v in ties.items() if v) or "none"
            print(f"LINK webkit {name} pid {pid}: ppid {row[0]}, pgid {row[1]}, sid {row[2]}, responsible {resp}, "
                  f"coalitions {coal} -> ties to a probe: {named}", flush=True)
            for line in launchd_lines(pid):
                print(f"LINK   launchd {pid}: {line}", flush=True)
        # The kernel's socket table: each UDP socket of a WebKit network process, with the process
        # it is counted for (netstat's epid, sysctl net.inet.udp.pcblist_n's so_e_pid).
        networking_now = {pid for pid, (name, *_rest) in seen.items() if "Networking" in name}
        if networking_now:
            table_out = subprocess.run(["netstat", "-anv", "-p", "udp"], capture_output=True, text=True).stdout.splitlines()
            if not sockets_header and table_out:
                sockets_header.extend(table_out[:2])
                for line in table_out[:2]:
                    print(f"LINK netstat: {line}", flush=True)
            for line in table_out:
                fields = line.split()
                pids = {int(f.split(":")[-1]) for f in fields if re.fullmatch(r"[\w.\-]*:\d+", f) and f.split(":")[-1].isdigit()}
                numbers = [int(f) for f in fields if f.isdigit()]
                if (pids | set(numbers)) & networking_now and line not in sockets_seen:
                    sockets_seen.add(line)
                    print(f"LINK socket: {line}", flush=True)
        # One network process killed once both probes have one: does WebKit start another, tied the same way?
        networking = [pid for pid, (name, *_rest) in seen.items() if "Networking" in name]
        if killed is None and len(networking) >= 2 and time.time() - started > 2:
            killed = networking[0]
            subprocess.run(["sudo", "-n", "kill", "-9", str(killed)], check=False)
            print(f"LINK killed network process {killed} (tied to {seen[killed][3]})", flush=True)
        time.sleep(0.3)
    for process, _ in probes:
        if process.poll() is None:
            process.kill()
    for reader in readers:
        reader.join(timeout=10)
    time.sleep(2)
    subprocess.run(["sudo", "-n", "pkill", "-INT", "-f", "tcpdump -i pktap"], check=False)
    tcpdump.wait(timeout=20)
    for pid, text in outputs.items():
        for line in (text or "").splitlines()[-6:]:
            print(f"LINK probe {pid} said: {line}", flush=True)

    with open(capture_path, errors="replace") as handle:
        packets = [p for p in (egress_check.parse(line) for line in handle) if p["dst"] is not None and str(p["dst"]) == STUN_ADDRESS]
    print(f"\nLINK packets to {STUN_ADDRESS}: {len(packets)}")
    senders = {}
    for packet in packets:
        key = (packet["proc"], packet["eproc"])
        senders[key] = senders.get(key, 0) + 1
    for (proc, eproc), count in sorted(senders.items(), key=lambda item: -item[1]):
        sender_pid = proc[1] if proc else None
        tie = seen.get(sender_pid, (None, None, None, {}))[3]
        print(f"LINK   {count} packet(s): sent by {proc}, counted for {eproc}; the sender's ties: "
              + (", ".join(f"{k} {v}" for k, v in tie.items() if v) or "none"))

    # The verdict, per kind of tie: every network process that sent a probe's packet must name exactly the
    # probe its packets were counted for (eproc), and the two probes' network processes must differ.
    print("\n==== Which tie holds ====")
    senders_by_pid = {}
    for packet in packets:
        if packet["proc"] and packet["eproc"]:
            senders_by_pid.setdefault(packet["proc"][1], set()).add(packet["eproc"][1])
    for kind in ("parent", "pgid", "sid", "responsible", "resource coalition", "jetsam coalition"):
        verdicts = []
        for sender, counted_for in senders_by_pid.items():
            tie = seen.get(sender, (None, None, None, {}))[3].get(kind)
            verdicts.append((sender, counted_for, tie))
        holds = bool(verdicts) and all(tie is not None and {tie} == counted for _, counted, tie in verdicts)
        distinct = len({tie for *_ignored, tie in verdicts}) == len(verdicts)
        print(f"LINK-VERDICT {kind}: {'HOLDS' if holds and distinct else 'does not hold'} — "
              + "; ".join(f"network process {s}: counted for {sorted(c)}, tie names {t}" for s, c, t in verdicts))
    networking = {pid: info for pid, info in seen.items() if "Networking" in info[0]}
    for kind in ("responsible", "resource coalition", "jetsam coalition"):
        tied = {pid: info[3].get(kind) for pid, info in networking.items()}
        print(f"LINK-NETWORKING {kind}: " + ", ".join(f"{pid} -> {tie}" for pid, tie in tied.items())
              + f" (probes {sorted(probe_pids)}, killed {killed})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
