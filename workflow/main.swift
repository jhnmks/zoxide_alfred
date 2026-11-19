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
    func removalPlan(_ arguments: [String]) throws -> (paths: [String], skipped: [String]) {
        let stored = try records(all: true)
        let exact = Set(stored)
        var resolvedRecords: [String: [String]] = [:]
        for path in stored {
            if let resolved = canonical(path) { resolvedRecords[resolved, default: []].append(path) }
        }
        var result: [String] = []
        var skipped: [String] = []
        var seen = Set<String>()
        for argument in arguments {
            let entries = exact.contains(argument) ? [argument] : argument.components(separatedBy: CharacterSet.newlines.union(.init(charactersIn: "\t"))).filter { !$0.isEmpty }
            for entry in entries {
                var path = entry
                guard path.hasPrefix("/") else {
                    throw WorkflowError("Nothing removed. Selection is not an absolute folder path: \(entry)")
                }
                if !exact.contains(path), let resolved = canonical(path), let matches = resolvedRecords[resolved] {
                    guard matches.count == 1 else {
                        throw WorkflowError("Nothing removed. Selection matches multiple zoxide records: \(entry)")
                    }
                    path = matches[0]
                }
                guard exact.contains(path) else {
                    if !skipped.contains(entry) { skipped.append(entry) }
                    continue
                }
                if seen.insert(path).inserted { result.append(path) }
            }
        }
        guard !result.isEmpty || !skipped.isEmpty else { throw WorkflowError("Select at least one zoxide record to remove.") }
        return (result, skipped)
    }
    func validateRemoval(_ arguments: [String]) throws -> [String] {
        try removalPlan(arguments).paths
    }
    func removalSearch(_ query: String) throws -> String {
        guard query.trimmingCharacters(in: .whitespacesAndNewlines) == "all" else {
            return try search(query, removing: true)
        }
        let paths = try records(all: true)
        let argument = try json(["action": "remove-all", "paths": paths])
        return try json(["items": [[
            "title": "Remove all \(paths.count) zoxide records…",
            "subtitle": "Clear the entire configured database. Confirmation required. No files deleted.",
            "valid": !paths.isEmpty, "arg": argument,
            "icon": ["path": "icon.png"]
        ]]])
    }
    func removeRequest(_ arguments: [String]) throws -> String {
        if arguments.count == 1, let data = arguments[0].data(using: .utf8),
           let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           request["action"] as? String == "remove-all", let paths = request["paths"] as? [String] {
            // Use the displayed snapshot: records added afterward are not silently included.
            return try remove(paths, all: true)
        }
        return try remove(arguments)
    }
    func remove(_ arguments: [String], all: Bool = false) throws -> String {
        let plan = try removalPlan(arguments)
        let paths = plan.paths
        guard !paths.isEmpty else {
            return "Nothing left to remove. The selected paths are no longer in zoxide. Clear Alfred’s buffer with Option-Backspace. No files were deleted."
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        let countLabel = paths.count == 1 ? "1 folder" : "\(paths.count) folders"
        alert.messageText = all ? "Remove all \(paths.count) zoxide records?" : "Remove \(countLabel) from zoxide?"
        alert.informativeText = (all ? "This clears every record listed below from the configured zoxide database. There is no undo. No files or folders will be deleted." : "These folders will be forgotten by zoxide. Their files and contents will remain untouched.") + (plan.skipped.isEmpty ? "" : "\n\nSkipped \(plan.skipped.count) buffered path(s) no longer recorded in zoxide.")
        alert.alertStyle = .informational
        let iconURL = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("icon.png")
        if let icon = NSImage(contentsOf: iconURL) { alert.icon = icon }
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: all ? "Remove all records" : "Remove from zoxide")
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[1].keyEquivalent = ""
        let removeButton = alert.buttons[1]
        removeButton.hasDestructiveAction = false
        removeButton.bezelColor = .systemBlue
        removeButton.contentTintColor = .white
        removeButton.attributedTitle = NSAttributedString(
            string: removeButton.title,
            attributes: [.foregroundColor: NSColor.white,
                         .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .medium)])

        let width: CGFloat = 480
        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 0
        list.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        list.translatesAutoresizingMaskIntoConstraints = false
        for (index, path) in paths.enumerated() {
            let url = URL(fileURLWithPath: path)
            let title = NSTextField(labelWithString: url.lastPathComponent.isEmpty ? "/" : url.lastPathComponent)
            title.font = .systemFont(ofSize: 13, weight: .semibold)
            title.lineBreakMode = .byTruncatingMiddle
            let detail = NSTextField(wrappingLabelWithString: path)
            detail.font = .systemFont(ofSize: 11)
            detail.textColor = .secondaryLabelColor
            detail.isSelectable = true
            detail.toolTip = path
            let labels = NSStackView(views: [title, detail])
            labels.orientation = .vertical
            labels.alignment = .leading
            labels.spacing = 3
            let image = NSImageView(image: NSImage(systemSymbolName: "folder", accessibilityDescription: "Folder")!)
            image.contentTintColor = .secondaryLabelColor
            image.translatesAutoresizingMaskIntoConstraints = false
            let row = NSStackView(views: [image, labels])
            row.alignment = .top
            row.spacing = 10
            row.edgeInsets = NSEdgeInsets(top: 11, left: 12, bottom: 11, right: 12)
            row.translatesAutoresizingMaskIntoConstraints = false
            list.addArrangedSubview(row)
            NSLayoutConstraint.activate([
                row.widthAnchor.constraint(equalToConstant: width),
                image.widthAnchor.constraint(equalToConstant: 20),
                image.heightAnchor.constraint(equalToConstant: 20),
                labels.widthAnchor.constraint(equalToConstant: width - 54)
            ])
            if index < paths.count - 1 {
                let divider = NSBox()
                divider.boxType = .separator
                list.addArrangedSubview(divider)
                divider.widthAnchor.constraint(equalToConstant: width).isActive = true
            }
        }
        list.widthAnchor.constraint(equalToConstant: width).isActive = true
        list.layoutSubtreeIfNeeded()
        let height = min(320, max(70, list.fittingSize.height))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .controlBackgroundColor
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 8
        scroll.layer?.borderWidth = 1
        scroll.layer?.borderColor = NSColor.separatorColor.cgColor
        scroll.documentView = list
        list.setFrameSize(NSSize(width: width, height: list.fittingSize.height))
        // NSStackView is unflipped; start at the first row rather than the bottom.
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, list.frame.height - height)))
        scroll.reflectScrolledClipView(scroll.contentView)
        alert.accessoryView = scroll
        guard alert.runModal() == .alertSecondButtonReturn else { return "" }
        var failures: [String] = []
        var count = 0
        for path in paths {
            do { _ = try zoxide(["remove", "--", path]); count += 1 }
            catch { failures.append(path + ": " + error.localizedDescription) }
        }
        return "Removed \(count) zoxide record(s). No files deleted." + (plan.skipped.isEmpty ? "" : " Skipped \(plan.skipped.count) unrecorded path(s).") + (failures.isEmpty ? "" : "\nFailed (\(failures.count)):\n" + failures.joined(separator: "\n"))
    }
    func add(_ path: String) throws -> String {
        guard path.hasPrefix("/"), directory(path) else { throw WorkflowError("An existing absolute folder path is required: " + path) }
        _ = try zoxide(["add", "--", path])
        let stored = try records(all: true)
        let resolved = canonical(path)
        guard stored.contains(path) || (resolved != nil && stored.contains(where: { canonical($0) == resolved })) else {
            if path == home || (resolved != nil && resolved == canonical(home)) {
                throw WorkflowError("Zoxide does not record your home folder (\(path)). Add a folder inside it instead, such as ~/Projects. Use ~ in Alfred or your terminal to open home.")
            }
            throw WorkflowError("Zoxide did not retain this folder: \(path). Check _ZO_EXCLUDE_DIRS and _ZO_MAXAGE in your zoxide environment. No record was added.")
        }
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
    case "delete-search": output = try workflow.removalSearch(query)
    case "add-path": output = try workflow.add(query)
    case "action": output = try workflow.action(query)
    case "remove-paths": output = try workflow.removeRequest(values)
    case "validate-removal": output = try json(["paths": workflow.validateRemoval(values)])
    default: throw WorkflowError("Unknown command: " + mode)
    }
    if !output.isEmpty { print(output) }
} catch {
    if ["browse", "search", "delete-search"].contains(mode) {
        print((try? json(["items": [["title": "Zoxide needs attention", "subtitle": error.localizedDescription, "valid": false]]])) ?? "{\"items\":[]}")
    } else { print("Zoxide: " + error.localizedDescription) }
}
