import SwiftUI

@main
struct MacPilotHelperApp: App {
    @StateObject private var server = HelperServer()

    var body: some Scene {
        // 메뉴바 아이콘 자체가 상태 표시: 권한 없음 ⚠️ / 서버 다운 ✕ / 정상 📡
        MenuBarExtra {
            MenuContentView(server: server)
        } label: {
            Image(systemName: !server.accessibilityGranted ? "exclamationmark.triangle.fill"
                  : (server.isRunning ? "dot.radiowaves.left.and.right" : "wifi.slash"))
        }
        .menuBarExtraStyle(.window)
    }
}
