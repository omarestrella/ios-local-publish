import Foundation
import Observation
import UIKit

@MainActor @Observable
final class PublisherClient {
    private(set) var apps: [AppBuilds] = []
    private(set) var connected = false
    private(set) var connecting = false
    var error: String?
    private(set) var connectionIssue: String?
    var address: String
    private var identity: ReceiverIdentity?
    var receiverID: String? { identity?.id }
    private var endpoint: URL?
    private let session: URLSession
    private let cacheURL: URL

    init() {
        address = UserDefaults.standard.string(forKey: "publisherURL")
            ?? Bundle.main.object(forInfoDictionaryKey: "PublisherURL") as? String ?? ""
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 20
        config.httpShouldSetCookies = false
        session = URLSession(configuration: config)
        cacheURL = URL.applicationSupportDirectory.appending(path: "inbox.json")
        if let data = try? Data(contentsOf: cacheURL) {
            if let inbox = try? JSONDecoder().decode(InboxResponse.self, from: data) { update(inbox.releases, catalog: inbox.apps ?? []) }
            else if let builds = try? JSONDecoder().decode([PublishedBuild].self, from: data) { update(builds) }
        }
        do { identity = try ReceiverIdentity.load() } catch { self.error = error.localizedDescription }
    }

    static func validURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.host != nil && url.user == nil && url.password == nil
            && url.query == nil && url.fragment == nil
    }

    func run() async {
        while !Task.isCancelled {
            await connectAndPoll()
            if Task.isCancelled { return }
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
        }
    }

    private func connectAndPoll() async {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)), Self.validURL(url), identity != nil else { return }
        endpoint = url
        connecting = true
        defer { connecting = false; connected = false }
        do {
            _ = try await request("connect", body: ["name": UIDevice.current.name,
                "platform": UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"])
            UserDefaults.standard.set(url.absoluteString, forKey: "publisherURL")
            while !Task.isCancelled {
                try await receiveInbox(from: url)
                connected = true
                connecting = false
                connectionIssue = nil
                try await Task.sleep(for: .seconds(5))
            }
        } catch is CancellationError {
        } catch {
            if !Task.isCancelled {
                let failure = error as NSError
                if failure.domain == NSURLErrorDomain && failure.code == NSURLErrorCannotFindHost && url.host?.hasSuffix(".ts.net") == true {
                    self.connectionIssue = "Can’t resolve this Tailscale address. Check your Tailscale connection."
                } else { self.connectionIssue = error.localizedDescription }
            }
        }
    }

    func disconnect() async {
        connected = false
        guard endpoint != nil else { return }
        // Best effort; the Mac also expires presence after 30 seconds.
        _ = try? await request("heartbeat", body: ["active": false])
    }

    func install(_ build: PublishedBuild) async {
        guard !build.expired else { error = "This build’s signing has expired."; return }
        var components = URLComponents(url: build.installURL, resolvingAgainstBaseURL: false)
        components?.host = ""
        let accepted = await UIApplication.shared.open(components?.url ?? build.installURL)
        if !accepted {
            let opened = await UIApplication.shared.open(build.installPageURL)
            if !opened { error = "Couldn’t open the installer." }
        }
    }

    private func trusted(_ build: PublishedBuild, from base: URL) -> Bool {
        guard let parts = URLComponents(url: build.installURL, resolvingAgainstBaseURL: false),
              parts.scheme == "itms-services",
              parts.queryItems?.first(where: { $0.name == "action" })?.value == "download-manifest",
              let manifestString = parts.queryItems?.first(where: { $0.name == "url" })?.value,
              let manifest = URL(string: manifestString) else { return false }
        let prefix = base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/"
        return manifest.scheme == "https" && manifest.absoluteString.hasPrefix(prefix)
            && build.installPageURL.absoluteString.hasPrefix(prefix)
    }

    private func update(_ builds: [PublishedBuild], catalog: [CatalogApp] = []) {
        var order = catalog.map(\.bundleID)
        var groups: [String: [PublishedBuild]] = [:]
        let names = Dictionary(uniqueKeysWithValues: catalog.map { ($0.bundleID, $0.name) })
        for build in builds {
            if !order.contains(build.bundleID) { order.append(build.bundleID) }
            groups[build.bundleID, default: []].append(build)
        }
        apps = order.map { id in AppBuilds(id: id, name: names[id] ?? groups[id]?.first?.name ?? id, builds: groups[id] ?? []) }
    }

    private func receiveInbox(from url: URL) async throws {
        let data = try await request("heartbeat", body: ["active": true])
        let inbox = try JSONDecoder().decode(InboxResponse.self, from: data)
        guard inbox.releases.allSatisfy({ trusted($0, from: url) }) else {
            throw ClientError.message("The publisher returned an install link outside its HTTPS service.")
        }
        try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(inbox).write(to: cacheURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        update(inbox.releases, catalog: inbox.apps ?? [])
        _ = try await request("receipts", body: ["release_ids": inbox.releases.map(\.releaseID)])
    }

    func saveApp(bundleID: String, name: String) async -> Bool {
        await mutate("apps/save", body: ["bundle_id": bundleID, "name": name])
    }
    func deleteBuild(_ build: PublishedBuild) async -> Bool {
        await mutate("builds/delete", body: ["release_id": build.releaseID])
    }
    func deleteApp(_ app: AppBuilds) async -> Bool {
        await mutate("apps/delete", body: ["bundle_id": app.id])
    }
    private func mutate(_ path: String, body: [String: Any]) async -> Bool {
        do {
            _ = try await request(path, body: body)
            guard let endpoint else { return false }
            try await receiveInbox(from: endpoint)
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    private func request(_ path: String, body: [String: Any]) async throws -> Data {
        guard let endpoint, let identity else { throw ClientError.message("Choose your Mac first.") }
        var request = URLRequest(url: endpoint.appending(path: "api/\(path)"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(identity.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body.merging(["id": identity.id]) { _, new in new })
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: String])?["error"]
            throw ClientError.message(message ?? "Couldn’t connect to your Mac.")
        }
        return data
    }
}

private enum ClientError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { text } else { nil } }
}
