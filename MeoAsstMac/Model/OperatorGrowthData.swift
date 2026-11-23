import Foundation

struct GrowthState: Equatable {
    let elite: Int
    let level: Int
    let skillRank: Int
    let mastery: [Int]
    var experience = 0
}

struct GrowthError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct GrowthData {
    struct Item: Decodable { let id: String; let count: Int }
    struct Gate: Decodable {
        let phase: String
        let level: Int
        func allows(_ state: GrowthState) -> Bool {
            guard let rank = Int(phase.dropFirst("PHASE_".count)) else { return false }
            return state.elite > rank || (state.elite == rank && state.level >= level)
        }
    }
    struct Upgrade: Decodable {
        let unlockCond: Gate
        let lvlUpCost: [Item]?
        let levelUpCost: [Item]?
    }
    struct Skill: Decodable { let levelUpCostCond: [Upgrade] }
    struct Phase: Decodable { let maxLevel: Int; let evolveCost: [Item]? }
    struct Character: Decodable {
        let name, rarity: String
        let isNotObtainable: Bool
        let phases: [Phase]
        let skills: [Skill]
        let allSkillLvlup: [Upgrade]
    }
    struct Constants: Decodable {
        let characterExpMap, characterUpgradeCostMap, evolveGoldCost: [[Int]]
        let completeGainBonus: Double
    }
    struct Recipe: Decodable {
        let itemId, formulaType: String
        let count: Int
        let costs: [Item]
        let goldCost: Int?
    }
    struct Building: Decodable { let workshopFormulas, manufactFormulas: [String: Recipe] }
    struct ExpItem: Decodable { let gainExp: Int }
    struct ItemTable: Decodable { let expItems: [String: ExpItem] }
    struct Stage: Decodable {
        let code, difficulty, diffGroup: String
        let canBattleReplay: Bool
        let apCost, goldGain: Int
    }
    struct StageTable: Decodable { let stages: [String: Stage] }
    struct Existence: Decodable { let exist: Bool; let openTime, closeTime: Double? }
    struct PenguinStage: Decodable { let stageId, code: String; let existence: [String: Existence] }
    struct Drop: Decodable {
        let stageId, itemId: String
        let times, quantity: Int
        let start: Double
        let end: Double?
    }
    struct Matrix: Decodable { let matrix: [Drop] }

    let characters: [String: Character]
    let constants: Constants
    let building: Building
    let items: ItemTable
    let stages: StageTable
    let penguinStages: [PenguinStage]
    let matrix: Matrix

    static func read<T: Decodable>(_ type: T.Type, url: URL) async throws -> T {
        let data: Data
        if url.isFileURL {
            data = try Data(contentsOf: url)
        } else {
            let (body, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw GrowthError("육성 데이터를 가져오지 못했습니다. " + url.lastPathComponent)
            }
            data = body
        }
        return try JSONDecoder().decode(type, from: data)
    }

    static func load(game: URL, statistics: URL) async throws -> GrowthData {
        @Sendable func gameFile(_ name: String) -> URL { game.appendingPathComponent(name + ".json") }
        @Sendable func statsFile(_ name: String) -> URL {
            if statistics.isFileURL { return statistics.appendingPathComponent(String(name.split(separator: "/").last!) + ".json") }
            return statistics.appendingPathComponent(name).appending(queryItems: [.init(name: "server", value: "KR")])
        }
        async let operators = read([String: Character].self, url: gameFile("character_table"))
        async let constants = read(Constants.self, url: gameFile("gamedata_const"))
        async let building = read(Building.self, url: gameFile("building_data"))
        async let items = read(ItemTable.self, url: gameFile("item_table"))
        async let stages = read(StageTable.self, url: gameFile("stage_table"))
        async let penguinStages = read([PenguinStage].self, url: statsFile("stages"))
        async let matrix = read(Matrix.self, url: statsFile("result/matrix"))
        return try await GrowthData(characters: operators, constants: constants, building: building, items: items,
                                    stages: stages, penguinStages: penguinStages, matrix: matrix)
    }

