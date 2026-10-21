import Foundation

@MainActor public final class InboxStore {
    public static let lease: TimeInterval = 30
    private let file: URL
    private var devices: [String: Object]
    private var deliveries: [String: [Object]]
    public init(state: URL) throws {
        file = state.appending(path: "inboxes.json")
        let saved = FileManager.default.fileExists(atPath: file.path) ? try readObject(file) : [:]
        devices = saved["receivers"] as? [String: Object] ?? [:]
        deliveries = saved["deliveries"] as? [String: [Object]] ?? [:]
    }
    private func save() throws {
        try writeObject(["receivers": devices, "deliveries": deliveries], to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    private func validID(_ value: String) throws {
        try require(matches(value, "^[A-Za-z0-9-]{16,64}$"), "Invalid receiver ID")
    }
    private func digest(_ token: String) throws -> String {
        try require(matches(token, "^[A-Za-z0-9_-]{32,128}$"), "Invalid receiver credential")
        return sha256(Data(token.utf8))
    }
    private func authenticate(_ id: String, _ token: String) throws {
        try validID(id)
        let actual = try digest(token)
        try require(devices[id]?["secret_hash"] as? String == actual, "Receiver authentication failed")
    }
    public func authorize(_ id: String, token: String) throws { try authenticate(id, token) }
    public func bundles(_ id: String) -> Set<String> { Set(deliveries[id, default: []].compactMap { ($0["payload"] as? Object)?["bundle_id"] as? String }) }
    public func ownsRelease(_ id: String, releaseID: String) -> Bool { deliveries[id, default: []].contains { $0["release_id"] as? String == releaseID } }
    public func releaseIDs() -> Set<String> { Set(deliveries.values.flatMap { $0 }.compactMap { $0["release_id"] as? String }) }
    public func removeRelease(_ releaseID: String) throws {
        for id in deliveries.keys { deliveries[id]?.removeAll { $0["release_id"] as? String == releaseID } }
        try save()
    }
    public func connect(_ body: Object, token: String) throws -> Object {
        let id = try string(body, "id"), name = try string(body, "name"), platform = try string(body, "platform")
        try validID(id)
        let hash = try digest(token)
        try require(name.count <= 100 && ["iPhone", "iPad"].contains(platform), "Invalid device name or platform")
        if devices[id] != nil { try authenticate(id, token) }
        else { try require(devices.count < 100, "Receiver limit reached") }
        var row = devices[id] ?? [:]
        row.merge(["id": id, "name": name, "platform": platform, "secret_hash": hash, "active": true, "last_seen": Date.now.timeIntervalSince1970]) { _, new in new }
        devices[id] = row
        try save()
        return ["receiver_id": id, "lease_seconds": Self.lease]
    }
    public func heartbeat(_ id: String, token: String, active: Bool) throws -> Object {
        try authenticate(id, token)
        devices[id]?["active"] = active
        devices[id]?["last_seen"] = Date.now.timeIntervalSince1970
        try save()
        return ["releases": deliveries[id, default: []].map { $0["payload"] as? Object ?? [:] }, "lease_seconds": Self.lease]
    }
    public func acknowledge(_ id: String, token: String, releases: [String]) throws -> Object {
        try authenticate(id, token)
        try require(releases.count <= 1000, "Too many receipts")
        let ids = Set(releases)
        deliveries[id] = deliveries[id, default: []].map { delivery in
            var delivery = delivery
            if ids.contains(delivery["release_id"] as? String ?? "") { delivery["received_at"] = iso() }
            return delivery
        }
        try save()
        return ["received": true, "installed": false]
    }
    public func receivers(now: Date = .now) -> [Object] {
        devices.values.map { row in
            var result = row
            result.removeValue(forKey: "secret_hash")
            result["connected"] = (row["active"] as? Bool == true) && now.timeIntervalSince1970 - (row["last_seen"] as? Double ?? 0) < Self.lease
            return result
        }.sorted { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }
    }
    public func select(_ id: String? = nil) throws -> Object {
        let online = receivers().filter { $0["connected"] as? Bool == true && (id == nil || $0["id"] as? String == id) }
        try require(online.count == 1, "Open Publish on the target device. Use --receiver ID when several are connected; run receivers list.")
        try require(online[0]["udid"] as? String != nil, "Bind this inbox to its hardware provisioning UDID: receivers bind --receiver ID --udid UDID")
        return online[0]
    }
    public func bind(_ id: String, udid: String) throws -> Object {
        let udid = try validateUDID(udid)
        try require(devices[id] != nil, "Unknown receiver. Open Publish on the device first.")
        devices[id]?["udid"] = udid
        try save()
        return ["receiver_id": id, "udid": udid]
    }
    public func deliver(_ id: String, release: Object) throws -> Object {
        let receiver = try select(id)
        let udid = try string(receiver, "udid")
        try require((release["devices"] as? [String] ?? []).contains(udid), "Signed IPA does not cover the selected receiver")
        let keys: Set<String> = ["release_id", "name", "bundle_id", "version", "build", "configuration", "published_at", "size_bytes", "expires_at", "install_url", "install_page_url", "sha256", "minimum_os"]
        let payload = release.filter { keys.contains($0.key) }
        let releaseID = try string(release, "release_id")
        if !deliveries[id, default: []].contains(where: { $0["release_id"] as? String == releaseID }) {
            deliveries[id, default: []].insert(["release_id": releaseID, "payload": payload], at: 0)
        }
        try save()
        return receipt(id, releaseID: releaseID)
    }
    public func receipt(_ id: String, releaseID: String) -> Object {
        let delivery = deliveries[id, default: []].first { $0["release_id"] as? String == releaseID }
        return ["receiver_id": id, "queued": delivery != nil, "received": delivery?["received_at"] != nil, "installed": false]
    }
}
