import Foundation
import AudibleCore

enum AudibleHTTP {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }()

    static func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        var request = request
        request.httpShouldHandleCookies = false
        request.timeoutInterval = 60
        do { return try await session.data(for: request) }
        catch {
            try Task.checkCancellation()
            throw AudibleErrorMessage.connection
        }
    }
}

final class DownloadRedirects: NSObject, URLSessionTaskDelegate {
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                               willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                               completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, AudibleContent.validDownloadURL(url) else { completionHandler(nil); return }
        var redirected = request
        redirected.httpShouldHandleCookies = false
        for field in ["Authorization", "Cookie", "x-adp-token", "x-adp-signature", "x-amz-access-token"] {
            redirected.setValue(nil, forHTTPHeaderField: field)
        }
        completionHandler(redirected)
    }
}

private enum AudibleErrorMessage: LocalizedError {
    case connection
    var errorDescription: String? { "Could not reach Audible. Check your connection and retry." }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                               willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                               completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
