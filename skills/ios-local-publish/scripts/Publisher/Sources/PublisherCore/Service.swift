import Foundation
import Darwin

public func request(_ url: URL, method: String = "GET", token: String? = nil, body: Object? = nil) async throws -> Object {
    var request = URLRequest(url: url); request.httpMethod = method; request.timeoutInterval = url.path.hasSuffix("/admin/publish") ? 300 : 15
    if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
    if let body { request.httpBody = try json(body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
    let (data, response) = try await URLSession.shared.data(for: request)
    let value = try object(data)
    guard let response = response as? HTTPURLResponse, response.statusCode == 200 else { throw PublishError(value["error"] as? String ?? "Service request failed") }
    return value
}
public func serviceSettings(_ state: URL) throws -> Object { try readObject(state.appending(path: "service.json")) }
public func admin(_ state: URL, _ path: String, body: Object = [:]) async throws -> Object {
    let config = try serviceSettings(state)
    let token = String(decoding: try Data(contentsOf: state.appending(path: "admin-token")), as: UTF8.self)
    guard let port = config["port"] as? Int, let url = URL(string: "http://127.0.0.1:\(port)/admin/\(path)") else { throw PublishError("Service is not running; run service start") }
    return try await request(url, method: "POST", token: token, body: body)
}
public func healthID(_ state: URL) -> Object { ["service": "ios-publish", "site_id": sha256(Data(state.appending(path: "site").path.utf8))] }

@MainActor public final class PublisherService {
    private let state: URL
    private let baseURL: String
    private let token: String
    private let store: InboxStore
    private let catalog: Catalog
    private var server: HTTPServer?
    private var bonjour: Process?
    public init(state: URL, baseURL: String) throws {
        self.state = state; self.baseURL = baseURL
        token = String(decoding: try Data(contentsOf: state.appending(path: "admin-token")), as: UTF8.self)
        store = try InboxStore(state: state)
        catalog = try Catalog(state: state)
    }
    public func start(port: UInt16, advertise: Bool = true) throws {
        let server = HTTPServer { [weak self] method, path, headers, data in
            guard let self else { return HTTPResponse(503, json: ["error": "Service stopped"]) }
            return await self.handle(method: method, path: path, headers: headers, data: data)
        }
        self.server = server
        try server.start(port: port)
        guard advertise else { return }
        let parsed = URL(string: baseURL)!
        let announcement = Process()
        announcement.executableURL = URL(filePath: "/usr/bin/dns-sd")
        announcement.arguments = ["-R", "Publish (\(Host.current().localizedName ?? "Mac"))", "_ios-publish._tcp", "local", String(parsed.port ?? 443), "url=" + baseURL]
        announcement.standardOutput = FileHandle.nullDevice
        announcement.standardError = FileHandle.nullDevice
        try announcement.run()
        bonjour = announcement
    }
    public func stop() {
        if let bonjour, bonjour.isRunning { bonjour.terminate(); bonjour.waitUntilExit() }
        bonjour = nil
    }
    private func handle(method: String, path raw: String, headers: [String: String], data: Data) async -> HTTPResponse {
        let path = raw.components(separatedBy: "?")[0]
        do {
            if method == "GET" && path == "/healthz" { return HTTPResponse(json: healthID(state)) }
            if method == "POST" && (path.hasPrefix("/api/") || path.hasPrefix("/admin/")) {
                let body = try object(data)
                let credential = headers["authorization"]?.replacingOccurrences(of: "Bearer ", with: "", options: .anchored) ?? ""
                if path.hasPrefix("/admin/") {
                    try require(credential == token && !credential.isEmpty, "Admin authentication failed")
                    switch path {
                    case "/admin/receivers": return HTTPResponse(json: ["receivers": store.receivers()])
                    case "/admin/select": return HTTPResponse(json: try store.select(body["id"] as? String))
                    case "/admin/bind": return HTTPResponse(json: try store.bind(string(body, "id"), udid: string(body, "udid")))
                    case "/admin/receipt": return HTTPResponse(json: store.receipt(try string(body, "id"), releaseID: try string(body, "release_id")))
                    case "/admin/cleanup-legacy":
                        return HTTPResponse(json: try catalog.pruneLegacy(keeping: store.releaseIDs()))
                    case "/admin/check-version":
                        try catalog.check(body)
                        return HTTPResponse(json: ["allowed": true])
                    case "/admin/publish":
                        let id = try string(body, "id")
                        let receiver = try store.select(id)
                        let path = try string(body, "ipa_path")
                        let days = body["min_validity_days"] as? Int ?? 30
                        try require(days >= 0, "Invalid signing lifetime")
                        var metadata = try Signing.inspect(URL(filePath: path), requiredUDID: string(receiver, "udid"), days: days)
                        if let configuration = body["configuration"] as? String { metadata["configuration"] = configuration }
                        let release = try await publish(metadata)
                        var result = release
                        do { result["delivery"] = try store.deliver(id, release: release) }
                        catch { throw PublishError("IPA is hosted at \(release["ipa_url"] ?? "") but receiver disconnected. Reuse --ipa \(path) after reconnecting.") }
                        try writeObject(result, to: state.appending(path: "latest.json"))
                        return HTTPResponse(json: result)
                    default: return HTTPResponse(404, json: ["error": "Unknown endpoint"])
                    }
                }
                switch path {
                case "/api/connect": return HTTPResponse(json: try store.connect(body, token: credential))
                case "/api/heartbeat":
                    if let active = body["active"] { try require(active is Bool, "active must be boolean") }
                    let id = try string(body, "id")
                    var inbox = try store.heartbeat(id, token: credential, active: body["active"] as? Bool ?? true)
                    inbox["apps"] = catalog.visibleApps(receiver: id, deliveredBundles: store.bundles(id))
                    return HTTPResponse(json: inbox)
                case "/api/apps/save":
                    let id = try string(body, "id")
                    try store.authorize(id, token: credential)
                    return HTTPResponse(json: try catalog.upsertApp(receiver: id, bundle: string(body, "bundle_id"), name: string(body, "name"), visible: store.bundles(id)))
                case "/api/builds/delete":
                    let id = try string(body, "id"), release = try string(body, "release_id")
                    try store.authorize(id, token: credential)
                    try require(store.ownsRelease(id, releaseID: release), "Build is not in this inbox")
                    try catalog.deleteRelease(release)
                    try store.removeRelease(release)
                    return HTTPResponse(json: ["deleted": true])
                case "/api/apps/delete":
                    let id = try string(body, "id"), bundle = try string(body, "bundle_id")
                    try store.authorize(id, token: credential)
                    let visible = catalog.visibleApps(receiver: id, deliveredBundles: store.bundles(id))
                    try require(visible.contains { $0["bundle_id"] as? String == bundle }, "App is not in this inbox")
                    for release in try catalog.releases() where release["bundle_id"] as? String == bundle {
                        let releaseID = try string(release, "release_id")
                        try catalog.deleteRelease(releaseID); try store.removeRelease(releaseID)
                    }
                    try catalog.removeApp(bundle)
                    return HTTPResponse(json: ["deleted": true])
                case "/api/receipts":
                    guard let ids = body["release_ids"] as? [String] else { throw PublishError("Invalid receipt list") }
                    return HTTPResponse(json: try store.acknowledge(string(body, "id"), token: credential, releases: ids))
                default: return HTTPResponse(404, json: ["error": "Unknown endpoint"])
                }
            }
            guard method == "GET" || method == "HEAD" else { return HTTPResponse(405, json: ["error": "Method not allowed"]) }
            let site = state.appending(path: "site").resolvingSymlinksInPath()
            guard let decoded = path.removingPercentEncoding else { throw PublishError("Invalid path") }
            try require(!decoded.split(separator: "/").contains(where: { $0.hasPrefix(".") }), "Invalid path")
            var file = site.appending(path: decoded.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).resolvingSymlinksInPath()
            if path == "/" { file = site.appending(path: "index.html") }
            try require(file.path.hasPrefix(site.path + "/"), "Invalid path")
            let data = try Data(contentsOf: file, options: .mappedIfSafe)
            let type = file.pathExtension == "ipa" ? "application/octet-stream" : file.pathExtension == "plist" ? "text/xml" : "text/html; charset=utf-8"
            return HTTPResponse(type: type, data: method == "HEAD" ? Data() : data, length: data.count)
        } catch {
            return HTTPResponse(400, json: ["error": error.localizedDescription])
        }
    }
    private func publish(_ metadata: Object) async throws -> Object {
        try catalog.check(metadata)
        let bundle = try string(metadata, "bundle_id")
        try require(matches(bundle, "^[A-Za-z0-9][A-Za-z0-9.-]*$"), "Invalid bundle ID")
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let relative = "apps/\(bundle)/\(id)"
        let directory = state.appending(path: "site/" + relative)
        let staging = state.appending(path: "staging/" + id)
        let url = baseURL + "/" + relative
        let manifestURL = url + "/manifest.plist", ipaURL = url + "/app.ipa"
        var components = URLComponents(); components.scheme = "itms-services"; components.host = ""; components.queryItems = [.init(name: "action", value: "download-manifest"), .init(name: "url", value: manifestURL)]
        let install = components.string!
        var release = metadata
        release.merge(["release_id": id, "published_at": iso(), "install_page_url": url + "/index.html", "latest_url": baseURL + "/apps/\(bundle)/index.html", "manifest_url": manifestURL, "ipa_url": ipaURL, "install_url": install, "installed": false, "published": true]) { _, new in new }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.copyItem(at: URL(filePath: try string(metadata, "ipa_path")), to: staging.appending(path: "app.ipa"))
        try writePlist(["items": [["assets": [["kind": "software-package", "url": ipaURL]], "metadata": ["bundle-identifier": bundle, "bundle-version": try string(metadata, "build"), "kind": "software", "title": try string(metadata, "name")]]]], to: staging.appending(path: "manifest.plist"))
        let landing = Data("<!doctype html><meta name=viewport content='width=device-width,initial-scale=1'><title>Publish</title><a href='\(install.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "'", with: "&#39;"))'>Install on iPhone or iPad</a>".utf8)
        try write(landing, to: staging.appending(path: "index.html"))
        try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: staging, to: directory)
        do {
            let (manifestData, manifestResponse) = try await URLSession.shared.data(from: URL(string: manifestURL)!)
            try require((manifestResponse as? HTTPURLResponse)?.statusCode == 200, "Hosted manifest download failed")
            let document = try plist(manifestData)
            let item = (document["items"] as? [Object])?.first
            let asset = (item?["assets"] as? [Object])?.first
            try require(asset?["url"] as? String == ipaURL, "Hosted manifest points at wrong IPA")
            let (download, response) = try await URLSession.shared.download(from: URL(string: ipaURL)!)
            defer { try? FileManager.default.removeItem(at: download) }
            try require((response as? HTTPURLResponse)?.statusCode == 200 && hashFile(download) == metadata["sha256"] as? String, "Hosted IPA checksum mismatch")
            try require((try download.resourceValues(forKeys: [.fileSizeKey]).fileSize) == metadata["size_bytes"] as? Int, "Hosted IPA size mismatch")
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        do { try catalog.commit(release) } catch { try? FileManager.default.removeItem(at: directory); throw error }
        release["hosting_verified"] = true
        try writeObject(release, to: state.appending(path: "releases/\(id).json"))
        try writeObject(release, to: state.appending(path: "latest.json"))
        try write(landing, to: directory.deletingLastPathComponent().appending(path: "index.html"))
        try write(Data("<!doctype html><title>Publish</title><p>Open Publish on your iPhone or iPad.</p>".utf8), to: state.appending(path: "site/index.html"))
        return release
    }
}
