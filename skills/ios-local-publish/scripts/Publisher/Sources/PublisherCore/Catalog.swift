import Foundation

public struct PublishedVersion: Comparable, Equatable {
    public let version: [Int]
    public let build: [Int]
    public init(version: String, build: String) throws {
        func components(_ value: String) throws -> [Int] {
            try require(matches(value, "^[0-9]+(?:\\.[0-9]+){0,2}$"), "Version/build must contain one to three numeric components")
            let parsed = value.split(separator: ".").compactMap { Int($0) }
            try require(parsed.count == value.split(separator: ".").count, "Version/build component is too large")
            return parsed + Array(repeating: 0, count: 3 - parsed.count)
        }
        self.version = try components(version); self.build = try components(build)
    }
    public static func < (left: Self, right: Self) -> Bool {
        left.version == right.version ? left.build.lexicographicallyPrecedes(right.build) : left.version.lexicographicallyPrecedes(right.version)
    }
}

@MainActor public final class Catalog {
    private let state: URL
    private var apps: [String: Object]
    private var floors: [String: Object]
    public init(state: URL) throws {
        self.state = state
        let file = state.appending(path: "catalog.json")
        let saved = FileManager.default.fileExists(atPath: file.path) ? try readObject(file) : [:]
        apps = saved["apps"] as? [String: Object] ?? [:]
        floors = saved["floors"] as? [String: Object] ?? [:]
        // Import the old publisher's history before any deletion can remove its high-water mark.
        for release in try releases() {
            let bundle = try string(release, "bundle_id")
            if apps[bundle] == nil { apps[bundle] = ["bundle_id": bundle, "name": release["name"] ?? bundle, "owners": [String]()] }
            try advance(release)
        }
        try save()
    }
    private func save() throws { try writeObject(["apps": apps, "floors": floors], to: state.appending(path: "catalog.json")) }
    public func releases() throws -> [Object] {
        let directory = state.appending(path: "releases")
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }.map(readObject)
            .sorted { ($0["published_at"] as? String ?? "") > ($1["published_at"] as? String ?? "") }
    }
    public func check(_ release: Object) throws {
        try Self.checkCandidate(release, floor: floors[try string(release, "bundle_id")])
    }
    nonisolated public static func checkCandidate(_ release: Object, floor: Object?) throws {
        let candidate = try PublishedVersion(version: string(release, "version"), build: string(release, "build"))
        if let floor {
            let latest = try PublishedVersion(version: string(floor, "version"), build: string(floor, "build"))
            try require(candidate >= latest, "Cannot publish \(release["version"] ?? "") (\(release["build"] ?? "")); latest published is \(floor["version"] ?? "") (\(floor["build"] ?? "")). Increase the version/build.")
            if candidate == latest, let hash = release["sha256"] as? String, let old = floor["sha256"] as? String {
                try require(hash == old, "This version/build was already published with a different IPA. Increase the build number.")
            }
        }
    }
    private func advance(_ release: Object) throws {
        let bundle = try string(release, "bundle_id")
        let candidate = try PublishedVersion(version: string(release, "version"), build: string(release, "build"))
        if let previous = floors[bundle], candidate < (try PublishedVersion(version: string(previous, "version"), build: string(previous, "build"))) { return }
        floors[bundle] = release.filter { ["bundle_id", "version", "build", "sha256"].contains($0.key) }
    }
    public func commit(_ release: Object) throws {
        try check(release)
        try advance(release)
        let bundle = try string(release, "bundle_id")
        if apps[bundle] == nil { apps[bundle] = ["bundle_id": bundle, "name": release["name"] ?? bundle, "owners": [String]()] }
        try save()
    }
    public func visibleApps(receiver: String, deliveredBundles: Set<String>) -> [Object] {
        apps.values.filter { app in
            deliveredBundles.contains(app["bundle_id"] as? String ?? "") || (app["owners"] as? [String] ?? []).contains(receiver)
        }.map { $0.filter { ["bundle_id", "name"].contains($0.key) } }
            .sorted { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }
    }
    public func upsertApp(receiver: String, bundle: String, name: String, visible: Set<String>) throws -> Object {
        try require(matches(bundle, "^[A-Za-z0-9][A-Za-z0-9.-]*$") && bundle.contains("."), "Enter an app bundle identifier")
        try require(!name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 100, "Enter an app name (up to 100 characters)")
        if apps[bundle] != nil {
            try require(visible.contains(bundle) || (apps[bundle]?["owners"] as? [String] ?? []).contains(receiver), "This app belongs to another inbox")
        }
        var app = apps[bundle] ?? ["bundle_id": bundle]
        var owners = Set(app["owners"] as? [String] ?? []); owners.insert(receiver)
        app["owners"] = Array(owners).sorted(); app["name"] = name
        apps[bundle] = app; try save()
        return app.filter { ["bundle_id", "name"].contains($0.key) }
    }
    public func removeApp(_ bundle: String) throws { apps.removeValue(forKey: bundle); try save() }
    public func floor(_ bundle: String) -> Object? { floors[bundle] }
    public func deleteRelease(_ id: String) throws {
        try require(matches(id, "^[a-f0-9]{32}$"), "Invalid release ID")
        let record = state.appending(path: "releases/\(id).json")
        let release = try readObject(record)
        // Floor is durable even when its last artifact is deleted.
        try advance(release); try save()
        let bundle = try string(release, "bundle_id")
        try require(matches(bundle, "^[A-Za-z0-9][A-Za-z0-9.-]*$"), "Invalid bundle identifier")
        let artifact = state.appending(path: "site/apps/\(bundle)/\(id)")
        if FileManager.default.fileExists(atPath: artifact.path) { try FileManager.default.removeItem(at: artifact) }
        try FileManager.default.removeItem(at: record)
        let remaining = try releases()
        if let path = release["ipa_path"] as? String, !remaining.contains(where: { $0["ipa_path"] as? String == path }) {
            let source = URL(filePath: path).resolvingSymlinksInPath()
            let runs = state.appending(path: "runs").resolvingSymlinksInPath()
            if source.path.hasPrefix(runs.path + "/") {
                let relative = source.path.dropFirst(runs.path.count + 1)
                if let component = relative.split(separator: "/").first {
                    let run = runs.appending(path: String(component))
                    let stillReferenced = remaining.contains { record in
                        guard let path = record["ipa_path"] as? String else { return false }
                        return URL(filePath: path).resolvingSymlinksInPath().path.hasPrefix(run.path + "/")
                    }
                    if !stillReferenced && FileManager.default.fileExists(atPath: run.path) { try FileManager.default.removeItem(at: run) }
                }
                if let last = try? readObject(state.appending(path: "last-build.json")), last["ipa_path"] as? String == path { try? FileManager.default.removeItem(at: state.appending(path: "last-build.json")) }
            }
        }
        try rebuildPointers()
    }
    public func rebuildPointers() throws {
        let remaining = try releases()
        let latestFile = state.appending(path: "latest.json")
        if let latest = remaining.first { try writeObject(latest, to: latestFile) }
        else { try? FileManager.default.removeItem(at: latestFile) }
        let root = state.appending(path: "site/apps")
        if FileManager.default.fileExists(atPath: root.path) {
            for folder in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
                let page = folder.appending(path: "index.html")
                if let latest = remaining.first(where: { $0["bundle_id"] as? String == folder.lastPathComponent }),
                   let id = latest["release_id"] as? String {
                    let content = try Data(contentsOf: folder.appending(path: "\(id)/index.html"))
                    try write(content, to: page)
                } else { try? FileManager.default.removeItem(at: folder) }
            }
        }
    }
    public func pruneLegacy(keeping nativeIDs: Set<String>) throws -> Object {
        let all = try releases()
        var keep = nativeIDs
        if keep.isEmpty {
            var seen = Set<String>()
            for release in all where seen.insert(try string(release, "bundle_id")).inserted { keep.insert(try string(release, "release_id")) }
        }
        var deleted = 0
        for release in all {
            let id = try string(release, "release_id")
            if !keep.contains(id) && !(release["hosting_verified"] is Bool) { try deleteRelease(id); deleted += 1 }
        }
        let retained = try releases()
        var keepRuns = Set<String>()
        for release in retained {
            if let path = release["ipa_path"] as? String { keepRuns.insert(URL(filePath: path).deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path) }
        }
        if let last = try? readObject(state.appending(path: "last-build.json")), let run = last["run_path"] as? String { keepRuns.insert(URL(filePath: run).resolvingSymlinksInPath().standardizedFileURL.path) }
        let runs = state.appending(path: "runs")
        var removedRuns = 0
        if FileManager.default.fileExists(atPath: runs.path) {
            for run in try FileManager.default.contentsOfDirectory(at: runs, includingPropertiesForKeys: nil) where !keepRuns.contains(run.resolvingSymlinksInPath().standardizedFileURL.path) {
                try FileManager.default.removeItem(at: run); removedRuns += 1
            }
        }
        return ["deleted_legacy_releases": deleted, "removed_unreferenced_runs": removedRuns, "retained_releases": retained.count]
    }
}
