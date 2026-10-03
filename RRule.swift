import Foundation

/// An iCalendar (RFC 5545) recurrence rule, limited to what EventKit can store.
/// Pure Foundation, so it can be tested without calendar access.
struct RecurrenceRule: Equatable {
    enum Frequency: String, CaseIterable {
        case daily = "DAILY", weekly = "WEEKLY", monthly = "MONTHLY", yearly = "YEARLY"
    }

    /// A BYDAY entry. `weekday` is 1 (Sunday) to 7 (Saturday), as in EventKit.
    /// `ordinal` is 0 for every such weekday, or 3 / -1 for "third" / "last".
    struct Day: Equatable {
        var weekday: Int
        var ordinal: Int = 0
    }

    enum Until: Equatable {
        case date(year: Int, month: Int, day: Int)  // UNTIL=20261231
        case utc(Date)                              // UNTIL=20261231T235959Z
        case floating(DateComponents)               // UNTIL=20261231T235959, in the event's time zone
    }

    enum End: Equatable {
        case count(Int)
        case until(Until)
    }

    var frequency: Frequency
    var interval = 1
    var byDay: [Day] = []
    var byMonthDay: [Int] = []
    var byMonth: [Int] = []
    var byYearDay: [Int] = []
    var byWeekNo: [Int] = []
    var bySetPos: [Int] = []
    var end: End?
    /// Set only when read from EventKit (1 = Sunday). Printed when it is not Monday.
    var weekStart: Int?

    static let weekdayCodes = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"]
    static let supportedParts = ["FREQ", "INTERVAL", "BYDAY", "BYMONTHDAY", "BYMONTH", "BYYEARDAY", "BYWEEKNO", "BYSETPOS", "COUNT", "UNTIL", "WKST"]
    static let unsupportedParts = ["BYSECOND", "BYMINUTE", "BYHOUR"]

