import Foundation
import os

struct KoreanShopNames {
    enum InputError: LocalizedError {
        case missingShopResources
        case unknownFilter(String)
        case unknownTool(String)

        var errorDescription: String? {
            switch self {
            case .missingShopResources: String(localized: "无法读取韩服购物资料", table: "KoreanInputs")
            case .unknownFilter(let name): String(localized: "请用游戏内韩文重新输入购物关键词：\(name)", table: "KoreanInputs")
            case .unknownTool(let name): String(localized: "请用游戏内韩文重新输入支援道具：\(name)", table: "KoreanInputs")
            }
        }
    }

    private struct Item: Decodable { let name: String }
    private struct OCRConfig: Decodable {
        let equivalence_classes: [[String]]

        func equivalent(_ text: String) -> String {
            var result = text
            for group in equivalence_classes {
                guard let canonical = group.first else { continue }
                for variant in group.dropFirst() {
                    result = result.replacingOccurrences(of: variant, with: canonical)
                }
            }
            return result
        }

        func replacementPattern(_ raw: String) -> String {
            var pattern = raw
            for group in equivalence_classes where group.count > 1 {
                let alternatives = "(?:" + group.joined(separator: "|") + ")"
                for variant in group {
                    pattern = pattern.replacingOccurrences(of: variant, with: alternatives)
                }
            }
            return pattern
        }
    }
    private struct Battle: Decodable {
        struct Entry: Decodable {
            let name: String
            let name_kr: String?
            let name_kr_unavailable: Bool?
        }
        let chars: [String: Entry]
    }

    private var chinese = [String: String]()
    private var korean = [String: String]()
    private var equivalentKorean = [String: String]()
    private var recognized = [String: String]()
    private var ocr = OCRConfig(equivalence_classes: [])
    private var tools = [String: Set<String>]()
    private static let cache = OSAllocatedUnfairLock(initialState: (revision: UInt64?.none, names: Self()))

