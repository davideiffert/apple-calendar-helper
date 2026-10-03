import EventKit
import Foundation

/// A failure the user can act on. The message becomes an `error=` line.
struct CommandError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

typealias JSONObject = [String: Any]

// eventIdentifier is accepted and ignored, so a dumped event can be created as a copy.
let createFields = ["calendarIdentifier", "sourceTitle", "calendarTitle", "eventIdentifier", "title", "startDate", "endDate", "isAllDay", "timeZone", "recurrence", "location", "notes", "url"]
let changeFields = ["title", "startDate", "endDate", "isAllDay", "timeZone", "recurrence", "location", "notes", "url", "calendar"]

extension AppDelegate {
    func runCommand() {
        guard let command = args.first else {
            listCalendars()
            return
        }
        do {
            switch command {
            case "list-calendars": listCalendars()
            case "dump-events": try dumpEvents()
            case "create-events": try createEvents()
            case "update-event": try updateEvent()
            case "delete-event": try deleteEvent()
            default: throw CommandError("unknown command \(command). Commands: \(commandNames.joined(separator: ", "))")
            }
        } catch let error as CommandError {
            store.reset()  // drop any unsaved edits so they never reach a later save
            lines.append("error=\(error.message)")
        } catch {
            store.reset()
            lines.append("error=\(describe(error))")
        }
    }

    // MARK: Commands

    func listCalendars() {
        for calendar in store.calendars(for: .event) {
            lines.append("\(calendar.source.title)\t\(calendar.title)\t\(calendar.calendarIdentifier)")
        }
    }

