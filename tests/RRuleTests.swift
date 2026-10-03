import Foundation

// Plain test runner so the parser can be checked without Xcode or calendar access:
//   swiftc -parse-as-library RRule.swift tests/RRuleTests.swift -o build/rrule-tests && build/rrule-tests

@main
struct RRuleTests {
    static var failures = 0
    static var count = 0

    static func check(_ ok: Bool, _ message: String, line: Int = #line) {
        count += 1
        if !ok {
            failures += 1
            print("FAIL line \(line): \(message)")
        }
    }

    /// Parses and expects the canonical form `expected` (defaults to the input).
    static func ok(_ input: String, _ expected: String? = nil, line: Int = #line) {
        do {
            let rule = try RecurrenceRule.parse(input)
            check(rule.rrule == (expected ?? input), "\(input) -> \(rule.rrule), expected \(expected ?? input)", line: line)
            let again = try RecurrenceRule.parse(rule.rrule)
            check(again == rule, "\(input) does not survive a round trip", line: line)
        } catch {
            check(false, "\(input) failed: \(error)", line: line)
        }
    }

    /// Expects a parse error whose message contains `fragment`.
    static func bad(_ input: String, _ fragment: String, line: Int = #line) {
        do {
            let rule = try RecurrenceRule.parse(input)
            check(false, "\(input) parsed as \(rule.rrule), expected an error about \(fragment)", line: line)
        } catch {
            check("\(error)".contains(fragment), "\(input): \"\(error)\" does not mention \(fragment)", line: line)
        }
    }

