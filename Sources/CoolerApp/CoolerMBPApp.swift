import SwiftUI

@main
struct CoolerMBPApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(state)
        } label: {
            Text(state.menuBarText)
                .monospacedDigit()
        }
        .menuBarExtraStyle(.window)
    }
}
