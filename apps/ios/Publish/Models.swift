import Foundation

struct PublishedBuild: Codable, Identifiable, Equatable {
    let releaseID: String
    let name: String
    let bundleID: String
    let version: String
    let build: String
    let configuration: String?
    let publishedAt: String?
    let sizeBytes: Int64
    let expiresAt: String
    let installURL: URL
    let installPageURL: URL
    var id: String { releaseID }
    var expired: Bool {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expiry = formatter.date(from: expiresAt) ?? ISO8601DateFormatter().date(from: expiresAt)
        return expiry.map { $0 <= .now } ?? true
    }
    enum CodingKeys: String, CodingKey {
        case releaseID = "release_id", name, bundleID = "bundle_id", version, build, configuration
        case publishedAt = "published_at", sizeBytes = "size_bytes", expiresAt = "expires_at"
        case installURL = "install_url", installPageURL = "install_page_url"
    }
}

struct AppBuilds: Identifiable, Equatable {
    let id: String
    let name: String
    let builds: [PublishedBuild]
}

struct CatalogApp: Codable, Identifiable, Equatable {
    let bundleID: String
    let name: String
    var id: String { bundleID }
    enum CodingKeys: String, CodingKey { case bundleID = "bundle_id", name }
}

struct InboxResponse: Codable {
    let releases: [PublishedBuild]
    let apps: [CatalogApp]?
}

struct Publisher: Identifiable, Equatable {
    let name: String
    let url: URL
    var id: String { url.absoluteString }
}
