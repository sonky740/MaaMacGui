import SwiftUI

struct KoreanOperatorField<Config>: View {
    let title: LocalizedStringResource
    @Binding var config: Config
    let name: WritableKeyPath<Config, String>
    let draft: WritableKeyPath<Config, String?>

    @State private var editing = false
    @State private var names = KoreanOperatorNames.current

    var body: some View {
        if KoreanInputResources.isKoreanUI {
            VStack(alignment: .leading) {
                OperatorNamePicker(title: title, text: Binding {
                    config[keyPath: draft] ?? names.display(config[keyPath: name])
                } set: { config[keyPath: draft] = $0 }, names: names, onSelect: { accept($0.core) },
                                   onFinish: finishEditing, onEditing: { editing = $0 })
                let saved = config[keyPath: name]
                let aliases = names.candidates(names.display(saved))
                let hasDraft: Bool = config[keyPath: draft] != nil
                if !hasDraft, aliases.count > 1, let choice = aliases.first(where: { $0.core == saved }) {
                    Text(verbatim: choice.selectionLabel).font(.caption)
                } else if !editing, let error {
                    Text(verbatim: error.localizedDescription)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .onAppear { names = .current }
            .onDisappear { finishEditing() }
            .onReceive(NotificationCenter.default.publisher(for: .koreanInputResourcesChanged)) { _ in
                names = .current
            }
        } else {
            TextField(String(localized: title), text: $config[dynamicMember: name])
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

}

struct OperatorNamePicker: View {
    let title: LocalizedStringResource
    @Binding var text: String
    let names: KoreanOperatorNames
    let onSelect: (KoreanOperatorNames.Candidate) -> Void
    var onFinish: () -> Void = {}
    var onEditing: (Bool) -> Void = { _ in }

    @State private var focusRequest = 0
    @State private var expanded = false
    @State private var showAll = false
    @State private var highlighted: String?

    var body: some View {
        let matches = expanded ? names.suggestions(showAll ? "" : text) : []
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                OperatorSearchTextField(title: String(localized: title), text: text, focusRequest: focusRequest,
                                        onEdit: { value in
                    text = value
                    highlighted = nil
                    showAll = false
                    expanded = true
                }, onFocus: { editing in
                    onEditing(editing)
                    if !editing {
                        expanded = false
                        onFinish()
                    }
                }, onCommand: { command in
                    switch command {
                    case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
                        if !expanded {
                            showAll = text.isEmpty
                            expanded = true
                        }
                        move(command == #selector(NSResponder.moveDown(_:)) ? 1 : -1,
                             expanded && !matches.isEmpty ? matches : names.suggestions(text))
                    case #selector(NSResponder.insertNewline(_:)):
                        if let selected = matches.first(where: { $0.core == highlighted }) {
                            choose(selected)
                        } else if matches.count == 1, let selected = matches.first, !text.isEmpty {
                            choose(selected)
                        } else {
                            onFinish()
                            expanded = false
                        }
                    case #selector(NSResponder.cancelOperation(_:)) where expanded:
                        expanded = false
                    default: return false
                    }
                    return true
                })
                Button {
                    expanded.toggle()
                    showAll = true
                    highlighted = nil
                    focusRequest += 1
                } label: {
                    Image(systemName: "chevron.down")
                }
                .accessibilityLabel("오퍼레이터 목록")
            }
            if expanded {
                if matches.isEmpty {
                    Text("검색 결과 없음").foregroundStyle(.secondary)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(matches, id: \.core) { item in
                                    Button {
                                        choose(item)
                                    } label: {
                                        Text(verbatim: label(item))
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(4)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .focusable(false)
                                    .background(highlighted == item.core ? Color.accentColor.opacity(0.2) : .clear)
                                }
                            }
                        }
                        .frame(height: CGFloat(min(matches.count, 6)) * 27)
                        .onChange(of: highlighted) { if let highlighted { proxy.scrollTo(highlighted) } }
                    }
                }
            }
        }
    }

    private func move(_ step: Int, _ matches: [KoreanOperatorNames.Candidate]) {
        guard !matches.isEmpty else { return }
        let index = matches.firstIndex { $0.core == highlighted } ?? (step > 0 ? -1 : matches.count)
        highlighted = matches[min(max(index + step, 0), matches.count - 1)].core
    }

    private func choose(_ item: KoreanOperatorNames.Candidate) {
        onSelect(item)
        expanded = false
        highlighted = nil
    }

    private func label(_ item: KoreanOperatorNames.Candidate) -> String {
        guard names.candidates(item.korean).count > 1 else { return item.korean }
        return item.korean + " · " + item.selectionLabel
    }
}

private extension KoreanOperatorNames.Candidate {
    var selectionLabel: String {
        let localized = Bundle.main.localizedString(forKey: branch, value: branch, table: "KoreanInputs")
        return localized.isEmpty ? core : localized + " · " + core
    }
}

// Handle navigation in the native field editor, after the input method has processed the keystroke.
private struct OperatorSearchTextField: NSViewRepresentable {
    let title: String
    let text: String
    let focusRequest: Int
    let onEdit: (String) -> Void
    let onFocus: (Bool) -> Void
    let onCommand: (Selector) -> Bool
    @Environment(\.isEnabled) private var enabled

    init(title: String, text: String, focusRequest: Int, onEdit: @escaping (String) -> Void,
         onFocus: @escaping (Bool) -> Void, onCommand: @escaping (Selector) -> Bool) {
        self.title = title
        self.text = text
        self.focusRequest = focusRequest
        self.onEdit = onEdit
        self.onFocus = onFocus
        self.onCommand = onCommand
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.usesSingleLineMode = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        let coordinator = context.coordinator
        let requestFocus = focusRequest != coordinator.parent.focusRequest
        coordinator.parent = self
        field.isEnabled = enabled
        field.placeholderString = title
        field.setAccessibilityLabel(title)
        if field.stringValue != text, (field.currentEditor() as? NSTextView)?.hasMarkedText() != true {
            field.stringValue = text
        }
        if requestFocus, field.currentEditor() == nil { field.window?.makeFirstResponder(field) }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: OperatorSearchTextField
        init(_ parent: OperatorSearchTextField) { self.parent = parent }

        func controlTextDidBeginEditing(_ notification: Notification) { parent.onFocus(true) }
        func controlTextDidEndEditing(_ notification: Notification) { parent.onFocus(false) }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.onEdit(field.stringValue)
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            !textView.hasMarkedText() && parent.onCommand(commandSelector)
        }
    }
}
