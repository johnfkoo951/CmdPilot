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
}
