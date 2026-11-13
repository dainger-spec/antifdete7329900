import Foundation

/// The whole network of one virtual machine, in this process.
///
/// The guest's only network card is one end of a datagram socket; this is the other end. It
/// answers the guest's ARP, DHCP and DNS itself and ends every TCP connection the guest opens,
/// carrying its bytes on through the profile's proxy (SOCKS5 or HTTP CONNECT) — by host name
/// where the guest asked for a name, so the proxy resolves it. There is no other way out: no
/// route, no NAT, no socket that is not a connection to the proxy. What the proxy does not carry
/// (UDP, IPv6, connections to private addresses) is refused here.
///
/// No root and no kernel extension: it is all sockets this process may open anyway.
public final class VMNetwork: @unchecked Sendable {
    private let configuration: VMNetConfiguration
    private let frameDescriptor: Int32

    /// Held for the whole of `start` and `stop`, so that the two never interleave.
    private let lifecycle = NSLock()
    /// Guards the fields below.
    private let state = NSLock()
    private var loop: NetworkLoop?
    private var loopThread: Thread?
    private var lastCounters = VMNetCounters()
    private var logHandler: (@Sendable (String) -> Void)?
    private var optionsValue = NetworkLoop.Options()

    /// `frameDescriptor`: a connected datagram socket (or, in the interop test, a TAP descriptor):
    /// one Ethernet frame per read and per write. The caller owns it and closes it after `stop()`.
    ///
    /// The descriptor is used without waiting. On a socket nothing of its mode is changed for
    /// that; its buffers are made larger when they are small (SO_RCVBUF to 4 MiB, SO_SNDBUF to
    /// 1 MiB), and on macOS it is set not to raise SIGPIPE. A descriptor that is not a socket is
    /// set non-blocking.
    ///
    /// The other end of the pair — the one the virtual machine gets — is the caller's to prepare:
    /// what the stack sends waits in THAT end's receive buffer, and macOS's default for a
    /// datagram socket holds two frames. Give it a SO_RCVBUF of megabytes before handing it over,
    /// or downloads crawl (the stack then waits a millisecond for every couple of frames).
    public init(configuration: VMNetConfiguration, frameDescriptor: Int32) {
        self.configuration = configuration
        self.frameDescriptor = frameDescriptor
    }

    deinit { stop() }

    /// Set before start(). Lines for a log file: counts and reasons only — NEVER a destination
    /// host name or address (that is the person's browsing history) and NEVER the proxy's user
    /// name or password. Called on the network's thread.
    public var log: (@Sendable (String) -> Void)? {
        get {
            state.lock()
            defer { state.unlock() }
            return logHandler
        }
        set {
            state.lock()
            logHandler = newValue
            state.unlock()
        }
    }

    /// Starts the network on a thread of its own and returns at once. Does nothing when it runs already.
    public func start() {
        lifecycle.lock()
        defer { lifecycle.unlock() }
        state.lock()
        let running = loop != nil
        let handler = logHandler
        let options = optionsValue
        var counters = lastCounters
        state.unlock()
        guard !running else { return }
        counters.connectionsActive = 0
        guard let loop = NetworkLoop(configuration: configuration, frameDescriptor: frameDescriptor, options: options,
                                     counters: counters, log: handler) else {
            handler?("network not started: no descriptors left for it")
            return
        }
        let thread = Thread { loop.run() }
        thread.name = "VMNetwork"
        thread.stackSize = 1 << 20
        state.lock()
        self.loop = loop
        loopThread = thread
        state.unlock()
        thread.start()
    }

    /// Closes every connection to the proxy and ends the thread; returns when it has ended. Does
    /// nothing when the network does not run. The frame descriptor stays open: it is the caller's.
    public func stop() {
        state.lock()
        let onOwnThread = loop != nil && loopThread === Thread.current
        let own = loop
        state.unlock()
        if onOwnThread {
            // Called from the network's own thread (from the log handler) there is nobody to wait
            // for: the loop ends when the handler returns, and a later `stop()` tidies up.
            own?.requestStop()
            return
        }
        lifecycle.lock()
        defer { lifecycle.unlock() }
        state.lock()
        let running = loop
        state.unlock()
        guard let running else { return }
        running.requestStop()
        running.waitUntilEnded()
        state.lock()
        lastCounters = running.snapshot
        loop = nil
        loopThread = nil
        state.unlock()
    }

    /// What the network has carried so far. May be called from any thread.
    public func counters() -> VMNetCounters {
        state.lock()
        defer { state.unlock() }
        return loop?.snapshot ?? lastCounters
    }

    /// The loop's settings, for tests: shorter timeouts, smaller buffers. Read at `start()`.
    var options: NetworkLoop.Options {
        get {
            state.lock()
            defer { state.unlock() }
            return optionsValue
        }
        set {
            state.lock()
            optionsValue = newValue
            state.unlock()
        }
    }

    /// For the interop test only: the share of frames (0 to 1) thrown away in each direction, to
    /// show that lost segments are sent again. Read at `start()`.
    @_spi(Testing) public func setFrameLossForTesting(toGuest: Double, fromGuest: Double) {
        state.lock()
        optionsValue.lossToGuest = toGuest
        optionsValue.lossFromGuest = fromGuest
        state.unlock()
    }
}
