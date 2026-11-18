#!/usr/bin/env swift
import Foundation

struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
let fm = FileManager.default
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let temporary = fm.temporaryDirectory.appendingPathComponent("zoxide-tests-\(UUID().uuidString)", isDirectory: true)
var checks = 0

func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw TestFailure(message) }
    checks += 1
}

// Files, rather than pipes, keep larger query results from blocking child processes.
func run(_ executable: String, _ args: [String], environment: [String: String]? = nil) throws -> String {
    let output = temporary.appendingPathComponent(UUID().uuidString)
    _ = fm.createFile(atPath: output.path, contents: nil)
    defer { try? fm.removeItem(at: output) }
    let handle = try FileHandle(forWritingTo: output)
    defer { try? handle.close() }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = args
    process.currentDirectoryURL = root
    process.environment = environment
    process.standardOutput = handle
    process.standardError = handle
    try process.run()
    process.waitUntilExit()
    let text = String(decoding: try Data(contentsOf: output), as: UTF8.self)
    guard process.terminationStatus == 0 else {
        throw TestFailure("\(executable) \(args) exited \(process.terminationStatus): \(text)")
    }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}

func dictionary(_ data: Data) throws -> [String: Any] {
    guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw TestFailure("Expected a JSON object: \(String(decoding: data, as: UTF8.self))")
    }
    return result
}
func json(_ text: String) throws -> [String: Any] { try dictionary(Data(text.utf8)) }
func plist(_ data: Data) throws -> [String: Any] {
    guard let result = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
        throw TestFailure("Expected a plist dictionary")
    }
    return result
}
func directory(_ name: String) throws -> String {
    let path = temporary.appendingPathComponent(name)
    try fm.createDirectory(at: path, withIntermediateDirectories: true)
    return path.path
}

