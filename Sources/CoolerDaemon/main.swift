import Foundation
import CoolerShared
import CoolerDaemonCore

final class DaemonService: NSObject, CoolerDaemonXPCProtocol {
    let runtime: ControllerRuntime

    init(runtime: ControllerRuntime) {
        self.runtime = runtime
    }

    func fetchStatus(withReply reply: @escaping (NSData?, NSString?) -> Void) {
        let clientPID = NSXPCConnection.current()?.processIdentifier
        let logRequest = NSXPCConnection.current()?.effectiveUserIdentifier == 0
        if logRequest { fputs("CoolerMBP: status request from pid \(clientPID ?? -1)\n", stderr) }
        runtime.getStatus { status in
            let age = Date().timeIntervalSince(status.timestamp)
            guard age <= 10 else {
                reply(nil, "SMC status is stale (last update \(Int(age)) seconds ago); sensor polling may be delayed." as NSString)
                if logRequest { fputs("CoolerMBP: stale status reply sent to pid \(clientPID ?? -1)\n", stderr) }
                return
            }
            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                reply(try encoder.encode(status) as NSData, nil)
                if logRequest { fputs("CoolerMBP: status reply sent to pid \(clientPID ?? -1)\n", stderr) }
            } catch {
                reply(nil, String(describing: error) as NSString)
            }
        }
    }

    func setMode(_ rawValue: NSString, withReply reply: @escaping (Bool, NSString?) -> Void) {
        fputs("CoolerMBP: mode request \(rawValue)\n", stderr)
        guard let mode = CoolingMode(rawValue: rawValue as String) else {
            reply(false, "Unknown mode" as NSString)
            return
        }
        runtime.setMode(mode) { result in
            fputs("CoolerMBP: mode request completed: \(result)\n", stderr)
            switch result {
            case .success: reply(true, nil)
            case .failure(let error): reply(false, String(describing: error) as NSString)
            }
        }
    }

    func ping(withReply reply: @escaping (NSString) -> Void) {
        fputs("CoolerMBP: XPC ping received\n", stderr)
        reply("pong")
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    let service: DaemonService
    let authorizer = ClientAuthorizer()

    init(service: DaemonService) {
        self.service = service
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        fputs("CoolerMBP: checking XPC client pid \(connection.processIdentifier), uid \(connection.effectiveUserIdentifier)\n", stderr)
        guard authorizer.isAuthorized(connection) else {
            fputs("CoolerMBP: rejected unauthorized XPC client pid \(connection.processIdentifier)\n", stderr)
            return false
        }
        connection.exportedInterface = NSXPCInterface(with: CoolerDaemonXPCProtocol.self)
        connection.exportedObject = service
        connection.resume()
        fputs("CoolerMBP: accepted XPC client pid \(connection.processIdentifier)\n", stderr)
        return true
    }
}

do {
    fputs("CoolerMBP: daemon starting, pid \(getpid())\n", stderr)
    let runtime = try ControllerRuntime()
    fputs("CoolerMBP: SMC controller initialized\n", stderr)
    runtime.start()
    let service = DaemonService(runtime: runtime)
    let delegate = ListenerDelegate(service: service)

    signal(SIGTERM, SIG_IGN)
    signal(SIGINT, SIG_IGN)

    let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    termSource.setEventHandler {
        runtime.shutdown()
        exit(0)
    }
    termSource.resume()

    let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    intSource.setEventHandler {
        runtime.shutdown()
        exit(0)
    }
    intSource.resume()

    let listener = NSXPCListener(machServiceName: XPCConstants.machServiceName)
    listener.delegate = delegate
    listener.resume()
    fputs("CoolerMBP: XPC listener ready\n", stderr)

    RunLoop.main.run()
} catch {
    fputs("CoolerMBP daemon failed to start: \(error)\n", stderr)
    exit(1)
}
