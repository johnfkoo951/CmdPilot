import Foundation

/// cmux CLI/RPC 브리지 — 폰(에이전트 탭)에서 cmux 창/워크스페이스/탭을 직접 전환한다.
///
/// ⚠️ 보안: 이 서버는 LAN 무인증이므로 임의 명령 실행은 절대 금지.
///   - 동사 화이트리스트(state / select-workspace / focus-window / focus-tab)만 처리
///   - 대상 인자는 UUID 형식만 통과, 셸 미경유(Process 인자 배열 직접 전달)
enum CmuxBridge {
    private static let cliPath = "/Applications/cmux.app/Contents/Resources/bin/cmux"
    private static let queue = DispatchQueue(label: "com.joonlab.macpilot.cmux", qos: .userInitiated)

    static var available: Bool { FileManager.default.isExecutableFile(atPath: cliPath) }

    private static func isUUID(_ s: String) -> Bool { UUID(uuidString: s) != nil }

    /// cmux 소켓 패스워드 (~/.config/cmux/cmux.json 의 automation.socketPassword).
    /// cmux 소켓은 기본 cmuxOnly(자식 프로세스만 허용)라 외부인 이 헬퍼는 password 모드로 인증해야 한다.
    /// 파일이 JSONC(주석 포함)라 정규식으로만 읽는다 — 값은 폰에 절대 노출되지 않는다.
    private static func socketPassword() -> String? {
        let path = "\(NSHomeDirectory())/.config/cmux/cmux.json"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        guard let regex = try? NSRegularExpression(pattern: "\"socketPassword\"\\s*:\\s*\"([^\"]+)\""),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
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

    /// 창 + 창별 워크스페이스 + 선택 워크스페이스의 탭(터미널)을 한 페이로드로 만든다.
    private static func stateJSON() -> String {
        var windows: [[String: Any]] = []
        if let data = run(["list-windows", "--json"]),
           let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {
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
        // 소켓 접근 거부 감지 (cmuxOnly 모드가 아직 적용 중일 때) → 폰 UI가 안내 문구를 띄운다
        let denied = windows.isEmpty && run(["ping"]) == nil
        let payload: [String: Any] = ["t": "cmux", "available": available, "denied": denied, "windows": windows, "tabs": tabs]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8)
        else { return "{\"t\":\"cmux\",\"available\":false,\"windows\":[],\"tabs\":[]}" }
        return json
    }

    /// cmux CLI 실행 (3초 타임아웃). 파이프는 종료 대기 전에 비동기로 읽어 데드락을 피한다.
    private static func run(_ args: [String]) -> Data? {
        guard available else { debugLog("not executable: \(cliPath)"); return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = args
        if let password = socketPassword() {
            var env = ProcessInfo.processInfo.environment
            env["CMUX_SOCKET_PASSWORD"] = password
            process.environment = env
        }
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch {
            debugLog("spawn 실패 \(args.first ?? ""): \(error)")
            return nil
        }

        var data = Data()
        var errData = Data()
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
        if exitDone.wait(timeout: .now() + 3) == .timedOut {
            process.terminate()
            debugLog("timeout: \(args.joined(separator: " "))")
            return nil
        }
        _ = readDone.wait(timeout: .now() + 1)
        if process.terminationStatus != 0 {
            debugLog("exit \(process.terminationStatus) \(args.joined(separator: " ")): \(String(data: errData, encoding: .utf8) ?? "")")
            return nil
        }
        return data
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