func packaging() throws {
    let archive = root.appendingPathComponent("dist/Zoxide.alfredworkflow").path
    let listing = try run("/usr/bin/unzip", ["-Z1", archive])
    let names = listing.split(separator: "\n").map(String.init)
    try expect(names.count == 4 && Set(names) == Set(["info.plist", "zoxide-helper", "icon.png", "README.md"]), "Archive must contain exactly four root files")
    _ = try run("/usr/bin/unzip", ["-t", archive])
    let extraction = try directory("archive")
    _ = try run("/usr/bin/unzip", ["-q", archive, "-d", extraction])
    func extracted(_ name: String) -> URL { URL(fileURLWithPath: extraction).appendingPathComponent(name) }
    for name in ["info.plist", "zoxide-helper", "icon.png"] {
        let archived = try Data(contentsOf: extracted(name))
        let source = try Data(contentsOf: root.appendingPathComponent("workflow/\(name)"))
        try expect(archived == source, "Archive differs from workflow/\(name)")
    }
    let readme = try Data(contentsOf: root.appendingPathComponent("README.md"))
    let archivedReadme = try Data(contentsOf: extracted("README.md"))
    try expect(archivedReadme == readme, "Archive README must match source")
    try expect(fm.isExecutableFile(atPath: extracted("zoxide-helper").path), "ZIP must preserve helper executable permissions")
    let architectures = try run("/usr/bin/xcrun", ["lipo", "-archs", extracted("zoxide-helper").path])
    try expect(architectures == "arm64", "Helper must be arm64 only, not universal or Intel")
    _ = try run("/usr/bin/codesign", ["--verify", "--strict", extracted("zoxide-helper").path])
    let signature = try run("/usr/bin/codesign", ["-d", "--verbose=2", extracted("zoxide-helper").path])
    try expect(signature.contains("Signature=adhoc"), "Helper must be ad-hoc signed")
    let icon = try Data(contentsOf: extracted("icon.png"))
    try expect(icon.count > 24 && Array(icon.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10], "Icon must be PNG")
    try expect(Array(icon[16..<24]) == [0, 0, 2, 0, 0, 0, 2, 0], "Icon must be 512 × 512")
    let info = try plist(Data(contentsOf: extracted("info.plist")))
    try expect(info["version"] as? String == "2.0.0", "Expected workflow version 2.0.0")
    try expect(info["bundleid"] as? String == "io.github.zoxide-alfred", "Bundle identity must stay stable")
    try expect(info["readme"] as? String == String(decoding: readme, as: UTF8.self), "Plist must embed current README")
    guard let objects = info["objects"] as? [[String: Any]],
          let connections = info["connections"] as? [String: [[String: Any]]],
          let controls = info["userconfigurationconfig"] as? [[String: Any]] else {
        throw TestFailure("Missing workflow objects, connections, or controls")
    }
    func config(_ object: [String: Any]) -> [String: Any] { object["config"] as? [String: Any] ?? [:] }
    func object(_ key: String, _ value: String) throws -> [String: Any] {
        guard let found = objects.first(where: { config($0)[key] as? String == value }) else {
            throw TestFailure("Missing workflow object \(key)=\(value)")
        }
        return found
    }
    func destination(_ object: [String: Any]) -> String? {
        connections[object["uid"] as? String ?? ""]?.first?["destinationuid"] as? String
    }
    try expect(objects.count == 9, "Preserve nine workflow objects")
    for object in objects {
        if let script = config(object)["script"] as? String {
            try expect(script.hasPrefix("./zoxide-helper ") && !script.contains("zoxide.js") && !script.contains("osascript"), "Workflow scripts must invoke the native helper")
        }
    }
    let removal = try object("name", "Remove from zoxide")
    let deletion = try object("keyword", "z remove||z delete")
    try expect(objects.filter { config($0)["name"] as? String == "Remove from zoxide" }.count == 1, "One mixed-buffer removal action")
    try expect(config(removal)["acceptsfiles"] as? Bool == true && config(removal)["acceptstext"] as? Bool == true && config(removal)["acceptsmulti"] as? Int == 1, "Removal must accept mixed multi-selection")
    try expect(destination(removal) != nil && destination(removal) == destination(deletion), "Batch and single removal must share their action")
    try expect(deletion["type"] as? String == "alfred.workflow.input.scriptfilter", "Removal searches database, not Spotlight")
    let add = try object("keyword", "z add")
    let universalAdd = try object("name", "Add to zoxide")
    try expect(config(add)["types"] as? [String] == ["public.folder"], "Native add search must filter folders")
    try expect(destination(add) != nil && destination(add) == destination(universalAdd), "Add inputs must share their action")
    try expect(config(universalAdd)["acceptsmulti"] as? Int == 0 && config(universalAdd)["acceptstext"] as? Bool == false, "Add Universal Action remains single-file")
    try expect(Set(controls.compactMap { $0["variable"] as? String }) == Set(["terminal_app", "zoxide_path", "_ZO_DATA_DIR"]), "Preserve configuration variables")
    for control in controls {
        try expect(control["type"] as? String == "filepicker", "Keep native file pickers")
        let settings = control["config"] as? [String: Any] ?? [:]
        try expect(settings["filtermode"] as? Int == (control["variable"] as? String == "_ZO_DATA_DIR" ? 1 : 0), "Preserve file/folder picker modes")
    }
    try expect((info["variables"] as? [String: Any])?["_ZO_DATA_DIR"] == nil, "Do not override the default database with a blank variable")
    try expect(info["uidata"] is [String: Any], "Preserve workflow editor layout")
    print("PASS packaging and plist")
}

