import AppKit
import Foundation

/// 설치된 앱(.app 번들)을 스캔해 [{name, path, icon}] JSON 배열로 반환. 한 번 만들고 캐시.
/// icon 은 36px PNG 의 data URI. AppKit 아이콘 렌더가 필요해 main 에서 호출할 것.
enum AppList {
    private static var cachedJSON: String?

    static func json() -> String {
        if let cached = cachedJSON { return cached }

        let dirs = [
            "/Applications",
            "/Applications/Utilities",
            "/System/Applications",
            "/System/Applications/Utilities",
            (NSHomeDirectory() as NSString).appendingPathComponent("Applications"),
        ]
        var apps: [[String: String]] = []
        var seen = Set<String>()
        let fm = FileManager.default

        for dir in dirs {
            guard let items = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for item in items where item.hasSuffix(".app") {
                let name = (item as NSString).deletingPathExtension
                if seen.contains(name) { continue }
                seen.insert(name)
                let path = (dir as NSString).appendingPathComponent(item)
                apps.append(["name": name, "path": path, "icon": iconDataURI(path: path) ?? ""])
            }
        }
        apps.sort { ($0["name"] ?? "").localizedCaseInsensitiveCompare($1["name"] ?? "") == .orderedAscending }

        let data = (try? JSONSerialization.data(withJSONObject: apps)) ?? Data("[]".utf8)
        let result = String(data: data, encoding: .utf8) ?? "[]"
        cachedJSON = result
        return result
    }

    private static func iconDataURI(path: String) -> String? {
        let icon = NSWorkspace.shared.icon(forFile: path)
        let size = NSSize(width: 36, height: 36)
        let image = NSImage(size: size)
        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        icon.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1.0)
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return "data:image/png;base64," + png.base64EncodedString()
    }
}
