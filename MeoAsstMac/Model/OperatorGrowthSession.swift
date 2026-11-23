import Foundation
import JBirdCore

struct OperatorGrowthRequest {
    let name: String
    let formID: String
    let elite: Int
    let level: Int
    let skill: Int
    let skillLevel: Int
    let currentExperience: Int
    let allowedStages: Set<String>

    var targetMastery: Int { max(0, skillLevel - 7) }

    func slots(_ value: Int) -> [Int] {
        (1...3).map { $0 == skill ? value : 0 }
    }

    func params(form: KoreanOperatorNames.GrowthCandidate, masteryOnly: Bool = false, inspect: Bool = false, promotion: Int? = nil) throws -> String {
        var plan: [String: Any] = ["name": form.name, "role": form.role, "allow_chip_purchase": false]
        if inspect {
            return try growthJSON(["plans": [plan], "inspect_only": true, "inspection_skill": targetMastery > 0 ? skill : 0])
        }
        if let promotion {
            plan["elite"] = promotion
            plan["level"] = 1
            return try growthJSON(["plans": [plan]])
        }
        if !masteryOnly {
            plan["elite"] = elite
            plan["level"] = level
            if skillLevel >= 2 { plan["skill_level"] = min(7, skillLevel) }
        }
        if targetMastery > 0 { plan["skill_mastery"] = slots(targetMastery) }
        return try growthJSON(["plans": [plan]])
    }
}

private struct StageNavigationFailed: Error {}

private struct GrowthFailure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

private func growthJSON(_ value: [String: Any]) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
}

enum GrowthStageCatalog {
    private struct Stage: Decodable {
        struct Drop: Decodable {}
        let code: String
        let dropInfos: [Drop]?
    }

    static func supported(in roots: [URL]) throws -> Set<String> {
        let tasks = KoreanOCRTasks(roots: roots)
        if let error = tasks.loadError { throw error }
        var supported = Set<String>()
        for file in KoreanInputResources.customizableFiles("stages.json", in: roots) {
            let stages = try JSONDecoder().decode([Stage].self, from: Data(contentsOf: file))
            for stage in stages where stage.dropInfos != nil {
                let code = stage.code
                // These upstream aliases navigate to either tier 5 or tier 6.
                if code == "CE-5" || code == "LS-5" { continue }
                if tasks.contains(code) { supported.insert(code); continue }
                if let chapter = chapter(of: code), tasks.contains("Episode" + String(chapter)) {
                    supported.insert(code)
                }
            }
        }
        guard !supported.isEmpty else { throw GrowthFailure("본체 리소스에서 지원 스테이지를 읽을 수 없습니다.") }
        return supported
    }

    static func chapter(of code: String) -> Int? {
        guard let match = code.wholeMatch(of: #/^[A-Z]{0,3}([0-9]{1,2})-[0-9]{1,2}$/#) else { return nil }
        return Int(match.1)
    }
}

protocol GrowthHandle: Actor {
    nonisolated var messages: AsyncStream<MaaMessage> { get }
    var running: Bool { get }
    func appendTask(type: MAATaskType, params: String) throws -> Int32
    func start() throws
}

extension MAAHandle: GrowthHandle {}

@MainActor enum OperatorGrowthSession {
    typealias Plan = (String, GrowthState, GrowthState, [String: Int], Set<String>) async throws -> GrowthPlan

