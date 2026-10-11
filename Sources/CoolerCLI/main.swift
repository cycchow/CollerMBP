import Foundation
import CoolerShared

final class Client {
    private let connection: NSXPCConnection

    init() {
        connection = NSXPCConnection(machServiceName: XPCConstants.machServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: CoolerDaemonXPCProtocol.self)
        connection.resume()
    }

    deinit { connection.invalidate() }

    func status() -> Int32 {
        let sem = DispatchSemaphore(value: 0)
        var exitCode: Int32 = 1
        guard let proxy = proxy(onError: { sem.signal() }) else { return 1 }
        proxy.fetchStatus { data, error in
            defer { sem.signal() }
            if let error {
                fputs("error: \(error)\n", stderr)
                return
            }
            guard let data else { return }
            do {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let status = try decoder.decode(DaemonStatus.self, from: data as Data)
                print("mode: \(status.mode.rawValue)")
                if let t = status.controlTemperature { print(String(format: "control temp: %.1f C", t)) }
                print("thermal state: \(status.thermalState)")
                for fan in status.fans {
                    print("fan \(fan.index): \(fan.actualRPM) rpm (target \(fan.targetRPM), \(fan.mode), range \(fan.minRPM)-\(fan.maxRPM))")
                }
                if let err = status.lastError { print("last error: \(err)") }
                exitCode = 0
            } catch {
                fputs("decode error: \(error)\n", stderr)
            }
        }
        if sem.wait(timeout: .now() + 5) == .timedOut {
            fputs("error: status request timed out after 5 seconds (client pid \(getpid()))\n", stderr)
            return 1
        }
        return exitCode
    }

    func setMode(_ mode: CoolingMode) -> Int32 {
        let sem = DispatchSemaphore(value: 0)
        var exitCode: Int32 = 1
        guard let proxy = proxy(onError: { sem.signal() }) else { return 1 }
        proxy.setMode(mode.rawValue as NSString) { success, error in
            if success {
                print("mode set to \(mode.rawValue)")
                exitCode = 0
            } else {
                fputs("error: \((error as String?) ?? "unknown error")\n", stderr)
            }
            sem.signal()
        }
        if sem.wait(timeout: .now() + 8) == .timedOut {
            fputs("error: \(mode.rawValue) request timed out after 8 seconds (client pid \(getpid()))\n", stderr)
            return 1
        }
        return exitCode
    }

    func ping() -> Int32 {
        let sem = DispatchSemaphore(value: 0)
        var exitCode: Int32 = 1
        guard let proxy = proxy(onError: { sem.signal() }) else { return 1 }
        proxy.ping { response in
            print(response)
            exitCode = response == "pong" ? 0 : 1
            sem.signal()
        }
        if sem.wait(timeout: .now() + 5) == .timedOut {
            fputs("error: XPC ping timed out after 5 seconds (client pid \(getpid()))\n", stderr)
            return 1
        }
        return exitCode
    }

    private func proxy(onError: @escaping () -> Void) -> CoolerDaemonXPCProtocol? {
        connection.remoteObjectProxyWithErrorHandler { error in
            fputs("XPC error: \(error)\n", stderr)
            onError()
        } as? CoolerDaemonXPCProtocol
    }
}

let args = CommandLine.arguments.dropFirst()
let command = args.first ?? "status"
let client = Client()
let code: Int32
switch command {
case "status": code = client.status()
case "ping": code = client.ping()
case "auto", "reset": code = client.setMode(.appleAuto)
case "cool": code = client.setMode(.coolSurface)
case "max": code = client.setMode(.maximum)
default:
    print("usage: coolermbpctl [status|ping|auto|cool|max]")
    code = 2
}
exit(code)
