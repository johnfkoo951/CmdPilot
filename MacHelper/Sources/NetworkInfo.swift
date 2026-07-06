import Foundation
import SystemConfiguration

enum NetworkInfo {
    /// mDNS .local 호스트네임 (예: "joon-m5-max.local"). IP가 바뀌어도 안 변함.
    static func localHostName() -> String? {
        guard let cf = SCDynamicStoreCopyLocalHostName(nil) else { return nil }
        let name = (cf as String).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : "\(name).local"
    }

    /// LAN IPv4 주소를 반환 (en0 = Wi-Fi 우선). 아이폰에 보여줄 접속 주소용.
    static func primaryIPv4() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }

        var candidates: [String: String] = [:]
        var pointer = ifaddr
        while let ptr = pointer {
            defer { pointer = ptr.pointee.ifa_next }

            let flags = Int32(ptr.pointee.ifa_flags)
            guard let addr = ptr.pointee.ifa_addr,
                  (flags & IFF_UP) != 0,
                  (flags & IFF_LOOPBACK) == 0,
                  addr.pointee.sa_family == UInt8(AF_INET)
            else { continue }

            let name = String(cString: ptr.pointee.ifa_name)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                        &host, socklen_t(host.count),
                        nil, 0, NI_NUMERICHOST)
            candidates[name] = String(cString: host)
        }

        return candidates["en0"] ?? candidates["en1"] ?? candidates.values.first
    }

    /// `tailscale serve` 로 앞단화된 tailnet HTTPS 주소 (예: https://mac.tailnet.ts.net).
    /// 에어마우스/모션 센서는 iOS가 secure context(HTTPS)에서만 허용하므로 이 주소로 접속해야 동작한다.
    /// serve 미설정이면 nil. tailscale CLI 를 짧게 호출한다(수백 ms).
    static func tailscaleHTTPSURL() -> String? {
        let bins = ["/usr/local/bin/tailscale",
                    "/opt/homebrew/bin/tailscale",
                    "/Applications/Tailscale.app/Contents/MacOS/Tailscale"]
        guard let bin = bins.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        guard let out = runTool(bin, ["serve", "status"]) else { return nil }
        // 출력 예: "https://mac.tailnet.ts.net (tailnet only)\n|-- / proxy http://127.0.0.1:8766"
        for raw in out.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("https://") else { continue }
            var url = line.split(separator: " ").first.map(String.init) ?? line
            if url.hasSuffix("/") { url.removeLast() }
            return url
        }
        return nil
    }

    private static func runTool(_ path: String, _ args: [String]) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()   // stderr 삼킴
        do { try proc.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
