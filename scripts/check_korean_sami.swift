// swiftc -target arm64-apple-macos14.0 MeoAsstMac/Model/{KoreanInputResources,KoreanOCRTasks,KoreanSamiNames}.swift scripts/check_korean_sami.swift -o /tmp/check-korean-sami
// /tmp/check-korean-sami /path/to/resource
import Foundation

@main
struct CheckKoreanSami {
    @MainActor static func main() throws {
        let base = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let kr = base.appendingPathComponent("global/YoStarKR/resource")
        KoreanInputResources.record(base, base: true, reset: true, koreanServer: true)
        KoreanInputResources.record(kr, base: false, reset: false, koreanServer: true)
        let names = KoreanSamiNames.current
        for kind in [SamiInputKind.forecastFoldartal, .startingFoldartals] {
            try check(names.coreName("오리지늄", as: kind) == "源石", "optional OCR capture")
            try check(names.display("源石", as: kind) == "오리지늄", "read old value")
            try check(names.coreName("사냥꾼".decomposedStringWithCanonicalMapping, as: kind) == "猎手", "Hangul composition")
            try check(names.coreName("오리지", as: kind) == nil, "reject OCR-only abbreviation")
            try check(names.coreName("레이더", as: kind) == nil, "exclude equipment sharing this OCR task")
            try check(names.coreName("구성", as: kind) == nil, "exclude section headers")
        }
        try check(names.coreName("  수적 붕괴  ", as: .paradigms) == "去量化", "anchored OCR rule")
        try check(names.coreName("수적 붕괴 심화", as: .paradigms) == "去量深化", "longer paradigm")
        try check(names.coreName("수적붕괴심화오타", as: .paradigms) == nil, "no substring auto-selection")
        try check(names.coreName("保留", as: .paradigms) == "保留", "legacy untranslated value")
        try check(names.coreName("", as: .paradigms) == "", "preserve empty value")
        let boardFile = base.appendingPathComponent("roguelike/Sami/foldartal.json")
        var boardData = try JSONSerialization.jsonObject(with: Data(contentsOf: boardFile)) as! [String: Any]
        let groups = boardData["foldartal"] as! [[String: Any]]
        let boards = groups.flatMap { ($0["foldartal"] as! [[String: Any]]).compactMap { $0["name"] as? String } }
        let paradigmFile = base.appendingPathComponent("roguelike/Sami/collapsal_paradigms.json")
        let data = try JSONSerialization.jsonObject(with: Data(contentsOf: paradigmFile)) as! [String: Any]
        let paradigms = (data["collapsal_paradigms"] as! [[String: String]]).flatMap { [$0["level_1"]!, $0["level_2"]!] }
        for (values, kind) in [(boards, SamiInputKind.forecastFoldartal), (boards, .startingFoldartals), (paradigms, .paradigms)] {
            for value in values {
                let korean = names.display(value, as: kind)
                try check(korean != value && names.coreName(korean, as: kind) == value, "resource round trip: " + value)
            }
        }

        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        let newBoard = "新增测试板"
        boardData["foldartal"] = groups + [["foldartal": [["name": newBoard]]]]
        try write(boardData, to: temp.appendingPathComponent("roguelike/Sami/foldartal.json"))
        let inheritedTask = "Sami@Roguelike@FoldartalGainOcrNextLevel"
        let target = temp.appendingPathComponent("tasks/custom/location.json")
        try write([inheritedTask: ["baseTask": "#none", "text": [newBoard], "ocrReplace": [["새암호판", newBoard]]]], to: target)
        KoreanInputResources.record(temp, base: false, reset: false, koreanServer: true)
        try check(KoreanSamiNames.current.coreName("새 암호판", as: .forecastFoldartal) == newBoard, "new resource only")
        try check(KoreanSamiNames.current.coreName("새 암호판", as: .startingFoldartals) == nil, "leaf-specific override")
        try check(KoreanSamiNames.current.coreName("오리지늄", as: .forecastFoldartal) == nil, "replaced task")
        let custom = temp.appendingPathComponent("foldartal_custom.json")
        try write(["groups": []], to: custom)
        KoreanInputResources.record(temp, base: false, reset: false, koreanServer: true)
        try check(KoreanSamiNames.current.coreName("새암호판", as: .forecastFoldartal) == newBoard, "custom strategy without name list")
        try write(["foldartal": groups], to: custom)
        KoreanInputResources.record(temp, base: false, reset: false, koreanServer: true)
        try check(KoreanSamiNames.current.coreName("새암호판", as: .forecastFoldartal) == nil, "custom name list overrides regular file")
        try FileManager.default.removeItem(at: custom)
        try write([inheritedTask: ["text": ["源石", newBoard], "ocrReplace": [["새이름", newBoard], ["새이름", "源石"]]]], to: target)
        KoreanInputResources.record(temp, base: false, reset: false, koreanServer: true)
        try check(KoreanSamiNames.current.coreName("새이름", as: .forecastFoldartal) == nil, "ambiguous names after reload")
        try check(KoreanSamiNames.current.coreName("새암호판", as: .forecastFoldartal) == nil, "invalidated stale alias")
        print("Sami input checks passed: \(boards.count) Foldartals in two fields, \(paradigms.count) paradigms, resource updates, collisions and rejected inputs")
    }

    static func check(_ value: Bool, _ message: String) throws {
        if !value { throw NSError(domain: "SamiCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    static func write(_ object: Any, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }
}
