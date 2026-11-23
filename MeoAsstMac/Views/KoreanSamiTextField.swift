import SwiftUI

struct KoreanSamiTextField: View {
    let title: LocalizedStringKey
    @Binding var config: RoguelikeConfiguration
    let kind: SamiInputKind

    @State private var names = KoreanSamiNames.current
    @FocusState private var focused: Bool

    private var draftKey: WritableKeyPath<RoguelikeConfiguration, String?> {
        switch kind {
        case .forecastFoldartal: \.forecastDraft
        case .startingFoldartals: \.startingBoardsDraft
        case .paradigms: \.paradigmsDraft
        }
    }

    private var values: [String] {
        switch kind {
        case .forecastFoldartal: [config.first_floor_foldartal]
        case .startingFoldartals: config.start_foldartal_list
        case .paradigms: config.expected_collapsal_paradigms
        }
    }

    private func tokens(_ value: String) -> [String] {
        if kind == .forecastFoldartal { return [value] }
        return value.components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        let displayed = KoreanInputResources.isKoreanUI ? values.map { names.display($0, as: kind) } : values
        let draft = config[keyPath: draftKey]
        TextField(title, text: Binding {
            draft ?? displayed.joined(separator: "; ")
        } set: { input in
            config[keyPath: draftKey] = input
        })
        .focused($focused)
        .onSubmit { finishEditing() }
        .onDisappear { finishEditing() }
        .onChange(of: focused) { _, focused in
            if !focused { finishEditing() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .koreanInputResourcesChanged)) { _ in
            names = .current
        }
        if !focused, let invalid = (draft.map(tokens) ?? values).first(where: { names.coreName($0, as: kind) == nil }) {
            Text(verbatim: kind.error(for: invalid).localizedDescription)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private func finishEditing() {
        guard let draft = config[keyPath: draftKey] else { return }
        let values = tokens(draft)
        let resolved = values.compactMap { names.coreName($0, as: kind) }
        guard resolved.count == values.count else { return }
        var updated = config
        switch kind {
        case .forecastFoldartal: updated.first_floor_foldartal = resolved.first ?? ""
        case .startingFoldartals: updated.start_foldartal_list = resolved
        case .paradigms: updated.expected_collapsal_paradigms = resolved
        }
        updated[keyPath: draftKey] = nil
        config = updated
    }
}
