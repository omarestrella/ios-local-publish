import Foundation
import Testing
@testable import PublisherCore

@Suite @MainActor struct InboxTests {
    let id = "abcdef00-1234-5678-9000-012345678900"
    let token = String(repeating: "a", count: 64)
    let udid = "00000000-0000000000000001"
    func withStore(_ test: (InboxStore, URL) throws -> Void) throws {
        try temporary { directory in
            let store = try InboxStore(state: directory)
            _ = try store.connect(["id": id, "name": "Phone", "platform": "iPhone"], token: token)
            try test(store, directory)
        }
    }
    @Test func foregroundLeaseAndBinding() throws {
        try withStore { store, _ in
            #expect(throws: PublishError.self) { try store.select() }
            _ = try store.bind(id, udid: udid)
            #expect(try store.select()["id"] as? String == id)
            #expect(store.receivers(now: Date.now.addingTimeInterval(31))[0]["connected"] as? Bool == false)
            _ = try store.heartbeat(id, token: token, active: false)
            #expect(try store.select()["id"] as? String == id)
        }
    }
    @Test func receiverCannotBeHijacked() throws {
        try withStore { store, _ in
            #expect(throws: PublishError.self) { try store.connect(["id": id, "name": "Imposter", "platform": "iPhone"], token: String(repeating: "b", count: 64)) }
            #expect(throws: PublishError.self) { try store.heartbeat(id, token: String(repeating: "b", count: 64), active: true) }
        }
    }
    @Test func offlinePublicationAndPersistence() throws {
        try withStore { store, directory in
            _ = try store.bind(id, udid: udid)
            _ = try store.heartbeat(id, token: token, active: false)
            let release: Object = ["release_id": "release", "devices": [udid], "build": "46", "name": "Juno", "ipa_path": "/private/artifact", "signing": "private"]
            let delivery = try store.deliver(id, release: release)
            #expect(delivery["queued"] as? Bool == true)
            let offlineRestart = try InboxStore(state: directory)
            #expect(try offlineRestart.select()["id"] as? String == id)
            let inbox = try offlineRestart.heartbeat(id, token: token, active: true)["releases"] as! [Object]
            #expect(inbox.count == 1)
            #expect(inbox[0]["ipa_path"] == nil && inbox[0]["signing"] == nil)
            let restarted = try InboxStore(state: directory)
            let refreshed = try restarted.heartbeat(id, token: token, active: true)["releases"] as! [Object]
            #expect(refreshed[0]["release_id"] as? String == "release")
        }
    }
    @Test func wrongDeviceCoverageStopsDelivery() throws {
        try withStore { store, _ in
            _ = try store.bind(id, udid: udid)
            #expect(throws: PublishError.self) { try store.deliver(id, release: ["release_id": "r", "devices": ["OTHER"]]) }
        }
    }
    @Test func inboxesAreIsolatedAndAmbiguousSelectionFails() throws {
        try withStore { store, _ in
            let other = "abcdef00-1234-5678-9000-012345678901"
            let otherToken = String(repeating: "b", count: 64)
            _ = try store.connect(["id": other, "name": "Tablet", "platform": "iPad"], token: otherToken)
            _ = try store.bind(id, udid: udid)
            _ = try store.bind(other, udid: "00000000-0000000000000002")
            _ = try store.deliver(id, release: ["release_id": "r", "devices": [udid]])
            let inbox = try store.heartbeat(other, token: otherToken, active: true)["releases"] as! [Object]
            #expect(inbox.isEmpty)
            #expect(throws: PublishError.self) { try store.select() }
        }
    }
    @Test func validatesHardwareUDIDsAndBuildNumbers() throws {
        #expect(throws: PublishError.self) { try validateUDID(UUID().uuidString) }
        #expect(try validateUDID(udid.lowercased()) == udid)
        #expect(try BuildPipeline.nextBuild(["24", "46", "45"]) == "47")
        #expect(try BuildPipeline.nextBuild(["1.2", "1.1.9"]) == "1.3")
        #expect(throws: PublishError.self) { try BuildPipeline.nextBuild(["abc"]) }
    }
    @Test func profileRequiresAdHocIdentityAndLifetime() throws {
        let cert = Data("certificate".utf8)
        var profile: Object = ["Entitlements": ["application-identifier": "PREFIX.com.app", "get-task-allow": false], "TeamIdentifier": ["TEAM"], "ProvisionedDevices": [udid], "ExpirationDate": Date.now.addingTimeInterval(90 * 86400), "DeveloperCertificates": [cert]]
        #expect(Signing.profileMatches(profile, bundle: "com.app", team: "TEAM", udid: udid, certificate: sha1(cert), days: 30))
        profile["ProvisionsAllDevices"] = true
        #expect(!Signing.profileMatches(profile, bundle: "com.app", team: "TEAM", udid: udid, certificate: sha1(cert), days: 30))
    }
    @Test func rejectsMalformedIPAWithoutExtraction() throws {
        try temporary { directory in
            let ipa = directory.appending(path: "bad.ipa")
            try Data("invalid".utf8).write(to: ipa)
            #expect(throws: PublishError.self) { try Signing.validateZip(ipa) }
        }
    }
    @Test func rejectsUnknownFlags() throws {
        let options = try Options(["publish", "--receiver", id, "--unknown", "value"])
        #expect(throws: PublishError.self) { try options.check(["receiver"]) }
    }
}

