import Darwin
import Foundation

/// Publishes a completed same-volume staging file under a collision-free user-visible name.
/// `FileSaver.uniqueURL` is only a hint; `RENAME_EXCL` is the atomic cross-window/process arbiter.
nonisolated enum AtomicFilePublisher {
    static func publish(staging: URL, in directory: URL, filename: String) throws -> URL {
        while true {
            try Task.checkCancellation()
            let destination = FileSaver.uniqueURL(in: directory, filename: filename)
            if renamex_np(staging.path, destination.path, UInt32(RENAME_EXCL)) == 0 {
                return destination
            }
            if errno == EEXIST { continue }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
