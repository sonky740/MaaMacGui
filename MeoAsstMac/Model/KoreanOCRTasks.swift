import Foundation

/// Reads the OCR fields inherited by the core's active tasks.
struct KoreanOCRTasks {
    private struct Definition: Sendable {
        var base: String?
        var replacements: [[String]]?
        var text: [String]?
        var replaceFull: Bool?

        mutating func overlay(_ fields: [String: Any]) {
            if let base = fields["baseTask"] as? String {
                self = Definition(base: base == "#none" ? nil : base)
            }
            if let value = fields["ocrReplace"] as? [[String]] { replacements = value }
            if let value = fields["text"] as? [String] { text = value }
            if let value = fields["replaceFull"] as? Bool { replaceFull = value }
        }
    }

    private let definitions: [String: Definition]
    let loadError: Error?

    init(roots: [URL]) {
        var definitions = [String: Definition]()
        do {
            for root in roots {
                var namesInLayer = Set<String>()
                for file in try Self.taskFiles(in: root) {
                    let json = try JSONSerialization.jsonObject(with: Data(contentsOf: file))
                    guard let tasks = json as? [String: [String: Any]] else {
                        throw CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: file])
                    }
                    for (name, fields) in tasks {
                        guard namesInLayer.insert(name).inserted else {
                            throw CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: file])
                        }
                        definitions[name, default: Definition()].overlay(fields)
                    }
                }
            }
            self.definitions = definitions
            loadError = nil
        } catch {
            self.definitions = [:]
            loadError = error
        }
    }

    private static func taskFiles(in root: URL) throws -> [URL] {
        let fm = FileManager.default
        let directory = root.appendingPathComponent("tasks")
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue {
            var readError: Error?
            let files = fm.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey],
                                      options: [.skipsHiddenFiles]) { _, error in
                readError = error
                return false
            }
            var result = [URL]()
            while let file = files?.nextObject() as? URL {
                if file.pathExtension == "json", try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                    result.append(file)
                }
            }
            if let readError { throw readError }
            return result
        }
        let file = root.appendingPathComponent("tasks.json")
        return fm.fileExists(atPath: file.path) ? [file] : []
    }

    private func inherited<Value>(_ key: KeyPath<Definition, Value?>, for task: String) -> Value? {
        var name: String? = task
        var visited = Set<String>()
        while let current = name, visited.insert(current).inserted {
            let definition = definitions[current]
            if let value = definition?[keyPath: key] { return value }
            // TaskData tries successively shorter @-qualified names when baseTask is absent.
            name = definition?.base ?? current.indices.lazy.filter { current[$0] == "@" }
                .map { String(current[current.index(after: $0)...]) }.first { self.definitions[$0] != nil }
        }
        return nil
    }

    func contains(_ name: String) -> Bool { definitions[name] != nil }
    func replacements(for task: String) -> [[String]] { inherited(\.replacements, for: task) ?? [] }
    func text(for task: String) -> [String] { inherited(\.text, for: task) ?? [] }
    func replacesWholeText(for task: String) -> Bool { inherited(\.replaceFull, for: task) ?? false }
}
