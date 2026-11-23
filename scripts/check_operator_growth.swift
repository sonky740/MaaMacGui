import Foundation

@main
enum CheckOperatorGrowth {
    static func main() async throws {
        try sharedDropsAndWorkshop()
        if let path = CommandLine.arguments.dropFirst().first {
            let dir = URL(fileURLWithPath: path)
            let data = try await GrowthData.load(game: dir, statistics: dir)
            try narantuya(data)
            print("KR Narantuya promotion, EXP, LMD, skill, mastery and farming checks passed")
        }
        print("Offline stage, inventory, recipe and mastery checks passed")
    }

    static let current = GrowthState(elite: 0, level: 1, skillRank: 1, mastery: [0, 0, 0])
    static func sharedDropsAndWorkshop() throws {
        let cost = [GrowthData.Item(id: "A", count: 4), .init(id: "B", count: 2)]
        let upgrade = GrowthData.Upgrade(unlockCond: .init(phase: "PHASE_0", level: 1), lvlUpCost: cost, levelUpCost: nil)
        let op = GrowthData.Character(name: "테스트", rarity: "TIER_2", isNotObtainable: false,
                                      phases: [.init(maxLevel: 10, evolveCost: nil)], skills: [], allSkillLvlup: [upgrade])
        let codes = ["A", "B", "AB", "CLOSED", "TOUGH", "OLD", "LOW", "DOUBLE", "TRIPLE"]
        let stageCosts = [4, 4, 5, 1, 1, 1, 1, 7, 10]
        let drops = ["A": ["A"], "B": ["B"], "AB": ["A", "B"], "CLOSED": ["A","B"],
                     "TOUGH": ["A","B"], "OLD": ["A","B"], "LOW": ["A","B"], "DOUBLE": ["A"], "TRIPLE": ["A"]]
        var stages = [String: GrowthData.Stage]()
        var metadata = [GrowthData.PenguinStage]()
        var matrix = [GrowthData.Drop]()
        for (code, ap) in zip(codes, stageCosts) {
            stages[code] = .init(code: code, difficulty: "NORMAL", diffGroup: code == "TOUGH" ? "TOUGH" : "NONE",
                                 canBattleReplay: true, apCost: ap, goldGain: 0)
            metadata.append(.init(stageId: code, code: code, existence: ["KR": .init(exist: code != "CLOSED", openTime: nil, closeTime: nil)]))
            for item in drops[code]! {
                matrix.append(.init(stageId: code, itemId: item, times: code == "LOW" ? 1 : 100,
                                    quantity: ["DOUBLE": 200, "TRIPLE": 300][code] ?? 100, start: 0, end: code == "OLD" ? 1 : nil))
            }
        }
        let recipe = GrowthData.Recipe(itemId: "A", formulaType: "F_EVOLVE", count: 2,
                                       costs: [.init(id: "C", count: 1)], goldCost: 0)
        let data = GrowthData(characters: ["char_test": op], constants: .init(characterExpMap: [], characterUpgradeCostMap: [], evolveGoldCost: [[], []], completeGainBonus: 1.2),
                              building: .init(workshopFormulas: ["a": recipe], manufactFormulas: [:]), items: .init(expItems: [:]),
                              stages: .init(stages: stages), penguinStages: metadata, matrix: .init(matrix: matrix))
        let target = GrowthState(elite: 0, level: 1, skillRank: 2, mastery: [0, 0, 0])
        func plan(_ allowed: Set<String>, _ inventory: [String: Int]) throws -> GrowthPlan {
            try OperatorGrowthPlanner.plan(data: data, name: "테스트", current: current, target: target, inventory: inventory, allowedStages: allowed)
        }
        let shared = try plan(Set(codes), ["C": 1])
        precondition(shared.missing.isEmpty && shared.runs.count == 1 && shared.runs[0].stage == "AB" && shared.runs[0].times == 2)
        precondition(shared.crafts == ["A": 1])
        let lastItem = try plan(["A", "DOUBLE"], ["A": 3, "B": 2])
        precondition(lastItem.runs.count == 1 && lastItem.runs[0].stage == "A" && lastItem.runs[0].times == 1)
        let twoItems = try plan(["A", "TRIPLE"], ["A": 2, "B": 2])
        precondition(twoItems.integerOptimal && twoItems.runs.count == 1 &&
                     twoItems.runs[0].stage == "A" && twoItems.runs[0].times == 2)
        let prices = Dictionary(uniqueKeysWithValues: zip(codes, stageCosts))
        for needA in 0...4 {
            for needB in 0...2 {
                let route = try plan(["A", "B", "AB", "TRIPLE"], ["A": 4 - needA, "B": 2 - needB])
                var minimum = Int.max
                for shared in 0...4 {
                    for triple in 0...2 {
                        let singles = max(0, needA - shared - 3 * triple) + max(0, needB - shared)
                        minimum = min(minimum, 5 * shared + 10 * triple + 4 * singles)
                    }
                }
                precondition(route.integerOptimal && route.runs.reduce(0) { $0 + $1.times * prices[$1.stage]! } == minimum)
            }
        }
        let enough = try plan([], ["A": 4, "B": 2])
        precondition(enough.runs.isEmpty && enough.crafts.isEmpty && enough.missing.isEmpty)
        let unavailable = try plan(["B"], [:])
        precondition(unavailable.missing == ["C": 2] && unavailable.runs[0].stage == "B")
        // A joint drop covers B while yielding half of A. Rounding an A craft needs an extra intermediate C.
        let nested = GrowthData(characters: data.characters, constants: data.constants,
            building: .init(workshopFormulas: [
                "a": .init(itemId: "A", formulaType: "F_EVOLVE", count: 1, costs: [.init(id: "C", count: 3)], goldCost: 0),
                "c": .init(itemId: "C", formulaType: "F_EVOLVE", count: 1, costs: [.init(id: "D", count: 1)], goldCost: 0)
            ], manufactFormulas: [:]), items: data.items, stages: data.stages, penguinStages: metadata,
            matrix: .init(matrix: [.init(stageId: "AB", itemId: "A", times: 100, quantity: 50, start: 0, end: nil),
                                   .init(stageId: "AB", itemId: "B", times: 100, quantity: 100, start: 0, end: nil)]))
        let chain = try OperatorGrowthPlanner.plan(data: nested, name: "테스트", current: current, target: target,
            inventory: ["A": 3, "B": 1, "D": 3], allowedStages: ["AB"])
        precondition(chain.integerOptimal && chain.sanity == 5 && chain.missing.isEmpty && chain.crafts == ["A": 1, "C": 3])
        do {
            _ = try data.requirements(name: "테스트", current: current, target: .init(elite: 0, level: 1, skillRank: 2, mastery: [1, 0, 0]))
            preconditionFailure("Mastery requires an available skill and the required elite rank")
        } catch is GrowthError {}
    }

