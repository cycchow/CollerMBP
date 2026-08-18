import Foundation
import CoolerShared

final class DaemonService: NSObject, CoolerDaemonXPCProtocol {
    let runtime: ControllerRuntime

    init(runtime: ControllerRuntime) {
        self.runtime = runtime
    }

    func fetchStatus(withReply reply: @escaping (NSData?, NSString?) -> Void) {
        runtime.getStatus { status in
            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                reply(try encoder.encode(status) as NSData, nil)
            } catch {
                reply(nil, String(describing: error) as NSString)
            }
        }
    }

    func setMode(_ rawValue: NSString, withReply reply: @escaping (Bool, NSString?) -> Void) {
        guard let mode = CoolingMode(rawValue: rawValue as String) else {
            reply(false, "Unknown mode" as NSString)
            return
        }
        runtime.setMode(mode) { result in
            switch result {
            case .success: reply(true, nil)
            case .failure(let error): reply(false, String(describing: error) as NSString)
            }
        }
    }

    func ping(withReply reply: @escaping (NSString) -> Void) {
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
        guard authorizer.isAuthorized(connection) else {
            fputs("CoolerMBP: rejected unauthorized XPC client pid \(connection.processIdentifier)\n", stderr)
            return false
        }
        connection.exportedInterface = NSXPCInterface(with: CoolerDaemonXPCProtocol.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}

do {
    let runtime = try ControllerRuntime()
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

    RunLoop.main.run()
} catch {
    fputs("CoolerMBP daemon failed to start: \(error)\n", stderr)
    exit(1)
}
