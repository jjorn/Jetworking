import Foundation
import os.log

/// The default logger currently used within the logging interceptors using either `os_log` or `print`
public final class DefaultLogger: Logger {
    public init() {
        // NOTE: Nothing to do here, needed due to accessibility
    }

    /// Function to log either to `os_log` or `print` according to the os used. Prior iOS 10 or OSX 10.12 `print` is used, `os_log` for newer versions.
    /// - parameter message: The message to be logged.
    public func log(_ message: String) {
        if #available(iOS 10.0, OSX 10.12, *) {
            os_log("%@", message)
        } else {
            print(message)
        }
    }
}
