import Darwin
import Foundation

public final class SMCWriterLock {
    private let descriptor: Int32

    public init(path: String = "/var/run/com.superstring.CoolerMBP.smc.lock") throws {
        descriptor = open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw LockError(operation: "open", code: errno) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            throw LockError(operation: "acquire", code: code)
        }
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}

private struct LockError: Error, CustomStringConvertible {
    let operation: String
    let code: Int32

    var description: String { "Unable to \(operation) CoolerMBP SMC writer lock (errno \(code))" }
}
