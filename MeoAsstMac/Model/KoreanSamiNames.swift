import Foundation

enum SamiInputKind: CaseIterable {
    case forecastFoldartal, startingFoldartals, paradigms

    fileprivate var ocrTasks: [String] {
        let prefix = "Sami@Roguelike@"
        switch self {
        case .forecastFoldartal: return [prefix + "FoldartalGainOcrNextLevel"]
        case .startingFoldartals: return [prefix + "FoldartalGainOcr"]
        case .paradigms: return [prefix + "CheckCollapsalParadigmsBanner", prefix + "CheckCollapsalParadigmsPanel"]
        }
    }

    func error(for value: String) -> NSError {
        let format = self == .paradigms
            ? NSLocalizedString("无法识别萨米坍缩范式“%@”", tableName: "KoreanInputs", comment: "")
            : NSLocalizedString("无法识别萨米密文板“%@”", tableName: "KoreanInputs", comment: "")
        return NSError(domain: "MAA.SamiInput", code: 1,
                       userInfo: [NSLocalizedDescriptionKey: String(format: format, value)])
    }
}

struct KoreanSamiNames {
    private struct Vocabulary {
        var aliases = [String: Set<String>]()
        var labels = [String: String]()
        var canonical = Set<String>()
    }

    private let vocabulary: [SamiInputKind: Vocabulary]

    init(roots: [URL]) {
        let tasks = KoreanOCRTasks(roots: roots)
        let boards = Self.boardNames(roots: roots)
        let paradigms = Self.paradigmNames(roots: roots)
        var vocabulary = [SamiInputKind: Vocabulary]()
        for kind in SamiInputKind.allCases {
            let possible = kind == .paradigms ? paradigms : boards
            var words = Vocabulary()
            for task in kind.ocrTasks {
                let allowed = possible.intersection(tasks.text(for: task))
                words.canonical.formUnion(allowed)
                for pair in tasks.replacements(for: task) where pair.count == 2 && allowed.contains(pair[1]) {
                    let source = pair[0]
                    guard !source.isEmpty, let regex = try? NSRegularExpression(pattern: "^(?:" + source + ")$") else {
                        continue
                    }
                    // A pattern such as 오리지(늄)? also contains the full spelling. Never display raw regex.
                    let spelling = source.trimmingCharacters(in: CharacterSet(charactersIn: "^$"))
                        .replacingOccurrences(of: #"\(([가-힣]+)\)\?"#, with: "$1", options: .regularExpression)
                    guard spelling.rangeOfCharacter(from: CharacterSet(charactersIn: #"\^$.*+?()[]{}|"#)) == nil,
                          regex.firstMatch(in: spelling, range: NSRange(spelling.startIndex..., in: spelling)) != nil else {
                        continue
                    }
                    words.aliases[spelling.filter { !$0.isWhitespace }, default: []].insert(pair[1])
                    if words.labels[pair[1]] == nil { words.labels[pair[1]] = spelling }
                }
            }
            vocabulary[kind] = words
        }
        self.vocabulary = vocabulary
    }

    func display(_ value: String, as kind: SamiInputKind) -> String {
        guard let label = vocabulary[kind]?.labels[value],
              coreName(label, as: kind) == value else { return value }
        return label
    }

    func coreName(_ value: String, as kind: SamiInputKind) -> String? {
        let input = value.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        guard !input.isEmpty, vocabulary[kind]?.canonical.contains(input) != true else { return input }
        let matches = vocabulary[kind]?.aliases[input.filter { !$0.isWhitespace }] ?? []
        // Existing raw core values may predate our vocabulary.
        if matches.isEmpty, !Self.hasHangul(input) { return input }
        return matches.count == 1 ? matches.first : nil
    }

    private static func hasHangul(_ value: String) -> Bool {
        value.range(of: #"[가-힣ㄱ-ㅎㅏ-ㅣ\u1100-\u11FF]"#, options: .regularExpression) != nil
    }

    private static func groups(_ key: String, in path: String, roots: [URL]) -> [[String: Any]] {
        for file in KoreanInputResources.customizableFiles(path, in: roots).reversed() {
            guard let data = try? Data(contentsOf: file),
                let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { return [] }
            if let theme = object["theme"] as? String, theme != "Sami" { continue }
            // A custom board strategy may set groups without supplying a new name list.
            if let groups = object[key] as? [[String: Any]] { return groups }
        }
        return []
    }

    private static func boardNames(roots: [URL]) -> Set<String> {
        let groups = groups("foldartal", in: "roguelike/Sami/foldartal.json", roots: roots)
        return Set(groups.flatMap { ($0["foldartal"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? [] })
    }

    private static func paradigmNames(roots: [URL]) -> Set<String> {
        let levels = groups("collapsal_paradigms", in: "roguelike/Sami/collapsal_paradigms.json", roots: roots)
        return Set(levels.flatMap { [$0["level_1"] as? String, $0["level_2"] as? String].compactMap { $0 } })
    }

    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var value: (revision: UInt64, names: KoreanSamiNames)?
    }
    private static let cache = Cache()

    static var current: KoreanSamiNames {
        cache.lock.lock()
        defer { cache.lock.unlock() }
        let revision = KoreanInputResources.revision
        if let value = cache.value, value.revision == revision { return value.names }
        // These inputs always target core names, including when a Korean UI controls another server.
        let roots = KoreanInputResources.isKoreanServer ? KoreanInputResources.roots : KoreanInputResources.baseRoots.flatMap {
            [$0, $0.appendingPathComponent("global/YoStarKR/resource")]
        }
        let names = Self(roots: roots)
        cache.value = (revision, names)
        return names
    }
}
