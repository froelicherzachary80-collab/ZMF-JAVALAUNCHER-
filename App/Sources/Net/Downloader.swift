import Foundation

/// A file the installer needs, with the integrity data Mojang (or a loader
/// meta service) publishes for it.
struct DownloadItem: Hashable, Sendable {
    let url: URL
    let destination: URL
    let sha1: String?
    let size: Int64?
}

enum VerifyResult: Equatable {
    case ok, missing, corrupt
}

/// Concurrent, verified downloader. Files already present with the right hash
/// are skipped, so install, verify and repair share one code path.
actor Downloader {
    struct Progress: Sendable {
        var completedFiles = 0
        var totalFiles = 0
        var completedBytes: Int64 = 0
        var totalBytes: Int64 = 0
        var fraction: Double {
            if totalBytes > 0 { return min(1, Double(completedBytes) / Double(totalBytes)) }
            return totalFiles == 0 ? 1 : Double(completedFiles) / Double(totalFiles)
        }
    }

    private let maxConcurrent: Int
    init(maxConcurrent: Int = 8) { self.maxConcurrent = maxConcurrent }

    static func verify(_ item: DownloadItem) -> VerifyResult {
        let fm = FileManager.default
        guard fm.fileExists(item.destination) else { return .missing }
        if let size = item.size, size > 0, fm.fileSize(item.destination) != size { return .corrupt }
        if let sha1 = item.sha1, Hashing.sha1(of: item.destination)?.lowercased() != sha1.lowercased() { return .corrupt }
        return .ok
    }

    /// Downloads every item that is missing or fails verification.
    func fetch(_ items: [DownloadItem], progress: @escaping @Sendable (Progress) -> Void) async throws {
        let unique = Array(Set(items))
        var state = Progress(totalFiles: unique.count, totalBytes: unique.reduce(0) { $0 + ($1.size ?? 0) })
        progress(state)

        let limit = maxConcurrent
        try await withThrowingTaskGroup(of: Int64.self) { group in
            var pending = unique[...]
            var running = 0
            while running < limit, let item = pending.popFirst() {
                group.addTask { try await Self.fetchOne(item) }
                running += 1
            }
            while let bytes = try await group.next() {
                state.completedFiles += 1
                state.completedBytes += bytes
                progress(state)
                if let item = pending.popFirst() {
                    group.addTask { try await Self.fetchOne(item) }
                }
            }
        }
    }

    private static func fetchOne(_ item: DownloadItem) async throws -> Int64 {
        if verify(item) == .ok { return item.size ?? 0 }
        var lastError: Error?
        for attempt in 1...3 {
            do {
                let (temp, response) = try await HTTP.session.download(from: item.url)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw HTTPError(status: http.statusCode, url: item.url, body: "")
                }
                let fm = FileManager.default
                try fm.createDirectory(at: item.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(item.destination) { try fm.removeItem(at: item.destination) }
                try fm.moveItem(at: temp, to: item.destination)
                if let sha1 = item.sha1, Hashing.sha1(of: item.destination)?.lowercased() != sha1.lowercased() {
                    try? fm.removeItem(at: item.destination)
                    throw InstallError.checksumMismatch(item.destination.lastPathComponent)
                }
                return item.size ?? fm.fileSize(item.destination) ?? 0
            } catch {
                lastError = error
                zlog.warn("Download attempt \(attempt) failed for \(item.url): \(error.localizedDescription)")
                try await Task.sleep(nanoseconds: UInt64(attempt) * 500_000_000)
            }
        }
        throw lastError ?? InstallError.downloadFailed(item.url.absoluteString)
    }
}

enum InstallError: LocalizedError {
    case checksumMismatch(String)
    case downloadFailed(String)
    case versionNotFound(String)
    case unsupported(String)
    case invalidFile(String)

    var errorDescription: String? {
        switch self {
        case .checksumMismatch(let f): return "Checksum mismatch for \(f)"
        case .downloadFailed(let u): return "Download failed: \(u)"
        case .versionNotFound(let v): return "Version \(v) not found"
        case .unsupported(let r): return r
        case .invalidFile(let f): return "Invalid file: \(f)"
        }
    }
}