    func dumpEvents() throws {
        guard args.count == 6 else {
            throw CommandError("usage dump-events <account> <calendar, calendar ID, or '*'> <start-yyyy-mm-dd> <end-yyyy-mm-dd> <output-json>")
        }
        let (source, calendarName, startText, endText) = (args[1], args[2], args[3], args[4])
        let outputPath = resolvePath(args[5])
        guard let start = dayFormatter().date(from: startText), let end = dayFormatter().date(from: endText) else {
            throw CommandError("bad date \(startText) or \(endText). Use yyyy-mm-dd")
        }
        guard end > start else {
            throw CommandError("end date \(endText) must be after start date \(startText). The end date is not included")
        }
        guard end <= localCalendar().date(byAdding: .year, value: 4, to: start)! else {
            throw CommandError("EventKit searches at most 4 years at a time. Split the range into smaller dumps")
        }
        let calendars = store.calendars(for: .event).filter {
            $0.source.title == source && (calendarName == "*" || $0.title == calendarName || $0.calendarIdentifier == calendarName)
        }
        guard !calendars.isEmpty else { throw calendarNotFound(source, calendarName) }

        let events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: calendars))
        do {
            let data = try JSONSerialization.data(withJSONObject: events.map(snapshot), options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
        } catch {
            throw CommandError("cannot write \(outputPath): \(describe(error)). Pick a folder you can write to")
        }
        lines.append("dumped=\(events.count)")
        lines.append("output=\(outputPath)")
    }

    func createEvents() throws {
        guard args.count == 3 else { throw CommandError("usage create-events <input-json> <receipt-json>") }
        let inputPath = resolvePath(args[1])
        let receiptPath = resolvePath(args[2])
        guard let items = try readJSON(inputPath) as? [Any] else {
            throw CommandError("\(inputPath) must hold a JSON array of events. See the create-events example in README.md")
        }
        guard !items.isEmpty else { throw CommandError("\(inputPath) has no events to create") }

        // Check every event before saving any, so a bad batch creates nothing.
        var events: [EKEvent] = []
        var problems: [String] = []
        for (index, item) in items.enumerated() {
            let title = (item as? JSONObject)?["title"] as? String
            let place = "event \(index)" + (title.map { " (\"\($0)\")" } ?? "")
            do {
                events.append(try buildEvent(item, at: place))
            } catch let error as CommandError {
                problems.append(error.message)
            }
        }
        guard problems.isEmpty else {
            lines += problems.map { "error=\($0)" }
            throw CommandError("nothing was created. Fix the errors above and run it again")
        }
        try requireWritable(receiptPath, input: inputPath)

        for event in events {
            do {
                try store.save(event, span: .thisEvent, commit: false)
            } catch {
                throw CommandError("EventKit refused \"\(event.title ?? "")\": \(describe(error)). Nothing was created")
            }
        }
        do {
            try store.commit()
        } catch {
            throw CommandError("saving failed: \(describe(error)). Some events may have been created. Check with dump-events before retrying")
        }
        lines.append("created=\(events.count)")
        writeReceipt(events.map(snapshot), to: receiptPath)
    }

    func updateEvent() throws {
        guard args.count == 3 else { throw CommandError("usage update-event <input-json> <receipt-json>") }
        let inputPath = resolvePath(args[1])
        let receiptPath = resolvePath(args[2])
        guard let input = try readJSON(inputPath) as? JSONObject else {
            throw CommandError("\(inputPath) must hold one JSON object. See the update-event example in README.md")
        }
        try checkKeys(input, allowed: ["eventIdentifier", "occurrenceStart", "span", "changes"], required: ["eventIdentifier", "changes"], at: "update")
        guard let changes = input["changes"] as? JSONObject, !changes.isEmpty else {
            throw CommandError("\"changes\" must be an object with at least one of: \(changeFields.joined(separator: ", "))")
        }
        try checkKeys(changes, allowed: changeFields, required: [], at: "changes")

        let event = try findEvent(try string(input, "eventIdentifier", at: "update")!,
                                  occurrence: try string(input, "occurrenceStart", at: "update"),
                                  hint: "Add \"occurrenceStart\" (the occurrence's startDate from dump-events) and \"span\"")
        let span = try resolveSpan(try string(input, "span", at: "update"), for: event, hint: "Add \"span\": \"this\" (only this occurrence) or \"future\" (this and later ones)")
        try requireWritable(receiptPath, input: inputPath)

        let before = snapshot(event)
        try apply(changes, to: event, span: span)
        do {
            try store.save(event, span: span, commit: true)
        } catch {
            throw CommandError("EventKit refused the change: \(describe(error)). Nothing was changed")
        }
        lines.append("updated=1")
        lines.append("eventIdentifier=\(event.eventIdentifier ?? "")")
        writeReceipt(["span": spanName(span), "before": before, "after": snapshot(event)], to: receiptPath)
    }

    func deleteEvent() throws {
        let usage = CommandError("usage delete-event <event-id> <receipt-json> [occurrence-start] [--span this|future]")
        var positional: [String] = []
        var spanText: String?
        var rest = args.dropFirst()
        while let arg = rest.popFirst() {
            if arg == "--span" || arg.hasPrefix("--span=") {
                guard spanText == nil else { throw CommandError("--span appears twice. Give it once") }
                if arg == "--span" {
                    guard let value = rest.popFirst() else { throw usage }
                    spanText = value
                } else {
                    spanText = String(arg.dropFirst(7))
                }
            } else if arg.hasPrefix("--") {
                throw CommandError("unknown option \(arg). The only option is --span this|future")
            } else {
                positional.append(arg)
            }
        }
        guard (2...3).contains(positional.count) else { throw usage }

        let event = try findEvent(positional[0], occurrence: positional.count == 3 ? positional[2] : nil,
                                  hint: "Add the occurrence's startDate from dump-events and --span this or --span future")
        let span = try resolveSpan(spanText, for: event, hint: "Add --span this (only this occurrence) or --span future (this and later ones)")
        let receiptPath = resolvePath(positional[1])
        try requireWritable(receiptPath, input: nil)

        let before = snapshot(event)
        do {
            try store.remove(event, span: span, commit: true)
        } catch {
            throw CommandError("EventKit refused the delete: \(describe(error)). Nothing was changed")
        }
        lines.append("deleted=1")
        writeReceipt(["span": spanName(span), "deleted": before], to: receiptPath)
    }

    // MARK: Building and changing events

    func buildEvent(_ item: Any, at place: String) throws -> EKEvent {
        guard let fields = item as? JSONObject else { throw CommandError("\(place) must be a JSON object") }
        try checkKeys(fields, allowed: createFields, required: ["title", "startDate", "endDate"], at: place)

        let event = EKEvent(eventStore: store)
        if let id = try string(fields, "calendarIdentifier", at: place) {
            event.calendar = try writableCalendar(try calendarReference(id))
        } else if let source = try string(fields, "sourceTitle", at: place), let title = try string(fields, "calendarTitle", at: place) {
            event.calendar = try writableCalendar(try findCalendar(source, title))
        } else {
            throw CommandError("\(place): needs calendarIdentifier, or sourceTitle and calendarTitle")
        }
        event.title = try string(fields, "title", at: place)!
        event.isAllDay = try bool(fields, "isAllDay", at: place) ?? false

        // Absent: the Mac's zone. null: floating, the same clock time in any zone.
        var zone = TimeZone.current
        if let name = try string(fields, "timeZone", at: place) {
            guard !event.isAllDay else { throw CommandError("\(place): timeZone does not apply to all-day events. Remove it") }
            zone = try timeZone(name, at: place)
        }
        let floating = fields["timeZone"] is NSNull
        event.timeZone = event.isAllDay || floating ? nil : zone
        try setTimes(event, start: try string(fields, "startDate", at: place)!, end: try string(fields, "endDate", at: place)!, zone: zone, at: place)

        event.location = try string(fields, "location", at: place)
        event.notes = try string(fields, "notes", at: place)
        event.url = try url(fields, at: place)
        if let text = try string(fields, "recurrence", at: place) {
            event.recurrenceRules = [try ekRule(text, zone: zone, at: place)]
        }
        return event
    }

    /// Applies an update-event "changes" object. Throws before saving if anything is invalid.
    func apply(_ changes: JSONObject, to event: EKEvent, span: EKSpan) throws {
        let place = "changes"
        let has = { (key: String) in changes[key] != nil }
        for key in ["title", "startDate", "endDate", "isAllDay"] where changes[key] is NSNull {
            throw CommandError("\(key) cannot be null")
        }

        // A recurrence equal to the current rule (as dump-events printed it) is left alone.
        var recurrenceChanged = has("recurrence")
        if let text = try string(changes, "recurrence", at: place) {
            let current = event.recurrenceRules?.first.map { RecurrenceRule($0, allDay: event.isAllDay).rrule }
            let wanted = try? RecurrenceRule.parse(text).rrule
            if text == current || (wanted != nil && wanted == current) { recurrenceChanged = false }
        } else if has("recurrence") && !event.hasRecurrenceRules {
            recurrenceChanged = false
        }
        if recurrenceChanged && event.hasRecurrenceRules && span == .thisEvent {
            throw CommandError("a recurrence change applies to the series from this occurrence on. Use \"span\": \"future\"")
        }

        let wasAllDay = event.isAllDay
        let allDay = try bool(changes, "isAllDay", at: place) ?? wasAllDay
        let start = try string(changes, "startDate", at: place)
        let end = try string(changes, "endDate", at: place)
        if allDay != wasAllDay && (start == nil || end == nil) {
            throw CommandError("changing isAllDay needs both startDate and endDate, as yyyy-mm-dd for all-day events or a time for timed events")
        }

        var zone = event.timeZone ?? .current
        var floating = event.timeZone == nil && !wasAllDay
        if has("timeZone") {
            if let name = try string(changes, "timeZone", at: place) {
                guard !allDay else { throw CommandError("timeZone does not apply to all-day events. Remove it") }
                zone = try timeZone(name, at: place)
                floating = false
            } else {
                zone = .current
                floating = !allDay
            }
        }

        var newCalendar: EKCalendar?
        if has("calendar") {
            newCalendar = try writableCalendar(try calendarReference(changes["calendar"]!))
        }
        var rules: [EKRecurrenceRule]??
        if recurrenceChanged {
            rules = .some(try string(changes, "recurrence", at: place).map { [try ekRule($0, zone: zone, at: place)] })
        }
        var title: String?
        if has("title") {
            guard let text = try string(changes, "title", at: place) else { throw CommandError("title cannot be null") }
            title = text
        }
        let newURL = try url(changes, at: place)

        // Everything is valid. Apply it.
        let oldStart = event.startDate!
        let oldEnd = event.endDate!
        event.isAllDay = allDay
        if has("timeZone") || allDay != wasAllDay {
            event.timeZone = allDay || floating ? nil : zone
        }
        switch (start, end) {
        case let (start?, end?):
            try setTimes(event, start: start, end: end, zone: zone, at: place)
        case let (start?, nil):
            // Keep the length of the event.
            if allDay {
                let newStart = try parseDay(start, field: "startDate", at: place)
                let calendar = localCalendar()
                let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: oldStart), to: calendar.startOfDay(for: oldEnd)).day!
                event.startDate = newStart
                event.endDate = calendar.date(byAdding: .day, value: days, to: newStart)
            } else {
                let newStart = try parseTime(start, zone: zone, field: "startDate", at: place)
                event.startDate = newStart
                event.endDate = newStart.addingTimeInterval(oldEnd.timeIntervalSince(oldStart))
            }
        case let (nil, end?):
            let newEnd = allDay
                ? localCalendar().date(byAdding: .day, value: -1, to: try parseDay(end, field: "endDate", at: place))!
                : try parseTime(end, zone: zone, field: "endDate", at: place)
            guard newEnd >= oldStart, allDay || newEnd > oldStart else {
                throw CommandError("endDate \(end) must be after the event's start, \(formatStart(event))")
            }
            event.endDate = newEnd
        case (nil, nil):
            break
        }
        if let title { event.title = title }
        if has("location") { event.location = try string(changes, "location", at: place) }
        if has("notes") { event.notes = try string(changes, "notes", at: place) }
        if has("url") { event.url = newURL }
        if let rules { event.recurrenceRules = rules }
        if let newCalendar { event.calendar = newCalendar }
    }

    /// Sets start and end. All-day input uses yyyy-mm-dd with an exclusive end date.
    func setTimes(_ event: EKEvent, start: String, end: String, zone: TimeZone, at place: String) throws {
        if event.isAllDay {
            let first = try parseDay(start, field: "startDate", at: place)
            let after = try parseDay(end, field: "endDate", at: place)
            guard after > first else {
                throw CommandError("\(place): all-day endDate must be after startDate. The end date is exclusive, so a one-day event on \(start) ends the next day")
            }
            event.startDate = first
            event.endDate = localCalendar().date(byAdding: .day, value: -1, to: after)
        } else {
            let first = try parseTime(start, zone: zone, field: "startDate", at: place)
            let last = try parseTime(end, zone: zone, field: "endDate", at: place)
            guard last > first else { throw CommandError("\(place): endDate must be after startDate") }
            event.startDate = first
            event.endDate = last
        }
    }

    func ekRule(_ text: String, zone: TimeZone, at place: String) throws -> EKRecurrenceRule {
        do {
            return try RecurrenceRule.parse(text).ekRule(in: zone)
        } catch let error as RecurrenceRule.ParseError {
            throw CommandError("\(place): recurrence \"\(text)\": \(error.description)")
        }
    }

    // MARK: Finding things

    func findEvent(_ id: String, occurrence: String?, hint: String) throws -> EKEvent {
        guard let first = store.event(withIdentifier: id) else {
            throw CommandError("event not found: \(id). Get event IDs from dump-events")
        }
        guard let occurrence else {
            if first.hasRecurrenceRules {
                throw CommandError("\(id) is a repeating event. \(hint). Nothing was changed")
            }
            return first
        }
        let at: Date
        if let date = isoFormatter().date(from: occurrence) ?? dayFormatter().date(from: occurrence) {
            at = date
        } else {
            throw CommandError("bad occurrence start \(occurrence). Copy startDate from dump-events")
        }
        let predicate = store.predicateForEvents(withStart: at.addingTimeInterval(-1), end: at.addingTimeInterval(86_400), calendars: [first.calendar])
        guard let match = store.events(matching: predicate).first(where: { $0.eventIdentifier == id && $0.startDate == at }) else {
            throw CommandError("no occurrence of \(id) starts at \(occurrence). Copy startDate from dump-events. Nothing was changed")
        }
        return match
    }

    func resolveSpan(_ text: String?, for event: EKEvent, hint: String) throws -> EKSpan {
        switch text {
        case nil:
            if event.hasRecurrenceRules {
                throw CommandError("\(event.eventIdentifier ?? "this event") is a repeating event. \(hint). Nothing was changed")
            }
            return .thisEvent
        case "this": return .thisEvent
        case "future": return .futureEvents
        case let other?: throw CommandError("span must be this or future, not \(other)")
        }
    }

    func spanName(_ span: EKSpan) -> String {
        span == .futureEvents ? "future" : "this"
    }

    /// Matches a calendar by account and either its title or its ID from list-calendars.
    func findCalendar(_ source: String, _ title: String) throws -> EKCalendar {
        let matches = store.calendars(for: .event).filter {
            $0.source.title == source && ($0.title == title || $0.calendarIdentifier == title)
        }
        if matches.count > 1 {
            throw CommandError("\(matches.count) calendars in \(source) are named \(title). Use the calendar ID from list-calendars instead")
        }
        guard let calendar = matches.first else { throw calendarNotFound(source, title) }
        return calendar
    }

    /// An update-event "calendar": a calendar ID, or {"sourceTitle", "calendarTitle"}.
    func calendarReference(_ value: Any) throws -> EKCalendar {
        if let id = value as? String {
            guard let calendar = store.calendar(withIdentifier: id) else {
                throw CommandError("no calendar has ID \(id). Run list-calendars to see IDs")
            }
            return calendar
        }
        guard let fields = value as? JSONObject else {
            throw CommandError("calendar must be a calendar ID or {\"sourceTitle\": ..., \"calendarTitle\": ...}")
        }
        try checkKeys(fields, allowed: ["sourceTitle", "calendarTitle"], required: ["sourceTitle", "calendarTitle"], at: "calendar")
        return try findCalendar(try string(fields, "sourceTitle", at: "calendar")!, try string(fields, "calendarTitle", at: "calendar")!)
    }

    func writableCalendar(_ calendar: EKCalendar) throws -> EKCalendar {
        guard calendar.allowsContentModifications else {
            throw CommandError("calendar \(calendar.source.title)/\(calendar.title) is read-only. Pick another one from list-calendars")
        }
        return calendar
    }

    func calendarNotFound(_ source: String, _ title: String) -> CommandError {
        CommandError("calendar not found: \(source)/\(title). Run list-calendars to see account and calendar names")
    }

    // MARK: Output

    /// An event as dump-events prints it. Every field can be fed back to create-events or update-event.
    func snapshot(_ event: EKEvent) -> JSONObject {
        func orNull(_ value: Any?) -> Any { value ?? NSNull() }
        return [
            "eventIdentifier": orNull(event.eventIdentifier),
            "calendarIdentifier": event.calendar.calendarIdentifier,
            "calendarTitle": event.calendar.title,
            "sourceTitle": event.calendar.source.title,
            "title": event.title ?? "",
            "startDate": formatStart(event),
            "endDate": formatEnd(event),
            "isAllDay": event.isAllDay,
            "timeZone": orNull(event.isAllDay ? nil : event.timeZone?.identifier),
            "location": orNull(event.location),
            "notes": orNull(event.notes),
            "url": orNull(event.url?.absoluteString),
            "recurrence": orNull(event.recurrenceRules?.first.map { RecurrenceRule($0, allDay: event.isAllDay).rrule })
        ]
    }

    func formatStart(_ event: EKEvent) -> String {
        event.isAllDay ? dayFormatter().string(from: event.startDate) : isoFormatter().string(from: event.startDate)
    }

    /// All-day ends print as the exclusive yyyy-mm-dd that create-events takes.
    func formatEnd(_ event: EKEvent) -> String {
        guard event.isAllDay else { return isoFormatter().string(from: event.endDate) }
        let calendar = localCalendar()
        let lastDay = calendar.startOfDay(for: event.endDate)
        let exclusive = lastDay == event.endDate && event.endDate > event.startDate
            ? lastDay
            : calendar.date(byAdding: .day, value: 1, to: lastDay)!
        return dayFormatter().string(from: exclusive)
    }

    /// Checked before any change, so a bad receipt path never leaves a change unreported.
    /// It does not touch an existing file.
    func requireWritable(_ path: String, input: String?) throws {
        guard path != input else {
            throw CommandError("the receipt would overwrite the input file \(path). Use a different receipt file. Nothing was changed")
        }
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        let writable = fm.fileExists(atPath: path, isDirectory: &isDirectory)
            ? !isDirectory.boolValue && fm.isWritableFile(atPath: path)
            : fm.isWritableFile(atPath: (path as NSString).deletingLastPathComponent)
        guard writable else {
            throw CommandError("cannot write receipt \(path): the folder is missing or not writable. Nothing was changed")
        }
    }

    func writeReceipt(_ receipt: Any, to path: String) {
        do {
            let data = try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            lines.append("receipt=\(path)")
        } catch {
            lines.append("error=the calendar was changed, but the receipt could not be written to \(path): \(describe(error)). Check with dump-events before retrying")
        }
    }

    // MARK: Input

    func readJSON(_ path: String) throws -> Any {
        guard let data = FileManager.default.contents(atPath: path) else {
            throw CommandError("cannot read \(path). Check the path; relative paths start from the folder you ran the command in")
        }
        do {
            return try JSONSerialization.jsonObject(with: data)
        } catch {
            throw CommandError("\(path) is not valid JSON. See the examples in README.md")
        }
    }

    func checkKeys(_ object: JSONObject, allowed: [String], required: [String], at place: String) throws {
        if let unknown = object.keys.sorted().first(where: { !allowed.contains($0) }) {
            throw CommandError("\(place): unknown field \"\(unknown)\". Allowed: \(allowed.joined(separator: ", "))")
        }
        if let missing = required.first(where: { object[$0] == nil || object[$0] is NSNull }) {
            throw CommandError("\(place): missing field \"\(missing)\"")
        }
    }

    /// A string field, or nil when it is absent or null.
    func string(_ object: JSONObject, _ key: String, at place: String) throws -> String? {
        guard let value = object[key], !(value is NSNull) else { return nil }
        guard let text = value as? String else { throw CommandError("\(place): \"\(key)\" must be a string") }
        return text
    }

    func bool(_ object: JSONObject, _ key: String, at place: String) throws -> Bool? {
        guard let value = object[key], !(value is NSNull) else { return nil }
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw CommandError("\(place): \"\(key)\" must be true or false")
        }
        return number.boolValue
    }

    func url(_ object: JSONObject, at place: String) throws -> URL? {
        guard let text = try string(object, "url", at: place) else { return nil }
        guard let url = URL(string: text), url.scheme != nil else {
            throw CommandError("\(place): url \(text) is not a full URL, like https://example.com")
        }
        return url
    }

    func timeZone(_ name: String, at place: String) throws -> TimeZone {
        guard let zone = TimeZone(identifier: name) else {
            throw CommandError("\(place): unknown timeZone \(name). Use an IANA name like America/New_York")
        }
        return zone
    }

    /// A timed date: ISO 8601 with Z or an offset, or a local time in `zone`.
    func parseTime(_ text: String, zone: TimeZone, field: String, at place: String) throws -> Date {
        if let date = isoFormatter().date(from: text) { return date }
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = zone
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        throw CommandError("\(place): bad \(field) \(text). Use a local time like 2026-10-06T09:00:00, or UTC like 2026-10-06T15:00:00Z")
    }

    func parseDay(_ text: String, field: String, at place: String) throws -> Date {
        guard let date = dayFormatter().date(from: text) else {
            throw CommandError("\(place): bad \(field) \(text). All-day events use yyyy-mm-dd")
        }
        return date
    }

    func resolvePath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return expanded }
        return URL(fileURLWithPath: cwd).appendingPathComponent(expanded).path
    }

    /// Apple's error text without its trailing period, since messages are joined with ". ".
    func describe(_ error: Error) -> String {
        var text = error.localizedDescription
        while text.hasSuffix(".") { text.removeLast() }
        return text
    }

    func isoFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }

    func localCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    /// All-day dates are local calendar days.
    func dayFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = localCalendar()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
}

