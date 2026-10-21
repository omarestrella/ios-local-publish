import Foundation
import CryptoKit
import Darwin

public typealias Object = [String: Any]
public struct PublishError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
public func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw PublishError(message) }
}
public func string(_ object: Object, _ key: String) throws -> String {
    guard let value = object[key] as? String, !value.isEmpty else { throw PublishError("Missing \(key)") }
    return value
}
public func object(_ data: Data) throws -> Object {
    guard let result = try JSONSerialization.jsonObject(with: data) as? Object else { throw PublishError("Expected a JSON object") }
    return result
}
public func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted]) }
public func readObject(_ url: URL) throws -> Object { try object(Data(contentsOf: url)) }
public func write(_ data: Data, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
}
public func writeObject(_ value: Any, to url: URL) throws { try write(json(value), to: url) }
public func plist(_ data: Data) throws -> Object {
    guard let value = try PropertyListSerialization.propertyList(from: data, format: nil) as? Object else { throw PublishError("Invalid property list") }
    return value
}
public func writePlist(_ value: Any, to url: URL) throws {
    try write(PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0), to: url)
}
public func iso(_ date: Date = .now) -> String { ISO8601DateFormatter().string(from: date) }
public func date(_ text: String) throws -> Date {
    let fractional = ISO8601DateFormatter(); fractional.formatOptions.insert(.withFractionalSeconds)
    guard let value = fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text) else { throw PublishError("Invalid timestamp: \(text)") }
    return value
}
public func matches(_ value: String, _ pattern: String) -> Bool { value.range(of: pattern, options: .regularExpression) != nil }
public func validateUDID(_ value: String) throws -> String {
    try require(matches(value, "^(?:[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}|[0-9A-Fa-f]{40})$"), "Use the hardware provisioning UDID, not a CoreDevice UUID")
    return value.uppercased()
}
public func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
public func sha1(_ data: Data) -> String { Insecure.SHA1.hash(data: data).map { String(format: "%02X", $0) }.joined() }
public func hashFile(_ url: URL) throws -> String {
    let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
    var digest = SHA256()
    while let chunk = try file.read(upToCount: 1_048_576), !chunk.isEmpty { digest.update(data: chunk) }
    return digest.finalize().map { String(format: "%02x", $0) }.joined()
}
public func progress(_ value: String) { FileHandle.standardError.write(Data((value + "\n").utf8)) }

@discardableResult public func run(_ args: [String], log: URL? = nil) throws -> Data {
    let process = Process(); process.executableURL = URL(filePath: "/usr/bin/env"); process.arguments = args
    // Files avoid pipe deadlocks on verbose build output.
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let outputURL = log ?? directory.appending(path: "out")
    try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: outputURL.path, contents: nil)
    let errorURL = directory.appending(path: "err")
    FileManager.default.createFile(atPath: errorURL.path, contents: nil)
    let output = try FileHandle(forWritingTo: outputURL), error = try FileHandle(forWritingTo: errorURL)
    defer { try? output.close(); try? error.close() }
    process.standardOutput = output; process.standardError = log == nil ? error : output
    try process.run(); process.waitUntilExit()
    let data = try Data(contentsOf: outputURL)
    if process.terminationStatus != 0 {
        let detail = log.map { "See \($0.path)" } ?? String(decoding: (try? Data(contentsOf: errorURL)) ?? data, as: UTF8.self)
        throw PublishError("\(args.prefix(3).joined(separator: " ")) failed: \(detail.suffix(2500))")
    }
    return data
}
public func asc(_ arguments: [String]) throws -> Object { try object(run(["asc"] + arguments + ["--output", "json"])) }
public func rows(_ result: Object) -> [Object] { result["data"] as? [Object] ?? [] }
public func attributes(_ row: Object) -> Object { row["attributes"] as? Object ?? [:] }
public func temporary<T>(_ body: (URL) throws -> T) throws -> T {
    let url = FileManager.default.temporaryDirectory.appending(path: "ios-publish-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url) }
    return try body(url)
}
public func stateDirectory(_ explicit: String?) throws -> URL {
    if let path = explicit ?? ProcessInfo.processInfo.environment["IOS_PUBLISH_HOME"] { return URL(filePath: (path as NSString).expandingTildeInPath).standardizedFileURL }
    let settingsPath = ProcessInfo.processInfo.environment["IOS_LOCAL_PUBLISH_SETTINGS"] ?? NSHomeDirectory() + "/.config/ios-local-publish/settings.json"
    if FileManager.default.fileExists(atPath: settingsPath) {
        return URL(filePath: try string(readObject(URL(filePath: settingsPath)), "state_dir"))
    }
    return URL(filePath: NSHomeDirectory() + "/.local/share/ios-publish")
}
public struct Options {
    public var commands: [String] = []
    public var values: [String: [String]] = [:]
    public init(_ arguments: [String]) throws {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument.hasPrefix("--") {
                let parts = argument.dropFirst(2).split(separator: "=", maxSplits: 1).map(String.init)
                let key = parts[0]
                if ["json", "help", "wifi", "connected", "no-bonjour"].contains(key) { values[key] = ["true"] }
                else if parts.count == 2 { values[key, default: []].append(parts[1]) }
                else {
                    index += 1
                    try require(index < arguments.count && !arguments[index].hasPrefix("--"), "Missing value for --\(key)")
                    values[key, default: []].append(arguments[index])
                }
            } else { commands.append(argument) }
            index += 1
        }
    }
    public func get(_ key: String) -> String? { values[key]?.last }
    public func has(_ key: String) -> Bool { values[key] != nil }
    public func check(_ allowed: Set<String>) throws {
        let unknown = Set(values.keys).subtracting(allowed.union(["json", "state-dir", "help"]))
        try require(unknown.isEmpty, "Unknown options: " + unknown.sorted().joined(separator: ", "))
    }
}
