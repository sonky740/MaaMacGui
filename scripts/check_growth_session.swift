// Link the Debug build's MAA.debug.dylib and import its modules to run this replay without starting MAA.
import Foundation
import JBirdCore
@testable import MAA

private enum Replay: Error { case unexpectedStep }

private actor ReplayHandle: GrowthHandle {
    nonisolated let messages: AsyncStream<MaaMessage>
    private let continuation: AsyncStream<MaaMessage>.Continuation
    var running: Bool { false }
    typealias Step = (MAATaskType, [String: Any]) throws -> [(String, [String: Any])]
    private let steps: [Step]
    private(set) var count: Int32 = 0
    private var task: (MAATaskType, String)?

    init(_ steps: [Step]) {
        (messages, continuation) = AsyncStream.makeStream()
        self.steps = steps
    }

    func appendTask(type: MAATaskType, params: String) throws -> Int32 {
        task = (type, params)
        count += 1
        return count
    }

    func start() throws {
        guard let (type, params) = task, Int(count) <= steps.count else { throw Replay.unexpectedStep }
        let json = try JSONSerialization.jsonObject(with: Data(params.utf8)) as! [String: Any]
        let payloads = try steps[Int(count) - 1](type, json)
        func emit(_ code: Int, _ fields: [String: Any], id: Int32) throws {
            var body = fields
            body["taskid"] = id
            body["taskchain"] = type.rawValue
            let data = try JSONSerialization.data(withJSONObject: body)
            continuation.yield(.init(code: code, details: try JSON(data)))
        }
        try emit(.TaskChainError, [:], id: count + 100)
        for (what, data) in payloads {
            if what == "test:started" {
                try emit(.SubTaskStart, ["subtask": "ProcessTask", "details": ["task": "StartButton2"]], id: count)
                continue
            }
            if what == "test:navigation" {
                try emit(.SubTaskError, ["subtask": "StageNavigationTask"], id: count)
                try emit(.TaskChainError, [:], id: count)
                return
            }
            try emit(.SubTaskExtraInfo, ["what": what, "details": data], id: count)
        }
        try emit(.TaskChainCompleted, [:], id: count)
        try emit(.AllTasksCompleted, ["finished_tasks": [count]], id: count)
    }
}

@main enum CheckGrowthSession {
    private static let op = KoreanOperatorNames.GrowthCandidate(id: "char_test", name: "测试", role: "Sniper", branch: "test")
    private static func request(_ rank: Int = 9) -> OperatorGrowthRequest {
        .init(name: "테스트", formID: "", elite: 2, level: 60, skill: 2, skillLevel: rank,
              currentExperience: 0, allowedStages: [])
    }

    private static func inspect(_ verified: Bool = true, elite: Int = 2, level: Int = 59, exp: Int = 42) -> ReplayHandle.Step {
        { type, args in
            precondition(type == .OperProgress && args["inspect_only"] as? Bool == true)
            let plan = (args["plans"] as! [[String: Any]])[0]
            precondition(plan["role"] as? String == op.role && plan["name"] as? String == op.name)
            return [("OperProgressInspection", ["id": op.id, "name": op.name, "verified": verified, "elite": elite, "level": level,
                                               "skill_level": 7, "exp": exp, "skill_mastery": [-1, 0, -1]])]
        }
    }

    private static func depot(_ quantity: Int, cash: Int = 100) -> ReplayHandle.Step {
        { type, _ in
            precondition(type == .Depot)
            return [("DepotInfo", ["done": false, "data": ["part": 9999]]),
                    ("DepotInfo", ["done": true, "data": ["part": quantity, "4001": cash]])]
        }
    }

    private static let fight: ReplayHandle.Step = { type, args in
        precondition(type == .Fight && args["stage"] as? String == "1-7")
        for field in ["medicine", "stone", "medicine_expire_days"] { precondition(args[field] as? Int == 0) }
        precondition(args["times"] as? Int == 1 && args["series"] as? Int == 1)
        return [("StageDrops", ["stage": ["stageCode": "1-7"], "stars": 3, "drops": [["itemId":"part", "quantity":1]]])]
    }