extension RecurrenceRule {
    /// All-day events get a date-only UNTIL, as RFC 5545 requires for date starts.
    init(_ rule: EKRecurrenceRule, allDay: Bool) {
        let frequency: Frequency
        switch rule.frequency {
        case .daily: frequency = .daily
        case .weekly: frequency = .weekly
        case .monthly: frequency = .monthly
        case .yearly: frequency = .yearly
        @unknown default: frequency = .daily
        }
        self.init(frequency: frequency)
        interval = rule.interval
        byDay = (rule.daysOfTheWeek ?? []).map { Day(weekday: $0.dayOfTheWeek.rawValue, ordinal: $0.weekNumber) }
        byMonthDay = (rule.daysOfTheMonth ?? []).map(\.intValue)
        byMonth = (rule.monthsOfTheYear ?? []).map(\.intValue)
        byYearDay = (rule.daysOfTheYear ?? []).map(\.intValue)
        byWeekNo = (rule.weeksOfTheYear ?? []).map(\.intValue)
        bySetPos = (rule.setPositions ?? []).map(\.intValue)
        if let ruleEnd = rule.recurrenceEnd {
            if ruleEnd.occurrenceCount > 0 {
                end = .count(ruleEnd.occurrenceCount)
            } else if let date = ruleEnd.endDate {
                if allDay {
                    let day = Calendar(identifier: .gregorian).dateComponents(in: .current, from: date)
                    end = .until(.date(year: day.year!, month: day.month!, day: day.day!))
                } else {
                    end = .until(.utc(date))
                }
            }
        }
        if rule.firstDayOfTheWeek != 0 { weekStart = rule.firstDayOfTheWeek }
    }

