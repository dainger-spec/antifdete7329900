import BrowserCore
import Foundation

// `lumen-xray-config --port N --user U --pass P` < link
//
// Prints the relay's configuration for the share link on standard input, as the app gives it to Xray
// for a launch (`XrayConfig`; docs/TUNNEL.md, "Links"). For scripts/xray_relay_check.py, which runs
// it against real Xray servers of every protocol, on Linux and macOS. The link comes on standard
// input, never in argv (which any process of this user can read): it holds the server's secret.
var port: Int?
var user: String?
var password: String?
var arguments = CommandLine.arguments.dropFirst()
while let flag = arguments.popFirst() {
    let value = arguments.popFirst()
    switch flag {
    case "--port": port = value.flatMap(Int.init)
    case "--user": user = value
    case "--pass": password = value
    default:
        FileHandle.standardError.write(Data("usage: lumen-xray-config --port N --user U --pass P < link\n".utf8))
        exit(64)
    }
}
guard let port, let user, let password else {
    FileHandle.standardError.write(Data("usage: lumen-xray-config --port N --user U --pass P < link\n".utf8))
    exit(64)
}
let input = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
do {
    let link = try ShareLink.parse(input)
    let json = try XrayConfig.json(for: link, inbound: XrayConfig.Inbound(port: port, username: user, password: password))
    FileHandle.standardOutput.write(json)
    FileHandle.standardOutput.write(Data("\n".utf8))
} catch {
    // The reason, never the link (`ShareLinkError` carries no secret).
    FileHandle.standardError.write(Data("not a usable link: \(error)\n".utf8))
    exit(2)
}
