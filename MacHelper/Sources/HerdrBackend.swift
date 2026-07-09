import Foundation

/// herdr 백엔드 — 로컬 herdr 또는 SSH 릴레이로 원격 herdr를 조종한다(에이전트 상태 대시보드).
///
/// ⚠️ 실제 herdr v(2026-07) CLI로 검증한 계약(라이브 herdr에서 실측):
///  - 리스트 명령은 **`--json` 없이도 JSON 을 출력**한다(`--json`을 붙이면 "unknown command"). 형식은
///    `{"id":"cli:...","result":{"workspaces":[…]|"agents":[…]}}` — 배열은 `result` 아래에 있다.
///  - 상태값: idle / working / blocked / unknown.  pane id 형식: "w1:p1", workspace id: "w1".
///  - `pane read <id> --source visible` = 평문 텍스트.  `agent list`/`workspace list` = JSON.
///  - 소켓 인증 없음(로컬 파일권한만). 원격은 `ssh <host> herdr …` 릴레이.
final class HerdrBackend: MultiplexerBackend {
    static let shared = HerdrBackend()
    let id = "herdr"
    var label: String { config.mode == "remote" ? "herdr@\(config.sshHost ?? "remote")" : "herdr" }

    private let queue = DispatchQueue(label: "com.cmdspace.cmdpilot.herdr", qos: .userInitiated)

    // MARK: - 설정 (~/Library/Application Support/CmdPilot/herdr.json)

    /// { "mode":"local"|"remote", "sshHost":"devbox", "sshOpts":["-p","22"], "cliPath":"/…/herdr" }
    struct Config {
        var mode: String = "local"
        var sshHost: String? = nil
        var sshOpts: [String] = []
        var cliPath: String? = nil
    }

    private var config: Config { HerdrBackend.loadConfig() }

