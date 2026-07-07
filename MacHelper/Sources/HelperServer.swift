import AppKit
import ApplicationServices
import Darwin
import Foundation
import Network

/// 로컬 웹서버(HTTP + WebSocket). 아이폰 사파리가 접속하면 트랙패드 UI를 내려주고,
/// WebSocket 으로 받은 명령을 `EventInjector` 로 넘긴다.
final class HelperServer: ObservableObject {
    @Published var isRunning = false
    @Published var httpURL = ""
    @Published var ipFallback = ""
    @Published var httpsURL = ""   // 에어마우스(모션)용 tailnet HTTPS (tailscale serve). 없으면 빈 문자열.
    @Published var activeClients = 0
    @Published var accessibilityGranted = false

    // 진단용: 아이폰에서 명령이 실제로 도착하는지 확인
    @Published var commandCount = 0
    @Published var lastCommand = "-"

    // 선택적 PIN 페어링(같은 네트워크의 타인 접속 차단) — 기본 off
    @Published var pairingEnabled = false
    @Published var pairingPin = ""

    let port: UInt16 = 8766   // 8765 는 OmniControl bridge 가 사용 중이라 변경
    let launchAgentLabel = "com.joonlab.macpilot.helper"

    private var listener: NWListener?
    private var listener80: NWListener?    // 짧은 주소용 :80 보조 리스너 (선택)
    private var listener443: NWListener?   // HTTPS :443 (tls/pilot.p12 있을 때)
    private var connections: [ObjectIdentifier: HTTPWebSocketConnection] = [:]
    private var upgradedKeys: Set<ObjectIdentifier> = []
    private var accessibilityTimer: Timer?

    // 연결 장부는 전용 직렬 큐에서만 다룬다(메인 스레드 분리 → 다수 동시접속에도 응답 안 밀림)
    private let serverQueue = DispatchQueue(label: "com.joonlab.macpilot.server")
    private let maxConnections = 256   // 폭주(포트 스캐너 등) 시 FD 고갈 방지용 상한
    private let pairing = Pairing()    // 선택적 PIN 페어링(기본 off)

