//
//  StageActivity.swift
//  MAA
//
//  Created by hguandl on 2026/9/11.
//

import Foundation

struct StageActivityContext {
    let channel: MAAClientChannel
    let activities: MAAStageActivity?
}

extension StageActivityContext {
    func resourceCollectionStageIsOpen(at date: Date, in weekdays: [Int]?) -> Bool {
        if activities?.resourceCollection?.contains(date) == true { return true }
        if let weekdays, !weekdays.contains(channel.calendar.weekday(for: date)) {
            return false
        }
        return true
    }
}
