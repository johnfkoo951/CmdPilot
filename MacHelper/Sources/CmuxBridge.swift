import Foundation

/// cmux CLI/RPC 브리지 — 폰(에이전트 탭)에서 cmux 창/워크스페이스/탭을 직접 전환한다.
///
/// ⚠️ 보안: 이 서버는 LAN 무인증이므로 임의 명령 실행은 절대 금지.
///   - 동사 화이트리스트(state / select-workspace / focus-window / focus-tab)만 처리
///   - 대상 인자는 UUID 형식만 통과, 셸 미경유(Process 인자 배열 직접 전달)
enum CmuxBridge {
    private static let cliPath = "/Applications/cmux.app/Contents/Resources/bin/cmux"
    private static let queue = DispatchQueue(label: "com.cmdspace.cmdpilot.cmux", qos: .userInitiated)

    static var available: Bool { FileManager.default.isExecutableFile(atPath: cliPath) }

    private static func isUUID(_ s: String) -> Bool { UUID(uuidString: s) != nil }

    private static let cmuxConfigPath = "\(NSHomeDirectory())/.config/cmux/cmux.json"

    // MARK: - 소켓 인증 self-heal
    //
    // cmux 소켓은 기본 cmuxOnly(자식 프로세스만 허용)라 외부인 이 헬퍼는 password 모드로 인증해야 한다.
    // 문제: cmux 는 재시작할 때 cmux.json 의 socketPassword 를 파일에서 지우고 키체인으로 옮겨버려
    //       "password 모드 + 파일에 패스워드 없음" 상태가 되고, 외부 프로세스인 우리는 인증 불가가 된다.
    // 해법: 우리 소유의 고정 패스워드를 App Support 에 보관하고, cmux.json 이 그 값과 다르면 다시 써넣는다.
    //       cmux 가 파일을 핫리로드하므로 앱 재시작 없이 즉시 복구된다. (auth 실패 시 자동 발동)

    /// 우리가 관리하는 고정 소켓 패스워드 (App Support/CmdPilot/cmux-socket.pass). 없으면 생성.
    private static func canonicalPassword() -> String {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CmdPilot", isDirectory: true)
        let url = dir.appendingPathComponent("cmux-socket.pass")
        if let existing = try? String(contentsOf: url, encoding: .utf8) {
            let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pass = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
        try? pass.write(to: url, atomically: true, encoding: .utf8)
        return pass
    }

    /// cmux.json 을 우리 패스워드 + password 모드로 맞춘다. 이미 맞으면 아무것도 안 하고 false 반환.
    /// clean JSON 이면 파싱→수정→직렬화(정확), JSONC(주석)면 정규식 삽입(폴백)으로 처리한다.
    @discardableResult
    static func ensureConfigured() -> Bool {
        guard available else { return false }
        let pass = canonicalPassword()
        let text = (try? String(contentsOfFile: cmuxConfigPath, encoding: .utf8))
            ?? "{\n  \"schemaVersion\" : 1\n}\n"

        // 1) clean JSON 경로 (현재 cmux 가 쓰는 형식) — 안전·정확
        if let data = text.data(using: .utf8),
           var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            var automation = (obj["automation"] as? [String: Any]) ?? [:]
            if (automation["socketPassword"] as? String) == pass,
               (automation["socketControlMode"] as? String) == "password" {
                return false   // 이미 동기화됨
            }
            automation["socketControlMode"] = "password"
            automation["socketPassword"] = pass
            obj["automation"] = automation
            if let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
               let outStr = String(data: out, encoding: .utf8) {
                try? outStr.write(toFile: cmuxConfigPath, atomically: true, encoding: .utf8)
                debugLog("ensureConfigured: clean-JSON 재작성")
                return true
            }
        }

        // 2) JSONC(주석 포함) 폴백 — 정규식 surgical 삽입
        var t = text
        if let re = try? NSRegularExpression(pattern: "\"socketPassword\"\\s*:\\s*\"[^\"]*\"") {
            let full = NSRange(t.startIndex..., in: t)
            if re.firstMatch(in: t, range: full) != nil {
                t = re.stringByReplacingMatches(in: t, range: full, withTemplate: "\"socketPassword\" : \"\(pass)\"")
            } else if let reAuto = try? NSRegularExpression(pattern: "\"automation\"\\s*:\\s*\\{"),
                      let m = reAuto.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
                      let r = Range(m.range, in: t) {
                t.replaceSubrange(r, with: String(t[r]) + "\n    \"socketPassword\" : \"\(pass)\",")
            } else if let brace = t.firstIndex(of: "{") {
                let after = t.index(after: brace)
                t.replaceSubrange(after..<after, with: "\n  \"automation\" : { \"socketControlMode\" : \"password\", \"socketPassword\" : \"\(pass)\" },")
            }
        }
        if let reMode = try? NSRegularExpression(pattern: "\"socketControlMode\"\\s*:\\s*\"[^\"]*\"") {
            let full = NSRange(t.startIndex..., in: t)
            if reMode.firstMatch(in: t, range: full) != nil {
                t = reMode.stringByReplacingMatches(in: t, range: full, withTemplate: "\"socketControlMode\" : \"password\"")
            }
        }
        try? t.write(toFile: cmuxConfigPath, atomically: true, encoding: .utf8)
        debugLog("ensureConfigured: JSONC 정규식 삽입")
        return true
    }