    init() {
        HelperServer.raiseFileDescriptorLimit()
        resetLog()
        start()
        refreshAccessibility()
        // 권한 상태가 항상 최신으로 보이도록 주기적으로 갱신
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.refreshAccessibility()
        }
        // 앱 목록(아이콘 렌더)을 시작 직후 1회 미리 빌드→캐시. 이후 getApps 는 메인 블록 없이 즉시 응답.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { _ = AppList.json() }
        // cmux 소켓 인증을 미리 맞춰둔다(재시작으로 지워졌으면 복구) → 첫 에이전트 탭 요청이 바로 됨
        CmuxBridge.warmUp()
        // 페어링 상태를 UI 로 미러
        pairingEnabled = pairing.enabled
        pairingPin = pairing.pin
    }

    // MARK: - PIN 페어링

    func setPairing(_ on: Bool) {
        pairing.setEnabled(on)
        pairingEnabled = on
        if on { closeAllConnections() }   // 켜는 순간 기존 연결을 끊어 재페어링 강제
    }

    func regeneratePairingPin() {
        pairing.regeneratePin()
        pairingPin = pairing.pin
        closeAllConnections()             // PIN 변경 → 기존 쿠키 무효 → 끊어서 재페어링
    }

    private func closeAllConnections() {
        serverQueue.async { [weak self] in
            guard let self else { return }
            for c in self.connections.values { c.forceClose() }
        }
    }

    /// 프로세스 파일 디스크립터 소프트 한도를 올린다(기본값이 낮으면 다수 동시접속 때 소켓 고갈 → 흰 화면).
    private static func raiseFileDescriptorLimit() {
        var lim = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &lim) == 0 else { return }
        let target: rlim_t = 4096
        if lim.rlim_cur < target {
            lim.rlim_cur = min(target, lim.rlim_max)
            _ = setrlimit(RLIMIT_NOFILE, &lim)
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
                self?.accept(connection)   // 메인 X — 전용 큐에서 처리
            }
            listener.start(queue: .global(qos: .userInitiated))
            self.listener = listener
        } catch {
            print("[HelperServer] 리스너 시작 실패(포트 \(port) 사용 중일 수 있음): \(error)")
        }

        // 짧은 주소용 :80 보조 리스너 — macOS 는 비루트도 저포트 바인딩 가능.
        // 커스텀 도메인(CNAME → 테일스케일/mDNS)과 조합하면 포트 없는 주소로 접속된다.
        // 이미 다른 프로세스가 80을 쓰면 조용히 건너뛴다.
        if let port80 = NWEndpoint.Port(rawValue: 80) {
            let tcp = NWProtocolTCP.Options()
            tcp.noDelay = true
            let params = NWParameters(tls: nil, tcp: tcp)
            params.serviceClass = .responsiveData
            if let aux = try? NWListener(using: params, on: port80) {
                aux.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                aux.start(queue: .global(qos: .userInitiated))
                listener80 = aux
            }
        }

        // HTTPS(:443) — `App Support/MacPilot/tls/pilot.p12` 인증서가 있으면 켠다.
        // (acme.sh 가 Let's Encrypt 인증서를 발급/갱신해 p12 로 떨궈줌 — 갱신 훅이 헬퍼 재시작)
        // iOS 모션 센서(에어마우스) 등 보안 컨텍스트 필수 기능이 이 주소에서 동작한다.
        if let tls = HelperServer.loadTLSOptions(), let port443 = NWEndpoint.Port(rawValue: 443) {
            let tcp = NWProtocolTCP.Options()
            tcp.noDelay = true
            let params = NWParameters(tls: tls, tcp: tcp)
            params.serviceClass = .responsiveData
            if let aux = try? NWListener(using: params, on: port443) {
                aux.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                aux.start(queue: .global(qos: .userInitiated))
                listener443 = aux
            }
        }
    }

    /// tls/pilot.p12 에서 서버 인증서(identity)를 읽는다. 없거나 손상이면 nil → HTTPS 비활성.
    private static func loadTLSOptions() -> NWProtocolTLS.Options? {
        let p12URL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacPilot/tls/pilot.p12")
        guard let data = try? Data(contentsOf: p12URL) else { return nil }

        var items: CFArray?
        let options = [kSecImportExportPassphrase as String: "macpilot"] as CFDictionary
        let status = SecPKCS12Import(data as CFData, options, &items)

        var identity: SecIdentity?
        if status == errSecSuccess,
           let first = (items as? [[String: Any]])?.first,
           let raw = first[kSecImportItemIdentity as String] {
            identity = (raw as! SecIdentity)
        } else if status == errSecDuplicateItem {
            // 이미 키체인에 들어간 경우 → 라벨로 조회
            let query: [String: Any] = [
                kSecClass as String: kSecClassIdentity,
                kSecAttrLabel as String: "pilot.cmdspace.work",
                kSecReturnRef as String: true,
            ]
            var result: CFTypeRef?
            if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess {
                identity = (result as! SecIdentity)
            }
        }
        guard let identity, let secIdentity = sec_identity_create(identity) else { return nil }

        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secIdentity)
        return tls
    }

    private func accept(_ connection: NWConnection) {
        let client = HTTPWebSocketConnection(connection: connection, pairing: pairing)
        let key = ObjectIdentifier(client)

        client.onCommand = { [weak self, weak client] command in
            self?.handleCommand(command, client: client)
        }
        client.onUpgrade = { [weak self] in
            guard let self else { return }
            self.serverQueue.async { [weak self] in
                guard let self else { return }
                self.upgradedKeys.insert(key)
                let n = self.upgradedKeys.count
                DispatchQueue.main.async { [weak self] in self?.activeClients = n }
            }
        }
        client.onClose = { [weak self, weak client] in
            EventInjector.releaseAll()  // 드래그 중 연결이 끊겨도 버튼이 눌린 채 남지 않도록
            if #available(macOS 14.0, *), let client { ScreenStreamer.shared.removeViewer(client) }
            guard let self else { return }
            self.serverQueue.async { [weak self] in
                guard let self else { return }
                self.connections[key] = nil
                self.upgradedKeys.remove(key)
                let n = self.upgradedKeys.count
                DispatchQueue.main.async { [weak self] in self?.activeClients = n }
            }
        }

        // 연결 등록·시작은 전용 큐에서. 동시연결 상한 초과 시 새 연결 거절(폭주 방어).
        serverQueue.async { [weak self] in
            guard let self else { connection.cancel(); return }
            if self.connections.count >= self.maxConnections {
                connection.cancel()
                return
            }
            self.connections[key] = client
            client.start()
        }
    }

    /// WebSocket 으로 들어온 명령 처리. move/scroll(고빈도)은 메인 UI 갱신을 건너뛰고 주입만 한다.
    private func handleCommand(_ command: InboundCommand, client: HTTPWebSocketConnection?) {
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
            // 캐시 준비됐으면 즉시(오프메인) 응답. 아직이면 main 에서 1회 빌드(드문 경우).
            if let cached = AppList.cachedJSONIfReady() {
                client?.sendText("{\"t\":\"apps\",\"list\":\(cached)}")
            } else {
                DispatchQueue.main.async {
                    client?.sendText("{\"t\":\"apps\",\"list\":\(AppList.json())}")
                }
            }
            return
        case "cmux":
            // cmux 창/워크스페이스/탭 원격 전환 (CmuxBridge 가 화이트리스트 검증)
            CmuxBridge.handle(command) { [weak client] json in
                client?.sendText(json)
            }
            return
        case "cterm":
            // cmux 터미널 뷰 (포커스된 터미널 화면 텍스트 + 입력)
            switch command.action {
            case "grid":  CmuxBridge.terminalGrid { [weak client] json in client?.sendText(json) }
            case "input": CmuxBridge.terminalInput(command.text ?? "")
            default: break
            }
            return
        case "capture":
            // 맥 화면 → 폰 (JPEG base64)
            CaptureService.captureScreen { [weak client] json in
                client?.sendText(json)
            }
            return
        case "ocr":
            // 폰 카메라 이미지(base64) → OCR → 맥 클립보드
            CaptureService.ocrToClipboard(base64: command.text ?? "") { [weak client] json in
                client?.sendText(json)
            }
            return
        case "launch" where command.target == "macpilot://spotlight":
            // 발표 스팟라이트 토글 (덱 launch 스키마를 그대로 쓰는 내부 액션)
            SpotlightOverlay.shared.toggle()
            return
        case "mirror":
            // 맥 화면 실시간 미러링 (뷰어 등록/해제/적응 파라미터)
            guard #available(macOS 14.0, *), let client else { return }
            switch command.action {
            case "start":
                if let d = command.display { ScreenStreamer.shared.selectDisplay(CGDirectDisplayID(d), requester: client) }
                ScreenStreamer.shared.addViewer(client)
            case "stop":   ScreenStreamer.shared.removeViewer(client)
            case "config": ScreenStreamer.shared.configure(longEdge: command.w, fps: command.fps, quality: command.q)
            case "displays": ScreenStreamer.shared.sendDisplays(to: client)
            case "select": ScreenStreamer.shared.selectDisplay(command.display.map { CGDirectDisplayID($0) }, requester: client)
            default: break
            }
            return
        case "window":
            // 앱 내 창 전환 — 순수 AX(손쉬운 사용 권한만). AX 호출이 블록될 수 있어 전용 큐에서.
            let next = command.dir != "prev"
            DispatchQueue.global(qos: .userInitiated).async { [weak client] in
                let result = WindowSwitcher.cycle(next: next)
                let json: String
                switch result {
                case .ok(let n):       json = "{\"t\":\"window\",\"ok\":true,\"count\":\(n)}"
                case .single:          json = "{\"t\":\"window\",\"ok\":false,\"reason\":\"single\"}"
                case .none:            json = "{\"t\":\"window\",\"ok\":false,\"reason\":\"none\"}"
                case .axError(let c):  json = "{\"t\":\"window\",\"ok\":false,\"reason\":\"axerr\",\"code\":\(c)}"
                }
                client?.sendText(json)
            }
            return
        default:
            break
        }
        let t = command.t
        if t != "move", t != "scroll" {
            logCommand(command)
            DispatchQueue.main.async { [weak self] in
                self?.commandCount += 1
                self?.lastCommand = command.dir.map { "\(t):\($0)" } ?? t
            }
        }
        EventInjector.perform(command)
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
        // HTTPS 주소 (에어마우스/모션 = secure context 필수). 서브프로세스라 백그라운드에서.
        // 우선순위: 앱이 :443에서 서빙하는 인증서 CN(예: pilot.cmdspace.work) → tailscale serve.
        let has443 = (listener443 != nil)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var https = ""
            if has443, let cn = NetworkInfo.tlsCertCommonName() {
                https = "https://\(cn)"
            } else if let ts = NetworkInfo.tailscaleHTTPSURL() {
                https = ts
            }
            DispatchQueue.main.async { self?.httpsURL = https }
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        listener80?.cancel()
        listener80 = nil
        listener443?.cancel()
        listener443 = nil
        serverQueue.async { [weak self] in
            guard let self else { return }
            self.connections.values.forEach { $0.close() }
            self.connections.removeAll()
            self.upgradedKeys.removeAll()
            DispatchQueue.main.async { [weak self] in
                self?.activeClients = 0
                self?.isRunning = false
            }
        }
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

    func copyHTTPSURL() {
        copyText(httpsURL)
    }

    func copyStatusCommand() {
        copyText("./script/macpilotctl.sh status")
    }

    func openWebUI() {
        guard let url = URL(string: httpURL) else { return }
        NSWorkspace.shared.open(url)
    }

    func openURLString(_ s: String) {
        guard let url = URL(string: s) else { return }
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
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        }
    }
}
