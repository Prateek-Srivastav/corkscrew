import Foundation
import Synchronization

/// Downloads a large file (the engine pack) with progress.
///
/// Files a program downloads itself get no quarantine flag, so Gatekeeper doesn't check the Wine
/// binaries in the pack; the pack's SHA-256 is what vouches for them.
public enum Downloader {
    public enum DownloadError: Error, Equatable, CustomStringConvertible {
        case httpStatus(Int)

        public var description: String {
            switch self {
            case .httpStatus(let status): "the download failed (HTTP \(status))"
            }
        }
    }

    /// Downloads `url` to `destination`, replacing it. `progress` gets the fraction done (0…1) when
    /// the size is known. Cancelling the task cancels the download.
    public static func download(_ url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let delegate = Delegate(destination: destination, progress: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: url)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                delegate.state.withLock { $0.continuation = continuation }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    private final class Delegate: NSObject, URLSessionDownloadDelegate, Sendable {
        struct State {
            var continuation: CheckedContinuation<Void, Error>?
            /// Set when the file arrived but couldn't be kept (an HTTP error page, a failed move).
            var failure: Error?
        }

        let destination: URL
        let progress: @Sendable (Double) -> Void
        let state = Mutex(State())

        init(destination: URL, progress: @escaping @Sendable (Double) -> Void) {
            self.destination = destination
            self.progress = progress
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            guard totalBytesExpectedToWrite > 0 else { return }
            progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        }

        /// The temporary file is deleted when this returns, so it's moved here.
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                state.withLock { $0.failure = DownloadError.httpStatus(http.statusCode) }
                return
            }
            do {
                let fm = FileManager.default
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
                try fm.moveItem(at: location, to: destination)
            } catch {
                state.withLock { $0.failure = error }
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            let (continuation, failure) = state.withLock { state in
                defer { state.continuation = nil }
                return (state.continuation, error ?? state.failure)
            }
            if let failure { continuation?.resume(throwing: failure) } else { continuation?.resume() }
        }
    }
}
