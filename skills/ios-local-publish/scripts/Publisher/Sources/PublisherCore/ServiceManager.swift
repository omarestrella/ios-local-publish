import Foundation
import Darwin

public enum ServiceManager {
    public static func label(_ state: URL) -> String { "net.bitcreative.ios-publish." + sha256(Data(state.path.utf8)).prefix(12) }
    private static func tailnetHost() throws -> String {
        let status = try object(run(["tailscale", "status", "--json"]))
        try require(status["BackendState"] as? String == "Running", "Connect Tailscale on this Mac first")
        guard let host = (status["Self"] as? Object)?["DNSName"] as? String else { throw PublishError("No Tailscale DNS name") }
        return host.trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }
    private static func handler(_ host: String, port: Int) throws -> Object? {
        let status = try object(run(["tailscale", "serve", "status", "--json"]))
        let web = status["Web"] as? [String: Object] ?? [:]
        let handlers = web["\(host):\(port)"]?["Handlers"] as? [String: Object] ?? [:]
        return handlers["/ios-publish"] ?? handlers["/ios-publish/"]
    }
    public static func status(_ state: URL) async throws -> Object {
        let config = (try? serviceSettings(state)) ?? [:]
        guard let base = config["base_url"] as? String, let port = config["port"] as? Int else {
            return ["active": false, "message": "Run service start"]
        }
        var active = false
        if let value = try? await request(URL(string: "http://127.0.0.1:\(port)/healthz")!) { active = value["site_id"] as? String == healthID(state)["site_id"] as? String }
        let url = URL(string: base)!
        let current = try handler(url.host!, port: url.port ?? 443)
        let owned = current?["Proxy"] as? String == "http://127.0.0.1:\(port)"
        return ["base_url": base, "https_port": url.port ?? 443, "port": port, "active": active && owned, "owned": owned, "label": label(state)]
    }
    public static func start(_ state: URL, httpsPort requested: Int? = nil) async throws -> Object {
        let config = (try? serviceSettings(state)) ?? [:]
        let host = try tailnetHost()
        let httpsPort = requested ?? config["https_port"] as? Int ?? 443
        try require((1...65535).contains(httpsPort), "Invalid HTTPS port")
        let base = "https://\(host)" + (httpsPort == 443 ? "" : ":\(httpsPort)") + "/ios-publish"
        if let current = try handler(host, port: httpsPort) {
            let oldServer = (try? readObject(state.appending(path: "server.json"))) ?? [:]
            let oldPort = config["port"] as? Int ?? oldServer["port"] as? Int
            try require(oldPort.map { current["Proxy"] as? String == "http://127.0.0.1:\($0)" } == true || current["Path"] as? String == state.appending(path: "site").path, "This Tailscale route belongs to another service")
        }
        let executable = URL(filePath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let installed = state.appending(path: "bin/ios-publish")
        if requested == nil || requested == config["https_port"] as? Int,
           (try? await status(state)["active"] as? Bool) == true,
           (try? hashFile(executable)) == (try? hashFile(installed)) {
            try await verifyHTTPS(base, state: state)
            return try await status(state)
        }
        if let oldBase = config["base_url"] as? String, oldBase != base, let old = URL(string: oldBase),
           let port = config["port"] as? Int,
           try handler(old.host!, port: old.port ?? 443)?["Proxy"] as? String == "http://127.0.0.1:\(port)" {
            try run(["tailscale", "serve", "--https=\(old.port ?? 443)", "--set-path=/ios-publish", "off"])
        }
        let domain = "gui/\(getuid())", label = label(state)
        _ = try? run(["launchctl", "bootout", "\(domain)/\(label)"])
        if executable.path != installed.path { try write(Data(contentsOf: executable), to: installed) }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installed.path)
        let tokenFile = state.appending(path: "admin-token")
        if !FileManager.default.fileExists(atPath: tokenFile.path) {
            try write(Data((UUID().uuidString + UUID().uuidString).utf8), to: tokenFile)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenFile.path)
        }
        let port = try freePort()
        try writeObject(["base_url": base, "https_port": httpsPort, "port": port], to: state.appending(path: "service.json"))
        let agent = URL(filePath: NSHomeDirectory() + "/Library/LaunchAgents/\(label).plist")
        try FileManager.default.createDirectory(at: state.appending(path: "service-logs"), withIntermediateDirectories: true)
        try writePlist(["Label": label, "ProgramArguments": [installed.path, "daemon", "--state-dir", state.path, "--port", String(port), "--base-url", base], "RunAtLoad": true, "KeepAlive": true,
            "StandardOutPath": state.appending(path: "service-logs/stdout.log").path, "StandardErrorPath": state.appending(path: "service-logs/stderr.log").path,
            "EnvironmentVariables": ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"]], to: agent)
        try run(["launchctl", "bootstrap", domain, agent.path])
        var ready = false
        for _ in 0..<40 {
            if let result = try? await request(URL(string: "http://127.0.0.1:\(port)/healthz")!), result["site_id"] as? String == healthID(state)["site_id"] as? String { ready = true; break }
            try await Task.sleep(for: .milliseconds(250))
        }
        try require(ready, "Swift service failed to start; see \(state.path)/service-logs/stderr.log")
        try run(["tailscale", "serve", "--bg", "--yes", "--https=\(httpsPort)", "--set-path=/ios-publish", "http://127.0.0.1:\(port)"])
        try await verifyHTTPS(base, state: state)
        return try await status(state)
    }
    public static func verifyHTTPS(_ base: String, state: URL) async throws {
        let result = try await request(URL(string: base + "/healthz")!)
        try require(result["site_id"] as? String == healthID(state)["site_id"] as? String, "HTTPS endpoint points to a different publisher")
    }
    public static func stop(_ state: URL) throws -> Object {
        let config = try serviceSettings(state)
        let url = URL(string: try string(config, "base_url"))!
        let port = config["port"] as? Int ?? -1
        if let current = try handler(url.host!, port: url.port ?? 443) {
            try require(current["Proxy"] as? String == "http://127.0.0.1:\(port)", "Refusing to remove another service's route")
            try run(["tailscale", "serve", "--https=\(url.port ?? 443)", "--set-path=/ios-publish", "off"])
        }
        _ = try? run(["launchctl", "bootout", "gui/\(getuid())/\(label(state))"])
        let agent = URL(filePath: NSHomeDirectory() + "/Library/LaunchAgents/\(label(state)).plist")
        try? FileManager.default.removeItem(at: agent)
        return ["active": false]
    }
    private static func freePort() throws -> Int {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw PublishError("Cannot allocate a local service socket") }
        defer { close(descriptor) }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        try require(bound == 0, "Cannot allocate service port")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) } }
        try require(result == 0, "Cannot inspect service port")
        return Int(UInt16(bigEndian: address.sin_port))
    }
}
