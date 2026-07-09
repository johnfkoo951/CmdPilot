import Foundation

/// 덱(단축키/매크로 구성)을 맥에 파일로 저장 → 아이폰·아이패드가 같은 덱을 공유.
/// 위치: ~/Library/Application Support/CmdPilot/deck.json
enum DeckStore {
    private static var fileURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CmdPilot", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("deck.json")
    }

    static func loadString() -> String? {
        guard let data = try? Data(contentsOf: fileURL),
              let string = String(data: data, encoding: .utf8),
              !string.isEmpty else { return nil }
        return string
    }

    static func save(_ json: String) {
        try? json.data(using: .utf8)?.write(to: fileURL)
    }
}
