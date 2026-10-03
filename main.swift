import EventKit
import Foundation
import Cocoa

// Launched with no command (Finder, Login Items, `open`) or with `serve`: run the queue.
let firstArg = CommandLine.arguments.dropFirst().first
let serving = firstArg == nil || firstArg == "serve" || firstArg!.hasPrefix("-psn_")

struct DumpedEvent: Codable {
    let eventIdentifier: String?
    let calendarIdentifier: String
    let calendarTitle: String
    let sourceTitle: String
    let title: String
    let startDate: String
    let endDate: String
    let isAllDay: Bool
    let location: String?
    let notes: String?
    let url: String?
    let hasRecurrenceRules: Bool
}

struct EventToCreate: Codable {
    let sourceTitle: String
    let calendarTitle: String
    let title: String
    let startDate: String
    let endDate: String
    let isAllDay: Bool
    let recurrence: String?
    let recurrenceEndDate: String?
    let notes: String?
    let location: String?
}

struct QueuedCommand: Codable {
    let id: String?
    let command: String
    let args: [String]?
    let cwd: String?
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = EKEventStore()
    var lines: [String] = []
    var args = Array(CommandLine.arguments.dropFirst())
    var cwd = FileManager.default.currentDirectoryPath
    let commandNames = ["list-calendars", "dump-events", "create-events", "update-all-day-end", "delete-event", "delete-event-series"]
    let runtimeRoot: URL = {
        if let home = ProcessInfo.processInfo.environment["CALENDAR_HELPER_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/apple-calendar-helper")
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let initialStatus = EKEventStore.authorizationStatus(for: .event)
        lines.append("initialStatus=\(initialStatus.rawValue)")

        if initialStatus.rawValue == 3 {
            lines.append("granted=true")
            lines.append("finalStatus=\(initialStatus.rawValue)")
            if serving {
                startServer()
                writeOutput()
            } else {
                runCommand()
                writeOutput()
                NSApp.terminate(nil)
            }
            return
        }

        let finish: (Bool, Error?) -> Void = { granted, error in
            if let error {
                self.lines.append("error=\(error.localizedDescription)")
            }
            self.lines.append("granted=\(granted)")
            self.lines.append("finalStatus=\(EKEventStore.authorizationStatus(for: .event).rawValue)")
            DispatchQueue.main.async {
                if granted {
                    if serving {
                        self.startServer()
                        self.writeOutput()
                        return
                    } else {
                        self.runCommand()
                    }
                } else {
                    self.lines.append("error=calendar access denied. Allow \"Apple Calendar Helper\" in System Settings > Privacy & Security > Calendars. If it is already on, or you just rebuilt the app, run: tccutil reset Calendar \(Bundle.main.bundleIdentifier ?? "") && open -a \"Apple Calendar Helper\", then click Allow")
                    self.writeServerStatus("access-denied")
                }
                self.writeOutput()
                NSApp.terminate(nil)
            }
        }

        if serving {
            writeServerStatus("waiting-for-permission")
        }
        if #available(macOS 14.0, *) {
            store.requestFullAccessToEvents(completion: finish)
        } else {
            store.requestAccess(to: .event, completion: finish)
        }
    }

    func startServer() {
        let fm = FileManager.default
        for folder in ["commands", "processing", "results", "logs"] {
            try? fm.createDirectory(at: runtimeRoot.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        recoverInterruptedCommands()
        lines.append("server=started")
        lines.append("runtime=\(runtimeRoot.path)")
        writeServerStatus("started")
        DispatchQueue.global(qos: .utility).async {
            while true {
                self.processQueuedCommand()
                Thread.sleep(forTimeInterval: 1.0)
            }
        }
    }

    /// A command left in processing/ was cut off mid-run. It may or may not have
    /// changed the calendar, so report that rather than running it again.
    func recoverInterruptedCommands() {
        let fm = FileManager.default
        let processingDir = runtimeRoot.appendingPathComponent("processing")
        let resultsDir = runtimeRoot.appendingPathComponent("results")
        for file in (try? fm.contentsOfDirectory(at: processingDir, includingPropertiesForKeys: nil)) ?? [] where file.pathExtension == "json" {
            let id = file.deletingPathExtension().lastPathComponent
            let result: [String: Any] = [
                "id": id,
                "ok": false,
                "lines": ["error=the helper stopped while running this command. It may have partly run. Check with dump-events before retrying"]
            ]
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: resultsDir.appendingPathComponent(id + ".result.json"), options: .atomic)
            }
            try? fm.removeItem(at: file)
        }
    }

    func processQueuedCommand() {
        let fm = FileManager.default
        let commandsDir = runtimeRoot.appendingPathComponent("commands")
        let processingDir = runtimeRoot.appendingPathComponent("processing")
        let resultsDir = runtimeRoot.appendingPathComponent("results")
        guard let files = try? fm.contentsOfDirectory(at: commandsDir, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles]) else {
            return
        }
        let jsonFiles = files.filter { $0.pathExtension == "json" }.sorted { lhs, rhs in
            let left = (try? lhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
            let right = (try? rhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
            return left < right
        }
        guard let commandFile = jsonFiles.first else { return }

        let processingFile = processingDir.appendingPathComponent(commandFile.lastPathComponent)
        // Another helper instance may have claimed this file first.
        guard (try? fm.moveItem(at: commandFile, to: processingFile)) != nil else { return }
        do {
            let data = try Data(contentsOf: processingFile)
            let queued = try JSONDecoder().decode(QueuedCommand.self, from: data)
            let originalArgs = args
            let originalLines = lines
            args = [queued.command] + (queued.args ?? [])
            cwd = queued.cwd ?? NSHomeDirectory()
            lines = []
            runCommand()
            let result: [String: Any] = [
                "id": queued.id ?? processingFile.deletingPathExtension().lastPathComponent,
                "command": queued.command,
                "ok": !lines.contains(where: { $0.hasPrefix("error=") }),
                "lines": lines
            ]
            let resultData = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            let resultName = processingFile.deletingPathExtension().lastPathComponent + ".result.json"
            try resultData.write(to: resultsDir.appendingPathComponent(resultName), options: .atomic)
            args = originalArgs
            lines = originalLines
            try? fm.removeItem(at: processingFile)
            writeServerStatus("processed \(queued.command)")
        } catch {
            let result: [String: Any] = [
                "id": processingFile.deletingPathExtension().lastPathComponent,
                "ok": false,
                "lines": ["error=could not read command file \(commandFile.lastPathComponent): \(describe(error))"]
            ]
            if let resultData = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
                let resultName = processingFile.deletingPathExtension().lastPathComponent + ".result.json"
                try? resultData.write(to: resultsDir.appendingPathComponent(resultName), options: .atomic)
            }
            try? fm.removeItem(at: processingFile)
            writeServerStatus("error \(error.localizedDescription)")
        }
    }

    func writeServerStatus(_ status: String) {
        try? FileManager.default.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
        let statusPath = runtimeRoot.appendingPathComponent("status.json")
        let payload: [String: Any] = [
            "status": status,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "updatedAt": ISO8601DateFormatter().string(from: Date())
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: statusPath, options: .atomic)
        }
    }

    func runCommand() {
        guard let command = args.first else {
            listCalendars()
            return
        }

        switch command {
        case "list-calendars":
            listCalendars()
        case "dump-events":
            dumpEvents()
        case "create-events":
            createEvents()
        case "update-all-day-end":
            updateAllDayEnd()
        case "delete-event":
            deleteEvent()
        case "delete-event-series":
            deleteEventSeries()
        default:
            lines.append("error=unknown command \(command). Commands: \(commandNames.joined(separator: ", "))")
        }
    }

    func resolvePath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return expanded }
        return URL(fileURLWithPath: cwd).appendingPathComponent(expanded).path
    }

    func describe(_ error: Error) -> String {
        guard let decoding = error as? DecodingError else {
            // Messages are joined with ". ", so drop Apple's own trailing period.
            var text = error.localizedDescription
            while text.hasSuffix(".") { text.removeLast() }
            return text
        }
        func where_(_ path: [CodingKey]) -> String {
            path.map { $0.intValue.map { "item \($0)" } ?? $0.stringValue }.joined(separator: ".")
        }
        switch decoding {
        case .keyNotFound(let key, let ctx):
            return "missing field \"\(key.stringValue)\" at \(where_(ctx.codingPath).isEmpty ? "top level" : where_(ctx.codingPath))"
        case .typeMismatch(_, let ctx), .valueNotFound(_, let ctx):
            return "wrong type at \(where_(ctx.codingPath)): \(ctx.debugDescription)"
        case .dataCorrupted:
            return "not valid JSON"
        @unknown default:
            return error.localizedDescription
        }
    }

    func calendarNotFound(_ source: String, _ title: String) {
        lines.append("error=calendar not found: \(source)/\(title). Run list-calendars to see account and calendar names")
    }

    func eventNotFound(_ id: String) {
        lines.append("error=event not found: \(id). Get event IDs from dump-events")
    }

    func listCalendars() {
        for calendar in store.calendars(for: .event) {
            lines.append("\(calendar.source.title)\t\(calendar.title)\t\(calendar.calendarIdentifier)")
        }
    }

    func dumpEvents() {
        guard args.count >= 6 else {
            lines.append("error=usage dump-events <source> <calendar> <start-yyyy-mm-dd> <end-yyyy-mm-dd> <output-json>")
            return
        }

        let source = args[1]
        let calendarTitle = args[2]
        let startText = args[3]
        let endText = args[4]
        let outputPath = resolvePath(args[5])
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        let dayFormatter = DateFormatter()
        dayFormatter.calendar = Calendar(identifier: .gregorian)
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.timeZone = TimeZone.current
        dayFormatter.dateFormat = "yyyy-MM-dd"

        guard let start = dayFormatter.date(from: startText), let end = dayFormatter.date(from: endText) else {
            lines.append("error=bad date \(startText) or \(endText). Use yyyy-mm-dd")
            return
        }

        guard end > start else {
            lines.append("error=end date \(endText) must be after start date \(startText). The end date is not included")
            return
        }
        guard end <= Calendar(identifier: .gregorian).date(byAdding: .year, value: 4, to: start)! else {
            lines.append("error=EventKit searches at most 4 years at a time. Split the range into smaller dumps")
            return
        }

        let calendars = store.calendars(for: .event).filter {
            $0.source.title == source && (calendarTitle == "*" || $0.title == calendarTitle || $0.calendarIdentifier == calendarTitle)
        }
        if calendars.isEmpty {
            calendarNotFound(source, calendarTitle)
            return
        }

        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
        let events = store.events(matching: predicate).map { event in
            DumpedEvent(
                eventIdentifier: event.eventIdentifier,
                calendarIdentifier: event.calendar.calendarIdentifier,
                calendarTitle: event.calendar.title,
                sourceTitle: event.calendar.source.title,
                title: event.title ?? "",
                startDate: formatter.string(from: event.startDate),
                endDate: formatter.string(from: event.endDate),
                isAllDay: event.isAllDay,
                location: event.location,
                notes: event.notes,
                url: event.url?.absoluteString,
                hasRecurrenceRules: !(event.recurrenceRules ?? []).isEmpty
            )
        }

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(events)
            try data.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
            lines.append("dumped=\(events.count)")
            lines.append("output=\(outputPath)")
        } catch {
            lines.append("error=cannot write \(outputPath): \(describe(error)). Pick a folder you can write to")
        }
    }

    func createEvents() {
        guard args.count >= 3 else {
            lines.append("error=usage create-events <input-json> <receipt-json>")
            return
        }

        let inputPath = resolvePath(args[1])
        let receiptPath = resolvePath(args[2])
        guard let data = FileManager.default.contents(atPath: inputPath) else {
            lines.append("error=cannot read \(inputPath)")
            return
        }
        let events: [EventToCreate]
        do {
            events = try JSONDecoder().decode([EventToCreate].self, from: data)
        } catch {
            lines.append("error=bad input \(inputPath): \(describe(error)). See the create-events example in README.md")
            return
        }
        guard canWriteReceipt(receiptPath) else { return }

        let iso = isoFormatter()
        let days = dayFormatter()
        let recurrences = ["yearly", "weekly", "biweekly", "monthly-third-wednesday"]
        var receipts: [[String: String]] = []
        var failed = 0

        for item in events {
            func fail(_ message: String) {
                lines.append("error=\"\(item.title)\": \(message)")
                failed += 1
            }
            guard let calendar = findCalendar(item.sourceTitle, item.calendarTitle) else {
                failed += 1
                continue
            }

            let event = EKEvent(eventStore: store)
            event.calendar = calendar
            event.title = item.title
            event.notes = item.notes
            event.location = item.location
            event.isAllDay = item.isAllDay

            if item.isAllDay {
                guard let start = days.date(from: item.startDate), let end = days.date(from: item.endDate) else {
                    fail("bad all-day date. Use yyyy-mm-dd, with an exclusive end date")
                    continue
                }
                event.startDate = start
                event.endDate = Calendar(identifier: .gregorian).date(byAdding: .day, value: -1, to: end) ?? end
            } else {
                guard let start = iso.date(from: item.startDate), let end = iso.date(from: item.endDate) else {
                    fail("bad date. Use ISO 8601 with a time zone, like 2026-10-06T16:00:00Z")
                    continue
                }
                event.startDate = start
                event.endDate = end
            }

            if let recurrence = item.recurrence {
                guard recurrences.contains(recurrence) else {
                    fail("unknown recurrence \(recurrence). Use one of: \(recurrences.joined(separator: ", ")), or null")
                    continue
                }
                var until: EKRecurrenceEnd?
                if let text = item.recurrenceEndDate {
                    guard let date = iso.date(from: text) ?? days.date(from: text) else {
                        fail("bad recurrenceEndDate \(text). Use yyyy-mm-dd or ISO 8601")
                        continue
                    }
                    until = EKRecurrenceEnd(end: date)
                } else if recurrence != "yearly" {
                    fail("\(recurrence) needs a recurrenceEndDate")
                    continue
                }
                switch recurrence {
                case "yearly":
                    event.recurrenceRules = [EKRecurrenceRule(recurrenceWith: .yearly, interval: 1, end: until)]
                case "weekly":
                    event.recurrenceRules = [EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, end: until)]
                case "biweekly":
                    event.recurrenceRules = [EKRecurrenceRule(recurrenceWith: .weekly, interval: 2, end: until)]
                default:
                    event.recurrenceRules = [EKRecurrenceRule(
                        recurrenceWith: .monthly,
                        interval: 1,
                        daysOfTheWeek: [EKRecurrenceDayOfWeek(.wednesday, weekNumber: 3)],
                        daysOfTheMonth: nil,
                        monthsOfTheYear: nil,
                        weeksOfTheYear: nil,
                        daysOfTheYear: nil,
                        setPositions: nil,
                        end: until
                    )]
                }
            }

            do {
                try store.save(event, span: .thisEvent, commit: true)
                receipts.append(receiptFor(event))
            } catch {
                fail(describe(error))
            }
        }

        lines.append("created=\(receipts.count)")
        if failed > 0 && !receipts.isEmpty {
            lines.append("note=\(receipts.count) of \(events.count) events were created and are listed in the receipt. Fix the errors and resubmit only the failed events")
        }
        writeReceipt(receipts, to: receiptPath)
    }

    func updateAllDayEnd() {
        guard args.count >= 4 else {
            lines.append("error=usage update-all-day-end <event-identifier> <exclusive-end-yyyy-mm-dd> <receipt-json> [occurrence-start]")
            return
        }
        let endText = args[2]
        guard let exclusiveEnd = dayFormatter().date(from: endText),
              let inclusiveEnd = Calendar(identifier: .gregorian).date(byAdding: .day, value: -1, to: exclusiveEnd) else {
            lines.append("error=bad end date \(endText). Use yyyy-mm-dd (the day after the last day)")
            return
        }
        changeEvent(id: args[1], receiptPath: resolvePath(args[3]), occurrence: args.count > 4 ? args[4] : nil, done: "updated=1") { event in
            guard event.isAllDay else {
                self.lines.append("error=\(args[1]) is not an all-day event. Nothing was changed")
                return false
            }
            event.endDate = inclusiveEnd
            try self.store.save(event, span: .thisEvent, commit: true)
            return true
        }
    }

    func deleteEvent() {
        guard args.count >= 3 else {
            lines.append("error=usage delete-event <event-identifier> <receipt-json> [occurrence-start]")
            return
        }
        changeEvent(id: args[1], receiptPath: resolvePath(args[2]), occurrence: args.count > 3 ? args[3] : nil, done: "deleted=1") { event in
            try self.store.remove(event, span: .thisEvent, commit: true)
            return true
        }
    }

    func deleteEventSeries() {
        guard args.count >= 3 else {
            lines.append("error=usage delete-event-series <event-identifier> <receipt-json> [occurrence-start]")
            return
        }
        changeEvent(id: args[1], receiptPath: resolvePath(args[2]), occurrence: args.count > 3 ? args[3] : nil, done: "deletedSeries=1") { event in
            try self.store.remove(event, span: .futureEvents, commit: true)
            return true
        }
    }

    /// Finds one event (or one occurrence of a repeating event), checks the receipt
    /// can be written, applies `change`, then writes the receipt.
    func changeEvent(id: String, receiptPath: String, occurrence: String?, done: String, change: (EKEvent) throws -> Bool) {
        guard let event = findEvent(id, occurrence: occurrence) else { return }
        guard canWriteReceipt(receiptPath) else { return }
        let receipt = receiptFor(event)
        do {
            guard try change(event) else { return }
        } catch {
            lines.append("error=\(describe(error)). Nothing was changed")
            return
        }
        lines.append(done)
        writeReceipt(receipt, to: receiptPath)
    }

    func findEvent(_ id: String, occurrence: String?) -> EKEvent? {
        guard let first = store.event(withIdentifier: id) else {
            eventNotFound(id)
            return nil
        }
        guard let occurrence else {
            if !(first.recurrenceRules ?? []).isEmpty {
                lines.append("error=\(id) is a repeating event. Add the occurrence's startDate from dump-events as the last argument. Nothing was changed")
                return nil
            }
            return first
        }
        guard let at = isoFormatter().date(from: occurrence) else {
            lines.append("error=bad occurrence start \(occurrence). Copy startDate from dump-events, like 2026-10-06T16:00:00Z")
            return nil
        }
        let predicate = store.predicateForEvents(withStart: at.addingTimeInterval(-1), end: at.addingTimeInterval(86_400), calendars: [first.calendar])
        if let match = store.events(matching: predicate).first(where: { $0.eventIdentifier == id && $0.startDate == at }) {
            return match
        }
        lines.append("error=no occurrence of \(id) starts at \(occurrence). Check startDate in dump-events. Nothing was changed")
        return nil
    }

    func receiptFor(_ event: EKEvent) -> [String: String] {
        let iso = isoFormatter()
        return [
            "title": event.title ?? "",
            "calendar": event.calendar.title,
            "source": event.calendar.source.title,
            "eventIdentifier": event.eventIdentifier ?? "",
            "startDate": iso.string(from: event.startDate),
            "endDate": iso.string(from: event.endDate)
        ]
    }

    /// Checked before any change, so a bad receipt path never leaves a change unreported.
    func canWriteReceipt(_ path: String) -> Bool {
        do {
            try Data("{}".utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
            return true
        } catch {
            lines.append("error=cannot write receipt \(path): \(describe(error)). Nothing was changed")
            return false
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

    func isoFormatter() -> ISO8601DateFormatter {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        return iso
    }

    func dayFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    /// Matches a calendar by account and either its title or its ID from list-calendars.
    func findCalendar(_ source: String, _ title: String) -> EKCalendar? {
        let matches = store.calendars(for: .event).filter {
            $0.source.title == source && ($0.title == title || $0.calendarIdentifier == title)
        }
        if matches.count > 1 {
            lines.append("error=\(matches.count) calendars in \(source) are named \(title). Use the calendar ID from list-calendars instead")
            return nil
        }
        guard let calendar = matches.first else {
            calendarNotFound(source, title)
            return nil
        }
        return calendar
    }

    func writeOutput() {
        try? FileManager.default.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
        let out = runtimeRoot.appendingPathComponent("last-run.txt")
        try? lines.joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
if serving {
    app.setActivationPolicy(.accessory)
} else {
    app.setActivationPolicy(.regular)
    app.activate(ignoringOtherApps: true)
}
app.run()
