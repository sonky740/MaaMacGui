import Foundation

struct GrowthRun {
    let stage: String
    let times: Int
    var trackedItems: Set<String> = []
    var guaranteedLMD = 0
}

struct GrowthPlan {
    let runs: [GrowthRun]
    let missing, required, crafts: [String: Int]
    var manufacturedItems: [String: Int] = [:]
    var integerOptimal = false
    var sanity = 0
}

private actor GrowthDataCache {
    static let shared = GrowthDataCache()
    private var snapshot: (Date, GrowthData)?
    func get() async throws -> GrowthData {
        if let (time, data) = snapshot, Date().timeIntervalSince(time) < 3600 { return data }
        let game = URL(string: "https://raw.githubusercontent.com/Kengxxiao/ArknightsGameData_YoStar/main/ko_KR/gamedata/excel")!
        let stats = URL(string: "https://penguin-stats.io/PenguinStats/api/v2")!
        let data = try await GrowthData.load(game: game, statistics: stats)
        snapshot = (Date(), data)
        return data
    }
}

enum OperatorGrowthPlanner {
    private struct Action {
        enum Kind { case fight, craft, missing }
        let kind: Kind
        let name: String
        let cost: Double
        var yield: [String: Double]
        var trackedItems: Set<String> = []
    }

    static func plan(name: String, current: GrowthState, target: GrowthState, inventory: [String: Int],
                     allowedStages: Set<String>) async throws -> GrowthPlan {
        let data = try await GrowthDataCache.shared.get()
        return try plan(data: data, name: name, current: current, target: target,
                        inventory: inventory, allowedStages: allowedStages)
    }

