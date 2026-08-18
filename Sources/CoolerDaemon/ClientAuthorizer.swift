import Foundation
import Security
import SystemConfiguration

final class ClientAuthorizer {
    private let trustedPaths = [
        "/Applications/CoolerMBP.app/Contents/MacOS/CoolerApp",
        "/usr/local/bin/coolermbpctl"
    ]

    func isAuthorized(_ connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == 0 || connection.effectiveUserIdentifier == consoleUserID(),
              let guestHash = signingHash(forPID: connection.processIdentifier) else {
            return false
        }

        return trustedPaths.contains { path in
            isRootOwnedExecutable(path) && signingHash(at: path) == guestHash
        }
    }

    private func consoleUserID() -> uid_t? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard let user = SCDynamicStoreCopyConsoleUser(nil, &uid, &gid) as String?,
              user != "loginwindow" else { return nil }
        return uid
    }

    private func isRootOwnedExecutable(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == 0,
              (info.st_mode & (S_IWGRP | S_IWOTH)) == 0 else {
            return false
        }
        return true
    }

    private func signingHash(forPID pid: pid_t) -> Data? {
        let attributes = [kSecGuestAttributePid: pid] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
              let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        return signingHash(of: staticCode)
    }

    private func signingHash(at path: String) -> Data? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
              let code else { return nil }
        return signingHash(of: code)
    }

    private func signingHash(of code: SecStaticCode) -> Data? {
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [CFString: Any] else { return nil }
        return dictionary[kSecCodeInfoUnique] as? Data
    }
}
