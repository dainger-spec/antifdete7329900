import Foundation

@main
enum VMController {
    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 2 else {
            print("Usage: VMController <url>")
            print("Example: VMController https://browserleaks.com")
            exit(1)
        }
        let url = args[1]
        let controller = Controller()
        controller.run(url: url)
    }
}

final class Controller {
    func run(url: String) {
        print("==> VM Controller")
        print("    Target: \(url)")
        print("")
        print("This is a stub. Next steps:")
        print("  1. Check / download base image")
        print("  2. Launch VM via Tart or vfkit")
        print("  3. Install agent")
        print("  4. Navigate Safari")
        print("")
        print("See vm/controller/tart-prototype.sh for the working bash version.")
    }
}
