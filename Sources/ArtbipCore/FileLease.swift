import Darwin
import Foundation

/// A separate open file description for each lease makes flock serialize both
/// threads in this process and other processes. Never unlink a lock file.
public final class FileLease: @unchecked Sendable {
    private let fd: Int32
    private init(_ url: URL) throws {
        fd = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
    deinit { close(fd) }
    public func release() { _ = flock(fd, LOCK_UN) }

    public static func acquireSync(_ url: URL) throws -> FileLease {
        let lease = try FileLease(url)
        while flock(lease.fd, LOCK_EX) != 0 {
            if errno != EINTR { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        return lease
    }

    public static func acquire(_ url: URL) async throws -> FileLease {
        let lease = try FileLease(url)
        while true {
            try Task.checkCancellation()
            if flock(lease.fd, LOCK_EX | LOCK_NB) == 0 { return lease }
            guard errno == EWOULDBLOCK || errno == EINTR else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}
