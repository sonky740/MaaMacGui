import Foundation
import os

struct KoreanOperatorNames {
    struct Candidate: Hashable {
        let core: String
        let korean: String
        let branch: String
    }

    struct GrowthCandidate: Identifiable, Hashable {
        let id: String
        let name: String
        let role: String
        let branch: String
    }

    enum InputError: LocalizedError {
        case unavailable
        case unknown(String)
        case ambiguous(String)

        var errorDescription: String? {
            switch self {
            case .unavailable: String(localized: "干员资料尚不可用", table: "KoreanInputs")
            case .unknown(let name): String(localized: "未找到干员：\(name)", table: "KoreanInputs")
            case .ambiguous(let name): String(localized: "请选择同名干员：\(name)", table: "KoreanInputs")
            }
        }
    }

    private struct BattleData: Decodable {
        struct Operator: Decodable {
            let name: String
            let name_kr: String?
            let name_kr_unavailable: Bool?
            let subProfessionId: String?
            let profession: String?
        }
        let chars: [String: Operator]
    }

    private var growthByName = [String: [GrowthCandidate]]()
    private var coreNames = Set<String>()
    private var byCore = [String: Candidate]()
    private var byKorean = [String: [Candidate]]()
    private static let cache = OSAllocatedUnfairLock(initialState: (revision: UInt64?.none, names: Self()))

    static var current: Self {
        cache.withLock { entry in
            let revision = KoreanInputResources.revision
            if entry.revision != revision {
                entry = (revision, load(roots: KoreanInputResources.roots))
            }
            return entry.names
        }
    }

    static func load(roots: [URL]) -> Self {
        // MaaCore replaces its entire operator table on each battle_data load.
        let files = KoreanInputResources.customizableFiles("battle_data.json", in: roots)
        guard let file = files.last,
            let data = try? Data(contentsOf: file),
            let battle = try? JSONDecoder().decode(BattleData.self, from: data)
        else { return Self() }

        var names = Self()
        for (id, entry) in battle.chars.sorted(by: { $0.key < $1.key }) where id.hasPrefix("char_") {
            guard !entry.name.isEmpty else { continue }
            names.coreNames.insert(entry.name)
            guard entry.name_kr_unavailable != true, let korean = entry.name_kr, !korean.isEmpty else { continue }
            if let role = entry.profession {
                let form = GrowthCandidate(id: id, name: entry.name, role: role.capitalized, branch: entry.subProfessionId ?? "")
                for alias in Set([entry.name, korean]) { names.growthByName[alias, default: []].append(form) }
            }
            let candidate = Candidate(core: entry.name, korean: korean, branch: entry.subProfessionId ?? "")
            if names.byCore[entry.name] == nil { names.byCore[entry.name] = candidate }
            if !names.byKorean[korean, default: []].contains(where: { $0.core == entry.name }) {
                names.byKorean[korean, default: []].append(candidate)
            }
        }
        return names
    }

    func suggestions(_ input: String) -> [Candidate] {
        let query = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = byCore.values.filter {
            query.isEmpty || $0.korean.localizedCaseInsensitiveContains(query) || $0.core.localizedCaseInsensitiveContains(query)
        }
        return matches.sorted { lhs, rhs in
            if !query.isEmpty {
                let left = lhs.korean.hasPrefix(query) || lhs.core.hasPrefix(query)
                let right = rhs.korean.hasPrefix(query) || rhs.core.hasPrefix(query)
                if left != right { return left }
            }
            return (lhs.korean, lhs.core) < (rhs.korean, rhs.core)
        }
    }

    func growthCandidates(_ text: String) -> [GrowthCandidate] {
        growthByName[text.trimmingCharacters(in: .whitespacesAndNewlines)] ?? []
    }

    func display(_ raw: String) -> String {
        byCore[raw]?.korean ?? raw
    }

    func candidates(_ text: String) -> [Candidate] {
        byKorean[text.trimmingCharacters(in: .whitespacesAndNewlines)] ?? []
    }

    func coreName(_ raw: String, koreanUI: Bool) throws -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return "" }
        if coreNames.contains(text) { return text }
        let matches = candidates(text)
        if matches.count == 1 { return matches[0].core }
        if matches.count > 1 { throw InputError.ambiguous(text) }
        // Other interface languages historically pass raw names to the core.
        if !koreanUI, text.range(of: #"\p{script=Hangul}"#, options: .regularExpression) == nil { return raw }
        if coreNames.isEmpty { throw InputError.unavailable }
        throw InputError.unknown(text)
    }
}