func integration() throws {
    let helper = root.appendingPathComponent("workflow/zoxide-helper").path
    let candidates = [ProcessInfo.processInfo.environment["ZOXIDE_TEST_BINARY"], "/opt/homebrew/bin/zoxide", "/usr/local/bin/zoxide", NSHomeDirectory() + "/.local/bin/zoxide", NSHomeDirectory() + "/.cargo/bin/zoxide"].compactMap { $0 }
    guard let binary = candidates.first(where: { fm.isExecutableFile(atPath: $0) }) else {
        throw TestFailure("Install zoxide or set ZOXIDE_TEST_BINARY to run integration tests")
    }
    var environment = ProcessInfo.processInfo.environment
    for key in ["_ZO_DATA_DIR", "XDG_DATA_HOME", "_ZO_EXCLUDE_DIRS", "_ZO_MAXAGE", "_ZO_RESOLVE_SYMLINKS", "zoxide_path", "terminal_app", "terminal"] {
        environment.removeValue(forKey: key)
    }
    environment["HOME"] = try directory("home")
    environment["_ZO_DATA_DIR"] = try directory("database")
    environment["zoxide_path"] = binary
    environment["_ZO_RESOLVE_SYMLINKS"] = "0"
    func invoke(_ args: [String], _ overrides: [String: String] = [:]) throws -> String {
        try run(helper, args, environment: environment.merging(overrides) { _, new in new })
    }
    func items(_ mode: String, _ query: String, _ overrides: [String: String] = [:]) throws -> [[String: Any]] {
        let response = try json(invoke([mode, query], overrides))
        guard let rows = response["items"] as? [[String: Any]] else { throw TestFailure("Missing Alfred items") }
        return rows
    }
    func paths(_ mode: String = "browse", _ query: String = "") throws -> [String] {
        try items(mode, query).compactMap { item in
            guard let arg = item["arg"] as? String, let data = try? json(arg) else { return nil }
            return data["path"] as? String
        }
    }
    func validated(_ args: [String]) throws -> [String] {
        let response = try json(invoke(["validate-removal"] + args))
        guard let paths = response["paths"] as? [String] else { throw TestFailure("Missing validated original paths") }
        return paths
    }
    try expect(try items("browse", "").first?["valid"] as? Bool == false, "Empty database gets an invalid row")
    let first = try directory("test it's a folder; $(echo injected) & \"quoted\" é 📁")
    let second = try directory("another record")
    let third = try directory("addition")
    let addItems = try items("search", "add \"\(first)\"")
    try expect(addItems.first?["valid"] as? Bool == true, "Legacy add parsing supports quoted paths")
    guard let addArgument = addItems.first?["arg"] as? String else { throw TestFailure("Missing add action") }
    try expect(try invoke(["action", addArgument]).contains("Added"), "Legacy add action writes isolated database")
    for path in [second, third] {
        try expect(try invoke(["add-path", path]).contains("Added"), "add-path accepts literal paths")
    }
    try expect(Set(try paths()) == Set([first, second, third]), "Browse returns all isolated records")
    try expect(try paths("browse", "test folder") == [first], "Multiple query terms match literally")
    try expect(try paths("search", "addition") == [third], "Command prefixes are not reserved words")
    let row = try items("browse", "folder")[0]
    try expect(row["uid"] == nil, "Alfred learning must not override zoxide ranking")
    let payload = try json(row["arg"] as? String ?? "")
    try expect(payload["action"] as? String == "open" && payload["path"] as? String == first, "Open payload preserves special characters")
    for (modifier, action) in [("cmd", "parent"), ("ctrl", "terminal"), ("shift", "copy")] {
        let mods = row["mods"] as? [String: [String: Any]] ?? [:]
        let data = try json(mods[modifier]?["arg"] as? String ?? "")
        try expect(data["action"] as? String == action && data["path"] as? String == first, "Safe \(modifier) payload")
    }
    try expect((row["text"] as? [String: String])?["copy"] == first, "Copy uses original path")
    let delete = try items("delete-search", "folder")[0]
    try expect(delete["arg"] as? String == first && delete["type"] as? String == "file:skipcheck" && delete["mods"] == nil, "Removal rows carry original paths, including stale entries")
    for query in ["add", "add Projects"] {
        try expect(try items("search", query).isEmpty, "Native folder search owns bare add commands")
    }
    try expect(try items("browse", "add Projects").isEmpty, "Browse preserves native add behavior")
    let before = Set(try paths())
    try expect(try validated([first, second, first]) == [first, second], "Validation deduplicates in selection order")
    for separator in ["\n", "\r", "\r\n", "\t"] {
        try expect(try validated([first + separator + second]) == [first, second], "Combined buffer delimiter is supported")
    }
    let alias = temporary.appendingPathComponent("alias to first").path
    try fm.createSymbolicLink(atPath: alias, withDestinationPath: first)
    try expect(try validated([alias]) == [first], "Unique symlink alias maps back to original stored path")
    for args in [[], ["relative/path"], ["/not/a/record"], [first + "\n/not/a/record"], [first, "/not/a/record"]] {
        try expect(try invoke(["validate-removal"] + args).hasPrefix("Zoxide:"), "Invalid batch rejects all paths without UI")
    }
    try expect(Set(try paths()) == before, "Validation must not mutate any records")
    // Two stored spellings of the same target make a third spelling ambiguous.
    _ = try run(binary, ["add", "--", alias], environment: environment)
    let otherAlias = temporary.appendingPathComponent("other alias").path
    try fm.createSymbolicLink(atPath: otherAlias, withDestinationPath: first)
    try expect(try invoke(["validate-removal", otherAlias]).hasPrefix("Zoxide:"), "Ambiguous filesystem aliases must fail closed")
    try expect(try validated([first]) == [first], "Exact stored path takes precedence over aliases")
    let stale = try directory("stale missing folder")
    _ = try invoke(["add-path", stale])
    try fm.removeItem(atPath: stale)
    try expect(try items("delete-search", "stale").first?["arg"] as? String == stale, "Deletion includes missing records")
    try expect(try validated([stale]) == [stale], "Missing exact records remain safe to select")
    for invalid in ["/does/not/exist/alfred-zoxide", "relative/path", root.appendingPathComponent("README.md").path] {
        try expect(try invoke(["add-path", invalid]).hasPrefix("Zoxide:"), "Reject invalid add paths without UI")
    }
    try expect(try invoke(["action", "not-json"]).hasPrefix("Zoxide:"), "Malformed action errors are readable")
    try expect(try items("search", "", ["zoxide_path": "/no/zoxide"]).first?["valid"] as? Bool == false, "Binary errors are invalid JSON rows")
    try expect(try invoke(["add-path", first], ["zoxide_path": "/no/zoxide"]).hasPrefix("Zoxide:"), "Action errors use text prefix")
    try expect(try items("search", "add /does/not/exist").first?["valid"] as? Bool == false, "Invalid typed add paths are display errors")
    // Seed zoxide's actual default under an isolated HOME, then pass blank Alfred overrides.
    var fallback = environment
    fallback.removeValue(forKey: "_ZO_DATA_DIR")
    fallback.removeValue(forKey: "XDG_DATA_HOME")
    _ = try run(binary, ["add", "--", first], environment: fallback)
    fallback["_ZO_DATA_DIR"] = ""
    fallback["XDG_DATA_HOME"] = ""
    let defaultResult = try json(run(helper, ["browse", "folder"], environment: fallback))
    let defaultRows = defaultResult["items"] as? [[String: Any]] ?? []
    let defaultPayload = try json(defaultRows.first?["arg"] as? String ?? "")
    try expect(defaultPayload["path"] as? String == first, "Blank overrides fall back to isolated HOME database")
    try expect(fm.fileExists(atPath: first) && fm.fileExists(atPath: second), "Tests never delete selected folders")
    print("PASS isolated helper/zoxide integration (no confirmation UI)")
}

do {
    #if !os(macOS) || !arch(arm64)
    throw TestFailure("Tests require an Apple Silicon Mac")
    #else
    try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: temporary) }
    try packaging()
    try integration()
    print("PASS \(checks) checks")
    #endif
} catch {
    try? fm.removeItem(at: temporary)
    FileHandle.standardError.write(Data("FAIL: \(error)\nBuild first with swift tools/build.swift.\n".utf8))
    exit(1)
}
