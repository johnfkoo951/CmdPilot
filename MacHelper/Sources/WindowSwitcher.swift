import Foundation

/// 앱 내 창 전환을 **키 입력(⌘`) 없이** 수행한다.
/// (사용자가 ⌘`·⇧⌘` 를 Alfred/Raycast 클립보드 등 다른 용도로 쓰는 경우 충돌 없이 동작)
///
/// 구현: System Events 로 **맥의 최전면 프로세스**의 창을 AXRaise 한다.
///   - 백그라운드(LSUIElement) 앱에서 `AXUIElementPerformAction` 을 직접 부르면 macOS 하드닝으로
///     -25200(cannotComplete)이 나므로, 자동화 브로커인 System Events 를 경유한다. (실측으로 확인)
///   - 최초 1회 "System Events 제어 허용?"(자동화) 프롬프트가 뜰 수 있음 → 허용하면 이후 유지.
enum WindowSwitcher {
    static func cycle(next: Bool) {
        // next=맨 뒤 창을 앞으로(정방향 순환), prev=두 번째 창을 앞으로(2창 토글/역방향)
        let pick = next ? "item (count of ws) of ws" : "item 2 of ws"
        let script = """
        tell application "System Events"
            set procs to (every process whose frontmost is true)
            if (count of procs) is 0 then return
            set p to item 1 of procs
            set ws to windows of p
            if (count of ws) < 2 then return
            perform action "AXRaise" of (\(pick))
        end tell
        """
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        proc.standardError = Pipe()   // 에러 출력이 콘솔로 새지 않게
        try? proc.run()
    }
}
