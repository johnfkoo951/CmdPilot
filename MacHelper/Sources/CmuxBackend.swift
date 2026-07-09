import Foundation

/// cmux 백엔드 — 기존 `CmuxBridge`(검증된 로컬 구현)를 `MultiplexerBackend` 로 감싸는 얇은 어댑터.
///
/// CmuxBridge 자체는 손대지 않는다(자동화 소켓 password self-heal·타임아웃 등 민감). 여기서는
/// 응답 JSON 에 backend/backends 메타만 주입한다. cmux 는 READ/SEND 가 **포커스된 터미널만**
/// 대상으로 하므로 `handle` 인자는 무시한다(cmux 계약상 `mobile.terminal.*` 이 포커스 전용).
final class CmuxBackend: MultiplexerBackend {
    static let shared = CmuxBackend()
    let id = "cmux"
    let label = "cmux"
    var available: Bool { CmuxBridge.available }

    func warmUp() { CmuxBridge.warmUp() }

    func handle(_ command: InboundCommand, reply: @escaping (String) -> Void) {
        CmuxBridge.handle(command) { json in
            reply(BridgeRouter.withBackendMeta(json, backend: "cmux"))
        }
    }

    func terminalGrid(handle: String?, reply: @escaping (String) -> Void) {
        CmuxBridge.terminalGrid(reply: reply)   // cmux: 포커스된 터미널만(handle 무시)
    }

    func terminalInput(handle: String?, text: String) {
        CmuxBridge.terminalInput(text)          // cmux: 포커스된 터미널로
    }
}
