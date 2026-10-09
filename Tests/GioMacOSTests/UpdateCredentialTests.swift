import Foundation
@testable import GioCore
@testable import GioMacOS
import Security
import XCTest

/// UP-15/UP-17: the Keychain save sequence (finding 4) and where the GitHub
/// token may travel (finding 6). No real Keychain, no network.
final class UpdateCredentialTests: XCTestCase {
    final class FakeKeychain: @unchecked Sendable {
        private let lock = NSLock()
        private var log: [String] = []
        private var deletedQueries: [[String: Any]] = []
        private var addedItems: [[String: Any]] = []
        var deleteStatus: OSStatus = errSecSuccess
        var addStatus: OSStatus = errSecSuccess

        var calls: [String] { lock.withLock { log } }
        var deleted: [[String: Any]] { lock.withLock { deletedQueries } }
        var added: [[String: Any]] { lock.withLock { addedItems } }

        var api: KeychainCalls {
            KeychainCalls(
                copyMatching: { [self] _ in
                    lock.withLock { log.append("copy") }
                    return (errSecItemNotFound, nil)
                },
                add: { [self] item in
                    lock.withLock {
                        log.append("add")
                        addedItems.append(item)
                    }
                    return addStatus
                },
                delete: { [self] query in
                    lock.withLock {
                        log.append("delete")
                        deletedQueries.append(query)
                    }
                    return deleteStatus
                }
            )
        }
    }

    private func assertGioItem(_ attributes: [String: Any], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(attributes[kSecClass as String] as? String, kSecClassGenericPassword as String, file: file, line: line)
        XCTAssertEqual(attributes[kSecAttrService as String] as? String, KeychainTokenStore.service, file: file, line: line)
        XCTAssertEqual(attributes[kSecAttrAccount as String] as? String, KeychainTokenStore.account, file: file, line: line)
        XCTAssertEqual(attributes[kSecAttrSynchronizable as String] as? Bool, false, file: file, line: line)
    }