    struct ParseError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    /// Parses an RRULE such as "FREQ=MONTHLY;BYDAY=3WE", with or without an "RRULE:"
    /// prefix, or one of the words daily, weekly, monthly, yearly.
    static func parse(_ input: String) throws -> RecurrenceRule {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("="), let word = Frequency(rawValue: text.uppercased()) {
            return RecurrenceRule(frequency: word)
        }
        if text.uppercased().hasPrefix("RRULE:") {
            text = String(text.dropFirst(6))
        }
        guard !text.isEmpty else {
            throw ParseError("empty rule. Use an RRULE like FREQ=WEEKLY;BYDAY=MO, or daily, weekly, monthly, yearly")
        }

        var parts: [String: String] = [:]
        for piece in text.split(separator: ";", omittingEmptySubsequences: true) {
            let pair = piece.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2, !pair[0].isEmpty, !pair[1].isEmpty else {
                throw ParseError("\"\(piece)\" is not NAME=VALUE")
            }
            let name = pair[0].uppercased()
            if unsupportedParts.contains(name) {
                throw ParseError("\(name) is valid iCalendar, but EventKit cannot set it. Remove it")
            }
            guard supportedParts.contains(name) else {
                throw ParseError("unknown rule part \(name). Supported: \(supportedParts.joined(separator: ", "))")
            }
            guard parts[name] == nil else {
                throw ParseError("\(name) appears twice")
            }
            parts[name] = String(pair[1])
        }

        guard let freqText = parts["FREQ"] else {
            throw ParseError("FREQ is required, like FREQ=WEEKLY")
        }
        guard let frequency = Frequency(rawValue: freqText.uppercased()) else {
            if ["SECONDLY", "MINUTELY", "HOURLY"].contains(freqText.uppercased()) {
                throw ParseError("FREQ=\(freqText.uppercased()) is valid iCalendar, but EventKit cannot store it. Use DAILY, WEEKLY, MONTHLY, or YEARLY")
            }
            throw ParseError("unknown FREQ \(freqText). Use DAILY, WEEKLY, MONTHLY, or YEARLY")
        }
        var rule = RecurrenceRule(frequency: frequency)

        // EventKit saves every rule with weeks starting Monday, the RFC 5545 default,
        // and cannot be told otherwise. So WKST=MO is accepted and nothing else is.
        if let value = parts["WKST"], value.uppercased() != "MO" {
            throw ParseError("WKST=\(value.uppercased()) cannot be set in EventKit, which always starts weeks on Monday. Remove WKST")
        }
        if let value = parts["INTERVAL"] {
            guard let n = Int(value), n > 0 else { throw ParseError("INTERVAL must be a whole number above 0, not \(value)") }
            rule.interval = n
        }
        if let value = parts["BYDAY"] {
            rule.byDay = try value.split(separator: ",", omittingEmptySubsequences: false).map { try parseDay(String($0), frequency) }
        }
        rule.byMonthDay = try numbers(parts["BYMONTHDAY"], "BYMONTHDAY", limit: 31)
        rule.byMonth = try numbers(parts["BYMONTH"], "BYMONTH", limit: 12, allowNegative: false)
        rule.byYearDay = try numbers(parts["BYYEARDAY"], "BYYEARDAY", limit: 366)
        rule.byWeekNo = try numbers(parts["BYWEEKNO"], "BYWEEKNO", limit: 53)
        rule.bySetPos = try numbers(parts["BYSETPOS"], "BYSETPOS", limit: 366)

        // EventKit's limits, which are stricter than RFC 5545 in places.
        func only(_ name: String, _ values: [Any], _ allowed: [Frequency], _ hint: String) throws {
            if !values.isEmpty && !allowed.contains(frequency) {
                throw ParseError("\(name) cannot be used with FREQ=\(frequency.rawValue) in EventKit. \(hint)")
            }
        }
        try only("BYDAY", rule.byDay, [.weekly, .monthly, .yearly], "Use FREQ=WEEKLY with BYDAY instead")
        try only("BYMONTHDAY", rule.byMonthDay, [.monthly], "Use FREQ=MONTHLY, or FREQ=YEARLY with a start date on that day")
        try only("BYMONTH", rule.byMonth, [.yearly], "Use FREQ=YEARLY")
        try only("BYYEARDAY", rule.byYearDay, [.yearly], "Use FREQ=YEARLY")
        try only("BYWEEKNO", rule.byWeekNo, [.yearly], "Use FREQ=YEARLY")
        try only("BYSETPOS", rule.bySetPos, [.weekly, .monthly, .yearly], "Use it with WEEKLY, MONTHLY, or YEARLY")
        if !rule.byWeekNo.isEmpty && rule.byDay.contains(where: { $0.ordinal != 0 }) {
            throw ParseError("BYDAY with a number (like 1MO) cannot be combined with BYWEEKNO. Use plain days, like BYDAY=MO")
        }
        if !rule.bySetPos.isEmpty && rule.byDay.isEmpty && rule.byMonthDay.isEmpty && rule.byMonth.isEmpty
            && rule.byYearDay.isEmpty && rule.byWeekNo.isEmpty {
            throw ParseError("BYSETPOS needs another BY part to pick from, like BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1")
        }

        if parts["COUNT"] != nil && parts["UNTIL"] != nil {
            throw ParseError("use COUNT or UNTIL, not both")
        }
        if let value = parts["COUNT"] {
            guard let n = Int(value), n > 0 else { throw ParseError("COUNT must be a whole number above 0, not \(value)") }
            rule.end = .count(n)
        }
        if let value = parts["UNTIL"] {
            rule.end = .until(try parseUntil(value))
        }
        return rule
    }

    static func parseDay(_ text: String, _ frequency: Frequency) throws -> Day {
        let upper = text.uppercased()
        guard upper.count >= 2, let weekday = weekdayCodes.firstIndex(of: String(upper.suffix(2))) else {
            throw ParseError("bad BYDAY value \"\(text)\". Use SU, MO, TU, WE, TH, FR, SA, optionally with a number like 3WE or -1FR")
        }
        let prefix = String(upper.dropLast(2))
        var day = Day(weekday: weekday + 1)
        if !prefix.isEmpty {
            guard let n = Int(prefix), n != 0, prefix.count <= 3 else {
                throw ParseError("bad BYDAY value \"\(text)\". The number before the day must be like 3 or -1")
            }
            switch frequency {
            case .monthly where !(-5...5 ~= n):
                throw ParseError("BYDAY=\(text) asks for week \(n) of a month. Use 1 to 5 or -1 to -5")
            case .yearly where !(-53...53 ~= n):
                throw ParseError("BYDAY=\(text) asks for week \(n) of a year. Use 1 to 53 or -1 to -53")
            case .daily, .weekly:
                throw ParseError("BYDAY=\(text) has a number, which only works with FREQ=MONTHLY or FREQ=YEARLY")
            default:
                break
            }
            day.ordinal = n
        }
        return day
    }