    private static func loadConfig() -> Config {
        let url = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CmdPilot/herdr.json")
        guard let data = try? Data(contentsOf: url),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return Config() }
        var c = Config()
        if let m = obj["mode"] as? String { c.mode = m }
        c.sshHost = obj["sshHost"] as? String
        c.sshOpts = (obj["sshOpts"] as? [String]) ?? []
        c.cliPath = obj["cliPath"] as? String
        return c
    }

    /// 로컬 herdr 바이너리 경로. `~/.local/bin/herdr`(공식 install.sh 기본 경로)를 포함해 탐색.
    private var localCLI: String? {
        let home = NSHomeDirectory()
        let candidates = [config.cliPath,
                          "\(home)/.local/bin/herdr",
                          "/opt/homebrew/bin/herdr", "/usr/local/bin/herdr", "/usr/bin/herdr"]
            .compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    var available: Bool {
        config.mode == "remote" ? (config.sshHost?.isEmpty == false) : (localCLI != nil)
    }

    // MARK: - 5-op

    func handle(_ command: InboundCommand, reply: @escaping (String) -> Void) {
        queue.async {
            let verb = command.dir ?? "state"
            let target = command.target ?? ""
            switch verb {
            case "state": break
            case "select-workspace" where !target.isEmpty:
                _ = self.run(["workspace", "focus", target])          // target = workspace_id (예: "w1")
            case "focus-tab" where !target.isEmpty:
                _ = self.run(["agent", "focus", target])              // target = pane_id (예: "w1:p1")
            case "focus-window":
                break                                                 // herdr 에 window 개념 없음
            default:
                return
            }
            reply(BridgeRouter.withBackendMeta(self.stateJSON(), backend: "herdr"))
        }
    }

    func terminalGrid(handle: String?, reply: @escaping (String) -> Void) {
        queue.async {
            guard let pane = (handle?.isEmpty == false) ? handle! : self.focusedPaneId() else {
                reply("{\"t\":\"ctermGrid\",\"error\":true}"); return
            }
            // 색 있는 ANSI 우선(cmux 수준 렌더). 실패 시 평문 폴백.
            let grid: [String: Any]
            if let out = self.run(["pane", "read", pane, "--source", "visible", "--format", "ansi"]),
               let text = String(data: out, encoding: .utf8), !text.isEmpty {
                grid = HerdrBackend.ansiGrid(text)
            } else if let out = self.run(["pane", "read", pane, "--source", "visible"]),
                      let text = String(data: out, encoding: .utf8) {
                grid = HerdrBackend.plainGrid(text)
            } else {
                reply("{\"t\":\"ctermGrid\",\"error\":true}"); return
            }
            let payload: [String: Any] = ["t": "ctermGrid", "grid": grid]
            reply(BridgeRouter.jsonString(payload) ?? "{\"t\":\"ctermGrid\",\"error\":true}")
        }
    }

    func terminalInput(handle: String?, text: String) {
        guard !text.isEmpty else { return }
        queue.async {
            guard let pane = (handle?.isEmpty == false) ? handle! : self.focusedPaneId() else { return }
            // 폰 터미널 뷰는 raw 이스케이프 시퀀스를 보낸다. 알려진 제어 시퀀스는 send-keys 명명키로,
            // 나머지 일반 텍스트는 send-text 로 보낸다.
            if let key = HerdrBackend.namedKey(for: text) {
                _ = self.run(["pane", "send-keys", pane, key])
            } else {
                _ = self.run(["pane", "send-text", pane, text])
            }
        }
    }

    // MARK: - 상태 합성

    /// `workspace list`(워크스페이스) + `agent list`(에이전트 pane+상태)를 폰 렌더러 형태로 합성.
    private func stateJSON() -> String {
        guard let wsOut = run(["workspace", "list"]) else {
            return unavailablePayload(denied: true)   // 소켓/서버 미기동 → 폰에 안내
        }
        let workspaces = HJSON.resultArray(wsOut, "workspaces").map { ws -> [String: Any] in
            [
                "id":       HJSON.str(ws, ["workspace_id"]),
                "title":    HJSON.str(ws, ["label"], default: "(무제)"),
                "selected": HJSON.bool(ws, ["focused"]),
                "color":    "",
                "pinned":   false,
            ]
        }
        let window: [String: Any] = ["id": "herdr", "index": 0, "key": true, "workspaces": workspaces]

        var tabs: [[String: Any]] = []
        if let agOut = run(["agent", "list"]) {
            tabs = HJSON.resultArray(agOut, "agents").map { ag in
                let name = HJSON.str(ag, ["agent"], default: "에이전트")
                let cwd  = HJSON.str(ag, ["cwd"])
                let base = cwd.isEmpty ? "" : " · " + (cwd as NSString).lastPathComponent
                return [
                    "id":      HJSON.str(ag, ["pane_id"]),
                    "title":   name + base,
                    "focused": HJSON.bool(ag, ["focused"]),
                    "state":   HerdrBackend.normalizeState(HJSON.str(ag, ["agent_status"])),
                ]
            }
        }

        let payload: [String: Any] = [
            "t": "cmux", "backend": "herdr", "available": true, "denied": false,
            "windows": [window], "tabs": tabs,
        ]
        return BridgeRouter.jsonString(payload) ?? unavailablePayload(denied: true)
    }

    /// 포커스된 pane id (`pane current` → result.pane.pane_id). READ/SEND 의 기본 대상.
    private func focusedPaneId() -> String? {
        guard let out = run(["pane", "current"]),
              let any = try? JSONSerialization.jsonObject(with: out),
              let obj = any as? [String: Any],
              let result = obj["result"] as? [String: Any],
              let pane = result["pane"] as? [String: Any],
              let pid = pane["pane_id"] as? String else { return nil }
        return pid
    }

    private func unavailablePayload(denied: Bool) -> String {
        let payload: [String: Any] = [
            "t": "cmux", "backend": "herdr", "available": true, "denied": denied,
            "windows": [], "tabs": [],
        ]
        return BridgeRouter.jsonString(payload) ?? "{\"t\":\"cmux\",\"backend\":\"herdr\",\"denied\":true}"
    }

    /// herdr 상태(idle/working/blocked/unknown) → 폰 UI 표준(idle/working/blocked/done). unknown→"".
    private static func normalizeState(_ s: String) -> String {
        switch s.lowercased() {
        case "working", "running", "busy":                 return "working"
        case "blocked", "waiting", "needs-input", "input": return "blocked"
        case "done", "finished", "complete", "completed":  return "done"
        case "idle", "ready":                              return "idle"
        default:                                           return ""
        }
    }

    /// 폰 터미널 뷰가 보내는 raw 제어 시퀀스 → herdr send-keys 명명 키. 매칭 없으면 nil(=일반 텍스트).
    private static func namedKey(for seq: String) -> String? {
        switch seq {
        case "\r", "\n":   return "enter"
        case "\u{1b}":     return "esc"
        case "\t":         return "tab"
        case "\u{03}":     return "ctrl+c"
        case "\u{7f}":     return "backspace"
        case "\u{1b}[A":   return "up"
        case "\u{1b}[B":   return "down"
        case "\u{1b}[C":   return "right"
        case "\u{1b}[D":   return "left"
        case "\u{1b}[H":   return "home"
        case "\u{1b}[F":   return "end"
        case "\u{1b}[3~":  return "delete"
        case "\u{1b}[5~":  return "pageup"
        case "\u{1b}[6~":  return "pagedown"
        default:
            if seq.count == 1, let u = seq.unicodeScalars.first, u.value >= 1, u.value <= 26 {
                return "ctrl+\(Character(UnicodeScalar(u.value + 96)!))"
            }
            return nil
        }
    }

    /// 평문 텍스트 → 폰 renderTermGrid 가 아는 grid(줄당 span 하나).
    private static func plainGrid(_ text: String) -> [String: Any] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var spans: [[String: Any]] = []
        var maxCol = 0
        for (i, line) in lines.enumerated() {
            spans.append(["row": i, "column": 0, "style_id": 0, "text": line, "cell_width": line.count])
            maxCol = max(maxCol, line.count)
        }
        return [
            "rows": lines.count, "columns": max(maxCol, 80),
            "row_spans": spans,
            "styles": [["id": 0, "background": "#12141a", "foreground": "#dfe3ea"]],
        ]
    }

    // MARK: - ANSI → 스타일 그리드 (herdr `pane read --format ansi` = 24bit truecolor)

    /// SGR 상태(색/굵기 등). style_id 매핑 키로 쓰려고 Hashable.
    private struct SGR: Hashable {
        var fg: String? = nil; var bg: String? = nil
        var bold = false; var italic = false; var faint = false; var inverse = false
        var isDefault: Bool { fg == nil && bg == nil && !bold && !italic && !faint && !inverse }
    }

    /// Tango 계열 16색(30–37/90–97, 40–47/100–107, 256색 0–15).
    private static let ansi16: [String] = [
        "#000000", "#cc0000", "#4e9a06", "#c4a000", "#3465a4", "#75507b", "#06989a", "#d3d7cf",
        "#555753", "#ef2929", "#8ae234", "#fce94f", "#729fcf", "#ad7fa8", "#34e2e2", "#eeeeec",
    ]
    private static func clampByte(_ v: Int) -> Int { min(255, max(0, v)) }
    private static func rgbHex(_ r: Int, _ g: Int, _ b: Int) -> String {
        String(format: "#%02x%02x%02x", clampByte(r), clampByte(g), clampByte(b))
    }
    /// xterm-256 팔레트 → hex.
    private static func ansi256(_ n: Int) -> String {
        if n < 16 { return ansi16[n] }
        if n >= 232 { let v = 8 + (n - 232) * 10; return rgbHex(v, v, v) }
        let idx = n - 16, lvl = [0, 95, 135, 175, 215, 255]
        return rgbHex(lvl[min(idx / 36, 5)], lvl[min((idx % 36) / 6, 5)], lvl[min(idx % 6, 5)])
    }

    /// `ESC[…m` 파라미터를 현재 SGR 상태에 적용.
    private static func applySGR(_ params: String, _ s: inout SGR) {
        let parts = params.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        if parts.isEmpty { s = SGR(); return }
        var k = 0
        while k < parts.count {
            let p = parts[k]
            switch p {
            case 0:            s = SGR()
            case 1:            s.bold = true
            case 2:            s.faint = true
            case 3:            s.italic = true
            case 7:            s.inverse = true
            case 22:           s.bold = false; s.faint = false
            case 23:           s.italic = false
            case 27:           s.inverse = false
            case 39:           s.fg = nil
            case 49:           s.bg = nil
            case 30...37:      s.fg = ansi16[p - 30]
            case 90...97:      s.fg = ansi16[p - 90 + 8]
            case 40...47:      s.bg = ansi16[p - 40]
            case 100...107:    s.bg = ansi16[p - 100 + 8]
            case 38, 48:
                if k + 1 < parts.count {
                    let mode = parts[k + 1]
                    if mode == 2, k + 4 < parts.count {
                        let hex = rgbHex(parts[k + 2], parts[k + 3], parts[k + 4])
                        if p == 38 { s.fg = hex } else { s.bg = hex }
                        k += 4
                    } else if mode == 5, k + 2 < parts.count {
                        let hex = ansi256(parts[k + 2])
                        if p == 38 { s.fg = hex } else { s.bg = hex }
                        k += 2
                    }
                }
            default: break
            }
            k += 1
        }
    }

    /// ANSI(SGR) 텍스트 → 폰 renderTermGrid 그리드(row_spans + styles). cmux 와 동일 스키마.
    private static func ansiGrid(_ text: String) -> [String: Any] {
        var styleIds: [SGR: Int] = [:]
        var styleList: [[String: Any]] = [["id": 0, "background": "#12141a", "foreground": "#dfe3ea"]]
        func styleId(_ s: SGR) -> Int {
            if s.isDefault { return 0 }
            if let id = styleIds[s] { return id }
            let id = styleList.count; styleIds[s] = id
            var d: [String: Any] = ["id": id]
            if let fg = s.fg { d["foreground"] = fg }
            if let bg = s.bg { d["background"] = bg }
            if s.bold { d["bold"] = true }
            if s.italic { d["italic"] = true }
            if s.faint { d["faint"] = true }
            if s.inverse { d["inverse"] = true }
            styleList.append(d); return id
        }

        var spans: [[String: Any]] = []
        var cur = SGR()
        var row = 0, col = 0, runStart = 0, maxCol = 0
        var run = ""
        func flush() {
            if !run.isEmpty {
                spans.append(["row": row, "column": runStart, "style_id": styleId(cur),
                              "text": run, "cell_width": run.count])
                run = ""
            }
        }

        let scalars = Array(text.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let v = scalars[i].value
            if v == 0x1B {                                   // ESC
                if i + 1 < scalars.count, scalars[i + 1].value == 0x5B {   // CSI: ESC [
                    var j = i + 2, params = ""
                    while j < scalars.count, !(scalars[j].value >= 0x40 && scalars[j].value <= 0x7E) {
                        params.unicodeScalars.append(scalars[j]); j += 1
                    }
                    if j < scalars.count, scalars[j].value == 0x6D {       // final 'm' → SGR
                        flush(); applySGR(params, &cur); runStart = col
                    }
                    i = j + 1; continue                       // 커서/삭제 등 나머지 CSI 무시
                } else if i + 1 < scalars.count, scalars[i + 1].value == 0x5D {  // OSC: ESC ]
                    var j = i + 2
                    while j < scalars.count {
                        if scalars[j].value == 0x07 { j += 1; break }
                        if scalars[j].value == 0x1B, j + 1 < scalars.count, scalars[j + 1].value == 0x5C { j += 2; break }
                        j += 1
                    }
                    i = j; continue
                } else { i += 2; continue }
            }
            if v == 0x0A { flush(); maxCol = max(maxCol, col); row += 1; col = 0; runStart = 0; i += 1; continue }
            if v == 0x0D { i += 1; continue }                 // 라인 끝 CR 무시
            run.unicodeScalars.append(scalars[i]); col += 1; i += 1
        }
        flush(); maxCol = max(maxCol, col)

        return [
            "rows": max(row + 1, 1),
            "columns": max(maxCol, 80),
            "row_spans": spans,
            "styles": styleList,
        ]
    }

    // MARK: - 실행 (로컬 herdr / 원격 ssh herdr)

    private func run(_ herdrArgs: [String]) -> Data? {
        let cfg = config
        let exeURL: URL
        let args: [String]
        if cfg.mode == "remote", let host = cfg.sshHost, !host.isEmpty {
            let remoteCmd = (["herdr"] + herdrArgs).map(HerdrBackend.shellQuote).joined(separator: " ")
            let cm = ["-o", "ControlMaster=auto",
                      "-o", "ControlPath=~/.ssh/macpilot-cm-%r@%h:%p",
                      "-o", "ControlPersist=300",
                      "-o", "ConnectTimeout=6",
                      "-o", "BatchMode=yes"]
            exeURL = URL(fileURLWithPath: "/usr/bin/ssh")
            args = cm + cfg.sshOpts + [host, remoteCmd]
        } else {
            guard let cli = localCLI else { return nil }
            exeURL = URL(fileURLWithPath: cli)
            args = herdrArgs
        }
        return HerdrBackend.exec(exeURL, args, timeout: cfg.mode == "remote" ? 6 : 3)
    }

    private static func exec(_ url: URL, _ args: [String], timeout: TimeInterval) -> Data? {
        let process = Process()
        process.executableURL = url
        process.arguments = args
        let out = Pipe(); let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch { return nil }
        var data = Data()
        let readDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            data = out.fileHandleForReading.readDataToEndOfFile()
            _ = err.fileHandleForReading.readDataToEndOfFile()
            readDone.signal()
        }
        let exitDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async { process.waitUntilExit(); exitDone.signal() }
        if exitDone.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return nil
        }
        _ = readDone.wait(timeout: .now() + 1)
        return process.terminationStatus == 0 ? data : nil
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// herdr JSON 접근자. 리스트는 `{"result":{"<key>":[…]}}` 형태라 result 아래를 판다.
private enum HJSON {
    static func resultArray(_ data: Data, _ key: String) -> [[String: Any]] {
        guard let any = try? JSONSerialization.jsonObject(with: data),
              let obj = any as? [String: Any] else { return [] }
        if let result = obj["result"] as? [String: Any], let arr = result[key] as? [[String: Any]] { return arr }
        if let arr = obj[key] as? [[String: Any]] { return arr }   // 폴백(최상위)
        return []
    }
    static func str(_ dict: [String: Any], _ keys: [String], default def: String = "") -> String {
        for k in keys { if let v = dict[k] as? String, !v.isEmpty { return v } }
        for k in keys { if let v = dict[k] { return String(describing: v) } }
        return def
    }
    static func bool(_ dict: [String: Any], _ keys: [String]) -> Bool {
        for k in keys {
            if let v = dict[k] as? Bool { return v }
            if let n = dict[k] as? NSNumber { return n.boolValue }
        }
        return false
    }
}
