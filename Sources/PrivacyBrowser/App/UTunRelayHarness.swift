import Foundation
import TunnelCore
import TunnelTransport

/// `sudo PrivacyBrowser --utun-relay <routes.json>`: the packet tunnel's data path on a utun
/// interface opened without the Network Extension (`UTunDevice`). The routes in the file (a JSON
/// array of `TunnelRoute`) are served by the extension's own `PacketRouter` and relayed through
/// their SOCKS5 proxies. `scripts/leak_check.py` runs it as root on the CI Mac and points
/// profiles at the routes' virtual relay addresses. Prints `UTUN READY <name>` once routed, then
/// runs until it is terminated (the interface and its routes go with the process).
enum UTunRelayHarness {
    static func start(arguments: [String]) -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        guard let index = arguments.firstIndex(of: "--utun-relay"), arguments.count > index + 1 else {
            print("usage: sudo PrivacyBrowser --utun-relay <routes.json>")
            exit(64)
        }
        let queue = DispatchQueue(label: "PrivacyBrowser.utun-relay")
        let log: (String) -> Void = { print("INFO utun: \($0)") }
        do {
            let routes = try JSONDecoder().decode([TunnelRoute].self, from: Data(contentsOf: URL(fileURLWithPath: arguments[index + 1])))
            try queue.sync {
                var device: UTunDevice?
                let router = PacketRouter(relays: SOCKS5RelayFactory(queue: queue, log: log), emit: { device?.write($0) }, log: log)
                device = try UTunDevice(queue: queue) { router.handlePacket($0) }
                for problem in try device!.configure() { log(problem) }
                for route in routes { router.register(route) }
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now() + 10, repeating: 10)
                timer.setEventHandler { router.expire() }
                timer.resume()
                // Kept for the life of the process.
                retained = [device as Any, router, timer]
                print("UTUN READY \(device!.name)")
            }
        } catch {
            print("UTUN FAILED: \(error)")
            exit(1)
        }
        dispatchMain()
    }

    private static var retained: [Any] = []
}
