//
//  ComponentDownloader.swift
//  SchnitzelKit
//
//  This file is part of Schnitzel.
//
//  Schnitzel is free software: you can redistribute it and/or modify it under the terms
//  of the GNU General Public License as published by the Free Software Foundation,
//  either version 3 of the License, or (at your option) any later version.
//
//  Schnitzel is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
//  without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
//  See the GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along with Schnitzel.
//  If not, see https://www.gnu.org/licenses/.
//

import Foundation
import os.log

/// Downloads a component, checks its SHA-256 and installs it into the store.
public struct ComponentDownloader: Sendable {
    public enum Progress: Sendable, Equatable {
        case downloading(received: Int64, total: Int64)
        case verifying
        case installing
    }

    let store: ComponentStore

    public init(store: ComponentStore) {
        self.store = store
    }

    public func download(_ component: AvailableComponent,
                         progress: @escaping @Sendable (Progress) -> Void) async throws -> InstalledComponent {
        let downloads = store.root.appending(path: ".downloads", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let archive = downloads.appending(path: "\(UUID().uuidString)-\(component.assetName)")
        defer { try? FileManager.default.removeItem(at: archive) }

        try await Self.fetch(component.downloadURL, to: archive, expectedSize: component.size, progress: progress)

        progress(.verifying)
        let actual = try Command.sha256(of: archive)
        if let expected = component.sha256, expected != actual {
            throw ComponentError.checksumMismatch(expected: expected, actual: actual)
        }

        progress(.installing)
        var installed = try await store.install(
            component.kind, version: component.version, archive: archive,
            source: component.downloadURL.absoluteString, sourceID: component.source.id, sha256: actual)
        if component.sha256 == nil {
            installed.manifest.notes.append("GitHub published no checksum for this file, so it couldn't be verified")
            try store.saveManifest(of: installed)
        }
        return installed
    }

    /// Downloads `url` to `destination`, reporting progress.
    static func fetch(_ url: URL, to destination: URL, expectedSize: Int64,
                      progress: @escaping @Sendable (Progress) -> Void) async throws {
        let delegate = DownloadDelegate(expectedSize: expectedSize, progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let temporary: URL = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.continuation = continuation
                let task = session.downloadTask(with: url)
                delegate.task = task
                task.resume()
            }
        } onCancel: {
            delegate.cancel()
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
    }
}

/// Bridges URLSession's download callbacks to async/await.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let expectedSize: Int64
    private let progress: @Sendable (ComponentDownloader.Progress) -> Void
    private var lastReport = Date.distantPast
    var task: URLSessionTask?
    var continuation: CheckedContinuation<URL, Error>?

    init(expectedSize: Int64, progress: @escaping @Sendable (ComponentDownloader.Progress) -> Void) {
        self.expectedSize = expectedSize
        self.progress = progress
    }

    func cancel() {
        lock.withLock { task }?.cancel()
    }

    private func finish(_ result: Result<URL, Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<URL, Error>? in
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(with: result)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let now = Date()
        let shouldReport = lock.withLock { () -> Bool in
            guard now.timeIntervalSince(lastReport) > 0.1 else { return false }
            lastReport = now
            return true
        }
        guard shouldReport else { return }
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expectedSize
        progress(.downloading(received: totalBytesWritten, total: total))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            finish(.failure(CatalogError.httpStatus(http.statusCode)))
            return
        }
        // `location` is deleted when this method returns, so move it somewhere safe first.
        let kept = FileManager.default.temporaryDirectory.appending(path: "schnitzel-download-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: location, to: kept)
            finish(.success(kept))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failure(error))
        }
    }
}
