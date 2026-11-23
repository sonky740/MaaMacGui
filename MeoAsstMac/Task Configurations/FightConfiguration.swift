//
//  FightConfiguration.swift
//  MAA
//
//  Created by hguandl on 16/4/2023.
//

import Foundation

struct FightConfiguration: MAATaskConfiguration {
    var type: MAATaskType { .Fight }

    var stage: String
    var medicine: Int?
    var medicine_expire_days: Int
    var stone: Int?
    var times: Int?
    var series: Int?
    var drops: [String: Int]?

    var report_to_penguin: Bool
    var penguin_id: String
    var server: String
    var client_type: String
    var DrGrandet: Bool

    var title: String {
        type.description
    }

    var subtitle: String {
        if stage == "" {
            return String(localized: "当前/上次")
        } else {
            return stage
        }
    }

    var summary: String {
        var parts = [String]()

        if let medicine {
            parts.append(String(localized: "理智药") + "\(medicine)")
        }

        if let stone {
            parts.append(String(localized: "源石") + "\(stone)")
        }

        if let times {
            parts.append("\(times)" + String(localized: "次"))
        }

        return parts.joined(separator: ";")
    }

    var projectedTask: MAATask {
        .fight(self)
    }

    typealias Params = Self

    var params: Self {
        self
    }

}

private enum LegacyCodingKeys: String, CodingKey {
    case expiring_medicine
}

extension FightConfiguration {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.stage = try container.decodeIfPresent(String.self, forKey: .stage) ?? ""
        self.medicine = try container.decodeIfPresent(Int.self, forKey: .medicine)
        if let days = try container.decodeIfPresent(Int.self, forKey: .medicine_expire_days) {
            medicine_expire_days = days
        } else {
            let legacyContainer = try decoder.container(keyedBy: LegacyCodingKeys.self)
            let medicine = try legacyContainer.decodeIfPresent(Int.self, forKey: .expiring_medicine)
            medicine_expire_days = (medicine ?? 0) > 0 ? 2 : 0
        }
        self.stone = try container.decodeIfPresent(Int.self, forKey: .stone)
        self.times = try container.decodeIfPresent(Int.self, forKey: .times)
        self.series = try container.decodeIfPresent(Int.self, forKey: .series)
        self.drops = try container.decodeIfPresent([String: Int].self, forKey: .drops)
        self.report_to_penguin = try container.decodeIfPresent(Bool.self, forKey: .report_to_penguin) ?? false
        self.penguin_id = try container.decodeIfPresent(String.self, forKey: .penguin_id) ?? ""
        self.server = try container.decodeIfPresent(String.self, forKey: .server) ?? "CN"
        self.client_type = try container.decodeIfPresent(String.self, forKey: .client_type) ?? ""
        self.DrGrandet = try container.decodeIfPresent(Bool.self, forKey: .DrGrandet) ?? false
    }
}

extension FightConfiguration {
    var localizedExpiry: LocalizedStringResource {
        switch medicine_expire_days {
        case 0: "不启用"
        case 1: "24小时内"
        case let d: "\(d - 1)天内"
        }
    }
}
