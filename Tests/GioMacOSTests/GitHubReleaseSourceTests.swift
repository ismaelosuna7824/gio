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

    private func source(_ transport: FakeTransport, token: String? = nil) -> GitHubReleaseSource {
        GitHubReleaseSource(repository: "owner/repo", userAgent: "Gio/0.1.0", token: { token }, transport: transport)
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

    func testTokenIsSentAsBearer() async {
        let transport = FakeTransport()
        transport.responses = [(200, [:], releasesJSON)]
        _ = await source(transport, token: "fake-test-token").fetchReleases()
        XCTAssertEqual(transport.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer fake-test-token")
    }

    func testNotFoundWithoutTokenMeansPrivateOrMissing() async {
        let transport = FakeTransport()
        transport.responses = [(404, [:], Data("{\"message\":\"Not Found\"}".utf8))]
        let result = await source(transport).fetchReleases()
        XCTAssertEqual(result.failure, .repositoryUnavailable)
    }

    func testNotFoundWithTokenAndOtherStatuses() async {
        let cases: [(Int, [String: String], String?, UpdateFailure)] = [
            (404, [:], "t", .repositoryNotFound),
            (401, [:], "t", .tokenRejected),
            (403, ["X-RateLimit-Remaining": "0"], nil, .rateLimited),
            (429, [:], nil, .rateLimited),
            (403, [:], "t", .tokenRejected),
            (500, [:], nil, .httpStatus(500)),
            (200, [:], nil, .malformedResponse),
        ]
        for (status, headers, token, expected) in cases {
            let transport = FakeTransport()
            transport.responses = [(status, headers, Data("{}".utf8))]
            let result = await source(transport, token: token).fetchReleases()
            XCTAssertEqual(result.failure, expected, "\(status)")
        }
    }

    func testTransportErrorsBecomeNetworkFailures() async {
        let transport = FakeTransport()
        transport.error = URLError(.notConnectedToInternet)
        let result = await source(transport, token: "fake-test-token").fetchReleases()
        guard case .network(let detail)? = result.failure else {
            return XCTFail("expected a network failure, got \(result)")
        }
        XCTAssertFalse(detail.contains("fake-test-token"))
    }

    func testTokenStoreNamesTheKeychainItem() {
        XCTAssertEqual(KeychainTokenStore.service, "dev.gio.windowmanager.update-token")
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
