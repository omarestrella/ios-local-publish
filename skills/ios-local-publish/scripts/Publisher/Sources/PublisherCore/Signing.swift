import Foundation

public struct Signing {
    public static func decodeProfile(_ data: Data) throws -> Object {
        try temporary { directory in
            let path = directory.appending(path: "profile.mobileprovision")
            try data.write(to: path)
            return try plist(run(["security", "cms", "-D", "-i", path.path]))
        }
    }
    public static func certificate(team: String, days: Int) throws -> Object {
        let identities = String(decoding: try run(["security", "find-identity", "-v", "-p", "codesigning"]), as: UTF8.self)
        var candidates: [Object] = []
        for row in rows(try asc(["certificates", "list", "--paginate"])) {
            let attrs = attributes(row)
            guard ["IOS_DISTRIBUTION", "DISTRIBUTION"].contains(attrs["certificateType"] as? String ?? ""),
                  let encoded = attrs["certificateContent"] as? String, let content = Data(base64Encoded: encoded),
                  let expiryString = attrs["expirationDate"] as? String else { continue }
            let fingerprint = sha1(content)
            let validIdentity = identities.components(separatedBy: .newlines).contains {
                $0.contains(fingerprint) && $0.contains("(\(team))") && !$0.contains("REVOKED")
            }
            let expiry = try date(expiryString)
            if validIdentity && expiry > .now.addingTimeInterval(Double(days) * 86400) {
                candidates.append(["id": try string(row, "id"), "sha1": fingerprint, "expires_at": expiryString])
            }
        }
        guard let candidate = candidates.max(by: { ($0["expires_at"] as? String ?? "") < ($1["expires_at"] as? String ?? "") }) else {
            throw PublishError("No local distribution private key for team \(team) valid beyond \(days) days. Check Keychain and asc account; --team does not switch accounts.")
        }
        return candidate
    }
    public static func bundles(_ application: URL) throws -> [URL] {
        let descendants = FileManager.default.enumerator(at: application, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
        return [application] + descendants.filter { ["app", "appex"].contains($0.pathExtension) }.sorted { $0.path < $1.path }
    }
    public static func archiveApp(_ archive: URL) throws -> URL {
        let apps = try FileManager.default.contentsOfDirectory(at: archive.appending(path: "Products/Applications"), includingPropertiesForKeys: nil).filter { $0.pathExtension == "app" }
        try require(apps.count == 1, "Expected one top-level app in archive")
        return apps[0]
    }
    public static func preflight(team: String, identifiers: [String], days: Int) throws -> Object {
        let cert = try certificate(team: team, days: days)
        let bundleRows = rows(try asc(["bundle-ids", "list", "--paginate"]))
        var ids: [String: Object] = [:]
        for row in bundleRows { ids[try string(attributes(row), "identifier")] = row }
        try require(identifiers.allSatisfy { ids[$0] != nil }, "Register bundle IDs and capabilities with the correct asc account first: \(identifiers.filter { ids[$0] == nil }.joined(separator: ", "))")
        let profiles = try rows(asc(["profiles", "list", "--profile-type", "IOS_APP_ADHOC", "--paginate"])).filter { attributes($0)["profileState"] as? String == "ACTIVE" }.map { row -> Object in
            let data = Data(base64Encoded: try string(attributes(row), "profileContent"))
            guard let data else { throw PublishError("Invalid profile content") }
            return ["row": row, "profile": try decodeProfile(data)]
        }
        return ["certificate": cert, "bundle_ids": ids, "profiles": profiles]
    }
    public static func profileMatches(_ profile: Object, bundle: String, team: String, udid: String, certificate: String, days: Int) -> Bool {
        let entitlements = profile["Entitlements"] as? Object ?? [:]
        let appID = entitlements["application-identifier"] as? String ?? ""
        let suffix = appID.split(separator: ".", maxSplits: 1).dropFirst().joined(separator: ".")
        return suffix == bundle && (profile["TeamIdentifier"] as? [String] ?? []).contains(team)
            && entitlements["get-task-allow"] as? Bool != true && profile["ProvisionsAllDevices"] as? Bool != true
            && (profile["ProvisionedDevices"] as? [String] ?? []).map { $0.uppercased() }.contains(udid)
            && (profile["ExpirationDate"] as? Date ?? .distantPast) > .now.addingTimeInterval(Double(days) * 86400)
            && (profile["DeveloperCertificates"] as? [Data] ?? []).contains { sha1($0) == certificate }
    }
    public static func prepare(archive: URL, udid: String, name: String, team: String, days: Int, directory: URL, preflight previous: Object? = nil) throws -> URL {
        let app = try archiveApp(archive)
        let identifiers = try bundles(app).map { try string(plist(Data(contentsOf: $0.appending(path: "Info.plist"))), "CFBundleIdentifier") }
        let preflight = try previous ?? self.preflight(team: team, identifiers: identifiers, days: days)
        let certificate = preflight["certificate"] as? Object ?? [:]
        let ids = preflight["bundle_ids"] as? [String: Object] ?? [:]
        try require(identifiers.allSatisfy { ids[$0] != nil }, "Embedded bundle ID missing from authenticated Apple account")
        let deviceRows = rows(try asc(["devices", "list", "--paginate"]))
        var device = deviceRows.first { (attributes($0)["udid"] as? String ?? "").uppercased() == udid }
        if let device { try require(attributes(device)["status"] as? String == "ENABLED", "Selected device is disabled in Apple Developer") }
        else { device = try asc(["devices", "register", "--name", name, "--udid", udid, "--platform", "IOS"])["data"] as? Object }
        guard let device else { throw PublishError("Could not register device") }
        var mapping: [String: String] = [:]
        for identifier in identifiers {
            let candidates = (preflight["profiles"] as? [Object] ?? []).filter { candidate in
                profileMatches(candidate["profile"] as? Object ?? [:], bundle: identifier, team: team, udid: udid, certificate: certificate["sha1"] as? String ?? "", days: days)
            }
            var row = candidates.max { (($0["profile"] as? Object)?["ExpirationDate"] as? Date ?? .distantPast) < (($1["profile"] as? Object)?["ExpirationDate"] as? Date ?? .distantPast) }?["row"] as? Object
            if row == nil {
                progress("Creating ad hoc profile for \(identifier)")
                row = try asc(["profiles", "create", "--name", "Publish \(identifier) \(Int(Date.now.timeIntervalSince1970))", "--profile-type", "IOS_APP_ADHOC", "--bundle", string(ids[identifier] ?? [:], "id"), "--certificate", string(certificate, "id"), "--device", string(device, "id")])["data"] as? Object
            }
            guard let row, let content = Data(base64Encoded: try string(attributes(row), "profileContent")) else { throw PublishError("Invalid provisioning profile") }
            let profile = try decodeProfile(content)
            try require(profileMatches(profile, bundle: identifier, team: team, udid: udid, certificate: try string(certificate, "sha1"), days: days), "Profile does not cover device, bundle, certificate, or required lifetime")
            let uuid = try string(profile, "UUID")
            let profileURL = URL(filePath: NSHomeDirectory() + "/Library/Developer/Xcode/UserData/Provisioning Profiles/\(uuid).mobileprovision")
            if !FileManager.default.fileExists(atPath: profileURL.path) { try write(content, to: profileURL) }
            mapping[identifier] = uuid
        }
        let path = directory.appending(path: "ExportOptions.plist")
        try writePlist(["method": "release-testing", "destination": "export", "signingStyle": "manual", "teamID": team,
            "signingCertificate": try string(certificate, "sha1"), "provisioningProfiles": mapping, "thinning": "<none>",
            "manageAppVersionAndBuildNumber": false, "stripSwiftSymbols": true], to: path)
        return path
    }
    public static func inspect(_ ipa: URL, requiredUDID: String? = nil, days: Int = 0) throws -> Object {
        // Validate archive paths before extraction, including symlink entries in the ZIP central directory.
        try validateZip(ipa)
        return try temporary { temp in
            try run(["ditto", "-x", "-k", ipa.path, temp.path])
            let apps = try FileManager.default.contentsOfDirectory(at: temp.appending(path: "Payload"), includingPropertiesForKeys: nil).filter { $0.pathExtension == "app" }
            try require(apps.count == 1, "IPA must contain one Payload/*.app")
            try run(["codesign", "--verify", "--deep", "--strict", apps[0].path])
            var commonDevices: Set<String>?, commonTeam: String?, expiry = Date.distantFuture
            for (index, bundle) in try bundles(apps[0]).enumerated() {
                let info = try plist(Data(contentsOf: bundle.appending(path: "Info.plist")))
                let profile = try decodeProfile(Data(contentsOf: bundle.appending(path: "embedded.mobileprovision")))
                let ents = profile["Entitlements"] as? Object ?? [:]
                let team = (profile["TeamIdentifier"] as? [String])?.first ?? ""
                let provisioned = Set((profile["ProvisionedDevices"] as? [String] ?? []).map { $0.uppercased() })
                let expiration = profile["ExpirationDate"] as? Date ?? .distantPast
                try require(ents["get-task-allow"] as? Bool != true && profile["ProvisionsAllDevices"] as? Bool != true && !provisioned.isEmpty, "IPA requires ad hoc distribution signing")
                try require(requiredUDID == nil || provisioned.contains(requiredUDID!), "IPA profile excludes selected receiver")
                try require(expiration > .now.addingTimeInterval(Double(days) * 86400), "IPA signing expires within \(days) days")
                let appID = try string(ents, "application-identifier")
                try require(appID.split(separator: ".", maxSplits: 1).dropFirst().joined(separator: ".") == info["CFBundleIdentifier"] as? String, "Profile bundle ID mismatch")
                let signed = try plist(run(["codesign", "-d", "--entitlements", ":-", bundle.path]))
                try require(signed["application-identifier"] as? String == appID && signed["com.apple.developer.team-identifier"] as? String == team && signed["get-task-allow"] as? Bool != true, "Signed entitlements mismatch")
                let prefix = temp.appending(path: "certificate-\(index)-").path
                try run(["codesign", "-d", "--extract-certificates=\(prefix)", bundle.path])
                let fingerprint = sha1(try Data(contentsOf: URL(filePath: prefix + "0")))
                try require((profile["DeveloperCertificates"] as? [Data] ?? []).contains { sha1($0) == fingerprint }, "Signing certificate is not in profile")
                try require(commonTeam == nil || commonTeam == team, "IPA contains different developer teams")
                commonTeam = team; expiry = min(expiry, expiration)
                commonDevices = commonDevices.map { $0.intersection(provisioned) } ?? provisioned
            }
            let info = try plist(Data(contentsOf: apps[0].appending(path: "Info.plist")))
            return ["ipa_path": ipa.path, "name": info["CFBundleDisplayName"] ?? info["CFBundleName"] ?? "App",
                "bundle_id": try string(info, "CFBundleIdentifier"), "version": String(describing: info["CFBundleShortVersionString"] ?? ""),
                "build": String(describing: info["CFBundleVersion"] ?? ""), "expires_at": iso(expiry), "team": commonTeam ?? "",
                "devices": Array(commonDevices ?? []).sorted(), "sha256": try hashFile(ipa),
                "size_bytes": try ipa.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0, "signatures_verified": true]
        }
    }
    public static func validateZip(_ ipa: URL) throws {
        let data = try Data(contentsOf: ipa, options: .mappedIfSafe)
        func u16(_ i: Int) -> Int { Int(data[i]) | Int(data[i+1]) << 8 }
        func u32(_ i: Int) -> Int { u16(i) | u16(i+2) << 16 }
        try require(data.count >= 22, "Invalid IPA ZIP")
        let minimum = max(0, data.count - 65557)
        guard let end = stride(from: data.count - 22, through: minimum, by: -1).first(where: { u32($0) == 0x06054b50 && $0 + 22 + u16($0 + 20) == data.count }) else { throw PublishError("Invalid IPA ZIP directory") }
        try require(u16(end+4) == 0 && u16(end+6) == 0, "Multi-volume IPAs are unsupported")
        var offset = u32(end+16)
        let count = u16(end+10)
        try require(count < 65535 && offset < end, "ZIP64 IPAs are unsupported")
        for _ in 0..<count {
            try require(offset >= 0 && offset + 46 <= end, "Truncated IPA directory")
            try require(u32(offset) == 0x02014b50, "Invalid IPA directory entry")
            let nameLength = u16(offset+28), extraLength = u16(offset+30), commentLength = u16(offset+32)
            try require(offset + 46 + nameLength + extraLength + commentLength <= end, "Truncated IPA entry")
            let name = String(decoding: data[(offset+46)..<(offset+46+nameLength)], as: UTF8.self)
            try require(!name.hasPrefix("/") && !name.contains("\\") && !name.contains("\0") && !name.split(separator: "/").contains(".."), "Unsafe path in IPA")
            let mode = (u32(offset+38) >> 16) & 0xf000
            // Reject links before extraction. iOS application IPAs don't need symlinks.
            try require(mode != 0xa000, "Symlinks in IPAs are unsupported")
            offset += 46 + nameLength + extraLength + commentLength
        }
    }
}
