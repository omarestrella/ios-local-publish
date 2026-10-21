import Foundation

public struct BuildPipeline {
    public static func project(_ path: String) throws -> URL {
        let url = URL(filePath: (path as NSString).expandingTildeInPath).standardizedFileURL
        var directory: ObjCBool = false
        try require(FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue, "Project directory does not exist")
        if ["xcodeproj", "xcworkspace"].contains(url.pathExtension) { return url }
        let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])!
        var choices: [URL] = []
        while let item = walker.nextObject() as? URL {
            if ["node_modules", "Pods", "Carthage"].contains(item.lastPathComponent) { walker.skipDescendants() }
            else if ["xcodeproj", "xcworkspace"].contains(item.pathExtension) { choices.append(item); walker.skipDescendants() }
            else if item.pathComponents.count - url.pathComponents.count >= 4 { walker.skipDescendants() }
        }
        let workspaces = choices.filter { $0.pathExtension == "xcworkspace" }
        choices = workspaces.isEmpty ? choices : workspaces
        try require(choices.count == 1, "Specify an exact .xcodeproj or .xcworkspace; project discovery is ambiguous")
        return choices[0]
    }
    public static func nextBuild(_ candidates: [String]) throws -> String {
        for value in candidates { try require(matches(value, "^[0-9]+(?:\\.[0-9]+){0,2}$") && value.split(separator: ".").allSatisfy { Int($0) != nil }, "Build number must contain one to three numeric components") }
        func parts(_ value: String) -> [Int] { let p = value.split(separator: ".").map { Int($0)! }; return p + Array(repeating: 0, count: 3 - p.count) }
        guard let highest = candidates.max(by: { parts($0).lexicographicallyPrecedes(parts($1)) }) else { throw PublishError("CURRENT_PROJECT_VERSION is unset; pass --build-number") }
        var components = highest.split(separator: ".").map(String.init)
        guard let last = components.last.flatMap(Int.init), last < Int.max else { throw PublishError("Build number overflow") }
        components[components.count - 1] = String(last + 1)
        return components.joined(separator: ".")
    }
    public static func build(_ options: Options, state: URL, config: Object, udid: String, deviceName: String) throws -> Object {
        let days = Int(options.get("min-validity-days") ?? "30") ?? -1
        try require(days >= 0, "--min-validity-days must be nonnegative")
        let runDirectory = state.appending(path: "runs/\(Int(Date.now.timeIntervalSince1970))-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
        var record: Object = ["run_path": runDirectory.path, "status": "building"]
        do {
            let archive: URL
            var team = options.get("team") ?? config["team"] as? String
            var preflight: Object?
            var requested: String?
            if let existing = options.get("archive") {
                try require(["project", "scheme", "configuration", "build-number", "build-setting"].allSatisfy { !options.has($0) }, "--archive cannot be combined with source build options")
                archive = URL(filePath: existing).standardizedFileURL
                team = try team ?? (plist(Data(contentsOf: archive.appending(path: "Info.plist")))["ApplicationProperties"] as? Object)?["Team"] as? String
            } else {
                let projectValue = options.get("project") ?? config["project"] as? String ?? ""
                let project = try project(projectValue)
                guard let scheme = options.get("scheme") ?? config["scheme"] as? String else { throw PublishError("Provide --scheme or configure with init") }
                let configuration = options.get("configuration") ?? config["configuration"] as? String ?? "Release"
                let extra = options.values["build-setting"] ?? []
                try require(!extra.contains(where: { $0.hasPrefix("CURRENT_PROJECT_VERSION=") }), "Use --build-number to override the build number")
                let settingsData = try run(["xcodebuild", project.pathExtension == "xcworkspace" ? "-workspace" : "-project", project.path, "-scheme", scheme, "-configuration", configuration] + extra + ["-showBuildSettings", "-json"])
                let settings = try JSONSerialization.jsonObject(with: settingsData) as? [Object] ?? []
                let applicationRows = settings.filter { ($0["buildSettings"] as? Object)?["PRODUCT_TYPE"] as? String == "com.apple.product-type.application" }
                let mainRow = applicationRows.first { $0["target"] as? String == scheme } ?? (applicationRows.count == 1 ? applicationRows[0] : nil)
                guard let main = mainRow?["buildSettings"] as? Object else { throw PublishError("Select a scheme with one application target") }
                team = team ?? main["DEVELOPMENT_TEAM"] as? String
                guard let team else { throw PublishError("Cannot infer developer team; pass --team") }
                let identifiers = settings.compactMap { row -> String? in
                    guard let settings = row["buildSettings"] as? Object, ["app", "appex"].contains(settings["WRAPPER_EXTENSION"] as? String ?? "") else { return nil }
                    return settings["PRODUCT_BUNDLE_IDENTIFIER"] as? String
                }
                let bundle = main["PRODUCT_BUNDLE_IDENTIFIER"] as? String ?? ""
                let marketing = main["MARKETING_VERSION"] as? String
                let catalogFile = state.appending(path: "catalog.json")
                let floor = options.commands.first == "publish" && FileManager.default.fileExists(atPath: catalogFile.path)
                    ? (try readObject(catalogFile)["floors"] as? [String: Object])?[bundle] : nil
                if let floor, let marketing, !marketing.isEmpty {
                    try Catalog.checkCandidate(["version": marketing, "build": try string(floor, "build")], floor: floor)
                }
                let ledgerFile = state.appending(path: "build-numbers.json")
                var ledger = FileManager.default.fileExists(atPath: ledgerFile.path) ? try readObject(ledgerFile) : [:]
                let key = sha256(Data("\(project.path)\n\(scheme)".utf8))
                var candidates: [String] = []
                if let floor, let marketing,
                   try PublishedVersion(version: marketing, build: "0") == PublishedVersion(version: string(floor, "version"), build: "0") {
                    candidates.append(try string(floor, "build"))
                }
                if let previous = (ledger[key] as? Object)?["build"] as? String { candidates.append(previous) }
                if let current = main["CURRENT_PROJECT_VERSION"] as? String, !current.isEmpty { candidates.append(current) }
                if let previous = try? readObject(state.appending(path: "last-build.json")),
                   (previous["project"] as? String ?? config["project"] as? String) == project.path,
                   (previous["scheme"] as? String ?? config["scheme"] as? String) == scheme, let value = previous["build"] as? String { candidates.append(value) }
                let number = try options.get("build-number") ?? nextBuild(candidates)
                _ = try nextBuild([number])
                if let floor, let marketing, !marketing.isEmpty {
                    try Catalog.checkCandidate(["version": marketing, "build": number], floor: floor)
                }
                preflight = try Signing.preflight(team: team, identifiers: identifiers, days: days)
                // Keep the high-water mark even if an explicit smaller build was requested.
                let high = try nextBuild(candidates + [number])
                var parts = high.split(separator: ".").map(String.init); parts[parts.count-1] = String(Int(parts.last!)! - 1)
                ledger[key] = ["project": project.path, "scheme": scheme, "build": parts.joined(separator: ".")]
                try writeObject(ledger, to: ledgerFile)
                archive = runDirectory.appending(path: "App.xcarchive")
                requested = number
                record.merge(["project": project.path, "scheme": scheme, "configuration": configuration, "requested_build": number]) { _, new in new }
                try writeObject(record, to: runDirectory.appending(path: "result.json"))
                var arguments = ["asc", "xcode", "archive", project.pathExtension == "xcworkspace" ? "--workspace" : "--project", project.path, "--scheme", scheme, "--configuration", configuration, "--archive-path", archive.path, "--xcodebuild-flag=-destination", "--xcodebuild-flag=generic/platform=iOS", "--xcodebuild-flag=CURRENT_PROJECT_VERSION=\(number)", "--output", "json"]
                arguments += extra.map { "--xcodebuild-flag=" + $0 }
                progress("Archiving \(scheme) build \(number)")
                try run(arguments, log: runDirectory.appending(path: "archive.log"))
            }
            guard let team else { throw PublishError("Cannot infer archive team; pass --team") }
            let exportOptions = try Signing.prepare(archive: archive, udid: udid, name: deviceName, team: team, days: days, directory: runDirectory, preflight: preflight)
            let ipa = runDirectory.appending(path: "App.ipa")
            try run(["asc", "xcode", "export", "--archive-path", archive.path, "--ipa-path", ipa.path, "--export-options", exportOptions.path, "--output", "json"], log: runDirectory.appending(path: "export.log"))
            let metadata = try Signing.inspect(ipa, requiredUDID: udid, days: days)
            try require(requested == nil || requested == metadata["build"] as? String, "Exported CFBundleVersion differs from the reserved build. Use $(CURRENT_PROJECT_VERSION) in Info.plist.")
            record.merge(metadata) { _, new in new }
            record["status"] = "built"; record["published"] = false
            try writeObject(record, to: runDirectory.appending(path: "result.json"))
            try writeObject(record, to: state.appending(path: "last-build.json"))
            return record
        } catch {
            record["status"] = "failed"; record["error"] = error.localizedDescription
            try? writeObject(record, to: runDirectory.appending(path: "result.json"))
            throw error
        }
    }
}
