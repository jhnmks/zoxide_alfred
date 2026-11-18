import AppKit
import Foundation
import Darwin

struct WorkflowError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

func json(_ value: Any) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
}
func lines(_ text: String) -> [String] {
    text.components(separatedBy: .newlines).filter { !$0.isEmpty }
}
func canonical(_ path: String) -> String? {
    guard let pointer = realpath(path, nil) else { return nil }
    defer { free(pointer) }
    return String(cString: pointer)
}
func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
func appleString(_ value: String) -> String {
    "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\r", with: "\\r")
        .replacingOccurrences(of: "\n", with: "\\n") + "\""
}

struct Workflow {
    var environment = ProcessInfo.processInfo.environment
    let fm = FileManager.default
    var home: String { environment["HOME"] ?? fm.homeDirectoryForCurrentUser.path }

    func expand(_ input: String) -> String {
        var path = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.count >= 2, let first = path.first, first == path.last, first == "\"" || first == "'" {
            path = String(path.dropFirst().dropLast())
        }
        if path == "~" { return home }
        return path.hasPrefix("~/") ? home + String(path.dropFirst()) : path
    }
    func directory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return fm.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
    func binary() throws -> String {
        let explicit = environment["zoxide_path"] ?? ""
        let candidates = explicit.isEmpty ? ["/opt/homebrew/bin/zoxide", "/usr/local/bin/zoxide", home + "/.local/bin/zoxide", home + "/.cargo/bin/zoxide"] : [expand(explicit)]
        guard let path = candidates.first(where: { $0.hasPrefix("/") && fm.isExecutableFile(atPath: $0) && !directory($0) }) else {
            throw WorkflowError("Install zoxide (brew install zoxide), or choose its installed executable in Configure Workflow.")
        }
        return path
    }
    // A single output pipe avoids deadlocks if the child fills stderr while stdout is read.
    func process(_ executable: String, _ arguments: [String], env: [String: String]? = nil) throws -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        task.environment = env ?? environment
        let output = Pipe()
        task.standardOutput = output
        task.standardError = output
        try task.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
        guard task.terminationStatus == 0 else {
            throw WorkflowError(text.isEmpty ? "\(executable) exited with status \(task.terminationStatus)" : text)
        }
        return text
    }
    func zoxide(_ arguments: [String]) throws -> String {
        var env = environment
        for key in ["_ZO_DATA_DIR", "XDG_DATA_HOME"] {
            if let value = env[key], !value.isEmpty { env[key] = expand(value) }
            else { env.removeValue(forKey: key) }
        }
        return try process(binary(), arguments, env: env)
    }
    func records(_ query: String = "", all: Bool = false) throws -> [String] {
        var args = ["query", "--list"]
        if all { args.append("--all") }
        args.append("--")
        args += query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        do { return lines(try zoxide(args)) }
        catch {
            if error.localizedDescription.contains("no match found") { return [] }
            throw error
        }
    }
    func payload(_ action: String, _ path: String) throws -> String {
        try json(["action": action, "path": path])
    }
    func item(_ path: String, removing: Bool) throws -> [String: Any] {
        var item: [String: Any] = [
            "title": URL(fileURLWithPath: path).lastPathComponent.isEmpty ? "/" : URL(fileURLWithPath: path).lastPathComponent,
            "subtitle": path, "arg": try payload("open", path),
            "icon": ["type": "fileicon", "path": path], "text": ["copy": path, "largetype": path],
            "quicklookurl": path, "action": ["file": path]
        ]
        if removing {
            item["type"] = "file:skipcheck"
            item["arg"] = path
            item["subtitle"] = "Enter: remove record · ⌥↓: buffer · ⌥→: action buffer — " + path
        } else {
            item["mods"] = [
                "cmd": ["arg": try payload("parent", path), "subtitle": "Open parent folder in Finder"],
                "ctrl": ["arg": try payload("terminal", path), "subtitle": "Open in configured terminal"],
                "shift": ["arg": try payload("copy", path), "subtitle": "Copy folder path"]
            ]
        }
        return item
    }
    func search(_ query: String, removing: Bool = false) throws -> String {
        _ = try binary()
        let paths = try records(query, all: removing)
        let items: [[String: Any]] = paths.isEmpty ? [["title": "No matching folders", "subtitle": "Check the optional data directory override in Configure Workflow.", "valid": false]] : try paths.map { try item($0, removing: removing) }
        return try json(["items": items])
    }
    func browse(_ query: String) throws -> String {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = text.split(maxSplits: 1, whereSeparator: { $0.isWhitespace }).map(String.init)
        let command = parts.first ?? ""
        if command == "remove" || command == "delete" { return try json(["items": []]) }
        if command == "add" {
            let path = expand(parts.count > 1 ? parts[1] : "")
            guard path.hasPrefix("/") else { return try json(["items": []]) }
            return try json(["items": [["title": directory(path) ? "Add folder to zoxide" : "Enter an existing absolute folder path", "subtitle": path, "valid": directory(path), "arg": try payload("add", path)]]])
        }
        return try search(text)
    }
    func validateRemoval(_ arguments: [String]) throws -> [String] {
        let stored = try records(all: true)
        let exact = Set(stored)
        var resolvedRecords: [String: [String]] = [:]
        for path in stored {
            if let resolved = canonical(path) { resolvedRecords[resolved, default: []].append(path) }
        }
        var result: [String] = []
        var seen = Set<String>()
        for argument in arguments {
            let entries = exact.contains(argument) ? [argument] : argument.components(separatedBy: CharacterSet.newlines.union(.init(charactersIn: "\t"))).filter { !$0.isEmpty }
            for entry in entries {
                var path = entry
                if !exact.contains(path), path.hasPrefix("/"), let resolved = canonical(path), let matches = resolvedRecords[resolved], matches.count == 1 {
                    path = matches[0]
                }
                guard path.hasPrefix("/"), exact.contains(path) else {
                    throw WorkflowError("Nothing removed. Selection does not uniquely match a zoxide record: \(entry)\nClear stale buffer items and select records from z remove again.")
                }
                if seen.insert(path).inserted { result.append(path) }
            }
        }
        guard !result.isEmpty else { throw WorkflowError("Select at least one zoxide record to remove.") }
        return result
    }
    func remove(_ arguments: [String]) throws -> String {
        let paths = try validateRemoval(arguments)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Remove \(paths.count) record(s) from zoxide?"
        alert.informativeText = "Only database records will be removed. No files or folders will be deleted."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Remove")
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[1].keyEquivalent = ""
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 560, height: 220))
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 900, height: max(220, paths.count * 22)))
        text.isEditable = false
        text.string = paths.joined(separator: "\n")
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        scroll.documentView = text
        alert.accessoryView = scroll
        guard alert.runModal() == .alertSecondButtonReturn else { return "" }
        var failures: [String] = []
        var count = 0
        for path in paths {
            do { _ = try zoxide(["remove", "--", path]); count += 1 }
            catch { failures.append(path + ": " + error.localizedDescription) }
        }
        return "Removed \(count) zoxide record(s). No files deleted." + (failures.isEmpty ? "" : "\nFailed (\(failures.count)):\n" + failures.joined(separator: "\n"))
    }
    func add(_ path: String) throws -> String {
        guard path.hasPrefix("/"), directory(path) else { throw WorkflowError("An existing absolute folder path is required: " + path) }
        _ = try zoxide(["add", "--", path])
        return "Added to zoxide: " + path
    }
    func terminal(_ path: String) throws {
        let configured = environment["terminal_app"] ?? ""
        let legacy = environment["terminal"] ?? "Terminal"
        var name = legacy
        var appPath = ""
        if !configured.isEmpty {
            appPath = expand(configured)
            guard appPath.hasPrefix("/"), appPath.hasSuffix(".app"), directory(appPath) else {
                throw WorkflowError("Choose an installed terminal .app in Configure Workflow.")
            }
            name = URL(fileURLWithPath: appPath).deletingPathExtension().lastPathComponent
        }
        if name == "Terminal" || name == "iTerm2" || name == "iTerm" {
            // AppleScript is used only for terminal APIs; all database/process work is Swift.
            let command = appleString("cd -- " + shellQuote(path))
            let script: String
            if name == "Terminal" {
                script = "tell application id \"com.apple.Terminal\"\nactivate\ndo script \(command)\nend tell"
            } else {
                script = "tell application id \"com.googlecode.iterm2\"\nactivate\nset newWindow to (create window with default profile)\ntell current session of newWindow to write text \(command)\nend tell"
            }
            var error: NSDictionary?
            guard let automation = NSAppleScript(source: script) else {
                throw WorkflowError("Could not prepare terminal automation.")
            }
            automation.executeAndReturnError(&error)
            if let error = error {
                throw WorkflowError("Terminal automation failed: \(error). Check macOS Automation permissions.")
            }
        } else {
            _ = try process("/usr/bin/open", ["-a", appPath.isEmpty ? name : appPath, path])
        }
    }
    func action(_ raw: String) throws -> String {
        guard let data = raw.data(using: .utf8), let object = try JSONSerialization.jsonObject(with: data) as? [String: String], let action = object["action"] else { throw WorkflowError("Invalid action payload.") }
        if action == "pick" {
            NSApplication.shared.setActivationPolicy(.accessory)
            NSApp.activate(ignoringOtherApps: true)
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let path = panel.url?.path else { return "" }
            return try add(path)
        }
        guard let path = object["path"], path.hasPrefix("/") else { throw WorkflowError("An absolute folder path is required.") }
        if action == "remove" { return try remove([path]) }
        if action == "add" { return try add(path) }
        if action == "copy" {
            NSPasteboard.general.clearContents()
            guard NSPasteboard.general.setString(path, forType: .string) else { throw WorkflowError("Could not copy folder path.") }
            return "Copied: " + path
        }
        guard directory(path) else { throw WorkflowError("Folder no longer exists: " + path) }
        switch action {
        case "open", "parent":
            let target = action == "parent" ? URL(fileURLWithPath: path).deletingLastPathComponent().path : path
            _ = try process("/usr/bin/open", ["-a", "Finder", target])
        case "terminal": try terminal(path)
        default: throw WorkflowError("Unknown action: " + action)
        }
        _ = try zoxide(["add", "--", path])
        return ""
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
let mode = arguments.first ?? "browse"
let values = Array(arguments.dropFirst())
let query = values.first ?? ""
let workflow = Workflow()
do {
    let output: String
    switch mode {
    case "browse": output = try workflow.browse(query)
    case "search":
        if query == "delete" || query.hasPrefix("delete ") { output = try workflow.search(String(query.dropFirst(6)).trimmingCharacters(in: .whitespaces), removing: true) }
        else { output = try workflow.browse(query) }
    case "delete-search": output = try workflow.search(query, removing: true)
    case "add-path": output = try workflow.add(query)
    case "action": output = try workflow.action(query)
    case "remove-paths": output = try workflow.remove(values)
    case "validate-removal": output = try json(["paths": workflow.validateRemoval(values)])
    default: throw WorkflowError("Unknown command: " + mode)
    }
    if !output.isEmpty { print(output) }
} catch {
    if ["browse", "search", "delete-search"].contains(mode) {
        print((try? json(["items": [["title": "Zoxide needs attention", "subtitle": error.localizedDescription, "valid": false]]])) ?? "{\"items\":[]}")
    } else { print("Zoxide: " + error.localizedDescription) }
}
