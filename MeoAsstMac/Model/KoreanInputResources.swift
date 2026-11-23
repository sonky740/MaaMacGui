import Foundation
import os

extension Notification.Name {
    static let koreanInputResourcesChanged = Self("KoreanInputResourcesChanged")
}

enum KoreanInputResources {
    private struct Loaded {
        var roots = [URL]()
        var bases = [URL]()
        var koreanServer = false
        var revision: UInt64 = 0
    }

    private static let loaded = OSAllocatedUnfairLock(initialState: Loaded())

    static var roots: [URL] { loaded.withLock { $0.roots } }
    static var baseRoots: [URL] { loaded.withLock { $0.bases } }
    static var revision: UInt64 { loaded.withLock { $0.revision } }
    static var isKoreanServer: Bool { loaded.withLock { $0.koreanServer } }
    static var isKoreanUI: Bool { Bundle.main.preferredLocalizations.first == "ko" }

    // MaaCore looks for each supplemental JSON at the layer root, even for nested resources.
    static func customizableFiles(_ path: String, in roots: [URL]) -> [URL] {
        let stem = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        return roots.flatMap { root in
            [root.appendingPathComponent(path), root.appendingPathComponent(stem + "_custom.json")]
                .filter { FileManager.default.fileExists(atPath: $0.path) }
        }
    }

    // Use only layers accepted by MaaCore. A resource update can replace a file at the same URL.
    @MainActor static func record(_ root: URL, base: Bool, reset: Bool, koreanServer: Bool) {
        loaded.withLock { state in
            if reset {
                state.roots.removeAll()
                state.bases.removeAll()
            }
            state.roots.removeAll { $0 == root }
            state.roots.append(root)
            if base {
                state.bases.removeAll { $0 == root }
                state.bases.append(root)
            }
            state.koreanServer = koreanServer
            state.revision += 1
        }
        NotificationCenter.default.post(name: .koreanInputResourcesChanged, object: nil)
    }
}