@Suite @MainActor struct CatalogTests {
    let bundle = "com.example.app"
    func release(_ version: String = "1.0.0", _ build: String = "64", id: String = String(repeating: "a", count: 32)) -> Object {
        ["bundle_id": bundle, "name": "Example", "version": version, "build": build, "release_id": id, "sha256": "hash", "published_at": "2026-10-21T00:00:00Z"]
    }
    @Test func versionGateIsNumericAndRejectsDowngrades() throws {
        let floor = release("1.10", "64")
        #expect(throws: PublishError.self) { try Catalog.checkCandidate(release("1.9", "999"), floor: floor) }
        #expect(throws: PublishError.self) { try Catalog.checkCandidate(release("1.10.0", "63"), floor: floor) }
        try Catalog.checkCandidate(release("1.10", "65"), floor: floor)
        try Catalog.checkCandidate(release("2.0", "1"), floor: floor)
        try Catalog.checkCandidate(release("1.10.0", "64"), floor: floor)
        var different = release("1.10", "64"); different["sha256"] = "different"
        #expect(throws: PublishError.self) { try Catalog.checkCandidate(different, floor: floor) }
    }
    @Test func deletionRetainsVersionFloorAcrossRestart() throws {
        try temporary { state in
            var record = release()
            record["ipa_path"] = state.appending(path: "runs/source/App.ipa").path
            let id = record["release_id"] as! String
            try writeObject(record, to: state.appending(path: "releases/\(id).json"))
            try write(Data("artifact".utf8), to: state.appending(path: "site/apps/\(bundle)/\(id)/app.ipa"))
            try write(Data("source".utf8), to: URL(filePath: record["ipa_path"] as! String))
            let catalog = try Catalog(state: state)
            try catalog.deleteRelease(id)
            #expect(!FileManager.default.fileExists(atPath: state.appending(path: "site/apps/\(bundle)/\(id)").path))
            #expect(try catalog.releases().isEmpty)
            #expect(!FileManager.default.fileExists(atPath: state.appending(path: "runs/source").path))
            let restarted = try Catalog(state: state)
            #expect(throws: PublishError.self) { try restarted.check(release("1.0", "63")) }
            try restarted.check(release("1.0", "65"))
        }
    }
    @Test func catalogCRUDIsScopedAndDoesNotResetFloor() throws {
        try temporary { state in
            let catalog = try Catalog(state: state)
            _ = try catalog.upsertApp(receiver: "owner", bundle: bundle, name: "Example", visible: [])
            #expect(catalog.visibleApps(receiver: "other", deliveredBundles: []).isEmpty)
            _ = try catalog.upsertApp(receiver: "owner", bundle: bundle, name: "Renamed", visible: [])
            #expect(catalog.visibleApps(receiver: "owner", deliveredBundles: [])[0]["name"] as? String == "Renamed")
            #expect(throws: PublishError.self) { try catalog.upsertApp(receiver: "other", bundle: bundle, name: "Stolen", visible: []) }
            try catalog.commit(release())
            try catalog.removeApp(bundle)
            #expect(catalog.visibleApps(receiver: "owner", deliveredBundles: []).isEmpty)
            #expect(throws: PublishError.self) { try catalog.check(release("0.9", "999")) }
        }
    }
    @Test func cleanupKeepsDeliveredBuildAndLatestUnpublishedRun() throws {
        try temporary { state in
            let oldID = String(repeating: "a", count: 32), currentID = String(repeating: "b", count: 32)
            var old = release("1.0", "63", id: oldID)
            var current = release("1.0", "64", id: currentID)
            old["hosting_verified"] = ["ipa": true]
            current["hosting_verified"] = true
            old["ipa_path"] = state.appending(path: "runs/old/App.ipa").path
            current["ipa_path"] = state.appending(path: "runs/current/App.ipa").path
            for record in [old, current] {
                let id = record["release_id"] as! String
                try writeObject(record, to: state.appending(path: "releases/\(id).json"))
                try write(Data("IPA".utf8), to: URL(filePath: record["ipa_path"] as! String))
                try write(Data("install".utf8), to: state.appending(path: "site/apps/\(bundle)/\(id)/index.html"))
            }
            try writeObject(["run_path": state.appending(path: "runs/unpublished").path], to: state.appending(path: "last-build.json"))
            try write(Data(), to: state.appending(path: "runs/unpublished/App.ipa"))
            let catalog = try Catalog(state: state)
            let result = try catalog.pruneLegacy(keeping: [currentID])
            #expect(result["deleted_legacy_releases"] as? Int == 1)
            #expect(try catalog.releases().count == 1)
            #expect(FileManager.default.fileExists(atPath: state.appending(path: "runs/current/App.ipa").path))
            #expect(FileManager.default.fileExists(atPath: state.appending(path: "runs/unpublished/App.ipa").path))
            #expect(!FileManager.default.fileExists(atPath: state.appending(path: "runs/old").path))
        }
    }
}
