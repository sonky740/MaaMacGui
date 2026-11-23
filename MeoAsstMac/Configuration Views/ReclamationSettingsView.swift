//
//  ReclamationSettingsView.swift
//  MAA
//
//  Created by hguandl on 16/4/2023.
//

import SwiftUI

struct ReclamationSettingsView: View {
    @Binding var config: ReclamationConfiguration
    @State private var names: KoreanShopNames?

    private func refreshNames() {
        names = KoreanInputResources.isKoreanUI && KoreanInputResources.isKoreanServer ? KoreanShopNames.current : nil
    }

    private var displayedTools: Binding<String> {
        let raw = $config.semicolonString(for: \.tools_to_craft)
        return Binding {
            config.tools_to_craft.map { (try? names?.craftTool($0)) ?? $0 }.joined(separator: "; ")
        } set: { raw.wrappedValue = $0 }
    }

    var body: some View {
        Form {
            Picker("主题：", selection: $config.theme) {
                ForEach(ReclamationTheme.allCases, id: \.rawValue) { theme in
                    Text(theme.description).tag(theme)
                }
            }

            Picker("策略：", selection: $config.mode) {
                ForEach(config.modes.sorted(by: <), id: \.key) { mode, desc in
                    Text(desc).tag(mode)
                }
            }

            if let tip = config.tip {
                Text(tip)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if config.toolsToCraftEnabled {
                TextField("支援道具：", text: displayedTools)
                TextField("组装批次数：", value: $config.num_craft_batches, format: .number)
                Picker("组装数量增加模式：", selection: $config.increment_mode) {
                    ForEach(config.increment_modes.sorted(by: <), id: \.key) { increment_mode, desc in
                        Text(desc).tag(increment_mode)
                    }
                }
            }
        }
        .animation(.default, value: config.theme)
        .animation(.default, value: config.mode)
        .animation(.default, value: config.toolsToCraftEnabled)
        .padding()
        .onAppear(perform: refreshNames)
        .onReceive(NotificationCenter.default.publisher(for: .koreanInputResourcesChanged)) { _ in refreshNames() }
    }
}

struct ReclamationSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        ReclamationSettingsView(config: .constant(.init()))
    }
}
