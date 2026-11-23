import SwiftUI

struct KoreanOperatorField<Config>: View {
    let title: LocalizedStringKey
    @Binding var config: Config
    let name: WritableKeyPath<Config, String>
    let draft: WritableKeyPath<Config, String?>

    @FocusState private var focused: Bool
    @State private var names = KoreanOperatorNames.current

    var body: some View {
        if KoreanInputResources.isKoreanUI {
            VStack(alignment: .leading) {
                let saved = config[keyPath: name]
                let text = config[keyPath: draft] ?? names.display(saved)
                TextField(title, text: Binding {
                    config[keyPath: draft] ?? names.display(config[keyPath: name])
                } set: { config[keyPath: draft] = $0 })
                    .focused($focused)
                    .onSubmit { finishEditing() }
                let candidates = names.candidates(text)
                if candidates.count > 1 {
                    Menu {
                        ForEach(candidates, id: \.core) { candidate in
                            Button(detail(candidate)) { accept(candidate.core) }
                        }
                    } label: {
                        if config[keyPath: draft] == nil, let selected = candidates.first(where: { $0.core == saved }) {
                            Text(verbatim: detail(selected))
                        } else {
                            Text("请选择同名干员：\(text)", tableName: "KoreanInputs")
                        }
                    }
                } else if !focused, let error {
                    Text(verbatim: error.localizedDescription)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .onAppear { names = .current }
            .onChange(of: focused) { if !focused { finishEditing() } }
            .onDisappear { finishEditing() }
            .onReceive(NotificationCenter.default.publisher(for: .koreanInputResourcesChanged)) { _ in
                names = .current
            }
        } else {
            TextField(title, text: $config[dynamicMember: name])
        }
    }

    private func finishEditing() {
        guard let text = config[keyPath: draft], let core = try? names.coreName(text, koreanUI: true) else { return }
        accept(core)
    }

    private func accept(_ core: String) {
        var updated = config
        updated[keyPath: name] = core
        updated[keyPath: draft] = nil
        config = updated
    }

    private var error: Error? {
        do {
            _ = try names.coreName(config[keyPath: draft] ?? config[keyPath: name], koreanUI: true)
            return nil
        } catch {
            return error
        }
    }

    private func detail(_ candidate: KoreanOperatorNames.Candidate) -> String {
        let branch = Bundle.main.localizedString(forKey: candidate.branch, value: candidate.branch, table: "KoreanInputs")
        return branch.isEmpty ? candidate.core : "\(branch) · \(candidate.core)"
    }
}
