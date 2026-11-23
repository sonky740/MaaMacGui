import Foundation

@propertyWrapper
struct InputDraft: Codable, Hashable, Sendable {
    var wrappedValue: String?
}

// A task can be saved while its field editor is composing text.
extension KeyedEncodingContainer {
    mutating func encode(_ draft: InputDraft, forKey key: Key) {}
}

extension KeyedDecodingContainer {
    func decode(_ type: InputDraft.Type, forKey key: Key) -> InputDraft {
        InputDraft()
    }
}