    static func narantuya(_ data: GrowthData) throws {
        let target = GrowthState(elite: 2, level: 60, skillRank: 7, mastery: [0, 0, 0])
        let required = try data.requirements(name: "나란투야", current: current, target: target)
        precondition(required["EXP"] == 588286 && required["4001"] == 761409)
        precondition(required["3301"] == 10 && required["3302"] == 24 && required["3303"] == 8)
        let targetMastery = GrowthState(elite: 2, level: 60, skillRank: 7, mastery: [3, 0, 0])
        let mastery = try data.requirements(name: "나란투야", current: target, target: targetMastery)
        precondition(mastery["3303"] == 35 && mastery["4001"] == nil)
        let stages = Set(data.penguinStages.map(\.code))
        let route = try OperatorGrowthPlanner.plan(data: data, name: "나란투야", current: current, target: target,
                                                  inventory: [:], allowedStages: stages)
        precondition(route.missing == ["32001": 4] && route.runs.contains { $0.stage.hasPrefix("CE-") })
        let inventory = required.filter { $0.key != "EXP" }.merging(["2004": 295], uniquingKeysWith: +)
        let stocked = try OperatorGrowthPlanner.plan(data: data, name: "나란투야", current: current, target: target,
                                                    inventory: inventory, allowedStages: [])
        precondition(stocked.runs.isEmpty && stocked.missing.isEmpty && stocked.crafts.isEmpty)
        var otherClassChips = inventory
        otherClassChips["3241"] = 0
        otherClassChips["3251"] = 12
        let chips = try OperatorGrowthPlanner.plan(data: data, name: "나란투야", current: current, target: target,
                                                  inventory: otherClassChips, allowedStages: [])
        precondition(chips.missing == ["3241": 5] && chips.crafts.isEmpty)
        var factoryStock = inventory
        factoryStock["3243"] = 2
        factoryStock["3242"] = 4
        factoryStock["32001"] = 1
        factoryStock["4006"] = 10_000
        let shortage = try OperatorGrowthPlanner.plan(data: data, name: "나란투야", current: current, target: target,
                                                     inventory: factoryStock, allowedStages: [])
        precondition(shortage.missing == ["32001": 1] && shortage.manufacturedItems == ["3243": 2])
        factoryStock["32001"] = 2
        let supplied = try OperatorGrowthPlanner.plan(data: data, name: "나란투야", current: current, target: target,
                                                     inventory: factoryStock, allowedStages: [])
        precondition(supplied.missing.isEmpty && supplied.runs.isEmpty && supplied.manufacturedItems == ["3243": 2])
    }
}
