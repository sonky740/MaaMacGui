import SwiftUI

struct OperatorGrowthView: View {
    @EnvironmentObject private var viewModel: MAAViewModel
    @AppStorage("GrowthOperator") private var name = ""
    @AppStorage("GrowthElite") private var elite = 2
    @AppStorage("GrowthLevel") private var level = 60
    @AppStorage("GrowthSkill") private var skill = 1
    @AppStorage("GrowthSkillLevel") private var skillLevel = 7
    @AppStorage("GrowthStages") private var stages = ""
    @State private var experience = 0
    @AppStorage("GrowthOperatorForm") private var formID = ""
    @State private var names = KoreanOperatorNames.current

    private var forms: [KoreanOperatorNames.GrowthCandidate] { names.growthCandidates(name) }

    var body: some View {
        Form {
            Section("육성 목표") {
                OperatorNamePicker(title: "오퍼레이터 이름", text: Binding {
                    name
                } set: { value in
                    name = value
                    experience = 0
                    formID = ""
                }, names: names) { choice in
                    experience = 0
                    name = choice.korean
                    let matching = forms.filter { $0.name == choice.core }
                    formID = matching.count == 1 ? matching[0].id : ""
                }
                if forms.count > 1 {
                    Picker("오퍼레이터 분류", selection: $formID) {
                        Text("선택하세요").tag("")
                        ForEach(forms) { form in
                            let branch = Bundle.main.localizedString(forKey: form.branch, value: form.role, table: "KoreanInputs")
                            Text(verbatim: branch + " · " + form.id).tag(form.id)
                        }
                    }
                }
                Picker("정예 단계", selection: $elite) {
                    ForEach(0...2, id: \.self) { Text("정예 \($0)").tag($0) }
                }
                Stepper("목표 레벨 \(level)", value: $level, in: 1...90)
                Picker("목표 스킬 레벨", selection: $skillLevel) {
                    ForEach(1...10, id: \.self) { Text(verbatim: String($0)).tag($0) }
                }
                if skillLevel > 7 {
                    Picker("전문화할 스킬", selection: $skill) {
                        ForEach(1...3, id: \.self) { Text("스킬 \($0)").tag($0) }
                    }
                    Text("목표 \(skillLevel)은 선택한 스킬의 전문화 \(skillLevel - 7)단계입니다.")
                }
            }
            Section("현재 육성 상태") {
                TextField("현재 레벨에서 쌓은 경험치", value: $experience, format: .number)
                Text("게임에서 경험치를 읽을 수 없을 때만 사용합니다. 정예·레벨·스킬은 프로필에서 확인합니다.")
            }
            Section("파밍") {
                TextField("파밍 스테이지 제한 (선택)", text: $stages, prompt: Text("예: 1-7, CE-6, LS-6, PR-B-2"))
                Text("비워 두면 본체가 지원하는 한국 서버 스테이지에서 경로를 찾습니다. 특정 스테이지만 허용하려면 코드를 쉼표로 구분하세요.")
            }
        }
        .formStyle(.grouped)
        .disabled(viewModel.status != .idle)
        .onReceive(NotificationCenter.default.publisher(for: .koreanInputResourcesChanged)) { _ in names = .current }
        if viewModel.clientChannel != .YoStarKR {
            Text("한국 서버에서 사용할 수 있습니다.")
        }
        if !viewModel.growthStatus.isEmpty {
            Text(verbatim: viewModel.growthStatus).textSelection(.enabled)
        }
        Button("파밍 및 육성 시작") {
            viewModel.startGrowth(.init(name: name, formID: formID, elite: elite, level: level, skill: skill, skillLevel: skillLevel,
                                        currentExperience: experience,
                                        allowedStages: Set(stages.uppercased().split {
                                            $0.isWhitespace || $0 == "," || $0 == "，"
                                        }.map(String.init))))
        }
        .disabled(viewModel.status != .idle || viewModel.clientChannel != .YoStarKR ||
                  forms.isEmpty || (forms.count > 1 && !forms.contains(where: { $0.id == formID })) ||
                  (skillLevel > 7 && elite != 2) || experience < 0)
    }
}