    static func plan(data: GrowthData, name: String, current: GrowthState, target: GrowthState,
                     inventory: [String: Int], allowedStages: Set<String>, now: Date = Date()) throws -> GrowthPlan {
        let required = try data.requirements(name: name, current: current, target: target)
        guard inventory.values.allSatisfy({ (0...999_999_999).contains($0) }) else { throw GrowthError("재고 수량이 올바르지 않습니다.") }
        var balance = inventory.mapValues(Double.init)
        for (card, value) in data.items.expItems {
            balance["EXP", default: 0] += (balance.removeValue(forKey: card) ?? 0) * Double(value.gainExp)
        }
        for (item, amount) in required { balance[item, default: 0] -= Double(amount) }
        let expenses = Set(required.keys)
        // OperProgress can manufacture dual chips but cannot exchange one class's chips for another's.
        let recipes = data.building.workshopFormulas.values.filter { ["F_EVOLVE", "F_SKILL"].contains($0.formulaType) }
                    + data.building.manufactFormulas.values.filter { $0.formulaType == "F_ASC" }
        var relevant = expenses
        var previous: Set<String>
        repeat {
            previous = relevant
            for recipe in recipes where relevant.contains(recipe.itemId) {
                relevant.formUnion(recipe.costs.map(\.id))
                if (recipe.goldCost ?? 0) > 0 { relevant.insert("4001") }
            }
        } while relevant != previous
        let items = relevant.sorted()
        let timestamp = now.timeIntervalSince1970 * 1000
        var stages: [String: Action] = [:]
        for s in data.penguinStages {
            guard allowedStages.contains(s.code), let region = s.existence["KR"], region.exist,
                  region.openTime.map({ $0 <= timestamp }) ?? true, region.closeTime.map({ timestamp < $0 }) ?? true,
                  let stage = data.stages.stages[s.stageId], stage.code == s.code, stage.canBattleReplay,
                  stage.difficulty == "NORMAL", ["NONE", "NORMAL"].contains(stage.diffGroup), stage.apCost > 0 else { continue }
            stages[s.stageId] = Action(kind: .fight, name: s.code, cost: Double(stage.apCost),
                                       yield: relevant.contains("4001") ? ["4001": floor(Double(stage.goldGain) * data.constants.completeGainBonus)] : [:])
        }
        let codeCounts = Dictionary(grouping: stages.values, by: \.name).mapValues(\.count)
        stages = stages.filter { codeCounts[$0.value.name] == 1 }
        for drop in data.matrix.matrix where stages[drop.stageId] != nil && drop.start <= timestamp &&
            (drop.end.map { timestamp < $0 } ?? true) && drop.times >= 30 && drop.quantity > 0 {
            let exp = data.items.expItems[drop.itemId]
            let item = exp == nil ? drop.itemId : "EXP"
            guard item != "4001", relevant.contains(item) else { continue }
            let amount = Double(drop.quantity) / Double(drop.times)
            stages[drop.stageId]?.yield[item, default: 0] += amount * Double(exp?.gainExp ?? 1)
            stages[drop.stageId]?.trackedItems.insert(drop.itemId)
        }
        var actions = stages.values.filter { $0.yield.values.contains { $0 > 0 } }.sorted { $0.name < $1.name }
        for recipe in recipes.sorted(by: { $0.itemId < $1.itemId }) where relevant.contains(recipe.itemId) && !recipe.costs.isEmpty {
            var yields = [recipe.itemId: Double(recipe.count)]
            for cost in recipe.costs { yields[cost.id, default: 0] -= Double(cost.count) }
            if let gold = recipe.goldCost, gold > 0 { yields["4001", default: 0] -= Double(gold) }
            actions.append(Action(kind: .craft, name: recipe.itemId, cost: 0, yield: yields))
        }
        // A costly external acquisition exposes ingredients that no allowed stage or recipe supplies.
        let produced = Set(actions.flatMap { $0.yield.filter { $0.value > 0 }.keys })
        var external = relevant.subtracting(produced)
        var reachable = external.union(actions.filter { $0.kind == .fight }.flatMap { $0.yield.keys })
        repeat {
            previous = reachable
            for recipe in recipes where recipe.costs.allSatisfy({ reachable.contains($0.id) }) {
                reachable.insert(recipe.itemId)
            }
        } while previous != reachable
        external.formUnion(relevant.subtracting(reachable))
        actions += external.sorted().map { Action(kind: .missing, name: $0, cost: 1e8, yield: [$0: 1]) }
        let initialBalance = balance
        var counts = Array(repeating: 0, count: actions.count)
        func book(_ index: Int, count: Int) {
            counts[index] += count
            for (item, yield) in actions[index].yield { balance[item, default: 0] += Double(count) * yield }
        }
        // Rounding a parent recipe can require additional crafts of an already rounded ingredient.
        for _ in 0...recipes.count {
            guard items.contains(where: { balance[$0, default: 0] < -1e-6 }) else { break }
            let amounts = try solve(actions: actions, items: items, balance: balance)
            for (index, amount) in amounts.enumerated() where amount > 1e-7 {
                book(index, count: Int(ceil(amount - 1e-7)))
            }
        }
        guard items.allSatisfy({ balance[$0, default: 0] >= -1e-6 }) else { throw GrowthError("합성 수량의 반올림 오차를 해소하지 못했습니다.") }
        let optimal = refineIntegerPlan(actions: actions, items: items, balance: initialBalance, counts: &counts)
        var runs: [GrowthRun] = []
        var crafts: [String: Int] = [:]
        var missing: [String: Int] = [:]
        var manufactured: [String: Int] = [:]
        let factoryProducts = Set(data.building.manufactFormulas.values.filter { $0.formulaType == "F_ASC" }.map(\.itemId))
        for (index, count) in counts.enumerated() where count > 0 {
            let action = actions[index]
            switch action.kind {
            case .fight:
                let tracked = action.trackedItems.isEmpty && action.yield["4001", default: 0] > 0
                    ? Set(["4001"]) : action.trackedItems
                runs.append(.init(stage: action.name, times: count, trackedItems: tracked,
                                  guaranteedLMD: Int(action.yield["4001", default: 0])))
            case .craft:
                crafts[action.name, default: 0] += count
                if factoryProducts.contains(action.name) {
                    manufactured[action.name, default: 0] += count * Int(action.yield[action.name, default: 0])
                }
            case .missing: missing[action.name, default: 0] += count
            }
        }
        let sanity = zip(actions, counts).reduce(0) { sum, entry in
            sum + (entry.0.kind == .fight ? Int(entry.0.cost) * entry.1 : 0)
        }
        return GrowthPlan(runs: runs, missing: missing, required: required, crafts: crafts,
                          manufacturedItems: manufactured, integerOptimal: optimal, sanity: sanity)
    }

    private struct Bounds {
        var lower: [Int: Int] = [:]
        var upper: [Int: Int] = [:]
    }

