import Foundation
import PublisherCore
import Darwin

@main struct PublisherCommand {
    @MainActor static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        do {
            let options = try Options(arguments)
            if options.has("help") || options.commands.isEmpty { print(help); return }
            let state = try stateDirectory(options.get("state-dir"))
            try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
            let command = options.commands[0]
            let readOnly = ["daemon", "receivers", "latest", "inspect", "doctor"].contains(command) || (command == "service" && options.commands.dropFirst().first == "status")
            var lock: Int32 = -1
            if !readOnly {
                lock = open(state.appending(path: ".lock").path, O_CREAT | O_RDWR, 0o600)
                try require(lock >= 0 && flock(lock, LOCK_EX | LOCK_NB) == 0, "Another publisher is changing this state directory")
            }
            defer { if lock >= 0 { close(lock) } }
            let result = try await execute(options, state: state)
            print(String(decoding: try json(["ok": true].merging(result) { _, new in new }), as: UTF8.self))
        } catch {
            if arguments.contains("--json") {
                print(String(decoding: (try? json(["ok": false, "error": error.localizedDescription])) ?? Data(), as: UTF8.self))
            } else { progress("Error: \(error.localizedDescription)") }
            exit(1)
        }
    }
    @MainActor static func execute(_ options: Options, state: URL) async throws -> Object {
        let command = options.commands[0]
        let configURL = state.appending(path: "config.json")
        var config = FileManager.default.fileExists(atPath: configURL.path) ? try readObject(configURL) : [:]
        switch command {
        case "daemon":
            try options.check(["port", "base-url", "no-bonjour"])
            guard let port = UInt16(options.get("port") ?? ""), let base = options.get("base-url") else { throw PublishError("Daemon requires --port and --base-url") }
            let service = try PublisherService(state: state, baseURL: base)
            try service.start(port: port, advertise: !options.has("no-bonjour"))
            var signals: [DispatchSourceSignal] = []
            for number in [SIGTERM, SIGINT] {
                signal(number, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
                source.setEventHandler { service.stop(); exit(0) }
                source.activate(); signals.append(source)
            }
            while true {
                try await Task.sleep(for: .seconds(3600))
                _ = service; _ = signals
            }
        case "init":
            try options.check(["project", "scheme", "team", "configuration"])
            guard let value = options.get("project"), let scheme = options.get("scheme") else { throw PublishError("init requires --project and --scheme") }
            config["project"] = try BuildPipeline.project(value).path
            config["scheme"] = scheme; config["configuration"] = options.get("configuration") ?? "Release"
            if let team = options.get("team") { config["team"] = team }
            try writeObject(config, to: configURL)
            return config
        case "service":
            try options.check(["https-port"])
            let verb = options.commands.dropFirst().first ?? "status"
            if verb == "start" {
                if let port = options.get("https-port") { try require(Int(port) != nil, "Invalid HTTPS port") }
                return try await ServiceManager.start(state, httpsPort: options.get("https-port").flatMap(Int.init))
            }
            try require(!options.has("https-port"), "--https-port only applies to service start")
            if verb == "stop" { return try ServiceManager.stop(state) }
            try require(verb == "status", "Use service start, status, or stop")
            return try await ServiceManager.status(state)
        case "builds":
            try options.check([])
            try require(options.commands.dropFirst().first == "cleanup-legacy", "Use builds cleanup-legacy")
            return try await admin(state, "cleanup-legacy")
        case "receivers":
            try options.check(["receiver", "udid", "release"])
            let verb = options.commands.dropFirst().first ?? "list"
            if verb == "list" { return try await admin(state, "receivers") }
            guard let id = options.get("receiver") else { throw PublishError("Use --receiver ID") }
            if verb == "bind", let udid = options.get("udid") { return try await admin(state, "bind", body: ["id": id, "udid": validateUDID(udid)]) }
            if verb == "receipt", let release = options.get("release") { return try await admin(state, "receipt", body: ["id": id, "release_id": release]) }
            throw PublishError("Use receivers list, bind --receiver ID --udid UDID, or receipt --receiver ID --release ID")
        case "devices":
            try options.check(["wifi", "connected"])
            try require(options.commands.dropFirst().first == "list", "Use devices list for provisioning identifiers; native receivers are listed separately")
            return try temporary { directory in
                let path = directory.appending(path: "devices.json")
                try run(["xcrun", "devicectl", "list", "devices", "--json-output", path.path])
                let document = try readObject(path)
                let raw = (document["result"] as? Object)?["devices"] as? [Object] ?? []
                var result: [Object] = []
                for row in raw {
                    let properties = row["properties"] as? Object ?? [:]
                    let hardware = properties["hardware"] as? Object ?? row["hardwareProperties"] as? Object ?? [:]
                    let connection = properties["connection"] as? Object ?? row["connectionProperties"] as? Object ?? [:]
                    let device = properties["state"] as? Object ?? row["deviceProperties"] as? Object ?? [:]
                    guard hardware["reality"] as? String == "physical", ["iPhone", "iPad"].contains(hardware["deviceType"] as? String ?? "") else { continue }
                    if options.has("wifi") && connection["transportType"] as? String != "localNetwork" { continue }
                    if options.has("connected") && (connection["state"] as? String ?? connection["tunnelState"] as? String) != "connected" { continue }
                    result.append(["name": device["name"] ?? "Device", "udid": hardware["udid"] ?? "", "core_device_id": row["identifier"] ?? "", "type": hardware["deviceType"] ?? "", "transport": connection["transportType"] ?? "", "connection": connection["state"] ?? connection["tunnelState"] ?? "unknown"])
                }
                return ["devices": result]
            }
        case "build", "publish":
            try options.check(["project", "scheme", "configuration", "team", "archive", "build-number", "min-validity-days", "build-setting", "udid", "receiver", "ipa", "receipt-timeout"])
            let timeout = Int(options.get("receipt-timeout") ?? "20") ?? -1
            try require((0...300).contains(timeout), "--receipt-timeout must be 0...300 seconds")
            let days = Int(options.get("min-validity-days") ?? "30") ?? -1
            try require(days >= 0, "--min-validity-days must be nonnegative")
            if options.has("ipa") { try require(!["archive", "project", "scheme", "configuration", "build-number", "build-setting"].contains(where: options.has), "--ipa cannot be combined with source/archive build options") }
            if command == "build" {
                try require(!options.has("ipa") && !options.has("receiver") && !options.has("receipt-timeout"), "build accepts --udid; use publish to deliver")
                guard let udid = options.get("udid") else { throw PublishError("build requires --udid HARDWARE_UDID") }
                return try BuildPipeline.build(options, state: state, config: config, udid: validateUDID(udid), deviceName: "Developer device")
            }
            try require(!options.has("udid"), "Publish selects a native inbox with --receiver. Bind its hardware UDID with receivers bind.")
            _ = try await ServiceManager.start(state)
            let receiver = try await admin(state, "select", body: options.get("receiver").map { ["id": $0] } ?? [:])
            let id = try string(receiver, "id"), udid = try string(receiver, "udid")
            let metadata: Object
            if let ipa = options.get("ipa") {
                metadata = ["ipa_path": URL(filePath: ipa).standardizedFileURL.path]
            } else {
                metadata = try BuildPipeline.build(options, state: state, config: config, udid: udid, deviceName: string(receiver, "name"))
            }
            var body: Object = ["id": id, "ipa_path": try string(metadata, "ipa_path"), "min_validity_days": days]
            if let configuration = metadata["configuration"] { body["configuration"] = configuration }
            progress("Publishing to connected receiver \(receiver["name"] ?? id)")
            var result = try await admin(state, "publish", body: body)
            let deadline = Date.now.addingTimeInterval(Double(timeout))
            while Date.now < deadline {
                let receipt = try await admin(state, "receipt", body: ["id": id, "release_id": try string(result, "release_id")])
                result["delivery"] = receipt
                if receipt["received"] as? Bool == true { break }
                try await Task.sleep(for: .milliseconds(500))
            }
            try writeObject(result, to: state.appending(path: "latest.json"))
            return result
        case "inspect":
            try options.check(["udid", "min-validity-days"])
            guard let path = options.commands.dropFirst().first else { throw PublishError("inspect requires an IPA path") }
            return try Signing.inspect(URL(filePath: path), requiredUDID: options.get("udid").map(validateUDID))
        case "latest":
            try options.check([])
            return try readObject(state.appending(path: "latest.json"))
        case "doctor":
            try options.check([])
            let status = try await ServiceManager.status(state)
            let auth = try asc(["auth", "status"])
            if status["active"] as? Bool == true { try await ServiceManager.verifyHTTPS(string(status, "base_url"), state: state) }
            return ["service": status, "apple_auth": auth, "xcode": String(decoding: try run(["xcodebuild", "-version"]), as: UTF8.self)]
        default: throw PublishError("Unknown command: \(command)")
        }
    }
    static let help = """
    Publish — native iOS build inbox + Swift Mac service
    service start [--https-port 8443] | status | stop
    receivers list
    receivers bind --receiver ID --udid HARDWARE_UDID
    receivers receipt --receiver ID --release ID
    builds cleanup-legacy
    init --project App.xcodeproj --scheme App [--team TEAM]
    publish [--receiver ID] [--project PATH --scheme APP] [--configuration Debug]
    publish --receiver ID --ipa App.ipa
    build --udid HARDWARE_UDID [source options | --archive App.xcarchive]
    devices list [--wifi] [--connected]
    inspect App.ipa [--udid HARDWARE_UDID]
    doctor | latest
    All commands accept --state-dir PATH and --json. JSON goes to stdout; progress goes to stderr.
    """
}
