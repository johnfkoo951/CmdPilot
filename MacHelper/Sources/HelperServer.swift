import AppKit
import ApplicationServices
import Foundation
import Network

/// 로컬 웹서버(HTTP + WebSocket). 아이폰 사파리가 접속하면 트랙패드 UI를 내려주고,
/// WebSocket 으로 받은 명령을 `EventInjector` 로 넘긴다.
final class HelperServer: ObservableObject {
    @Published var isRunning = false
    @Published var httpURL = ""
    @Published var ipFallback = ""
    @Published var activeClients = 0
    @Published var accessibilityGranted = false

    // 진단용: 아이폰에서 명령이 실제로 도착하는지 확인
    @Published var commandCount = 0
    @Published var lastCommand = "-"

    let port: UInt16 = 8766   // 8765 는 OmniControl bridge 가 사용 중이라 변경
    let launchAgentLabel = "com.joonlab.macpilot.helper"

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: HTTPWebSocketConnection] = [:]
    private var upgradedKeys: Set<ObjectIdentifier> = []
    private var accessibilityTimer: Timer?

    init() {
        resetLog()
        start()
        refreshAccessibility()
        // 권한 상태가 항상 최신으로 보이도록 주기적으로 갱신
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.refreshAccessibility()
        }
    }

    func start() {
        do {
            guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
            // TCP_NODELAY: Nagle 이 소형 WS 프레임(move)을 묶어 보내면 커서가 덩어리져 보인다.
            // 지연·부드러움에 가장 큰 영향을 주는 설정.
            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.noDelay = true
            tcpOptions.enableKeepalive = true
            tcpOptions.keepaliveIdle = 30
            let params = NWParameters(tls: nil, tcp: tcpOptions)
            params.serviceClass = .responsiveData   // 인터랙티브 트래픽 우선순위
            let listener = try NWListener(using: params, on: nwPort)

            listener.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    switch state {
                    case .ready:
                        self?.isRunning = true
                        self?.updateURL()
                    case .failed, .cancelled:
                        self?.isRunning = false
                    default:
                        break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                DispatchQueue.main.async { self?.accept(connection) }
            }
            listener.start(queue: .global(qos: .userInitiated))
            self.listener = listener
        } catch {
            print("[HelperServer] 리스너 시작 실패(포트 \(port) 사용 중일 수 있음): \(error)")
        }
    }

    private func accept(_ connection: NWConnection) {
        let client = HTTPWebSocketConnection(connection: connection)
        let key = ObjectIdentifier(client)

        client.onCommand = { [weak self, weak client] command in
            // 덱 동기화 명령은 입력 주입이 아니라 별도 처리
            switch command.t {
            case "ping":
                let payload: [String: Any] = [
                    "t": "pong",
                    "id": command.id ?? "",
                    "serverTime": Int(Date().timeIntervalSince1970 * 1000)
                ]
                if let data = try? JSONSerialization.data(withJSONObject: payload),
                   let text = String(data: data, encoding: .utf8) {
                    client?.sendText(text)
                }
                return
            case "getDeck":
                let json = DeckStore.loadString() ?? "null"
                client?.sendText("{\"t\":\"deck\",\"json\":\(json)}")
                return
            case "saveDeck":
                if let json = command.deckJson { DeckStore.save(json) }
                return
            case "getApps":
                // 아이콘 렌더(AppKit)는 main 에서. 최초 1회만 빌드되고 캐시됨.
                DispatchQueue.main.async {
                    client?.sendText("{\"t\":\"apps\",\"list\":\(AppList.json())}")
                }
                return
            case "cmux":
                // cmux 창/워크스페이스/탭 원격 전환 (CmuxBridge 가 화이트리스트 검증)
                CmuxBridge.handle(command) { [weak client] json in
                    client?.sendText(json)
                }
                return
            default:
                break
            }
            self?.logCommand(command)
            DispatchQueue.main.async {
                self?.commandCount += 1
                self?.lastCommand = command.dir.map { "\(command.t):\($0)" } ?? command.t
            }
            EventInjector.perform(command)
        }
        client.onUpgrade = { [weak self] in
            DispatchQueue.main.async {
                self?.upgradedKeys.insert(key)
                self?.activeClients = self?.upgradedKeys.count ?? 0
            }
        }
        client.onClose = { [weak self] in
            EventInjector.releaseAll()  // 드래그 중 연결이 끊겨도 버튼이 눌린 채 남지 않도록
            DispatchQueue.main.async {
                self?.connections[key] = nil
                self?.upgradedKeys.remove(key)
                self?.activeClients = self?.upgradedKeys.count ?? 0
            }
        }

        connections[key] = client
        client.start()
    }

    private func updateURL() {
        // .local 고정 주소 우선 (IP가 바뀌어도 안 변함)
        if let host = NetworkInfo.localHostName() {
            httpURL = "http://\(host):\(port)"
        } else if let ip = NetworkInfo.primaryIPv4() {
            httpURL = "http://\(ip):\(port)"
        } else {
            httpURL = "http://localhost:\(port)"
        }
        // IP 폴백 (mDNS 안 될 때용)
        if let ip = NetworkInfo.primaryIPv4() {
            ipFallback = "또는 http://\(ip):\(port)"
        } else {
            ipFallback = ""
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        Array(connections.values).forEach { $0.close() }
        connections.removeAll()
        upgradedKeys.removeAll()
        activeClients = 0
        isRunning = false
    }

    func restart() {
        stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.start()
        }
    }

    // MARK: - 손쉬운 사용(Accessibility) 권한

    func refreshAccessibility() {
        accessibilityGranted = AXIsProcessTrusted()
    }

    func promptAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func copyURL() {
        copyText(httpURL)
    }

    func copyStatusCommand() {
        copyText("./script/macpilotctl.sh status")
    }

    func openWebUI() {
        guard let url = URL(string: httpURL) else { return }
        NSWorkspace.shared.open(url)
    }

    func openLogsFolder() {
        let url = URL(fileURLWithPath: "\(NSHomeDirectory())/Library/Logs/MacPilot", isDirectory: true)
        NSWorkspace.shared.open(url)
    }

    var launchModeDescription: String {
        ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == launchAgentLabel
            ? "LaunchAgent 상시 실행"
            : "직접 실행"
    }

    var restartBehaviorDescription: String {
        ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == launchAgentLabel
            ? "앱을 종료해도 launchd가 다시 시작"
            : "터미널/실행 세션 종료 시 함께 종료"
    }

    private func copyText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - 진단 로깅 (/tmp/macpilot-cmd.log)

    private let logURL = URL(fileURLWithPath: "/tmp/macpilot-cmd.log")

    private func resetLog() {
        try? "".write(to: logURL, atomically: true, encoding: .utf8)
    }

    /// move/scroll(연속 명령)을 뺀 개별 명령만 파일에 기록 → 디버깅용
    private func logCommand(_ command: InboundCommand) {
        guard command.t != "move", command.t != "scroll" else { return }
        let line = "[\(command.t)] dir=\(command.dir ?? "-") btn=\(command.button ?? "-") key=\(command.keyCode.map(String.init) ?? "-")\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: logURL)
        }
    }
}