    // Branch on fractional battles and recipes together. A large search can return its best feasible incumbent.
    private static func refineIntegerPlan(actions: [Action], items: [String], balance: [String: Double],
                                          counts: inout [Int]) -> Bool {
        func cost(_ values: [Int]) -> Double {
            zip(actions, values).reduce(0) { $0 + $1.0.cost * Double($1.1) }
        }
        var best = cost(counts)
        guard best > 0 else { return true }
        var pending = [Bounds()]
        // Limit the cost of each post-battle replan on large KR drop matrices.
        let nodeLimit = actions.count > 100 ? 32 : 512
        for _ in 0..<nodeLimit {
            guard let bounds = pending.popLast() else { return true }
            var available = balance
            var lowerCost = 0.0
            for (i, quantity) in bounds.lower {
                lowerCost += Double(quantity) * actions[i].cost
                for (item, amount) in actions[i].yield { available[item, default: 0] += Double(quantity) * amount }
            }
            if lowerCost >= best - 1e-6 { continue }
            var limited = actions
            var keys = items
            for i in bounds.upper.keys.sorted() {
                let key = "#limit" + String(i)
                available[key] = Double(bounds.upper[i]! - bounds.lower[i, default: 0])
                limited[i].yield[key] = -1
                keys.append(key)
            }
            let values: [Double]
            do {
                values = try solve(actions: limited, items: keys, balance: available)
            } catch IntegerSearchError.infeasible {
                continue
            } catch {
                return false
            }
            let lowerBound = zip(actions, values).reduce(lowerCost) { $0 + $1.0.cost * $1.1 }
            if ceil(lowerBound - 1e-6) >= best { continue }
            if let i = values.indices.filter({ abs(values[$0] - values[$0].rounded()) > 1e-7 }).max(by: {
                abs(values[$0] - values[$0].rounded()) < abs(values[$1] - values[$1].rounded())
            }) {
                let floorValue = bounds.lower[i, default: 0] + Int(floor(values[i]))
                var high = bounds
                high.lower[i] = floorValue + 1
                var low = bounds
                low.upper[i] = floorValue
                pending.append(high)
                pending.append(low)
            } else {
                let candidate = values.indices.map { bounds.lower[$0, default: 0] + Int(values[$0].rounded()) }
                var final = balance
                for (action, count) in zip(actions, candidate) where count > 0 {
                    for (item, amount) in action.yield { final[item, default: 0] += amount * Double(count) }
                }
                guard items.allSatisfy({ final[$0, default: 0] >= -1e-6 }) else { return false }
                counts = candidate
                best = cost(candidate)
            }
        }
        return pending.isEmpty
    }

    private enum IntegerSearchError: LocalizedError {
        case infeasible
        var errorDescription: String? { "허용한 스테이지와 조합식으로 파밍 계획을 계산할 수 없습니다." }
    }

    // Solve the dual covering LP. Each slack variable's reduced cost gives the associated primal action count.
    private static func solve(actions: [Action], items: [String], balance: [String: Double]) throws -> [Double] {
        let n = items.count
        let m = actions.count
        var columns = Array(0..<n)
        var rows = Array(n..<(n + m))
        var table = actions.map { action in items.map { action.yield[$0] ?? 0 } + [action.cost] }
        table.append(items.map { balance[$0] ?? 0 } + [0])
        for _ in 0..<20_000 {
            // Bland's ordering also handles the degenerate zero-cost workshop constraints.
            guard let enter = (0..<n).filter({ table[m][$0] < -1e-8 }).min(by: { columns[$0] < columns[$1] }) else {
                var result = Array(repeating: 0.0, count: m)
                for j in 0..<n where columns[j] >= n {
                    let value = table[m][j]
                    guard value.isFinite, value < 1e10 else { throw GrowthError("파밍 수량이 계산 범위를 벗어났습니다.") }
                    result[columns[j] - n] = max(0, value)
                }
                return result
            }
            var leave: Int?
            var best = Double.infinity
            for i in 0..<m where table[i][enter] > 1e-9 {
                let ratio = table[i][n] / table[i][enter]
                if ratio < best - 1e-9 || (abs(ratio - best) <= 1e-9 && rows[i] < rows[leave ?? i]) {
                    leave = i
                    best = ratio
                }
            }
            guard let pivot = leave else { throw IntegerSearchError.infeasible }
            let divisor = table[pivot][enter]
            for j in 0...n { table[pivot][j] /= divisor }
            table[pivot][enter] = 1 / divisor
            let pivotRow = table[pivot]
            for i in 0...m where i != pivot {
                let factor = table[i][enter]
                guard factor != 0 else { continue }
                table[i][enter] = 0
                for j in 0...n { table[i][j] -= factor * pivotRow[j] }
            }
            let old = columns[enter]
            columns[enter] = rows[pivot]
            rows[pivot] = old
        }
        throw GrowthError("파밍 경로 계산이 수렴하지 않았습니다.")
    }
}