    static func run(_ request: OperatorGrowthRequest, form: KoreanOperatorNames.GrowthCandidate, handle: any GrowthHandle,
                    stageActivity: StageActivityContext,
                    planRoute: Plan = OperatorGrowthPlanner.plan(name:current:target:inventory:allowedStages:),
                    waitForTraining: () async throws -> Void = { try await Task.sleep(for: .seconds(3600)) },
                    report: (String) -> Void) async throws {
        try Task.checkCancellation()
        let roots = KoreanInputResources.roots
        let supported = try await Task.detached { try GrowthStageCatalog.supported(in: roots) }.value
        var candidates = request.allowedStages.isEmpty ? supported : supported.intersection(request.allowedStages)
        func inspect(fallbackEXP: Int) async throws -> GrowthState {
            report("오퍼레이터 프로필에서 정예·레벨·스킬을 확인합니다.")
            let inspection = try await execute(.OperProgress, params: request.params(form: form, inspect: true), handle: handle)
            guard let profile = inspection.profile, profile.verified, profile.id == form.id, profile.name == form.name,
                  profile.mastery.count == 3 else {
                throw GrowthFailure("대상 오퍼레이터의 프로필을 확인할 수 없습니다.")
            }
            let selectedMastery = request.targetMastery > 0 ? profile.mastery[request.skill - 1] : 0
            return GrowthState(elite: profile.elite, level: profile.level, skillRank: profile.rank,
                               mastery: request.slots(selectedMastery), experience: profile.exp ?? fallbackEXP)
        }
        var current = try await inspect(fallbackEXP: request.currentExperience)
        let target = GrowthState(elite: request.elite, level: request.level, skillRank: min(request.skillLevel, 7),
                                 mastery: request.slots(request.targetMastery))
        var inaccessibleStages = 0
        var lastStock = [String: Int]()
        var expectedDrops = [String: Int]()
        var unreflected = [String: (fights: Int, count: Int)]()
        var manufacturedStock = [String: Int]()
        func progress(params: String) async throws -> [ProgressDetail] {
            while true {
                let result = try await execute(.OperProgress, params: params,
                                               handle: handle)
                let details = result.details.filter { $0.name == form.name }
                guard !details.isEmpty else { throw GrowthFailure("육성 결과를 확인할 수 없습니다.") }
                if details.contains(where: { $0.reason == "ChipManufacturing" }) {
                    guard !manufacturedStock.isEmpty else { throw GrowthFailure("제조소에서 듀얼 칩 수령 상태를 확인하세요.") }
                    report("듀얼 칩 생산을 시작했습니다. 창고에 반영된 뒤 정예화를 계속합니다.")
                    var delivered = false
                    for _ in 0..<3 {
                        let scan = try await execute(.Depot, handle: handle)
                        if let items = scan.inventory, manufacturedStock.allSatisfy({ items[$0.key, default: 0] >= $0.value }) {
                            delivered = true
                            break
                        }
                    }
                    guard delivered else { throw GrowthFailure("창고에 듀얼 칩이 도착하지 않았습니다. 제조소에서 수령 후 다시 시작하세요.") }
                    manufacturedStock.removeAll()
                    continue
                }
                for detail in details where detail.result != "Success" && detail.reason != "TrainingRoomBusy" {
                    throw GrowthFailure("본체의 육성 결과 · \(detail.reason)")
                }
                return details
            }
        }

        while true {
            report("창고를 확인하고 부족한 재료의 파밍 경로를 계산합니다.")
            let scan = try await execute(.Depot, handle: handle)
            guard let inventory = scan.inventory, !inventory.isEmpty else {
                throw GrowthFailure("창고에서 최종 재고를 읽을 수 없습니다.")
            }
            for (item, quantity) in expectedDrops {
                let previous = lastStock[item, default: 0]
                if inventory[item, default: 0] > previous {
                    unreflected[item] = nil
                } else {
                    var missing = unreflected[item, default: (0, 0)]
                    missing.fights += 1
                    missing.count += quantity
                    unreflected[item] = missing
                    // Depot can present quantities in abbreviated units such as 1.2만.
                    let precision = previous < 10_000 ? 1 : Int(pow(10, floor(log10(Double(previous))) - 1))
                    if missing.fights >= 3 && missing.count >= precision {
                        throw GrowthFailure("확인된 전리품(\(item))이 세 차례 이상 창고에 반영되지 않았습니다.")
                    }
                }
            }
            lastStock = inventory
            expectedDrops.removeAll()
            let openStages = FightStage.openForGrowth(candidates, at: .now, in: stageActivity)
            let plan = try await planRoute(form.id, current, target, inventory, openStages)
            try Task.checkCancellation()
            if !plan.missing.isEmpty {
                let names = await MAAProvider.shared.itemNames(for: plan.missing.keys)
                let missing = plan.missing.sorted { $0.key < $1.key }.map { item, quantity in
                    let name = names[item].flatMap { $0.isEmpty ? nil : $0 } ?? item
                    return "\(name) × \(quantity)"
                }
                throw GrowthFailure("선택한 스테이지와 합성으로 충당할 수 없는 재료 · " + missing.joined(separator: ", "))
            }
            guard let next = plan.runs.first else {
                for (item, count) in plan.manufacturedItems where count > 0 {
                    manufacturedStock[item] = inventory[item, default: 0] + count
                }
                if current.elite < request.elite {
                    let nextElite = current.elite + 1
                    report("정예 \(nextElite)단계로 승급합니다.")
                    let details = try await progress(params: request.params(form: form, promotion: nextElite))
                    guard details.contains(where: { $0.elite == nextElite && $0.level == 1 }) else {
                        throw GrowthFailure("정예 승급 결과를 확인할 수 없습니다.")
                    }
                    let promoted = try await inspect(fallbackEXP: 0)
                    guard promoted.elite == nextElite else { throw GrowthFailure("승급 후 프로필의 정예 단계가 일치하지 않습니다.") }
                    current = promoted
                    manufacturedStock.removeAll()
                    unreflected.removeAll()
                    continue
                }
                break
            }
            guard openStages.contains(next.stage), next.times > 0 else {
                throw GrowthFailure("파밍 계획의 스테이지 또는 횟수가 유효하지 않습니다.")
            }
            // A single battle makes the next decision depend on actual drops and remaining sanity.
            let estimate = plan.integerOptimal ? "평균 드롭 기준 최소" : "평균 드롭 기준 예상"
            report("\(next.stage) 1회 파밍 · 이 스테이지 예상 \(next.times)회 · 전체 \(estimate) 이성 \(plan.sanity)")
            let chapter = GrowthStageCatalog.chapter(of: next.stage)
            let stage = (chapter ?? 0) >= 10 ? next.stage + "-Normal" : next.stage
            let params = try growthJSON(["stage": stage, "times": 1, "series": 1, "medicine": 0,
                                         "stone": 0, "medicine_expire_days": 0, "server": "KR", "client_type": "YoStarKR"])
            let fight: Evidence
            do {
                fight = try await execute(.Fight, params: params, handle: handle)
            } catch is StageNavigationFailed where request.allowedStages.isEmpty && inaccessibleStages < 3 {
                candidates.remove(next.stage)
                inaccessibleStages += 1
                report("\(next.stage)에 진입하지 못해 이번 실행에서 제외합니다.")
                continue
            } catch {
                try Task.checkCancellation()
                throw GrowthFailure("\(next.stage) 파밍 중단 · \(error.localizedDescription) 대리 지휘 가능한 스테이지를 지정해 다시 시작하세요.")
            }
            guard let drops = fight.stageDrops[next.stage] else {
                throw GrowthFailure("\(next.stage) 전투 결과를 확인할 수 없습니다. 이성과 대리 지휘 상태를 확인하세요.")
            }
            expectedDrops = drops.filter { next.trackedItems.contains($0.key) && $0.value > 0 }
            if next.trackedItems == ["4001"] && expectedDrops.isEmpty && next.guaranteedLMD > 0 {
                // Base battle LMD is credited even when absent from the drop list.
                expectedDrops["4001"] = next.guaranteedLMD
            }
        }

        var masteryOnly = false
        while true {
            report(masteryOnly ? "훈련실에서 전문화 진행 상태를 확인합니다." : "대상 오퍼레이터의 정예·레벨·스킬을 올립니다.")
            let details = try await progress(params: request.params(form: form, masteryOnly: masteryOnly))
            if !masteryOnly {
                guard details.contains(where: { $0.elite == request.elite && $0.level == request.level }),
                      request.skillLevel < 2 || details.contains(where: { $0.rank == min(request.skillLevel, 7) }) else {
                    throw GrowthFailure("목표 정예 단계, 레벨 또는 공통 스킬 레벨을 확인할 수 없습니다.")
                }
            }
            if request.targetMastery == 0 { return }
            if details.contains(where: { $0.reason == "AlreadySatisfied" &&
                ($0.mastery.count == 3 && $0.mastery[request.skill - 1] >= request.targetMastery) }) { return }
            guard details.contains(where: { $0.reason == "TrainingRoomBusy" ||
                ($0.mastery.count == 3 && ($0.reason == "Completed" || $0.reason == "PrerequisiteTraining")) }) else {
                throw GrowthFailure("전문화 훈련 상태를 확인할 수 없습니다.")
            }
            report("훈련 중입니다. 한 시간 뒤 훈련실을 다시 확인합니다.")
            masteryOnly = true
            try await waitForTraining()
        }
    }