    static func main() {
        // Shorthand words
        ok("daily", "FREQ=DAILY")
        ok("weekly", "FREQ=WEEKLY")
        ok("Monthly", "FREQ=MONTHLY")
        ok("YEARLY", "FREQ=YEARLY")

        // Prefix, case, whitespace, and part order
        ok("RRULE:FREQ=WEEKLY;BYDAY=MO", "FREQ=WEEKLY;BYDAY=MO")
        ok("rrule:freq=weekly;byday=mo,we", "FREQ=WEEKLY;BYDAY=MO,WE")
        ok("  FREQ=DAILY;INTERVAL=2  ", "FREQ=DAILY;INTERVAL=2")
        ok("BYDAY=TU;FREQ=WEEKLY", "FREQ=WEEKLY;BYDAY=TU")
        ok("FREQ=WEEKLY;INTERVAL=1", "FREQ=WEEKLY")
        ok("FREQ=WEEKLY;BYDAY=MO;", "FREQ=WEEKLY;BYDAY=MO")

        // Common real rules
        ok("FREQ=MONTHLY;BYDAY=3WE")                         // third Wednesday
        ok("FREQ=MONTHLY;BYDAY=-1FR")                        // last Friday
        ok("FREQ=MONTHLY;BYDAY=+2MO", "FREQ=MONTHLY;BYDAY=2MO")
        ok("FREQ=WEEKLY;INTERVAL=2;BYDAY=TU,TH")             // every other Tue and Thu
        ok("FREQ=MONTHLY;BYMONTHDAY=1,15")
        ok("FREQ=MONTHLY;BYMONTHDAY=-1")                     // last day of the month
        ok("FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1")  // last weekday of the month
        ok("FREQ=YEARLY;BYMONTH=11;BYDAY=4TH")               // US Thanksgiving
        ok("FREQ=YEARLY;BYMONTH=1,7")
        ok("FREQ=YEARLY;BYYEARDAY=100,-1")
        ok("FREQ=YEARLY;BYWEEKNO=20;BYDAY=MO")
        ok("FREQ=YEARLY;BYDAY=20MO")
        ok("FREQ=WEEKLY;BYDAY=MO,WE,FR;BYSETPOS=1")

        // Ends
        ok("FREQ=DAILY;COUNT=10")
        ok("FREQ=WEEKLY;UNTIL=20261231")
        ok("FREQ=WEEKLY;UNTIL=20261231T235959Z")
        ok("FREQ=WEEKLY;UNTIL=20261231T170000")
        ok("FREQ=YEARLY;UNTIL=20280229")                     // leap day exists
        ok("FREQ=MONTHLY;BYDAY=3WE;UNTIL=20270101T000000Z")

        // Unsupported by EventKit
        bad("FREQ=HOURLY", "EventKit cannot store it")
        bad("FREQ=MINUTELY", "EventKit cannot store it")
        bad("FREQ=SECONDLY", "EventKit cannot store it")
        bad("FREQ=DAILY;BYHOUR=9", "EventKit cannot set it")
        bad("FREQ=DAILY;BYMINUTE=30", "BYMINUTE")
        bad("FREQ=DAILY;BYSECOND=0", "BYSECOND")
        bad("FREQ=WEEKLY;WKST=SU", "WKST=SU cannot be set")
        ok("FREQ=WEEKLY;INTERVAL=2;BYDAY=TU;WKST=MO", "FREQ=WEEKLY;INTERVAL=2;BYDAY=TU")  // EventKit's own week start
        bad("FREQ=DAILY;BYDAY=MO", "cannot be used with FREQ=DAILY")
        bad("FREQ=WEEKLY;BYMONTHDAY=1", "BYMONTHDAY cannot be used with FREQ=WEEKLY")
        bad("FREQ=YEARLY;BYMONTHDAY=1", "BYMONTHDAY cannot be used with FREQ=YEARLY")
        bad("FREQ=MONTHLY;BYMONTH=1", "BYMONTH cannot be used")
        bad("FREQ=MONTHLY;BYYEARDAY=1", "BYYEARDAY cannot be used")
        bad("FREQ=MONTHLY;BYWEEKNO=1", "BYWEEKNO cannot be used")
        bad("FREQ=DAILY;BYSETPOS=1", "BYSETPOS cannot be used")
        bad("FREQ=WEEKLY;BYDAY=2MO", "only works with FREQ=MONTHLY or FREQ=YEARLY")

        bad("FREQ=YEARLY;BYWEEKNO=20;BYDAY=1MO", "cannot be combined with BYWEEKNO")

        // Malformed
        bad("", "empty rule")
        bad("RRULE:", "empty rule")
        bad("fortnightly", "not NAME=VALUE")
        bad("INTERVAL=2", "FREQ is required")
        bad("FREQ=WEEKLEY", "unknown FREQ")
        bad("FREQ=WEEKLY;FREQ=DAILY", "appears twice")
        bad("FREQ=WEEKLY;BYDAYS=MO", "unknown rule part BYDAYS")
        bad("FREQ=WEEKLY;BYDAY=", "not NAME=VALUE")
        bad("FREQ=WEEKLY;=MO", "not NAME=VALUE")
        bad("FREQ=DAILY;INTERVAL=0", "INTERVAL must be")
        bad("FREQ=DAILY;INTERVAL=-1", "INTERVAL must be")
        bad("FREQ=DAILY;INTERVAL=two", "INTERVAL must be")
        bad("FREQ=DAILY;COUNT=0", "COUNT must be")
        bad("FREQ=DAILY;COUNT=5;UNTIL=20261231", "not both")
        bad("FREQ=WEEKLY;BYDAY=XX", "bad BYDAY")
        bad("FREQ=WEEKLY;BYDAY=MO,,TU", "bad BYDAY")
        bad("FREQ=MONTHLY;BYDAY=0MO", "bad BYDAY")
        bad("FREQ=MONTHLY;BYDAY=6MO", "week 6 of a month")
        bad("FREQ=MONTHLY;BYDAY=-6MO", "week -6 of a month")
        bad("FREQ=YEARLY;BYDAY=54MO", "week 54 of a year")
        bad("FREQ=MONTHLY;BYMONTHDAY=32", "bad BYMONTHDAY")
        bad("FREQ=MONTHLY;BYMONTHDAY=0", "bad BYMONTHDAY")
        bad("FREQ=MONTHLY;BYMONTHDAY=-32", "bad BYMONTHDAY")
        bad("FREQ=MONTHLY;BYMONTHDAY=-9223372036854775808", "bad BYMONTHDAY")  // would overflow abs()
        bad("FREQ=MONTHLY;BYMONTHDAY=99999999999999999999", "bad BYMONTHDAY")
        bad("FREQ=DAILY;INTERVAL=99999999999999999999", "INTERVAL must be")
        bad("FREQ=MONTHLY;BYDAY=-999MO", "bad BYDAY")
        bad("FREQ=YEARLY;BYMONTH=13", "bad BYMONTH")
        bad("FREQ=YEARLY;BYMONTH=-1", "bad BYMONTH")
        bad("FREQ=YEARLY;BYYEARDAY=367", "bad BYYEARDAY")
        bad("FREQ=YEARLY;BYWEEKNO=54", "bad BYWEEKNO")
        bad("FREQ=MONTHLY;BYSETPOS=1", "needs another BY part")
        bad("FREQ=MONTHLY;BYDAY=MO;BYSETPOS=400", "bad BYSETPOS")
        bad("FREQ=DAILY;UNTIL=2026", "bad UNTIL")
        bad("FREQ=DAILY;UNTIL=20261301", "bad UNTIL")
        bad("FREQ=DAILY;UNTIL=20270229", "does not exist")
        bad("FREQ=DAILY;UNTIL=20261231T25", "bad UNTIL")
        bad("FREQ=DAILY;UNTIL=20261231T250000Z", "bad UNTIL")
        bad("FREQ=DAILY;UNTIL=20261231X170000", "bad UNTIL")
        bad("FREQ=DAILY;UNTIL=2026-12-31", "bad UNTIL")

        // Structure, not just the string
        if let rule = try? RecurrenceRule.parse("FREQ=MONTHLY;BYDAY=3WE,-1FR;COUNT=4") {
            check(rule.byDay == [.init(weekday: 4, ordinal: 3), .init(weekday: 6, ordinal: -1)], "BYDAY weekdays use EventKit numbering")
            check(rule.end == .count(4), "COUNT parsed")
        } else {
            check(false, "third Wednesday rule did not parse")
        }

        // A week start read from EventKit is shown unless it is the Monday default
        var sundayStart = RecurrenceRule(frequency: .weekly, interval: 2, byDay: [.init(weekday: 2)])
        sundayStart.weekStart = 1
        check(sundayStart.rrule == "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO;WKST=SU", "WKST exported: \(sundayStart.rrule)")
        sundayStart.weekStart = 2
        check(sundayStart.rrule == "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO", "Monday week start left out: \(sundayStart.rrule)")

        // UNTIL as a moment
        let denver = TimeZone(identifier: "America/Denver")!
        let iso = ISO8601DateFormatter()
        check(iso.string(from: RecurrenceRule.untilDate(.date(year: 2026, month: 11, day: 3), in: denver)) == "2026-11-04T06:59:59Z",
              "a date-only UNTIL covers the whole local day")
        let floating = DateComponents(year: 2026, month: 7, day: 1, hour: 9, minute: 0, second: 0)
        check(iso.string(from: RecurrenceRule.untilDate(.floating(floating), in: denver)) == "2026-07-01T15:00:00Z",
              "a floating UNTIL uses the event's zone")

        print(failures == 0 ? "rrule tests: \(count) checks passed" : "rrule tests: \(failures) of \(count) checks failed")
        exit(failures == 0 ? 0 : 1)
    }
}
