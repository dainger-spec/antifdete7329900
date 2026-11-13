import AppKit
import BrowserCore
import Foundation
import Virtualization

// LumenVM — the one executable of the app that holds Apple's virtualization right
// (`com.apple.security.virtualization`, Resources/LumenVM.entitlements). The app starts it for
// each thing a virtual machine is needed for (`VMHelperRequest`): to ask Apple which macOS this Mac
// can run as a guest, to install it, and to run a profile's machine in a window. It is told what to
// do in one JSON line on its standard input and says what happens in JSON lines on its standard
// output (`VMHelperEvent`); it ends when the machine has.
//
// A process of its own, so that the app's own executable keeps the signature it has (docs/TUNNEL.md
// on what a new entitlement beside the network extension's can do), and so that a machine that
// fails takes nothing of the app with it.

setvbuf(stdout, nil, _IOLBF, 0)

// `--check`: started and able to say so — what the build's own checks ask of every executable.
if CommandLine.arguments.contains("--check") {
    print("LumenVM: virtualization \(VZVirtualMachine.isSupported ? "available" : "not available") on this Mac")
    exit(0)
}

guard let line = readLine(strippingNewline: true), let request = try? VMHelperRequest.parse(line) else {
    HelperIO.fail("LumenVM is started by Lumen, with a request on its standard input.")
}
guard VZVirtualMachine.isSupported else {
    HelperIO.fail("This Mac cannot run virtual machines.")
}

let application = NSApplication.shared
let delegate = HelperDelegate(request: request)
application.delegate = delegate
// Only a running machine has a window, and with it a place in the Dock.
application.setActivationPolicy(request.mode == .run ? .regular : .prohibited)
application.run()