    private static func progress(_ reason: String, mastery: Int, full: Bool) -> ReplayHandle.Step {
        { type, args in
            precondition(type == .OperProgress)
            let plan = (args["plans"] as! [[String: Any]])[0]
            precondition(plan["allow_chip_purchase"] as? Bool == false && plan["skill_mastery"] as? [Int] == [0, 2, 0])
            var evidence = [(String, [String: Any])]()
            if full {
                precondition(plan["elite"] as? Int == 2 && plan["level"] as? Int == 60 && plan["skill_level"] as? Int == 7)
                evidence += [("OperProgressDetail", ["name": op.name, "result": "Success", "result_detail": "Completed", "elite": 2, "level": 60]),
                             ("OperProgressDetail", ["name": op.name, "result": "Success", "result_detail": "AlreadySatisfied", "skill_level": 7])]
            } else { precondition(plan["elite"] == nil && plan["skill_level"] == nil) }
            evidence.append(("OperProgressDetail", ["name": op.name, "result": "Success", "result_detail": reason,
                                                    "skill_mastery": [0, mastery, 0]]))
            return evidence
        }
    }

    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"Episode1":{}}"#.utf8).write(to: root.appendingPathComponent("tasks.json"))
        try Data(#"[{"code":"1-7","dropInfos":[]},{"code":"EX-1","dropInfos":[]}]"#.utf8)
            .write(to: root.appendingPathComponent("stages.json"))
        KoreanInputResources.record(root, base: true, reset: true, koreanServer: true)
        let ctx = StageActivityContext(channel: .YoStarKR, activities: nil)
        let route: OperatorGrowthSession.Plan = { id, current, target, inventory, allowed in
            precondition(id == op.id && current.level == 59 && current.experience == 42 && current.mastery == [0,0,0])
            precondition(target.level == 60 && target.mastery == [0,2,0] && allowed == ["1-7"])
            return .init(runs: inventory["part"] == 0 ? [.init(stage: "1-7", times: 1, trackedItems: ["part"])] : [], missing: [:],
                         required: ["part": 1], crafts: [:])
        }
        let handle = ReplayHandle([inspect(), depot(0), fight, depot(1), progress("PrerequisiteTraining", mastery: 1, full: true),
                                   progress("Completed", mastery: 2, full: false), progress("AlreadySatisfied", mastery: 2, full: false)])
        var waits = 0
        try await OperatorGrowthSession.run(request(), form: op, handle: handle, stageActivity: ctx, planRoute: route,
                                            waitForTraining: { waits += 1 }, report: { _ in })
        let count = await handle.count
        precondition(count == 7 && waits == 2)

        let bad = ReplayHandle([inspect(false)])
        do {
            try await OperatorGrowthSession.run(request(), form: op, handle: bad, stageActivity: ctx,
                                                planRoute: route, report: { _ in })
            preconditionFailure("Unverified operator accepted")
        } catch { precondition(error.localizedDescription.contains("프로필")) }
        let countBad = await bad.count
        precondition(countBad == 1)
        let stale = ReplayHandle([inspect(), depot(0), fight, depot(0, cash: 101), fight, depot(0, cash: 102),
                                  fight, depot(0, cash: 103)])
        do {
            try await OperatorGrowthSession.run(request(), form: op, handle: stale, stageActivity: ctx,
                                                planRoute: route, report: { _ in })
            preconditionFailure("Unreflected drops were ignored")
        } catch { precondition(error.localizedDescription.contains("전리품")) }
        let countStale = await stale.count
        precondition(countStale == 8)

        let dryFight: ReplayHandle.Step = { type, _ in
            precondition(type == .Fight)
            return [("StageDrops", ["stage": ["stageCode": "1-7"], "stars": 3, "drops": []])]
        }
        let dry = ReplayHandle([inspect(), depot(0), dryFight, depot(0), dryFight, depot(0),
                                dryFight, depot(0), fight, depot(1), progress("AlreadySatisfied", mastery: 2, full: true)])
        try await OperatorGrowthSession.run(request(), form: op, handle: dry, stageActivity: ctx,
                                            planRoute: route, report: { _ in })
        let income: OperatorGrowthSession.Plan = { _, _, _, _, _ in
            .init(runs: [.init(stage: "1-7", times: 8, trackedItems: ["4001"], guaranteedLMD: 10_000)],
                  missing: [:], required: ["4001": 900_000], crafts: [:])
        }
        let blockedIncome = ReplayHandle([inspect(), depot(0, cash: 500_000), dryFight, depot(0, cash: 500_000),
                                         dryFight, depot(0, cash: 500_000), dryFight, depot(0, cash: 500_000)])
        do {
            try await OperatorGrowthSession.run(request(), form: op, handle: blockedIncome, stageActivity: ctx,
                                                planRoute: income, report: { _ in })
            preconditionFailure("Missing guaranteed LMD was ignored")
        } catch { precondition(error.localizedDescription.contains("4001")) }
        let pocketChange: OperatorGrowthSession.Plan = { _, _, _, inventory, _ in
            .init(runs: inventory["4001"] == 500_000 ? [.init(stage: "1-7", times: 8, trackedItems: ["4001"], guaranteedLMD: 216)] : [],
                  missing: [:], required: ["4001": 502_000], crafts: [:])
        }
        let rounded = ReplayHandle([inspect(), depot(0, cash: 500_000), dryFight, depot(0, cash: 500_000),
                                    dryFight, depot(0, cash: 500_000), dryFight, depot(0, cash: 500_000),
                                    dryFight, depot(0, cash: 501_000), progress("AlreadySatisfied", mastery: 2, full: true)])
        try await OperatorGrowthSession.run(request(), form: op, handle: rounded, stageActivity: ctx,
                                            planRoute: pocketChange, report: { _ in })

        let promoted: ReplayHandle.Step = { type, args in
            precondition(type == .OperProgress)
            let plan = (args["plans"] as! [[String: Any]])[0]
            precondition(plan["elite"] as? Int == 2 && plan["level"] as? Int == 1)
            precondition(plan["skill_level"] == nil && plan["skill_mastery"] == nil)
            return [("OperProgressDetail", ["name": op.name, "result": "Success", "result_detail": "Completed", "elite": 2, "level": 1])]
        }
        func cards(_ remaining: Int) -> ReplayHandle.Step {
            { type, _ in
                precondition(type == .Depot)
                return [("DepotInfo", ["done": true, "data": ["2004": remaining, "4001": 999_999]])]
            }
        }
        let expDrop: ReplayHandle.Step = { type, _ in
            precondition(type == .Fight)
            return [("StageDrops", ["stage": ["stageCode": "1-7"], "stars": 3,
                                    "drops": [["itemId": "2004", "quantity": 1]]])]
        }
        let reprice: OperatorGrowthSession.Plan = { _, current, target, inventory, _ in
            precondition(target.elite == 2 && target.level == 60)
            let requiredExp = current.elite == 1 ? 2000 : 1200
            precondition(current.experience == (current.elite == 1 ? 100 : 0))
            let ranShort = inventory["2004"]! * 2000 < requiredExp
            return .init(runs: ranShort ? [.init(stage: "1-7", times: 1, trackedItems: ["2004"])] : [],
                         missing: [:], required: ["EXP": requiredExp], crafts: [:])
        }
        let sparse = ReplayHandle([inspect(elite: 1, level: 79, exp: 100), cards(1), promoted, inspect(elite: 2, level: 1, exp: 0),
                                   cards(0), expDrop, cards(1), progress("AlreadySatisfied", mastery: 2, full: true)])
        try await OperatorGrowthSession.run(request(), form: op, handle: sparse, stageActivity: ctx,
                                            planRoute: reprice, report: { _ in })

        let navFailure: ReplayHandle.Step = { type, _ in
            precondition(type == .Fight)
            return [("test:navigation", [:])]
        }
        let autoReroute: OperatorGrowthSession.Plan = { _, _, _, _, allowed in
            .init(runs: allowed.contains("1-7") ? [.init(stage: "1-7", times: 1)] : [], missing: [:], required: [:], crafts: [:])
        }
        let locked = ReplayHandle([inspect(), depot(0), navFailure, depot(0), progress("AlreadySatisfied", mastery: 2, full: true)])
        var reports = [String]()
        try await OperatorGrowthSession.run(request(), form: op, handle: locked, stageActivity: ctx,
                                            planRoute: autoReroute, report: { reports.append($0) })
        precondition(reports.contains(where: { $0.contains("1-7") && $0.contains("제외") }))
        let ambiguous = ReplayHandle([inspect(), depot(0), { _, _ in [("test:started", [:]), ("test:navigation", [:])] }])
        do {
            try await OperatorGrowthSession.run(request(), form: op, handle: ambiguous, stageActivity: ctx,
                                                planRoute: autoReroute, report: { _ in })
            preconditionFailure("Retried an ambiguous failure after combat began")
        } catch { precondition(error.localizedDescription.contains("파밍 중단")) }
        let pending: ReplayHandle.Step = { type, _ in
            precondition(type == .OperProgress)
            return [("OperProgressDetail", ["name": op.name, "result": "Skipped", "result_detail": "ChipManufacturing"])]
        }
        let noCombat: OperatorGrowthSession.Plan = { _, _, _, _, _ in
            .init(runs: [], missing: [:], required: ["part": 2], crafts: ["part": 2], manufacturedItems: ["part": 2])
        }
        let chips = ReplayHandle([inspect(), depot(0), pending, depot(1), depot(2),
                                  progress("AlreadySatisfied", mastery: 2, full: true)])
        try await OperatorGrowthSession.run(request(), form: op, handle: chips, stageActivity: ctx,
                                            planRoute: noCombat, report: { _ in })
        let countChips = await chips.count
        precondition(countChips == 6)
        let uncollected = ReplayHandle([inspect(), depot(0), pending, depot(0), depot(0), depot(0)])
        do {
            try await OperatorGrowthSession.run(request(), form: op, handle: uncollected, stageActivity: ctx,
                                                planRoute: noCombat, report: { _ in })
            preconditionFailure("Duplicate chip order accepted")
        } catch { precondition(error.localizedDescription.contains("수령")) }
        let countUncollected = await uncollected.count
        precondition(countUncollected == 6)
        print("Growth queue replay passed: strict inspection, one fight, real depot replan, waiting for verified mastery, stale loot, blocked routes, delayed and uncollected chips.")
    }
}
