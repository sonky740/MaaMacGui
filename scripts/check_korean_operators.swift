// swiftc MeoAsstMac/Model/{InputDraft,KoreanInputResources,KoreanOperatorNames}.swift scripts/check_korean_operators.swift -o /tmp/check-korean-operators
// /tmp/check-korean-operators /path/to/resource
import Foundation

@main struct KoreanOperatorChecks {
    @MainActor static func main() throws {
        guard let path = CommandLine.arguments.dropFirst().first else {
            throw Failure(message: "Supply the directory containing battle_data.json")
        }
        let installed = URL(fileURLWithPath: path, isDirectory: true)
        KoreanInputResources.record(installed, base: true, reset: true, koreanServer: true)
        let names = KoreanOperatorNames.current
        try check(names.display("维什戴尔") == "위셔델", "existing settings")
        try check(names.coreName("  위셔델\n", koreanUI: true) == "维什戴尔", "Korean input")
        try check(names.coreName("위셔델".decomposedStringWithCanonicalMapping, koreanUI: true) == "维什戴尔", "decomposed")
        try check(names.coreName("维什戴尔", koreanUI: true) == "维什戴尔", "Chinese input")
        try check(names.coreName("", koreanUI: true).isEmpty, "automatic selection")
        try check(names.coreName("아미야", koreanUI: true) == "阿米娅", "same core across roles")
        try check(names.display("아직 없는 이름") == "아직 없는 이름", "preserve unmapped saved value")
        try expectError(.unknown("위셔뎰")) { try names.coreName("위셔뎰", koreanUI: true) }
        try check(names.coreName("legacy", koreanUI: false) == "legacy", "other GUI language")

        var config = SavedInput(core: "维什戴尔")
        config.draft = "위셔뎰"
        let plist = try PropertyListEncoder().encode(config)
        let plistValues = try PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: String]
        try check(plistValues == ["core": "维什戴尔"], "draft excluded from settings")
        let restored = try PropertyListDecoder().decode(SavedInput.self, from: plist)
        try check(restored.core == config.core && restored.draft == nil, "reopen last confirmed input")
        let payload = try JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: String]
        try check(payload == plistValues, "draft excluded from task JSON")
        try expectError(.unknown("위셔뎰")) { try names.coreName(config.draft ?? config.core, koreanUI: true) }

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let file = tmp.appendingPathComponent("battle_data.json")
        var chars = [
            "char_1": ["name": "新增一", "name_kr": "새 이름", "subProfessionId": "summoner"],
            "char_2": ["name": "新增二", "name_kr": "새 이름", "subProfessionId": "slower"],
            "char_3": ["name": "未实装", "name_kr": "미공개", "name_kr_unavailable": true],
            "trap_4": ["name": "测试陷阱", "name_kr": "테스트 함정"],
        ] as [String: [String: Any]]
        func write() throws {
            try JSONSerialization.data(withJSONObject: ["chars": chars]).write(to: file)
        }
        try write()
        KoreanInputResources.record(tmp, base: true, reset: false, koreanServer: true)
        let custom = KoreanOperatorNames.current
        try expectError(.ambiguous("새 이름")) { try custom.coreName("새 이름", koreanUI: true) }
        let matches = custom.candidates("새 이름")
        try check(matches.count == 2 && Set(matches.map(\.branch)).count == 2, "distinct candidates")
        for choice in matches {
            let saved = try custom.coreName(choice.core, koreanUI: true)
            try check(saved == choice.core && custom.display(saved) == "새 이름", "restore explicit choice")
        }
        try expectError(.unknown("미공개")) { try custom.coreName("미공개", koreanUI: true) }
        try expectError(.unknown("테스트 함정")) { try custom.coreName("테스트 함정", koreanUI: true) }
        try expectError(.unknown("위셔델")) { try custom.coreName("위셔델", koreanUI: true) }
        chars["char_5"] = ["name": "追加", "name_kr": "새 오퍼레이터"]
        try write()
        KoreanInputResources.record(tmp, base: true, reset: false, koreanServer: true)
        try check(KoreanOperatorNames.current.coreName("새 오퍼레이터", koreanUI: true) == "追加", "hot reload")
        let customFile = tmp.appendingPathComponent("battle_data_custom.json")
        let override = ["char_custom": ["name": "外部", "name_kr": "사용자 오퍼레이터"]]
        try JSONSerialization.data(withJSONObject: ["chars": override]).write(to: customFile)
        KoreanInputResources.record(tmp, base: true, reset: false, koreanServer: true)
        try check(KoreanOperatorNames.current.coreName("사용자 오퍼레이터", koreanUI: true) == "外部", "custom file")
        try expectError(.unknown("새 오퍼레이터")) {
            try KoreanOperatorNames.current.coreName("새 오퍼레이터", koreanUI: true)
        }
        let later = tmp.appendingPathComponent("higher")
        try FileManager.default.createDirectory(at: later, withIntermediateDirectories: false)
        try FileManager.default.copyItem(at: file, to: later.appendingPathComponent("battle_data.json"))
        KoreanInputResources.record(later, base: false, reset: false, koreanServer: true)
        try check(KoreanOperatorNames.current.coreName("새 오퍼레이터", koreanUI: true) == "追加", "later layer")
        try expectError(.unknown("사용자 오퍼레이터")) {
            try KoreanOperatorNames.current.coreName("사용자 오퍼레이터", koreanUI: true)
        }
        try Data("broken".utf8).write(to: customFile)
        KoreanInputResources.record(tmp, base: true, reset: false, koreanServer: true)
        try expectError(.unavailable) { try KoreanOperatorNames.current.coreName("위셔델", koreanUI: true) }
        print("Passed operator name, ambiguous selection, compatibility, and resource refresh checks")
    }

    struct SavedInput: Codable {
        var core: String
        @InputDraft var draft: String?
    }

    struct Failure: Error { let message: String }

    static func check(_ expression: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !expression() { throw Failure(message: message) }
    }

    static func expectError(_ expected: KoreanOperatorNames.InputError, _ read: () throws -> String) throws {
        do {
            let result = try read()
            throw Failure(message: "Unexpected resolution: \(result)")
        } catch let error as KoreanOperatorNames.InputError {
            try check(error.localizedDescription == expected.localizedDescription, "Unexpected error: \(error)")
        }
    }
}
