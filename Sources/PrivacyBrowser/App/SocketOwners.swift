import Darwin
import Foundation
import NetworkGuardCore

/// `Lumen --socket-owners 203.0.113.1`: every UDP and TCP socket of this Mac connected to an
/// address, as the kernel's table has it (SocketTable, which the network guard reads for each flow):
/// the process that uses it and the one it is counted for. CI holds it against a packet capture's
/// proc and eproc while the guard's probe runs (scripts/guard_probe_check.py).
enum SocketOwners {
    static func run(arguments: [String]) -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        guard let index = arguments.firstIndex(of: "--socket-owners"), arguments.indices.contains(index + 1),
              let address = GuardPolicy.canonicalAddress(arguments[index + 1]) else {
            print("usage: Lumen --socket-owners <address>")
            exit(2)
        }
        var status: Int32 = 0
        for transport in [GuardTransport.udp, .tcp] {
            switch SocketTable.read(transport) {
            case .failure(let error):
                print("KERNEL-TABLE \(transport.rawValue) not read: \(error)")
                status = 1
            case .success(let sockets):
                print("KERNEL-TABLE \(transport.rawValue): \(sockets.count) sockets")
                for socket in sockets where socket.remoteAddress == address {
                    print("KERNEL-SOCKET \(transport.rawValue) local=\(socket.localPort) remote=\(address):\(socket.remotePort) "
                          + "last=\(socket.lastPID) effective=\(socket.effectivePID) delegated=\(socket.delegated ? 1 : 0) "
                          + "counted=\(socket.countedFor)")
                }
            }
        }
        exit(status)
    }
}
