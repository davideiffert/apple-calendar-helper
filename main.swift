import EventKit
import Foundation
import Cocoa

// Launched with no command (Finder, Login Items, `open`) or with `serve`: run the queue.
let firstArg = CommandLine.arguments.dropFirst().first
let serving = firstArg == nil || firstArg == "serve" || firstArg!.hasPrefix("-psn_")

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
    let commandNames = ["list-calendars", "dump-events", "create-events", "update-event", "delete-event"]
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
        let id = processingFile.deletingPathExtension().lastPathComponent
        let resultFile = resultsDir.appendingPathComponent(id + ".result.json")
        let queued: QueuedCommand
        do {
            queued = try JSONDecoder().decode(QueuedCommand.self, from: Data(contentsOf: processingFile))
        } catch {
            deliver(["error=could not read command file \(commandFile.lastPathComponent): \(describe(error)). It did not run"], id: id, to: resultFile)
            try? fm.removeItem(at: processingFile)
            return
        }

        let saved = (args, lines, cwd)
        args = [queued.command] + (queued.args ?? [])
        cwd = queued.cwd ?? NSHomeDirectory()
        lines = []
        runCommand()
        let output = lines
        (args, lines, cwd) = saved

        if deliver(output, id: id, to: resultFile) {
            try? fm.removeItem(at: processingFile)
            writeServerStatus("processed \(queued.command)")
        } else {
            // Keep the processing record: the next start reports it as "may have run".
            writeServerStatus("error: \(queued.command) ran, but its result could not be written to \(resultsDir.path)")
        }
    }

    @discardableResult
    func deliver(_ output: [String], id: String, to file: URL) -> Bool {
        let result: [String: Any] = ["id": id, "ok": !output.contains(where: { $0.hasPrefix("error=") }), "lines": output]
        guard let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) else { return false }
        return (try? data.write(to: file, options: .atomic)) != nil
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
