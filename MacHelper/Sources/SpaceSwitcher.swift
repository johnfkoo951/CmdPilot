import ColorSync
import CoreGraphics
import Foundation

/// macOS 비공개 CGS(SkyLight) API로 데스크탑(공간)을 직접 전환한다.
/// ⚠️ 비공개 API — macOS 버전에 따라 키 구조/동작이 달라질 수 있다.
///    실패/성공 여부는 /tmp/macpilot-cmd.log 에 기록한다.
enum SpaceSwitcher {
    private typealias MainConnFn = @convention(c) () -> Int32
    private typealias CopySpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias SetCurrentFn = @convention(c) (Int32, CFString, UInt64) -> Void

    private static let handle: UnsafeMutableRawPointer? =
        dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)

    private static func resolve<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle, let symbol = dlsym(handle, name) else { return nil }
        return unsafeBitCast(symbol, to: T.self)
    }

    private static let mainConnection = resolve("CGSMainConnectionID", as: MainConnFn.self)
    private static let copySpaces = resolve("CGSCopyManagedDisplaySpaces", as: CopySpacesFn.self)
    private static let setCurrentSpace = resolve("CGSManagedDisplaySetCurrentSpace", as: SetCurrentFn.self)

    /// dir "left" = 이전(왼쪽) 공간, "right" = 다음(오른쪽) 공간. 성공 시 true.
    @discardableResult
    static func switchSpace(_ dir: String) -> Bool {
        guard let mainConnection, let copySpaces, let setCurrentSpace else {
            log("API 해석 실패 (dlopen/dlsym)")
            return false
        }
        let cid = mainConnection()
        guard let array = copySpaces(cid)?.takeRetainedValue() as? [[String: Any]], !array.isEmpty else {
            log("CGSCopyManagedDisplaySpaces 실패")
            return false
        }

        // 커서가 있는 디스플레이를 우선 선택 (없으면 첫 번째)
        let cursorDisplay = displayUUIDUnderCursor()
        let display = array.first(where: { ($0["Display Identifier"] as? String) == cursorDisplay }) ?? array[0]

        guard let displayID = display["Display Identifier"] as? String,
              let spaces = display["Spaces"] as? [[String: Any]],
              let current = display["Current Space"] as? [String: Any] else {
            log("디스플레이 구조 파싱 실패 keys=\(Array(display.keys))")
            return false
        }

        // 사용자 데스크탑(type 0)만 (전체화면 공간 type 4 등 제외)
        let userSpaces = spaces.filter { (($0["type"] as? NSNumber)?.intValue ?? 0) == 0 }
        let ids = userSpaces.map { spaceID($0) }
        let currentID = spaceID(current)
        guard let idx = ids.firstIndex(of: currentID) else {
            log("현재 공간 못 찾음 cur=\(currentID) ids=\(ids)")
            return false
        }

        let targetIdx = dir == "left" ? idx - 1 : idx + 1
        guard targetIdx >= 0, targetIdx < ids.count else {
            log("끝 공간 dir=\(dir) idx=\(idx) count=\(ids.count)")
            return false
        }
        setCurrentSpace(cid, displayID as CFString, ids[targetIdx])
        log("전환 호출 dir=\(dir) \(currentID)→\(ids[targetIdx]) (\(ids.count)개, display=\(displayID))")
        return true
    }

    private static func spaceID(_ dict: [String: Any]) -> UInt64 {
        if let n = dict["ManagedSpaceID"] as? NSNumber { return n.uint64Value }
        if let n = dict["id64"] as? NSNumber { return n.uint64Value }
        return 0
    }

    private static func displayUUIDUnderCursor() -> String? {
        let mouse = CGEvent(source: nil)?.location ?? .zero
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return nil }
        for id in ids where CGDisplayBounds(id).contains(mouse) {
            if let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() {
                return CFUUIDCreateString(nil, uuid) as String?
            }
        }
        return nil
    }

    private static func log(_ message: String) {
        let line = "[space] \(message)\n"
        let url = URL(fileURLWithPath: "/tmp/macpilot-cmd.log")
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
