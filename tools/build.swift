#!/usr/bin/env swift
import Foundation

struct BuildError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

let fm = FileManager.default
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let workflow = root.appendingPathComponent("workflow", isDirectory: true)

func run(_ executable: String, _ arguments: [String], in directory: URL? = nil) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = directory ?? root
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw BuildError("\(executable) failed (status \(process.terminationStatus)).")
    }
}

func build() throws {
    #if !os(macOS) || !arch(arm64)
    throw BuildError("Build on an Apple Silicon Mac with Xcode Command Line Tools installed.")
    #else
    let plistURL = workflow.appendingPathComponent("info.plist")
    guard var info = try PropertyListSerialization.propertyList(
        from: Data(contentsOf: plistURL), options: [], format: nil
    ) as? [String: Any], var objects = info["objects"] as? [[String: Any]] else {
        throw BuildError("workflow/info.plist must contain the existing Alfred workflow template.")
    }
    for index in objects.indices {
        guard var config = objects[index]["config"] as? [String: Any],
              let script = config["script"] as? String else { continue }
        config["script"] = script.replacingOccurrences(
            of: "/usr/bin/osascript -l JavaScript ./zoxide.js", with: "./zoxide-helper")
        objects[index]["config"] = config
    }
    info["objects"] = objects
    info["version"] = "2.0.0"
    info["readme"] = try String(contentsOf: root.appendingPathComponent("README.md"), encoding: .utf8)

    try run("/usr/bin/xcrun", ["swiftc", "-O", "-target", "arm64-apple-macosx12.0",
                               "workflow/main.swift", "-o", "workflow/zoxide-helper"])
    let helper = workflow.appendingPathComponent("zoxide-helper")
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
    try run("/usr/bin/codesign", ["--force", "--sign", "-", helper.path])
    try run("/usr/bin/xcrun", ["swift", "tools/icon.swift"])

    let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    let staging = fm.temporaryDirectory.appendingPathComponent("zoxide-build-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: staging, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: staging) }
    try plist.write(to: staging.appendingPathComponent("info.plist"), options: .atomic)
    for name in ["zoxide-helper", "icon.png"] {
        try fm.copyItem(at: workflow.appendingPathComponent(name), to: staging.appendingPathComponent(name))
    }
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staging.appendingPathComponent("zoxide-helper").path)
    try fm.copyItem(at: root.appendingPathComponent("README.md"), to: staging.appendingPathComponent("README.md"))
    let archive = staging.appendingPathComponent("Zoxide.alfredworkflow")
    try run("/usr/bin/zip", ["-q", archive.path, "info.plist", "zoxide-helper", "icon.png", "README.md"], in: staging)
    let dist = root.appendingPathComponent("dist", isDirectory: true)
    try fm.createDirectory(at: dist, withIntermediateDirectories: true)
    try Data(contentsOf: archive).write(to: dist.appendingPathComponent("Zoxide.alfredworkflow"), options: .atomic)
    try plist.write(to: plistURL, options: .atomic)
    print("dist/Zoxide.alfredworkflow")
    #endif
}

do { try build() }
catch {
    FileHandle.standardError.write(Data("Build failed: \(error)\n".utf8))
    exit(1)
}
