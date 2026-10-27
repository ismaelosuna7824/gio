import Foundation
@testable import GioCore
@testable import GioMacOS
import XCTest

/// UP-07: the GitHub releases adapter over a fake transport (no network).
final class GitHubReleaseSourceTests: XCTestCase {
    final class FakeTransport: UpdateHTTPTransport, @unchecked Sendable {
        var responses: [(Int, [String: String], Data)] = []
        private(set) var requests: [URLRequest] = []
        var error: Error?

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            requests.append(request)
            if let error {
                throw error
            }
            let (status, headers, body) = responses.removeFirst()
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            return (body, response)
        }
    }

    private let releasesJSON = Data("""
    [{"tag_name": "v0.2.0", "draft": false, "prerelease": false, "body": "notes", "assets": []}]
    """.utf8)

    private func source(_ transport: FakeTransport) -> GitHubReleaseSource {
        GitHubReleaseSource(repository: "owner/repo", userAgent: "Gio/0.1.0", transport: transport)
    }

    func testFetchesAndDecodesReleases() async throws {
        let transport = FakeTransport()
        transport.responses = [(200, ["ETag": "\"abc\""], releasesJSON)]
        let result = await source(transport).fetchReleases()
        XCTAssertEqual(try result.get().map(\.tagName), ["v0.2.0"])
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.github.com/repos/owner/repo/releases?per_page=30")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Gio/0.1.0")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "If-None-Match"))
    }

    func testETagIsSentAndNotModifiedReusesTheCache() async throws {
        let transport = FakeTransport()
        transport.responses = [(200, ["Etag": "W/\"abc\""], releasesJSON), (304, [:], Data())]
        let releases = source(transport)
        _ = await releases.fetchReleases()
        let second = await releases.fetchReleases()
        XCTAssertEqual(try second.get().map(\.tagName), ["v0.2.0"])
        XCTAssertEqual(transport.requests.last?.value(forHTTPHeaderField: "If-None-Match"), "W/\"abc\"")
    }

    func testNotFoundMeansPrivateOrMissing() async {
        let transport = FakeTransport()
        transport.responses = [(404, [:], Data("{\"message\":\"Not Found\"}".utf8))]
        let result = await source(transport).fetchReleases()
        XCTAssertEqual(result.failure, .repositoryUnavailable)
    }

    func testOtherStatuses() async {
        let cases: [(Int, [String: String], UpdateFailure)] = [
            (401, [:], .httpStatus(401)),
            (403, ["X-RateLimit-Remaining": "0"], .rateLimited),
            (429, [:], .rateLimited),
            (403, [:], .httpStatus(403)),
            (500, [:], .httpStatus(500)),
            (200, [:], .malformedResponse),
        ]
        for (status, headers, expected) in cases {
            let transport = FakeTransport()
            transport.responses = [(status, headers, Data("{}".utf8))]
            let result = await source(transport).fetchReleases()
            XCTAssertEqual(result.failure, expected, "\(status)")
        }
    }

    func testTransportErrorsBecomeNetworkFailures() async {
        let transport = FakeTransport()
        transport.error = URLError(.notConnectedToInternet)
        let result = await source(transport).fetchReleases()
        guard case .network(let detail)? = result.failure else {
            return XCTFail("expected a network failure, got \(result)")
        }
        XCTAssertEqual(detail, "offline")
    }

    func testAssetsDownloadAnonymouslyFromTheBrowserURL() throws {
        let asset = GitHubReleaseAsset(
            name: "Gio-0.3.0.dmg", size: 1, url: "https://api.github.com/repos/o/r/releases/assets/7",
            browserDownloadURL: "https://github.com/o/r/releases/download/v0.3.0/Gio-0.3.0.dmg"
        )
        let request = try XCTUnwrap(updateAssetRequest(asset, userAgent: "Gio/0.2.0"))
        XCTAssertEqual(request.url?.absoluteString, "https://github.com/o/r/releases/download/v0.3.0/Gio-0.3.0.dmg")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Gio/0.2.0")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }
}

extension Result {
    var failure: Failure? {
        if case .failure(let error) = self {
            return error
        }
        return nil
    }
}
