// swiftc MeoAsstMac/Model/{KoreanInputResources,KoreanOCRTasks,KoreanShopNames}.swift scripts/check_korean_shop.swift -o /tmp/check-korean-shop
// /tmp/check-korean-shop /path/to/resource
import Foundation

@main struct KoreanShopChecks {
    struct Failure: Error { let reason: String }

    static func check(_ condition: @autoclosure () throws -> Bool, _ reason: String) throws {
        if try !condition() { throw Failure(reason: reason) }
    }

    static func rejects(_ body: () throws -> String) throws {
        do { _ = try body() } catch is KoreanShopNames.InputError { return }
        throw Failure(reason: "expected a filter validation error")
    }

    @MainActor static func main() throws {
        let fm = FileManager.default
        guard CommandLine.arguments.count == 2 else { throw Failure(reason: "Supply the resource directory") }
        let base = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let kr = base.appendingPathComponent("global/YoStarKR/resource")
        KoreanInputResources.record(base, base: true, reset: true, koreanServer: true)
        KoreanInputResources.record(kr, base: false, reset: false, koreanServer: true)
        let names = KoreanShopNames.current
        try check(try ["招聘许可", "龙门币", "加急许可", "家具零件"].map(names.keyword)
                  == ["모집 허가증", "용문폐", "즉시 완료 허가증", "가구 부품"], "default filters and order")
        try check(try ["加急", "家具零"].map(names.keyword) == ["즉시 완료 허가증", "가구 부품"], "partial legacy filters")
        try check(names.displayedKeyword("加急") == "즉시 완료 허가증", "legacy partial editor")
        try check(names.displayedKeyword("招聘许可") == "모집 허가증", "existing settings")
        try check(try names.keyword("허가증") == "허가증", "Korean partial")
        try check(try names.keyword("미등록상품") == "미등록상품", "server-only product")
        try check(try names.keyword("").isEmpty, "empty row")
        try check(try names.craftTool("荧光棒") == "형광봉", "default RA tool")
        try check(try names.craftTool("새 도구") == "새 도구", "new RA tool as game text")
        try rejects { try names.keyword("许可") }
        try rejects { try names.craftTool("未知工具") }

        let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let locale = tmp.appendingPathComponent("global/YoStarKR/resource")
        try fm.createDirectory(at: locale, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        func write(_ object: Any, _ filename: String, in dir: URL) throws {
            try JSONSerialization.data(withJSONObject: object).write(to: dir.appendingPathComponent(filename))
        }
        try write(["1": ["name": "新增品"]], "item_index.json", in: tmp)
        try write(["1": ["name": "신규 상품"]], "item_index.json", in: locale)
        try write(["equivalence_classes": []], "ocr_config.json", in: locale)
        try write(["equivalence_classes": [[" ", "\u{a0}"]]], "ocr_config_custom.json", in: locale)
        try write(["chars": ["trap_test": ["name": "演算道具", "name_kr": "이전 도구"]]], "battle_data.json", in: locale)
        try write(["chars": ["trap_test": ["name": "演算道具", "name_kr": "새 도구"]]], "battle_data_custom.json", in: locale)
        try write(["CreditShop-ProductName": ["ocrReplace": [[" ", ""]], "replaceFull": true]], "tasks.json", in: locale)
        KoreanInputResources.record(tmp, base: true, reset: true, koreanServer: true)
        KoreanInputResources.record(locale, base: false, reset: false, koreanServer: true)
        let updated = KoreanShopNames.current
        try check(try updated.craftTool("演算道具") == "새 도구", "custom battle data overrides localized names")
        try check(updated.displayedKeyword("新增品") == "신규 상품", "new data for editor")
        try check(try updated.keyword("新增品") == "신규상품", "new item translated and OCR normalized")
        try check(try updated.keyword("신규 상품") == "신규상품", "new Korean item")
        try write(["1": ["name": "신규 상품"], "2": ["name": "신규 상품권"]], "item_index.json", in: locale)
        KoreanInputResources.record(locale, base: false, reset: false, koreanServer: true)
        try rejects { try KoreanShopNames.current.keyword("新增品") }
        try write(["1": ["name": "신규\u{a0}상품"]], "item_index.json", in: locale)
        KoreanInputResources.record(locale, base: false, reset: false, koreanServer: true)
        try check(try KoreanShopNames.current.keyword("신규 상품") == "신규상품", "space rule includes equivalent NBSP")

        try write(["CreditShop-ProductName": ["ocrReplace": []]], "tasks.json", in: locale)
        try write(["1": ["name": "신규 상품"], "2": ["name": "신규\u{a0}상품권"]], "item_index.json", in: locale)
        KoreanInputResources.record(locale, base: false, reset: false, koreanServer: true)
        try rejects { try KoreanShopNames.current.keyword("新增品") }
        try check(try KoreanShopNames.current.keyword("신규\u{a0}상품") == "신규\u{a0}상품",
                  "user keyword and OCR results use the same equivalence class")
        try write(["1": ["name": "滤一级"], "2": ["name": "滤二级"], "3": ["name": "其他"]], "item_index.json", in: tmp)
        try write(["1": ["name": "새 재료 상급"], "2": ["name": "새 재료 하급"], "3": ["name": "기타"]], "item_index.json", in: locale)
        KoreanInputResources.record(locale, base: false, reset: false, koreanServer: true)
        let partial = KoreanShopNames.current
        let groupTerm = try partial.keyword("滤")
        try check(groupTerm == "새 재료", "multi-product Chinese keyword preserves the matching IDs")
        try check(try partial.keyword(partial.displayedKeyword("滤")) == groupTerm, "multi-product editor round trip")
        print("Korean shop keywords and crafting names passed")
    }
}