    private struct Evidence {
        var inventory: [String: Int]?
        var profile: Profile?
        var stageDrops = [String: [String: Int]]()
        var details: [ProgressDetail] = []
    }

    private struct Profile {
        let id, name: String
        let verified: Bool
        let elite, level, rank: Int
        let exp: Int?
        let mastery: [Int]
    }

    private struct ProgressDetail {
        let name: String
        let result: String
        let reason: String
        let elite: Int?
        let level: Int?
        let rank: Int?
        let mastery: [Int]
    }

    private static func execute(_ type: MAATaskType, params: String = "{}", handle: any GrowthHandle) async throws -> Evidence {
        // AllTasksCompleted is emitted before the core's worker returns to idle.
        while await handle.running { try await Task.sleep(for: .milliseconds(100)) }
        try Task.checkCancellation()
        let id = try await handle.appendTask(type: type, params: params)
        try Task.checkCancellation()
        try await handle.start()
        var result = Evidence()
        var completed = false
        var navigationFailed = false
        var battleObserved = false
        for await message in handle.messages {
            try Task.checkCancellation()
            let info = message.details
            if message.code == .ConnectionInfo, (try? info["what"] as String) == "Disconnect" {
                throw GrowthFailure("에뮬레이터 연결이 끊어졌습니다.")
            }
            if message.code == .TaskChainStopped { throw CancellationError() }
            guard (try? info["taskid"] as Int32) == id else { continue }
            switch message.code {
            case .SubTaskError:
                if (try? info["subtask"] as String) == "StageNavigationTask" { navigationFailed = true }
            case .SubTaskStart:
                if let node: String = try? info["details"]["task"],
                   ["StartButton1", "StartButton2", "AnnihilationConfirm", "EndOfAction"].contains(node) {
                    battleObserved = true
                }
            case .TaskChainError:
                if type == .Fight && navigationFailed && !battleObserved { throw StageNavigationFailed() }
                throw GrowthFailure("\(type.description) 작업에 실패했습니다.")
            case .TaskChainCompleted:
                completed = true
            case .AllTasksCompleted:
                guard completed else { throw GrowthFailure("\(type.description) 작업 결과가 누락됐습니다.") }
                return result
            case .SubTaskExtraInfo:
                let details: JSON = try info["details"]
                switch (try? info["what"] as String) {
                case "DepotInfo":
                    let scan = try MAADepot(json: details)
                    if scan.done { result.inventory = scan.items }
                case "OperProgressInspection":
                    result.profile = .init(id: try details["id"], name: try details["name"], verified: try details["verified"],
                                           elite: try details["elite"], level: try details["level"], rank: try details["skill_level"],
                                           exp: try? details["exp"], mastery: try details["skill_mastery"])
                case "StageDrops":
                    battleObserved = true
                    if let code: String = try? details["stage"]["stageCode"], (try? details["stars"] as Int) == 3 {
                        let rows: [JSON] = try details["drops"]
                        var items = [String: Int]()
                        for row in rows {
                            let id: String = try row["itemId"]
                            let count: Int = try row["quantity"]
                            if count > 0 { items[id, default: 0] += count }
                        }
                        result.stageDrops[code] = items
                    }
                case "OperProgressDetail":
                    result.details.append(.init(name: try details["name"], result: try details["result"],
                                                reason: try details["result_detail"], elite: try? details["elite"],
                                                level: try? details["level"], rank: try? details["skill_level"],
                                                mastery: (try? details["skill_mastery"]) ?? []))
                default:
                    break
                }
            default:
                break
            }
        }
        try Task.checkCancellation()
        throw GrowthFailure("본체의 응답이 끊어졌습니다.")
    }
}
