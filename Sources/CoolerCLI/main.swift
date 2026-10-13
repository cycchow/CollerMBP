import Foundation
import Darwin
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
                print("hardware: \(self.hardwareModel())")
                print("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
                print("requested mode: \(status.mode.rawValue)")
                print("hardware recovery required: \(status.recoveryRequired == true)")
                print("verified fan-control: \(status.fans.map(\.mode).joined(separator: ", "))")
                print("thermal state: \(status.thermalState)")
                print("SMC: \(status.hardwareInfo)")
                if let t = status.controlTemperature { print(String(format: "control temp: %.1f C", t)) }
                if let t = status.cpuPeakTemperature { print(String(format: "CPU peak: %.1f C", t)) }
                if let t = status.gpuPeakTemperature { print(String(format: "GPU peak: %.1f C", t)) }
                if let t = status.hottestSensorTemperature { print(String(format: "hotspot: %.1f C", t)) }
                if let target = status.targetCoolingLevel { print(String(format: "target cooling: %.0f%%", target * 100)) }
                for fan in status.fans {
                    print("fan \(fan.index): \(fan.actualRPM) rpm (target \(fan.targetRPM), \(fan.mode), key \(fan.modeKey ?? "unknown"), range \(fan.minRPM)-\(fan.maxRPM))")
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

    private func hardwareModel() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var value = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &value, &size, nil, 0) == 0 else { return "unknown" }
        return String(cString: value)
    }
}

let args = CommandLine.arguments.dropFirst()
let command = args.first ?? "status"
let client = Client()
let code: Int32
switch command {
case "status", "diagnose": code = client.status()
case "ping": code = client.ping()
case "auto", "reset": code = client.setMode(.appleAuto)
case "cool": code = client.setMode(.coolSurface)
case "max": code = client.setMode(.maximum)
default:
    print("usage: coolermbpctl [status|diagnose|ping|auto|cool|max]")
    code = 2
}
exit(code)
