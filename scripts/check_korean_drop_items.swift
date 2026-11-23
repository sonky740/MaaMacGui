// swiftc MeoAsstMac/Model/FightDropItems.swift scripts/check_korean_drop_items.swift -o /tmp/check-drop-items
import Foundation

@main enum DropItemChecks {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        func names(_ language: String, _ roots: [URL]) throws -> [String: String] {
            Dictionary(uniqueKeysWithValues: try FightDropItem.load(language: language, baseRoots: roots).map { ($0.id, $0.name) })
        }
        let ko = try names("ko", [root])
        let cn = try names("zh-Hans", [root])
        precondition(ko["30011"] == "원암" && cn["30011"] == "源岩")
        precondition(ko["4002"] == nil)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        let kr = temp.appendingPathComponent("global/YoStarKR/resource")
        try FileManager.default.createDirectory(at: kr, withIntermediateDirectories: true)
        for label in ["새 재료", "바뀐 재료"] {
            try JSONEncoder().encode(["9999999": ["name": label]]).write(to: kr.appendingPathComponent("item_index.json"))
            let updated = try names("ko", [root, temp])
            precondition(updated["9999999"] == label)
            let chinese = try names("zh-Hans", [root, temp])
            precondition(chinese["9999999"] == nil)
        }
        print("PASS drop item IDs, language, exclusions and same-path resource replacement")
    }
}
