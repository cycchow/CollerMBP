import Foundation

public enum XPCConstants {
    public static let machServiceName = "com.superstring.CoolerMBP.daemon"
}

#if os(macOS)
@objc public protocol CoolerDaemonXPCProtocol {
    func fetchStatus(withReply reply: @escaping (NSData?, NSString?) -> Void)
    func setMode(_ rawValue: NSString, withReply reply: @escaping (Bool, NSString?) -> Void)
    func ping(withReply reply: @escaping (NSString) -> Void)
}
#endif
