#if canImport(Darwin)
import Darwin
import Foundation

extension VMLibrary.MachineFiles {
    public func prepareDisk(baseDirectory: URL?, newIdentity: () -> Data) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        // Two helper processes may overlap during relaunch. Lock the directory inode before
        // inspecting the disk or removing staging files. The kernel releases it on exit.
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard !isComplete else { return }
        if manager.fileExists(atPath: disk.path) {
            throw VMFailure(.files, "This machine has an existing disk but is missing firmware or identity files. Restore its metadata before starting it.")
        }
        guard let baseDirectory else {
            throw VMFailure(.noBase, "This machine has no disk, and no base system to make it from.")
        }
        let base = VMLibrary.MachineFiles(directory: baseDirectory)
        guard base.isComplete else {
            throw VMFailure(.noBase, "The base system is not installed.")
        }
        try manager.createDirectory(at: share, withIntermediateDirectories: true)
        // What a clone that stopped part-way left.
        let made = [auxiliaryStorage, hardwareModel, machineIdentifier]
        for url in made { try? manager.removeItem(at: url) }
        let cloning = directory.appendingPathComponent("disk.img.cloning")
        try? manager.removeItem(at: cloning)
        do {
            if clonefile(base.disk.path, cloning.path, 0) != 0 {
                let code = errno
                guard code == ENOTSUP || code == EXDEV else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
                }
                // A volume without copy-on-write support needs a whole copy.
                try manager.copyItem(at: base.disk, to: cloning)
            }
            try manager.copyItem(at: base.auxiliaryStorage, to: auxiliaryStorage)
            try manager.copyItem(at: base.hardwareModel, to: hardwareModel)
            try newIdentity().write(to: machineIdentifier, options: .atomic)
            // Publish the complete disk only after all its companion files exist.
            try manager.moveItem(at: cloning, to: disk)
        } catch {
            // A copy that stopped part-way — a full disk, above all — is gigabytes of nothing: gone
            // now, not left on the full disk until the machine's next start.
            for url in [cloning] + made { try? manager.removeItem(at: url) }
            throw error
        }
    }
}
#endif
