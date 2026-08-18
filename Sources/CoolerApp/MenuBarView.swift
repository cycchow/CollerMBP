import SwiftUI
import AppKit
import CoolerShared

struct MenuBarView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(state.status?.controlTemperature.map { "\(Int($0.rounded()))°C" } ?? "—°C")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                Spacer()
                Text(state.status?.thermalState.capitalized ?? "Disconnected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let status = state.status {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 5) {
                    GridRow { Text("CPU peak"); Text(temp(status.cpuPeakTemperature)) }
                    GridRow { Text("GPU peak"); Text(temp(status.gpuPeakTemperature)) }
                    GridRow { Text("Hottest sensor"); Text(temp(status.hottestSensorTemperature)) }
                    if let level = status.targetCoolingLevel {
                        GridRow { Text("Cooling level"); Text("\(Int((level * 100).rounded()))%") }
                    } else {
                        GridRow { Text("Cooling level"); Text("Apple controlled") }
                    }
                }
                .font(.system(size: 12))

                Divider()

                ForEach(status.fans, id: \.index) { fan in
                    HStack {
                        Text("Fan \(fan.index + 1)")
                        Spacer()
                        Text("\(fan.actualRPM) RPM")
                            .monospacedDigit()
                        Text(fan.mode)
                            .foregroundStyle(.secondary)
                            .frame(width: 55, alignment: .trailing)
                    }
                    .font(.system(size: 12))
                }

                Divider()

                modeButton(.appleAuto, current: status.mode)
                modeButton(.coolSurface, current: status.mode)
                modeButton(.maximum, current: status.mode)

                Text("Cool Surface uses a 20-second representative CPU/GPU average. It starts near 58°C, becomes stronger at 70°C, and reaches maximum at 80°C, a 95°C hotspot, or macOS serious/critical thermal state.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let error = state.connectionError ?? state.status?.lastError {
                Divider()
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Toggle("Launch at Login", isOn: Binding(
                get: { state.launchAtLogin },
                set: { state.setLaunchAtLogin($0) }
            ))
            .font(.system(size: 12))

            HStack {
                Button("Refresh") { state.refresh() }
                Spacer()
                Button("Quit UI") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 330)
    }

    @ViewBuilder
    private func modeButton(_ mode: CoolingMode, current: CoolingMode) -> some View {
        Button {
            state.setMode(mode)
        } label: {
            HStack {
                Image(systemName: current == mode ? "checkmark.circle.fill" : "circle")
                Text(mode.displayName)
                Spacer()
            }
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
    }

    private func temp(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.1f°C", value)
    }
}
