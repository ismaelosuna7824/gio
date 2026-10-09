import CryptoKit
import Foundation
import GioCore

/// UP-08: fetch one release asset into a folder, reporting progress (0...1).
public protocol UpdateAssetDownloading: Sendable {
    func download(
        _ asset: GitHubReleaseAsset, to directory: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL
}

/// Public repositories download `browser_download_url`; with a token the
/// asset's API URL is used (`Accept: application/octet-stream`), which is
/// the only route for private repositories. GitHub redirects that to a
/// signed storage URL. The token only ever goes to https://api.github.com
/// (`updateTokenAllowed`, UP-17): an asset URL elsewhere falls back to the
/// anonymous download, and every redirect drops the Authorization header
/// unless it stays on the API.
public final class URLSessionAssetDownloader: UpdateAssetDownloading, @unchecked Sendable {
    private let token: @Sendable () -> String?
    private let userAgent: String

    public init(userAgent: String, token: @escaping @Sendable () -> String?) {
        self.userAgent = userAgent
        self.token = token
    }

    public func download(
        _ asset: GitHubReleaseAsset, to directory: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        guard let request = updateAssetRequest(asset, token: token(), userAgent: userAgent) else {
            throw URLError(.badURL)
        }
        let destination = directory.appendingPathComponent(asset.name)
        let delegate = DownloadDelegate(expectedBytes: Int64(asset.size), destination: destination, progress: progress)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 15 * 60
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer {
            session.finishTasksAndInvalidate()
        }
        return try await withCheckedThrowingContinuation { continuation in
            delegate.continuation = continuation
            session.downloadTask(with: request).resume()
        }
    }
}

/// The request for one asset: the API URL with the token when the token may
/// go there, else the anonymous browser URL.
func updateAssetRequest(_ asset: GitHubReleaseAsset, token: String?, userAgent: String) -> URLRequest? {
    let token = token.flatMap { $0.isEmpty ? nil : $0 }
    let api = URL(string: asset.url)
    let authorized = token != nil && updateTokenAllowed(for: api)
    guard let url = authorized ? api : URL(string: asset.browserDownloadURL) else {
        return nil
    }
    var request = URLRequest(url: url)
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    if authorized, let token {
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    return request
}

/// The redirect policy for every updater request (UP-17): the token
/// survives a redirect only to https://api.github.com.
public func updateRedirectRequest(_ request: URLRequest) -> URLRequest {
    guard !updateTokenAllowed(for: request.url) else {
        return request
    }
    var next = request
    next.setValue(nil, forHTTPHeaderField: "Authorization")
    return next
}

/// Session delegate applying `updateRedirectRequest` (the release-list session).
public class UpdateTokenRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    public func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(updateRedirectRequest(request))
    }
}

private final class DownloadDelegate: UpdateTokenRedirectPolicy, URLSessionDownloadDelegate, @unchecked Sendable {
    let expectedBytes: Int64
    let destination: URL
    let progress: @Sendable (Double) -> Void
    /// Set before the task starts; resumed exactly once (delegate queue is serial).
    var continuation: CheckedContinuation<URL, Error>?
    private var moved: Result<URL, Error>?

    init(expectedBytes: Int64, destination: URL, progress: @escaping @Sendable (Double) -> Void) {
        self.expectedBytes = expectedBytes
        self.destination = destination
        self.progress = progress
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expectedBytes
        guard total > 0 else {
            return
        }
        progress(min(Double(totalBytesWritten) / Double(total), 1))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            moved = .failure(UpdateFailure.downloadFailed("HTTP \(http.statusCode)"))
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            moved = .success(destination)
        } catch {
            moved = .failure(UpdateFailure.downloadFailed("cannot save the file"))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let result: Result<URL, Error>
        if let error = error as? URLError {
            result = .failure(UpdateFailure.downloadFailed(urlErrorSummary(error)))
        } else if error != nil {
            result = .failure(UpdateFailure.downloadFailed("transfer failed"))
        } else {
            result = moved ?? .failure(UpdateFailure.downloadFailed("no data"))
        }
        if case .success = result {
            progress(1)
        }
        continuation?.resume(with: result)
        continuation = nil
    }
}

/// Lowercase hex SHA-256 of a file, read in 1 MiB chunks.
public func sha256Hex(ofFileAt url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer {
        try? handle.close()
    }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
        hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

public func sha256Hex(of data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