    func ekRule(in zone: TimeZone) -> EKRecurrenceRule {
        let ekFrequency: EKRecurrenceFrequency
        switch frequency {
        case .daily: ekFrequency = .daily
        case .weekly: ekFrequency = .weekly
        case .monthly: ekFrequency = .monthly
        case .yearly: ekFrequency = .yearly
        }
        func numbers(_ values: [Int]) -> [NSNumber]? {
            values.isEmpty ? nil : values.map { NSNumber(value: $0) }
        }
        let days = byDay.map { day -> EKRecurrenceDayOfWeek in
            let weekday = EKWeekday(rawValue: day.weekday)!
            return day.ordinal == 0 ? EKRecurrenceDayOfWeek(weekday) : EKRecurrenceDayOfWeek(weekday, weekNumber: day.ordinal)
        }
        var ruleEnd: EKRecurrenceEnd?
        switch end {
        case .count(let n): ruleEnd = EKRecurrenceEnd(occurrenceCount: n)
        case .until(let until): ruleEnd = EKRecurrenceEnd(end: RecurrenceRule.untilDate(until, in: zone))
        case nil: ruleEnd = nil
        }
        return EKRecurrenceRule(
            recurrenceWith: ekFrequency,
            interval: interval,
            daysOfTheWeek: days.isEmpty ? nil : days,
            daysOfTheMonth: numbers(byMonthDay),
            monthsOfTheYear: numbers(byMonth),
            weeksOfTheYear: numbers(byWeekNo),
            daysOfTheYear: numbers(byYearDay),
            setPositions: numbers(bySetPos),
            end: ruleEnd
        )
    }
}
