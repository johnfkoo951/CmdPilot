import CryptoKit
import Foundation
import Network

/// 단일 TCP 연결을 받아 (1) 정적 파일 HTTP 응답 또는 (2) WebSocket 업그레이드를
/// 처리하는 미니 서버 커넥션. 외부 의존성 없이 직접 프레이밍을 구현한다.
///
/// 흐름: HTTP 헤더 수신 → `/` 등 GET 이면 정적 파일 응답 후 종료,
///       `Upgrade: websocket` 이면 101 핸드셰이크 후 텍스트 프레임을 명령으로 디코드.
final class HTTPWebSocketConnection {
    private let connection: NWConnection
    private var buffer = [UInt8]()
    private var didUpgrade = false
    private var closing = false

    var onCommand: ((InboundCommand) -> Void)?
    var onUpgrade: (() -> Void)?
    var onClose: (() -> Void)?

    init(connection: NWConnection) {
        self.connection = connection
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.onClose?()
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .userInitiated))
        receiveLoop()
    }

    // MARK: - 수신 루프

    private func receiveLoop() {
        if closing { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(contentsOf: data)
                self.process()
            }
            if isComplete || error != nil {
                self.connection.cancel()
                return
            }
            self.receiveLoop()
        }
    }

    private func process() {
        if didUpgrade {
            parseFrames()
        } else if let headerEnd = indexOfCRLFCRLF(buffer) {
            let headerBytes = Array(buffer[0..<headerEnd])
            buffer.removeFirst(headerEnd + 4)
            if let request = String(bytes: headerBytes, encoding: .utf8) {
                handleRequest(request)
            } else {
                closeNow()
            }
        }
    }

    // MARK: - HTTP

    private func handleRequest(_ request: String) {
        let lines = request.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { closeNow(); return }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { closeNow(); return }
        let path = String(parts[1])

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        if headers["upgrade"]?.lowercased().contains("websocket") == true,
           let key = headers["sec-websocket-key"] {
            performHandshake(key: key)
        } else {
            serveStatic(path: path)
        }
    }

    private func performHandshake(key: String) {
        let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let digest = Insecure.SHA1.hash(data: Data((key + magic).utf8))
        let accept = Data(digest).base64EncodedString()
        let response = """
        HTTP/1.1 101 Switching Protocols\r
        Upgrade: websocket\r
        Connection: Upgrade\r
        Sec-WebSocket-Accept: \(accept)\r
        \r

        """
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in })
        didUpgrade = true
        onUpgrade?()
        parseFrames() // 버퍼에 남은 프레임 즉시 처리
    }

    /// 개발용 웹 루트 오버라이드. 이 폴더에 같은 이름의 파일이 있으면 번들 대신 그걸 서빙한다.
    /// → 웹(HTML/JS/CSS)만 고칠 땐 재빌드(=ad-hoc 재서명으로 손쉬운 사용 권한 리셋) 없이 반영.
    ///   동기화: ./script/macpilotctl.sh sync-web
    private static let webOverrideDir = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MacPilot/web", isDirectory: true)

    private func serveStatic(path: String) {
        let clean = path.split(separator: "?").first.map(String.init) ?? path
        let asset: (file: String, mime: String)?
        switch clean {
        case "/", "/index.html":    asset = ("index.html", "text/html; charset=utf-8")
        case "/app.js":             asset = ("app.js", "application/javascript; charset=utf-8")
        case "/style.css":          asset = ("style.css", "text/css; charset=utf-8")
        case "/manifest.webmanifest": asset = ("manifest.webmanifest", "application/manifest+json")
        case "/logo.png", "/favicon.ico":
                                    asset = ("logo.png", "image/png")
        case "/apple-touch-icon.png", "/apple-touch-icon-precomposed.png", "/icon-180.png":
                                    asset = ("icon-180.png", "image/png")
        case "/icon-192.png":       asset = ("icon-192.png", "image/png")
        case "/icon-512.png":       asset = ("icon-512.png", "image/png")
        case "/logo-mark.png":      asset = ("logo-mark.png", "image/png")
        case "/logo-mark-dark.png": asset = ("logo-mark-dark.png", "image/png")
        default:                    asset = nil
        }

        guard let asset else { sendSimple(status: "404 Not Found", body: "Not Found"); return }

        let dot = asset.file.lastIndex(of: ".")!
        let stem = String(asset.file[..<dot])
        let ext = String(asset.file[asset.file.index(after: dot)...])

        var body: Data? = try? Data(contentsOf: Self.webOverrideDir.appendingPathComponent(asset.file))
        if body == nil, let url = Bundle.main.url(forResource: stem, withExtension: ext) {
            body = try? Data(contentsOf: url)
        }
        guard let body else { sendSimple(status: "404 Not Found", body: "Not Found"); return }

        let head = "HTTP/1.1 200 OK\r\n"
            + "Content-Type: \(asset.mime)\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Cache-Control: no-store\r\n"
            + "Connection: close\r\n\r\n"
        var response = Data(head.utf8)
        response.append(body)
        closing = true
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            self?.connection.cancel()
        })
    }

    private func sendSimple(status: String, body: String) {
        let head = "HTTP/1.1 \(status)\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
        closing = true
        connection.send(content: Data((head + body).utf8), completion: .contentProcessed { [weak self] _ in
            self?.connection.cancel()
        })
    }

    private func closeNow() {
        closing = true
        connection.cancel()
    }

    // MARK: - WebSocket 프레임

    private func parseFrames() {
        while let frame = nextFrame() {
            switch frame.opcode {
            case 0x1: // text
                if let command = try? JSONDecoder().decode(InboundCommand.self, from: frame.payload) {
                    onCommand?(command)
                }
            case 0x8: // close
                sendFrame(opcode: 0x8, payload: Data())
                closeNow()
                return
            case 0x9: // ping → pong
                sendFrame(opcode: 0xA, payload: frame.payload)
            default:
                break
            }
        }
    }

    /// 버퍼 맨 앞에서 완성된 프레임 하나를 떼어낸다. 미완성이면 nil.
    private func nextFrame() -> (opcode: UInt8, payload: Data)? {
        let b = buffer
        guard b.count >= 2 else { return nil }

        let opcode = b[0] & 0x0F
        let masked = (b[1] & 0x80) != 0
        var length = Int(b[1] & 0x7F)
        var index = 2

        if length == 126 {
            guard b.count >= 4 else { return nil }
            length = (Int(b[2]) << 8) | Int(b[3])
            index = 4
        } else if length == 127 {
            guard b.count >= 10 else { return nil }
            var value = 0
            for i in 2..<10 { value = (value << 8) | Int(b[i]) }
            length = value
            index = 10
        }

        var maskKey = [UInt8](repeating: 0, count: 4)
        if masked {
            guard b.count >= index + 4 else { return nil }
            for i in 0..<4 { maskKey[i] = b[index + i] }
            index += 4
        }

        guard b.count >= index + length else { return nil }
        var payload = Array(b[index..<index + length])
        if masked {
            for i in 0..<length { payload[i] ^= maskKey[i % 4] }
        }
        buffer.removeFirst(index + length)
        return (opcode, Data(payload))
    }

    /// 서버 → 클라이언트로 텍스트 메시지 전송 (덱 동기화용)
    func sendText(_ string: String) {
        sendFrame(opcode: 0x1, payload: Data(string.utf8))
    }

    func close() {
        sendFrame(opcode: 0x8, payload: Data())
        closeNow()
    }

    private func sendFrame(opcode: UInt8, payload: Data) {
        var frame: [UInt8] = [0x80 | opcode]
        let n = payload.count
        if n < 126 {
            frame.append(UInt8(n))
        } else if n < 65536 {
            frame.append(126)
            frame.append(UInt8((n >> 8) & 0xff))
            frame.append(UInt8(n & 0xff))
        } else {
            frame.append(127)
            for i in (0..<8).reversed() { frame.append(UInt8((n >> (8 * i)) & 0xff)) }
        }
        var data = Data(frame)
        data.append(payload)
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    // MARK: - 유틸

    private func indexOfCRLFCRLF(_ b: [UInt8]) -> Int? {
        guard b.count >= 4 else { return nil }
        var i = 0
        while i <= b.count - 4 {
            if b[i] == 13, b[i + 1] == 10, b[i + 2] == 13, b[i + 3] == 10 { return i }
            i += 1
        }
        return nil
    }
}
