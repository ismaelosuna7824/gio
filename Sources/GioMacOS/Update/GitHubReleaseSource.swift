import Foundation
import GioCore

/// UP-07: one HTTP round trip (URLSession in the app, a fake in tests).
public protocol UpdateHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionUpdateTransport: UpdateHTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .updateSession) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }
}

extension URLSession {
    /// Ephemeral (no cookies or disk cache of Gio's own), short timeouts,
    /// and the updater's redirect policy (the token stays on api.github.com).
    public static let updateSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration, delegate: UpdateTokenRedirectPolicy(), delegateQueue: nil)
    }()
}

/// `GET https://api.github.com/repos/<repo>/releases`, with an optional
/// bearer token (private repositories) and `If-None-Match`, so an unchanged
/// list costs no rate limit (GitHub does not count 304 answers).
public final class GitHubReleaseSource: UpdateReleaseSource, @unchecked Sendable {
    public let releasesURL: URL
    private let userAgent: String
    private let token: @Sendable () -> String?
    private let transport: UpdateHTTPTransport
    /// The last 200 answer and its ETag; guarded by `lock`.
    private var cached: (etag: String, releases: [GitHubRelease])?
    private let lock = NSLock()

    public init(
        repository: String, userAgent: String, token: @escaping @Sendable () -> String?,
        transport: UpdateHTTPTransport = URLSessionUpdateTransport()
    ) {
        releasesURL = URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=30")!
        self.userAgent = userAgent
        self.token = token
        self.transport = transport
    }

    public func fetchReleases() async -> Result<[GitHubRelease], UpdateFailure> {
        var request = URLRequest(url: releasesURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let token = token().flatMap { $0.isEmpty ? nil : $0 }
        if let token, updateTokenAllowed(for: releasesURL) {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let previous = lock.withLock { cached }
        if let previous {
            request.setValue(previous.etag, forHTTPHeaderField: "If-None-Match")
        }
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch let error as URLError {
            return .failure(.network(urlErrorSummary(error)))
        } catch {
            return .failure(.network("request failed"))
        }
        switch response.statusCode {
        case 200:
            guard let releases = try? decodeGitHubReleases(data) else {
                return .failure(.malformedResponse)
            }
            if let etag = response.value(forHTTPHeaderField: "ETag") {
                lock.withLock { cached = (etag, releases) }
            }
            return .success(releases)
        case 304:
            guard let previous else {
                return .failure(.malformedResponse)
            }
            return .success(previous.releases)
        case 404:
            return .failure(token == nil ? .repositoryUnavailable : .repositoryNotFound)
        case 401:
            return .failure(.tokenRejected)
        case 403, 429:
            if response.statusCode == 429 || response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" {
                return .failure(.rateLimited)
            }
            return .failure(token == nil ? .httpStatus(403) : .tokenRejected)
        default:
            return .failure(.httpStatus(response.statusCode))
        }
    }
}

/// A short, secret-free description (no URL, no headers).
func urlErrorSummary(_ error: URLError) -> String {
    switch error.code {
    case .notConnectedToInternet, .networkConnectionLost: return "offline"
    case .timedOut: return "timed out"
    case .cannotFindHost, .dnsLookupFailed: return "host not found"
    case .cancelled: return "cancelled"
    case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate:
        return "secure connection failed"
    default: return "URL error \(error.code.rawValue)"
    }
}