    static func numbers(_ text: String?, _ name: String, limit: Int, allowNegative: Bool = true) throws -> [Int] {
        guard let text else { return [] }
        return try text.split(separator: ",", omittingEmptySubsequences: false).map { piece in
            let range = allowNegative ? "1 to \(limit) or -1 to -\(limit)" : "1 to \(limit)"
            guard let n = Int(piece), n != 0, (allowNegative ? -limit : 1)...limit ~= n else {
                throw ParseError("bad \(name) value \"\(piece)\". Use \(range)")
            }
            return n
        }
    }

    static func parseUntil(_ text: String) throws -> Until {
        let hint = "UNTIL must look like 20261231, 20261231T170000Z, or 20261231T170000"
        let chars = Array(text.uppercased())
        func digits(_ from: Int, _ count: Int) -> Int? {
            guard chars.count >= from + count else { return nil }
            let slice = chars[from..<(from + count)]
            return slice.allSatisfy(\.isNumber) ? Int(String(slice)) : nil
        }
        guard let year = digits(0, 4), let month = digits(4, 2), let day = digits(6, 2),
              (1...12).contains(month), (1...31).contains(day) else {
            throw ParseError("bad UNTIL \(text). \(hint)")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let dateOnly = DateComponents(year: year, month: month, day: day)
        guard dateOnly.isValidDate(in: calendar) else {
            throw ParseError("bad UNTIL \(text): that date does not exist")
        }
        if chars.count == 8 {
            return .date(year: year, month: month, day: day)
        }
        guard chars.count == 15 || (chars.count == 16 && chars[15] == "Z"), chars[8] == "T",
              let hour = digits(9, 2), let minute = digits(11, 2), let second = digits(13, 2),
              hour < 24, minute < 60, second < 60 else {
            throw ParseError("bad UNTIL \(text). \(hint)")
        }
        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        if chars.count == 16 {
            return .utc(calendar.date(from: components)!)
        }
        return .floating(components)
    }

    /// The rule as an RRULE value, without the "RRULE:" prefix.
    var rrule: String {
        var parts = ["FREQ=\(frequency.rawValue)"]
        if interval != 1 { parts.append("INTERVAL=\(interval)") }
        func list(_ name: String, _ values: [Int]) {
            if !values.isEmpty { parts.append("\(name)=" + values.map(String.init).joined(separator: ",")) }
        }
        list("BYMONTH", byMonth)
        list("BYWEEKNO", byWeekNo)
        list("BYYEARDAY", byYearDay)
        list("BYMONTHDAY", byMonthDay)
        if !byDay.isEmpty {
            parts.append("BYDAY=" + byDay.map { ($0.ordinal == 0 ? "" : String($0.ordinal)) + RecurrenceRule.weekdayCodes[$0.weekday - 1] }.joined(separator: ","))
        }
        list("BYSETPOS", bySetPos)
        switch end {
        case .count(let n):
            parts.append("COUNT=\(n)")
        case .until(.date(let y, let m, let d)):
            parts.append(String(format: "UNTIL=%04d%02d%02d", y, m, d))
        case .until(.utc(let date)):
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
            parts.append("UNTIL=" + formatter.string(from: date))
        case .until(.floating(let c)):
            parts.append(String(format: "UNTIL=%04d%02d%02dT%02d%02d%02d", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!))
        case nil:
            break
        }
        if let weekStart, (1...7).contains(weekStart), weekStart != 2 {
            parts.append("WKST=" + RecurrenceRule.weekdayCodes[weekStart - 1])
        }
        return parts.joined(separator: ";")
    }

    /// The moment an UNTIL value ends in `zone`. A date-only UNTIL includes that whole day.
    static func untilDate(_ until: Until, in zone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        switch until {
        case .utc(let date):
            return date
        case .date(let y, let m, let d):
            return calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 23, minute: 59, second: 59))!
        case .floating(let c):
            return calendar.date(from: c)!
        }
    }
}