    /// 헬퍼 시작 시 1회 미리 동기화 — 첫 폰 요청이 바로 되도록.
    static func warmUp() {
        queue.async { _ = ensureConfigured() }
    }

    /// t:"cmux" 명령 처리. 상태 변경 동사는 실행 후 최신 상태를 회신한다.
    static func handle(_ command: InboundCommand, reply: @escaping (String) -> Void) {
        queue.async {
            let verb = command.dir ?? "state"
            let target = command.target ?? ""
            switch verb {
            case "state":
                break
            case "select-workspace" where isUUID(target):
                _ = run(["rpc", "workspace.select", jsonArg(["workspace_id": target])])
            case "focus-window" where isUUID(target):
                _ = run(["rpc", "window.focus", jsonArg(["window_id": target])])
            case "focus-tab" where isUUID(target):
                _ = run(["rpc", "surface.focus", jsonArg(["surface_id": target])])
            default:
                return   // 화이트리스트 밖 → 무시
            }
            reply(stateJSON())
        }
    }

    private static func jsonArg(_ dict: [String: String]) -> String {
        (try? JSONSerialization.data(withJSONObject: dict)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    // MARK: - 터미널 뷰 (에이전트 원격의 확장 — 포커스된 cmux 터미널 화면을 텍스트로)

    /// 현재 포커스된 cmux 터미널의 렌더 그리드(row_spans + styles + cursor)를 폰에 회신.
    /// 화면 미러(픽셀)와 달리 터미널 UI 텍스트만 가져오므로 가볍고 선명하다.
    static func terminalGrid(reply: @escaping (String) -> Void) {
        queue.async {
            if let data = run(["rpc", "mobile.terminal.replay", "{}"]),
               let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let grid = obj["render_grid"] {
                let payload: [String: Any] = ["t": "ctermGrid", "grid": grid]
                if let d = try? JSONSerialization.data(withJSONObject: payload),
                   let s = String(data: d, encoding: .utf8) { reply(s); return }
            }
            reply("{\"t\":\"ctermGrid\",\"error\":true}")
        }
    }

    /// 포커스된 cmux 터미널에 텍스트/제어문자 입력 (mobile.terminal.input).
    static func terminalInput(_ text: String) {
        guard !text.isEmpty else { return }
        queue.async { _ = run(["rpc", "mobile.terminal.input", jsonArg(["text": text])]) }
    }

    /// 창 + 창별 워크스페이스 + 선택 워크스페이스의 탭(터미널)을 한 페이로드로 만든다.
    private static func stateJSON() -> String {
        // list-windows 하나로 건강 상태를 판정한다(내부에서 self-heal). 실패하면 다른 명령들도
        // 죄다 타임아웃까지 행하므로, 더 부르지 말고 즉시 "복구 중"을 반환한다.
        // → self-heal 이 패스워드를 이미 다시 써넣었으니 폰의 다음 폴링(4초)에서 성공한다.
        guard let winRoot = run(["list-windows", "--json"]),
              let list = (try? JSONSerialization.jsonObject(with: winRoot)) as? [[String: Any]] else {
            return "{\"t\":\"cmux\",\"available\":\(available),\"denied\":true,\"windows\":[],\"tabs\":[]}"
        }

        var windows: [[String: Any]] = []
        do {
            for win in list {
                guard let id = win["id"] as? String else { continue }
                var spaces: [[String: Any]] = []
                if let wdata = run(["list-workspaces", "--json", "--id-format", "both", "--window", id]),
                   let obj = (try? JSONSerialization.jsonObject(with: wdata)) as? [String: Any],
                   let items = obj["workspaces"] as? [[String: Any]] {
                    for ws in items {
                        spaces.append([
                            "id": ws["id"] as? String ?? "",
                            "title": ws["title"] as? String ?? "(무제)",
                            "selected": ws["selected"] as? Bool ?? false,
                            "color": ws["custom_color"] as? String ?? "",
                            "pinned": ws["pinned"] as? Bool ?? false,
                        ])
                    }
                }
                windows.append([
                    "id": id,
                    "index": win["index"] as? Int ?? 0,
                    "key": win["key"] as? Bool ?? false,
                    "workspaces": spaces,
                ])
            }
        }
        // 선택된 워크스페이스의 탭(터미널) — 제목에 에이전트 상태가 실려 있어 원격 확인에 유용
        var tabs: [[String: Any]] = []
        if let tdata = run(["rpc", "mobile.workspace.list", "{}"]),
           let obj = (try? JSONSerialization.jsonObject(with: tdata)) as? [String: Any],
           let items = obj["workspaces"] as? [[String: Any]],
           let selected = items.first(where: { ($0["is_selected"] as? Bool) == true }),
           let terms = selected["terminals"] as? [[String: Any]] {
            for term in terms {
                tabs.append([
                    "id": term["id"] as? String ?? "",
                    "title": term["title"] as? String ?? "터미널",
                    "focused": term["is_focused"] as? Bool ?? false,
                ])
            }
        }
        // list-windows 가 성공한 지점이라 인증은 정상 — denied 는 false.
        let payload: [String: Any] = ["t": "cmux", "available": available, "denied": false, "windows": windows, "tabs": tabs]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8)
        else { return "{\"t\":\"cmux\",\"available\":false,\"windows\":[],\"tabs\":[]}" }
        return json
    }

    /// cmux CLI 실행. 소켓 인증 실패면 cmux.json 을 복구(ensureConfigured)하고 1회 재시도한다.
    private static func run(_ args: [String], allowHeal: Bool = true) -> Data? {
        guard available else { debugLog("not executable: \(cliPath)"); return nil }
        let result = exec(args)
        guard let result else { return nil }   // spawn/timeout 실패
        if result.status == 0 { return result.stdout }

        let errStr = String(data: result.stderr, encoding: .utf8) ?? ""
        debugLog("exit \(result.status) \(args.joined(separator: " ")): \(errStr)")

        // 인증 실패 감지 → self-heal 후 1회 재시도.
        // ⚠️ cmux reload-config 는 인증이 필요해 이 상황(패스워드 없음)에선 실패한다(닭-달걀).
        //    대신 cmux 의 파일워치가 cmux.json 쓰기를 ~2초 내 자동 반영하므로, 쓰고 기다린다.
        if allowHeal, isAuthFailure(errStr) {
            let changed = ensureConfigured()
            // 깨진 상태에선 cmux 명령이 타임아웃까지 행(hang)하므로 ping 폴링은 금물.
            // cmux.json 을 쓴 직후 한 번만 잠깐 기다렸다 재시도한다. (파일워치 채택 ~1-2초)
            // 한 상태요청은 run()을 여러 번 부르므로, 최근 대기했으면 재대기 생략.
            healLock.lock()
            let shouldWait = changed && Date().timeIntervalSince(lastHealPoll) > 6
            if shouldWait { lastHealPoll = Date() }
            healLock.unlock()
            if shouldWait { usleep(1_800_000) }
            debugLog("self-heal 재시도: \(args.first ?? "")")
            return run(args, allowHeal: false)
        }
        return nil
    }

    private static let healLock = NSLock()
    private static var lastHealPoll = Date.distantPast

    /// cmux 소켓 인증 실패 마커 (실측 확인한 실제 출력 문자열).
    /// - "Authentication required"/"auth_required": 패스워드는 있는데 클라이언트가 안/틀리게 보냄
    /// - "Invalid password": 우리 파일 값과 cmux 로드값 불일치(로테이션 직후)
    /// - "no socket password is configured"/"Password mode is enabled": ★재시작으로 패스워드가
    ///   지워진 상태 — cmux 가 실제로 내는 문자열. 이게 self-heal 의 주 트리거다.
    /// - "Access denied": cmuxOnly 모드(자식만 허용)로 되돌아간 경우
    private static func isAuthFailure(_ err: String) -> Bool {
        let markers = [
            "Authentication required", "auth_required", "Invalid password",
            "no socket password is configured", "Password mode is enabled", "Access denied",
        ]
        return markers.contains { err.localizedCaseInsensitiveContains($0) }
    }

    /// 단발 프로세스 실행 (3초 타임아웃). 파이프는 종료 대기 전에 비동기로 읽어 데드락 회피.
    private static func exec(_ args: [String]) -> (stdout: Data, stderr: Data, status: Int32)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["CMUX_SOCKET_PASSWORD"] = canonicalPassword()   // 우리가 관리하는 고정 패스워드
        process.environment = env
        let out = Pipe(); let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch {
            debugLog("spawn 실패 \(args.first ?? ""): \(error)")
            return nil
        }
        var data = Data(); var errData = Data()
        let readDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            data = out.fileHandleForReading.readDataToEndOfFile()
            errData = err.fileHandleForReading.readDataToEndOfFile()
            readDone.signal()
        }
        let exitDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            exitDone.signal()
        }
        if exitDone.wait(timeout: .now() + 2) == .timedOut {
            process.terminate()
            debugLog("timeout: \(args.joined(separator: " "))")
            return nil
        }
        _ = readDone.wait(timeout: .now() + 1)
        return (data, errData, process.terminationStatus)
    }

    /// 브리지 문제 진단용 로그 (/tmp/macpilot-cmux.log)
    private static func debugLog(_ message: String) {
        let line = "[\(Date())] \(message)\n"
        if let handle = FileHandle(forWritingAtPath: "/tmp/macpilot-cmux.log") {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(toFile: "/tmp/macpilot-cmux.log", atomically: true, encoding: .utf8)
        }
    }
}