    func testSaveDeletesAnyExistingItemThenAddsAFreshNonSynchronizableOne() throws {
        let keychain = FakeKeychain()
        let store = KeychainTokenStore(keychain: keychain.api)
        XCTAssertTrue(store.save("  fake-test-token\n"))
        XCTAssertEqual(keychain.calls, ["delete", "add"], "never updates an item someone else may have created")
        assertGioItem(try XCTUnwrap(keychain.deleted.first))
        let item = try XCTUnwrap(keychain.added.first)
        assertGioItem(item)
        XCTAssertEqual(item[kSecValueData as String] as? Data, Data("fake-test-token".utf8))
        XCTAssertEqual(
            item[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        )
    }

    func testSaveWithoutAPreviousItemStillAdds() {
        let keychain = FakeKeychain()
        keychain.deleteStatus = errSecItemNotFound
        XCTAssertTrue(KeychainTokenStore(keychain: keychain.api).save("fake-test-token"))
        XCTAssertEqual(keychain.calls, ["delete", "add"])
    }

    func testSaveStopsWhenTheOldItemCannotBeDeleted() {
        let keychain = FakeKeychain()
        keychain.deleteStatus = errSecAuthFailed
        XCTAssertFalse(KeychainTokenStore(keychain: keychain.api).save("fake-test-token"))
        XCTAssertEqual(keychain.calls, ["delete"])
    }

    func testSaveReportsAFailedAdd() {
        let keychain = FakeKeychain()
        keychain.addStatus = errSecDuplicateItem
        XCTAssertFalse(KeychainTokenStore(keychain: keychain.api).save("fake-test-token"))
    }

    func testBlankTokenTouchesNothing() {
        let keychain = FakeKeychain()
        XCTAssertFalse(KeychainTokenStore(keychain: keychain.api).save("  \n"))
        XCTAssertEqual(keychain.calls, [])
    }

    func testReadAndClearUseTheNonSynchronizableItem() throws {
        let keychain = FakeKeychain()
        let store = KeychainTokenStore(keychain: keychain.api)
        XCTAssertNil(store.read())
        XCTAssertTrue(store.clear())
        assertGioItem(try XCTUnwrap(keychain.deleted.first))
    }

    // MARK: Token host policy

    private func asset(url: String) -> GitHubReleaseAsset {
        GitHubReleaseAsset(
            name: "Gio-0.3.0.dmg", size: 1, url: url,
            browserDownloadURL: "https://github.com/o/r/releases/download/v0.3.0/Gio-0.3.0.dmg"
        )
    }

    func testAssetRequestSendsTheTokenOnlyToTheGitHubAPI() throws {
        let api = try XCTUnwrap(updateAssetRequest(
            asset(url: "https://api.github.com/repos/o/r/releases/assets/7"), token: "fake-test-token", userAgent: "Gio/0.2.0"
        ))
        XCTAssertEqual(api.url?.absoluteString, "https://api.github.com/repos/o/r/releases/assets/7")
        XCTAssertEqual(api.value(forHTTPHeaderField: "Authorization"), "Bearer fake-test-token")
        XCTAssertEqual(api.value(forHTTPHeaderField: "Accept"), "application/octet-stream")
        XCTAssertEqual(api.value(forHTTPHeaderField: "User-Agent"), "Gio/0.2.0")

        for elsewhere in ["https://evil.example/assets/7", "http://api.github.com/repos/o/r/releases/assets/7"] {
            let request = try XCTUnwrap(updateAssetRequest(asset(url: elsewhere), token: "fake-test-token", userAgent: "Gio"))
            XCTAssertEqual(request.url?.absoluteString, "https://github.com/o/r/releases/download/v0.3.0/Gio-0.3.0.dmg")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"), elsewhere)
        }

        let anonymous = try XCTUnwrap(updateAssetRequest(
            asset(url: "https://api.github.com/repos/o/r/releases/assets/7"), token: nil, userAgent: "Gio"
        ))
        XCTAssertEqual(anonymous.url?.absoluteString, "https://github.com/o/r/releases/download/v0.3.0/Gio-0.3.0.dmg")
        XCTAssertNil(anonymous.value(forHTTPHeaderField: "Authorization"))
    }

    private func redirect(to url: String) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        request.setValue("Bearer fake-test-token", forHTTPHeaderField: "Authorization")
        return request
    }

    func testRedirectKeepsTheTokenOnlyForTheGitHubAPIOverHTTPS() {
        XCTAssertEqual(
            updateRedirectRequest(redirect(to: "https://api.github.com/repos/o/r/releases/assets/8"))
                .value(forHTTPHeaderField: "Authorization"),
            "Bearer fake-test-token"
        )
        for url in [
            "https://objects.githubusercontent.com/github-production-release-asset/1",
            "http://api.github.com/repos/o/r/releases/assets/8",
            "https://api.github.com.evil.example/x",
        ] {
            XCTAssertNil(updateRedirectRequest(redirect(to: url)).value(forHTTPHeaderField: "Authorization"), url)
        }
    }

    func testReleaseListSessionAppliesTheSameRedirectPolicy() throws {
        let policy = try XCTUnwrap(URLSession.updateSession.delegate as? UpdateTokenRedirectPolicy)
        let task = URLSession.shared.dataTask(with: URL(string: "https://api.github.com/repos/o/r/releases")!)
        let response = try XCTUnwrap(HTTPURLResponse(
            url: URL(string: "https://api.github.com/repos/o/r/releases")!, statusCode: 302, httpVersion: "HTTP/1.1",
            headerFields: nil
        ))
        var forwarded: URLRequest?
        policy.urlSession(
            URLSession.updateSession, task: task, willPerformHTTPRedirection: response,
            newRequest: redirect(to: "https://evil.example/releases")
        ) { forwarded = $0 }
        XCTAssertEqual(forwarded?.url?.host, "evil.example")
        XCTAssertNil(forwarded?.value(forHTTPHeaderField: "Authorization"))
    }
}
