#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// A small file of the folder a machine shares with the app (`VMLibrary.MachineFiles.share`),
/// read as what it is: something the machine's macOS — and anything that runs in it — can write.
///
/// Such a file may be a symbolic link to a file of this Mac's, a pipe that never ends, a device,
/// or gigabytes. So it is opened without following a link (`O_NOFOLLOW`) and without waiting
/// (`O_NONBLOCK`), taken only when what was opened is a regular file, and read up to a small
/// limit; anything else is refused by its kind, which is all the log says of it. Not for the main
/// thread: a file on the share is a file of the guest's.
public enum VMShareFile {
    /// Why a file was not read. A kind only, for the log.
    public enum Refusal: String, Error, Sendable {
        /// There is no such file (yet): nothing to say.
        case missing
        /// A symbolic link: not followed.
        case symbolicLink
        /// A directory, a pipe, a socket, a device.
        case notARegularFile
        /// More than the limit.
        case tooLarge
        /// Not UTF-8 text.
        case notText
        /// The system would not open or read it.
        case unreadable
    }

    /// The most a status file or a marker of the guest's is read of: they are a few lines.
    public static let maximumBytes = 4096

    /// The file's text, or why there is none.
    public static func read(_ url: URL, maximumBytes: Int = VMShareFile.maximumBytes) -> Result<String, Refusal> {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            switch errno {
            case ENOENT, ENOTDIR: return .failure(.missing)
            case ELOOP: return .failure(.symbolicLink)
            default: return .failure(.unreadable)
            }
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { return .failure(.unreadable) }
        guard mode_t(info.st_mode) & mode_t(S_IFMT) == mode_t(S_IFREG) else { return .failure(.notARegularFile) }
        guard info.st_size <= off_t(maximumBytes) else { return .failure(.tooLarge) }
        // One byte more than the limit: a file that grew since `fstat` is still found too large.
        var bytes = [UInt8](repeating: 0, count: maximumBytes + 1)
        var have = 0
        while have < bytes.count {
            let got: Int = bytes.withUnsafeMutableBytes { buffer in
                #if canImport(Darwin)
                return Darwin.read(descriptor, buffer.baseAddress! + have, buffer.count - have)
                #else
                return Glibc.read(descriptor, buffer.baseAddress! + have, buffer.count - have)
                #endif
            }
            if got > 0 {
                have += got
            } else if got == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                return .failure(.unreadable)
            }
        }
        guard have <= maximumBytes else { return .failure(.tooLarge) }
        guard let text = String(bytes: bytes[0..<have], encoding: .utf8) else { return .failure(.notText) }
        return .success(text)
    }

    /// Whether there is a regular file at `url` itself — a symbolic link, even to one, is not.
    public static func isRegularFile(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && mode_t(info.st_mode) & mode_t(S_IFMT) == mode_t(S_IFREG)
    }
}

extension VMGuestStatus {
    /// What the guest's status file (`VMLibrary.MachineFiles.status`) says, read as a file of the
    /// guest's (`VMShareFile`); or why it was not read. Not for the main thread.
    public static func read(from url: URL) -> Result<VMGuestStatus, VMShareFile.Refusal> {
        VMShareFile.read(url).map(VMGuestStatus.init(text:))
    }
}
