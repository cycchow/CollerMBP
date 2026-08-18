import Foundation
import ServiceManagement
import CoolerShared

@MainActor
final class AppState: ObservableObject {
    @Published var status: DaemonStatus?
    @Published var connectionError: String?
    @Published var launchAtLogin = false

    private var connection: NSXPCConnection?
    private var timer: Timer?

    init() {
        refreshLaunchAtLogin()
        connect()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    deinit {
        timer?.invalidate()
        connection?.invalidate()
    }

    var menuBarText: String {
        if let temp = status?.controlTemperature {
            return "\(Int(temp.rounded()))°C"
        }
        return "—°C"
    }

    func refresh() {
        guard let proxy = proxy() else { return }
        proxy.fetchStatus { [weak self] data, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.connectionError = error as String
                    return
                }
                guard let data else {
                    self.connectionError = "Daemon returned no status"
                    return
                }
                do {
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    self.status = try decoder.decode(DaemonStatus.self, from: data as Data)
                    self.connectionError = nil
                } catch {
                    self.connectionError = "Unable to decode daemon status: \(error)"
                }
            }
        }
    }

    func setMode(_ mode: CoolingMode) {
        guard let proxy = proxy() else { return }
        proxy.setMode(mode.rawValue as NSString) { [weak self] success, error in
            Task { @MainActor in
                guard let self else { return }
                if !success {
                    self.connectionError = (error as String?) ?? "Unable to change mode"
                } else {
                    self.connectionError = nil
                    self.refresh()
                }
            }
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            refreshLaunchAtLogin()
        } catch {
            connectionError = "Launch-at-login change failed: \(error.localizedDescription)"
            refreshLaunchAtLogin()
        }
    }

    func refreshLaunchAtLogin() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func connect() {
        let conn = NSXPCConnection(machServiceName: XPCConstants.machServiceName, options: .privileged)
        conn.remoteObjectInterface = NSXPCInterface(with: CoolerDaemonXPCProtocol.self)
        conn.interruptionHandler = { [weak self] in
            Task { @MainActor in self?.connectionError = "Cooling daemon connection interrupted" }
        }
        conn.invalidationHandler = { [weak self] in
            Task { @MainActor in
                self?.connection = nil
                self?.connectionError = "Cooling daemon is unavailable"
            }
        }
        conn.resume()
        connection = conn
    }

    private func proxy() -> CoolerDaemonXPCProtocol? {
        if connection == nil { connect() }
        guard let connection else { return nil }
        return connection.remoteObjectProxyWithErrorHandler { [weak self] error in
            Task { @MainActor in self?.connectionError = error.localizedDescription }
        } as? CoolerDaemonXPCProtocol
    }
}
