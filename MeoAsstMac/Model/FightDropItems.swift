import Foundation

struct FightDropItem: Identifiable, Equatable {
    let id: String
    let name: String

    private static let excludedIDs = Set([
        3213, 3223, 3233, 3243,  // 双芯片
        3253, 3263, 3273, 3283,  // 双芯片
        7001, 7002, 7003, 7004,  // 许可
        6001,  // 演习卷
        4004, 4005,  // 凭证
        3141, 4002,  // 源石
        32001,  // 芯片助剂
        30115,  // 聚合剂
        30125,  // 双极纳米片
        30135,  // D32钢
        30145,  // 晶体电子单元
        30155,  // 烧结核凝晶
    ])

    static func load(language: String, baseRoots: [URL]) throws -> [Self] {
        let channel: String?
        switch language {
        case "ko": channel = "YoStarKR"
        case "en": channel = "YoStarEN"
        case "ja": channel = "YoStarJP"
        case "zh-Hant", "zh-TW": channel = "txwy"
        default: channel = nil
        }

        struct Entry: Decodable { let name: String }
        var base: [String: Entry] = [:]
        var translated: [String: Entry] = [:]
        let decoder = JSONDecoder()
        func read(_ directory: URL) throws -> [String: Entry]? {
            let file = directory.appendingPathComponent("item_index.json")
            guard FileManager.default.fileExists(atPath: file.path) else { return nil }
            return try decoder.decode([String: Entry].self, from: Data(contentsOf: file))
        }
        for root in baseRoots {
            if let items = try read(root) { base = items }
            if let channel, let items = try read(root.appendingPathComponent("global/\(channel)/resource")) {
                translated = items
            }
        }
        base.merge(translated) { _, local in local }
        return base.compactMap { id, item -> Self? in
            guard let number = Int(id), !excludedIDs.contains(number) else { return nil }
            return Self(id: id, name: item.name)
        }.sorted {
            let order = $0.name.localizedCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }
}
