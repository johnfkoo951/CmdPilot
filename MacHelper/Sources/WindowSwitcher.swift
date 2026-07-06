import AppKit
import ApplicationServices

/// 앱 내 창 전환을 **키 입력(⌘`)·System Events 없이** 순수 Accessibility API로 수행한다.
///
/// - CGEvent 주입에 이미 쓰는 **손쉬운 사용(Accessibility)** 권한 하나만으로 동작한다.
///   (자동화/AppleEvents 권한 불필요 → 사용자 머신에서 추가 프롬프트·추가 승인 없음)
/// - `AXUIElementCreateApplication(pid)`에서 얻은 창을 직접 `kAXRaiseAction`.
///   과거 -25200(cannotComplete)은 백그라운드 하드닝이 아니라 메시징 타임아웃/무효 참조 문제였고,
///   pid 기반 참조 + 메시징 타임아웃 상한으로 안정화됨. (System Events 경로는 사용자 머신에
///   자동화 권한이 없어 조용히 실패하던 것이 근본 원인이라 폐기)
enum WindowSwitcher {

    enum Result {
        case ok(count: Int)      // 전환 성공
        case single              // 전환 대상 창이 2개 미만 (단일 창 앱)
        case none                // 프론트 앱/창을 못 찾음
        case axError(Int)        // AX 액션 실패 (원인 코드)
    }

    /// next=true  → 맨 뒤 창을 앞으로(정방향 순환: 반복 시 모든 창을 순서대로 돈다)
    /// next=false → 두 번째 창을 앞으로(2창 토글 / 역방향)
    /// - AX 호출은 동기이며 최대 1s 블록될 수 있으므로 **EventInjector 큐가 아닌** 별도 큐에서 호출할 것.
    @discardableResult
    static func cycle(next: Bool) -> Result {
        guard let front = NSWorkspace.shared.frontmostApplication else { return .none }

        let app = AXUIElementCreateApplication(front.processIdentifier)
        // 불응 앱이 큐를 무한 점유하지 못하게 상한(초). 정상 앱은 즉시 응답.
        AXUIElementSetMessagingTimeout(app, 1.0)

        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &ref) == .success,
              let all = ref as? [AXUIElement], !all.isEmpty else { return .none }
        // kAXWindowsAttribute는 front→back z-순서(index 0 = 현재 최상단 창).

        // 표준 창만: 시트/다이얼로그/팝오버(AXSystemDialog 등) 제외, 최소화된 창 제외.
        func isEligible(_ w: AXUIElement) -> Bool {
            var s: CFTypeRef?
            AXUIElementCopyAttributeValue(w, kAXSubroleAttribute as CFString, &s)
            let sub = s as? String
            var m: CFTypeRef?
            AXUIElementCopyAttributeValue(w, kAXMinimizedAttribute as CFString, &m)
            let minimized = (m as? Bool) ?? false
            // 표준창이거나 subrole 미보고(nil) 창은 후보로. 명시적으로 시트/다이얼로그인 것만 배제.
            let standard = (sub == (kAXStandardWindowSubrole as String)) || (sub == nil)
            return standard && !minimized
        }
        var wins = all.filter(isEligible)
        // 비표준 subrole만 쓰는 특이 앱 방어: 후보가 부족하면 최소화 안 된 창 전체로 폴백.
        if wins.count < 2 {
            wins = all.filter { w in
                var m: CFTypeRef?
                AXUIElementCopyAttributeValue(w, kAXMinimizedAttribute as CFString, &m)
                return !((m as? Bool) ?? false)
            }
        }
        guard wins.count >= 2 else { return .single }

        // next: 맨 뒤 창을 raise → 반복 시 [A,B,C]→[C,A,B]→[B,C,A]… 전체 순환.
        // prev: 두 번째 창을 raise (역방향/2창 토글).
        let target = next ? wins[wins.count - 1] : wins[1]

        let raised = AXUIElementPerformAction(target, kAXRaiseAction as CFString)
        if raised != .success { return .axError(Int(raised.rawValue)) }

        // 일부 앱은 raise만으론 '메인 창' 표식이 안 바뀜 → 명시적으로 메인 지정(실패해도 무시).
        AXUIElementSetAttributeValue(target, kAXMainAttribute as CFString, kCFBooleanTrue)
        front.activate()   // 이미 프론트 앱이지만 활성 보장(엣지케이스 방어)

        return .ok(count: wins.count)
    }
}