    func requirements(name: String, current: GrowthState, target: GrowthState) throws -> [String: Int] {
        let matches = characters.filter { key, op in !op.isNotObtainable && (key == name || op.name == name) }
        guard matches.count == 1, let op = matches.first?.value,
              let rarity = Int(op.rarity.dropFirst("TIER_".count)), constants.evolveGoldCost.indices.contains(rarity - 1)
        else { throw GrowthError("한국 서버 데이터에서 오퍼레이터를 식별할 수 없습니다.") }
        func validate(_ state: GrowthState) -> Bool {
            op.phases.indices.contains(state.elite) && state.level >= 1 && state.level <= op.phases[state.elite].maxLevel &&
            (1...min(7, op.allSkillLvlup.count + 1)).contains(state.skillRank) &&
            state.mastery.count == 3 && state.mastery.enumerated().allSatisfy { slot, rank in
                rank == 0 || (op.skills.indices.contains(slot) && rank > 0 &&
                              rank <= op.skills[slot].levelUpCostCond.count && state.skillRank == 7 &&
                              op.skills[slot].levelUpCostCond[rank - 1].unlockCond.allows(state))
            } && (state.skillRank == 1 || op.allSkillLvlup[state.skillRank - 2].unlockCond.allows(state))
        }
        guard validate(current), validate(target), current.experience >= 0 else {
            throw GrowthError("정예·레벨·스킬 목표가 오퍼레이터의 해금 조건을 충족하지 않습니다.")
        }
        var required: [String: Int] = [:]
        func add(_ materials: [Item]) throws {
            for item in materials {
                guard item.count >= 0 && item.count <= 1_000_000 else { throw GrowthError("재료 수량이 올바르지 않습니다.") }
                required[item.id, default: 0] += item.count
            }
        }
        if (current.elite, current.level) < (target.elite, target.level) {
            for phase in current.elite...target.elite {
                let first = phase == current.elite ? current.level : 1
                let last = phase == target.elite ? target.level : op.phases[phase].maxLevel
                guard constants.characterExpMap.indices.contains(phase), constants.characterUpgradeCostMap.indices.contains(phase),
                      last - 1 <= constants.characterExpMap[phase].count,
                      last - 1 <= constants.characterUpgradeCostMap[phase].count else { throw GrowthError("레벨 비용표가 불완전합니다.") }
                let range = (first - 1)..<(last - 1)
                required["EXP", default: 0] += constants.characterExpMap[phase][range].reduce(0, +)
                required["4001", default: 0] += constants.characterUpgradeCostMap[phase][range].reduce(0, +)
                if phase < target.elite {
                    let fees = constants.evolveGoldCost[rarity - 1]
                    guard fees.indices.contains(phase), fees[phase] >= 0 else { throw GrowthError("정예화 비용을 확인할 수 없습니다.") }
                    required["4001", default: 0] += fees[phase]
                    try add(op.phases[phase + 1].evolveCost ?? [])
                }
            }
            let availableExp = op.phases[current.elite].maxLevel > current.level ? current.experience : 0
            if availableExp > 0 {
                guard availableExp < constants.characterExpMap[current.elite][current.level - 1] else {
                    throw GrowthError("현재 레벨의 보유 경험치를 확인해 주세요.")
                }
                required["EXP", default: 0] -= availableExp
            }
        }
        if current.skillRank < target.skillRank {
            for i in (current.skillRank - 1)..<(target.skillRank - 1) {
                guard let cost = op.allSkillLvlup[i].lvlUpCost else { throw GrowthError("스킬 비용을 확인할 수 없습니다.") }
                try add(cost)
            }
        }
        for i in 0..<3 where current.mastery[i] < target.mastery[i] {
            for rank in current.mastery[i]..<target.mastery[i] {
                guard let cost = op.skills[i].levelUpCostCond[rank].levelUpCost else { throw GrowthError("전문화 비용을 확인할 수 없습니다.") }
                try add(cost)
            }
        }
        return required.filter { $0.value > 0 }
    }
}