    static var current: Self {
        cache.withLock { cached in
            let revision = KoreanInputResources.revision
            if cached.revision != revision {
                cached = (revision, load(baseRoots: KoreanInputResources.baseRoots, roots: KoreanInputResources.roots))
            }
            return cached.names
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, files: [URL]) -> T? {
        guard let url = files.last(where: { FileManager.default.fileExists(atPath: $0.path) }),
            let data = try? Data(contentsOf: url)
        else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func load(baseRoots: [URL], roots: [URL]) -> Self {
        var result = Self()
        if let battle = decode(Battle.self, files: KoreanInputResources.customizableFiles("battle_data.json", in: roots)) {
            for (id, entry) in battle.chars where id.hasPrefix("trap_") && entry.name_kr_unavailable != true {
                if let name = entry.name_kr, !name.isEmpty {
                    result.tools[entry.name, default: []].insert(name)
                }
            }
        }

        let baseItems = baseRoots.map { $0.appendingPathComponent("item_index.json") }
        let activeItems = roots.map { $0.appendingPathComponent("item_index.json") }
        guard let source = decode([String: Item].self, files: baseItems),
            let activeIndex = activeItems.last(where: { FileManager.default.fileExists(atPath: $0.path) }),
            !baseItems.contains(activeIndex),
            let target = decode([String: Item].self, files: [activeIndex])
        else { return result }
        let tasks = KoreanOCRTasks(roots: roots)
        guard tasks.loadError == nil,
            let ocr = decode(OCRConfig.self, files: KoreanInputResources.customizableFiles("ocr_config.json", in: roots)),
            ocr.equivalence_classes.allSatisfy({ !$0.contains("") })
        else { return result }
        result.ocr = ocr
        let key = "CreditShop-ProductName"
        // The credit shop passes only the replacement list to OCRer, even when the task sets replaceFull.
        var rules = [(NSRegularExpression, String)]()
        for pair in tasks.replacements(for: key) {
            guard pair.count == 2, let regex = try? NSRegularExpression(pattern: ocr.replacementPattern(pair[0])) else { return result }
            rules.append((regex, pair[1]))
        }
        result.chinese = source.mapValues(\.name)
        result.korean = target.mapValues(\.name)
        result.equivalentKorean = result.korean.mapValues(ocr.equivalent)
        result.recognized = result.korean.mapValues { name in
            let replaced = rules.reduce(name) { term, rule in
                let range = NSRange(term.startIndex..., in: term)
                return rule.0.stringByReplacingMatches(in: term, range: range, withTemplate: rule.1)
            }
            return ocr.equivalent(replaced)
        }
        return result
    }

    private static func hasHan(_ name: String) -> Bool {
        name.range(of: #"\p{Han}"#, options: .regularExpression) != nil
    }

    private func ids(containing keyword: String, in names: [String: String]) -> Set<String> {
        Set(names.compactMap { $0.value.contains(keyword) ? $0.key : nil })
    }

    private func ocrKeyword(for display: String, matching expected: Set<String>) -> String? {
        let equivalent = ocr.equivalent(display)
        let exact = expected.filter { equivalentKorean[$0] == equivalent }
        var candidates = [display]
        candidates.append(contentsOf: Set(exact.compactMap { recognized[$0] }).sorted())
        candidates.append(equivalent.replacingOccurrences(of: " ", with: ""))
        return candidates.first { candidate in
            !candidate.isEmpty && ids(containing: ocr.equivalent(candidate), in: recognized) == expected
        }
    }

    private func translated(_ text: String) -> (display: String, keyword: String)? {
        let expected = ids(containing: text, in: chinese)
        let names = expected.compactMap { korean[$0] }
        guard names.count == expected.count,
            let shortest = names.sorted().min(by: { $0.count < $1.count }), !shortest.isEmpty
        else { return nil }

        // A translated partial filter must select precisely the same IDs in the editor and in the OCR results.
        func translation(_ display: String) -> (String, String)? {
            let equivalent = ocr.equivalent(display)
            guard ids(containing: equivalent, in: equivalentKorean) == expected,
                let keyword = ocrKeyword(for: display, matching: expected)
            else { return nil }
            return (display, keyword)
        }
        if let result = translation(shortest) { return result }
        if Set(names).count == 1 { return nil }

        let letters = Array(shortest)
        for length in stride(from: letters.count - 1, through: 1, by: -1) {
            for offset in 0...(letters.count - length) {
                let display = String(letters[offset..<(offset + length)])
                guard display == display.trimmingCharacters(in: .whitespacesAndNewlines),
                    display.rangeOfCharacter(from: .alphanumerics) != nil,
                    names.allSatisfy({ $0.contains(display) })
                else { continue }
                if let result = translation(display) { return result }
            }
        }
        return nil
    }

    func displayedKeyword(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.hasHan(text), !equivalentKorean.values.contains(ocr.equivalent(text)) else { return raw }
        return translated(text)?.display ?? raw
    }

    func keyword(_ raw: String) throws -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        if text.isEmpty { return "" }
        guard !korean.isEmpty else { throw InputError.missingShopResources }
        let equivalent = ocr.equivalent(text)
        if Self.hasHan(text), !equivalentKorean.values.contains(equivalent) {
            guard let result = translated(text) else { throw InputError.unknownFilter(text) }
            return result.keyword
        }
        let expected = ids(containing: equivalent, in: equivalentKorean)
        // Users can also filter a server-only product absent from the item index.
        if expected.isEmpty { return text }
        guard let keyword = ocrKeyword(for: text, matching: expected) else { throw InputError.unknownFilter(text) }
        return keyword
    }

    func craftTool(_ raw: String) throws -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.hasHan(text) else { return text }
        guard let names = tools[text], names.count == 1, let name = names.first else {
            throw InputError.unknownTool(text)
        }
        return name
    }
}
