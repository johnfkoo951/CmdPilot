import SwiftUI

@main
struct MacPilotHelperApp: App {
    @StateObject private var server = HelperServer()

    var body: some Scene {
        MenuBarExtra("CmdSpace Pilot", systemImage: "dot.radiowaves.left.and.right") {
            MenuContentView(server: server)
        }
        .menuBarExtraStyle(.window)
    }
}
