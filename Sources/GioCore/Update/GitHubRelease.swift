import Foundation

/// UP-02: the fields Gio reads from GitHub's `GET /repos/{repo}/releases`.
/// Unknown keys are ignored, optional ones may be null.
public struct GitHubReleaseAsset: Codable, Equatable, Sendable {
    public var name: String
    public var size: Int
    /// API URL; with `Accept: application/octet-stream` it downloads the
    /// asset (the only way for a private repository, with a token).
    public var url: String
    /// Public download URL (public repositories, no token).
    public var browserDownloadURL: String

    public init(name: String, size: Int, url: String, browserDownloadURL: String) {
        self.name = name
        self.size = size
        self.url = url
        self.browserDownloadURL = browserDownloadURL
    }

    enum CodingKeys: String, CodingKey {
        case name, size, url
        case browserDownloadURL = "browser_download_url"
    }
}

public struct GitHubRelease: Codable, Equatable, Sendable {
    public var tagName: String
    public var name: String?
    public var draft: Bool
    public var prerelease: Bool
    /// Markdown release notes.
    public var body: String?
    public var htmlURL: String?
    public var assets: [GitHubReleaseAsset]

    public init(
        tagName: String, name: String? = nil, draft: Bool = false, prerelease: Bool = false,
        body: String? = nil, htmlURL: String? = nil, assets: [GitHubReleaseAsset] = []
    ) {
        self.tagName = tagName
        self.name = name
        self.draft = draft
        self.prerelease = prerelease
        self.body = body
        self.htmlURL = htmlURL
        self.assets = assets
    }

    enum CodingKeys: String, CodingKey {
        case name, draft, prerelease, body, assets
        case tagName = "tag_name"
        case htmlURL = "html_url"
    }
}

/// Throws on anything but a JSON array of releases (an error object such as
/// `{"message": "Not Found"}` included).
public func decodeGitHubReleases(_ data: Data) throws -> [GitHubRelease] {
    try JSONDecoder().decode([GitHubRelease].self, from: data)
}

/// The repository releases are read from: `GioUpdateRepository` in the app's
/// Info.plist (an `owner/name` build setting), else Gio's own repository.
public let defaultUpdateRepository = "ismaelosuna7824/gio"

public func updateRepository(infoDictionary: [String: Any]?) -> String {
    guard let value = (infoDictionary?["GioUpdateRepository"] as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines) else {
        return defaultUpdateRepository
    }
    let parts = value.split(separator: "/", omittingEmptySubsequences: false)
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
    let valid = parts.count == 2 && parts.allSatisfy { part in
        !part.isEmpty && part.unicodeScalars.allSatisfy { $0.isASCII && allowed.contains($0) }
    }
    return valid ? value : defaultUpdateRepository
}
