import Foundation

/// 폰에서 원격 조종하는 터미널 멀티플렉서(백엔드)의 공통 추상화.
///
/// cmux(로컬 macOS 네이티브)·herdr(원격 에이전트 런타임) 등을 **같은 5-op 계약**으로 감싼다:
///   ① LIST   → `handle(dir:"state")` 응답의 windows[]/tabs[]
///   ② FOCUS  → `handle(dir: 전환동사, target:)`
///   ③ READ   → `terminalGrid(handle:)`
///   ④ SEND   → `terminalInput(handle:text:)`
///   ⑤ STATE  → LIST 응답의 tabs[].state (idle/working/blocked/done) — 지원 백엔드만
///
/// 설계: 기존 `CmuxBridge`(검증된 로컬 구현)는 손대지 않고 `CmuxBackend`가 감싼다.
/// 새 백엔드는 이 프로토콜만 구현하면 폰 UI가 자동으로 스위처에 노출한다(`available` 기준).
protocol MultiplexerBackend: AnyObject {
    var id: String { get }        // "cmux" | "herdr" | …  (와이어의 command.backend 와 매칭)
    var label: String { get }     // 폰 스위처 표시명
    var available: Bool { get }   // 설치/설정됨? (폰 스위처가 이걸로 필터)
    func warmUp()                 // 인증 프리싱크 등 (없으면 no-op)

    /// t:"cmux" 처리 — dir="state"면 LIST+STATE 스냅샷, focus 동사면 전환 후 스냅샷을 회신.
    func handle(_ command: InboundCommand, reply: @escaping (String) -> Void)
    /// t:"cterm" action="grid" — 대상(nil=포커스) pane 화면 그리드.
    func terminalGrid(handle: String?, reply: @escaping (String) -> Void)
    /// t:"cterm" action="input" — 대상(nil=포커스) pane 입력.
    func terminalInput(handle: String?, text: String)
}

extension MultiplexerBackend {
    func warmUp() {}
}

/// 설치된 백엔드 레지스트리 + `command.backend` 라우팅.
enum BridgeRouter {
    /// 등록 순서 = 폰 스위처 표시 순서. cmux 가 기본.
    static let all: [MultiplexerBackend] = [CmuxBackend.shared, HerdrBackend.shared]

    /// backend id → 백엔드. 없거나 빈 문자열이면 cmux(하위호환).
    static func backend(_ id: String?) -> MultiplexerBackend? {
        let target = (id?.isEmpty == false) ? id! : "cmux"
        return all.first { $0.id == target }
    }

    /// 헬퍼 시작 시 설치된 백엔드 프리워밍(cmux 소켓 인증 self-heal 등).
    static func warmUpAll() { all.forEach { if $0.available { $0.warmUp() } } }

    /// 폰 스위처용 백엔드 목록. 상태 JSON 의 `backends` 필드로 실린다.
    static func availableList() -> [[String: Any]] {
        all.map { ["id": $0.id, "label": $0.label, "available": $0.available] }
    }

    /// 알 수 없는/미설치 백엔드로 온 요청에 돌려줄 안전한 상태 JSON.
    static func unavailableState(_ id: String?) -> String {
        let payload: [String: Any] = [
            "t": "cmux", "backend": id ?? "cmux", "available": false,
            "denied": false, "windows": [], "tabs": [],
            "backends": availableList(),
        ]
        return jsonString(payload) ?? "{\"t\":\"cmux\",\"available\":false,\"backends\":[]}"
    }

    /// 백엔드가 낸 상태 JSON 에 backend/backends 메타를 주입 — 폰 스위처가 항상 최신 목록을 받도록.
    static func withBackendMeta(_ json: String, backend id: String) -> String {
        guard let data = json.data(using: .utf8),
              var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return json }
        if obj["backend"] == nil { obj["backend"] = id }
        obj["backends"] = availableList()
        return jsonString(obj) ?? json
    }

    static func jsonString(_ obj: Any) -> String? {
        guard let d = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
        return String(data: d, encoding: .utf8)
    }
}
