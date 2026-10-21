import Foundation

/// Installs, verifies, repairs and deletes Minecraft versions in the shared
/// store. Every file comes from Mojang's (or the mod loader's) own servers and
/// is checked against its published SHA-1.
@MainActor
final class InstallationManager: ObservableObject {
    struct Job: Identifiable {
        let id: String // version id
        var phase: String
        var progress: Double
        var detail: String
    }

    struct VerifyReport {
        var checked = 0
        var missing: [String] = []
        var corrupt: [String] = []
        var isHealthy: Bool { missing.isEmpty && corrupt.isEmpty }
    }

    @Published private(set) var manifest: VersionManifest?
    @Published private(set) var installed: [String] = []
    @Published private(set) var tasks: [String: Job] = [:]
    @Published var lastError: String?

    private let downloader = Downloader()

    init() {
        manifest = VersionManifest.cached()
        refreshInstalled()
    }

    func refreshManifest() async {
        do {
            manifest = try await VersionManifest.fetch()
        } catch {
            lastError = "Could not load the version list: \(error.localizedDescription)"
            zlog.error(lastError!)
        }
    }

    func refreshInstalled() {
        let fm = FileManager.default
        let ids = (try? fm.contentsOfDirectory(atPath: Paths.versions.path)) ?? []
        installed = ids.filter { fm.fileExists(Paths.versionJSON($0)) }.sorted()
    }

    func isInstalled(_ id: String) -> Bool { installed.contains(id) }

    // MARK: Install

    func install(_ id: String) async throws {
        tasks[id] = Job(id: id, phase: "Preparing", progress: 0, detail: "")
        defer { tasks[id] = nil; refreshInstalled() }
        do {
            try await installVersionDocument(id)
            let resolved = try VersionResolver.resolve(id)
            try await installFiles(for: resolved, rootID: VersionResolver.rootVersionID(id), taskID: id)
            zlog.info("Installed \(id)")
        } catch {
            zlog.error("Install of \(id) failed: \(error.localizedDescription)")
            throw error
        }
    }

    /// Ensures versions/<id>/<id>.json exists (and its parents).
    private func installVersionDocument(_ id: String) async throws {
        if !FileManager.default.fileExists(Paths.versionJSON(id)) {
            if manifest == nil { await refreshManifest() }
            guard let entry = manifest?.versions.first(where: { $0.id == id }) else { throw InstallError.versionNotFound(id) }
            update(id, phase: "Version metadata", progress: 0.01)
            try await downloader.fetch([DownloadItem(url: entry.url, destination: Paths.versionJSON(id), sha1: entry.sha1, size: nil)]) { _ in }
        }
        let doc = try VersionResolver.load(id)
        if let parent = doc.inheritsFrom { try await installVersionDocument(parent) }
    }

    private func installFiles(for version: VersionJSON, rootID: String, taskID: String) async throws {
        let items = try await requiredDownloads(for: version, rootID: rootID, taskID: taskID)
        update(taskID, phase: "Downloading", progress: 0.05)
        try await downloader.fetch(items) { [weak self] p in
            Task { @MainActor in
                self?.update(taskID, phase: "Downloading", progress: 0.05 + 0.95 * p.fraction,
                             detail: "\(p.completedFiles)/\(p.totalFiles) files · \(ByteCountFormatter.string(fromByteCount: p.completedBytes, countStyle: .file))")
            }
        }
    }

    /// Every file a version needs: client jar, libraries, asset index and
    /// objects, logging config.
    func requiredDownloads(for version: VersionJSON, rootID: String, taskID: String? = nil) async throws -> [DownloadItem] {
        var items: [DownloadItem] = []
        if let client = version.downloads?["client"], let url = client.url {
            items.append(DownloadItem(url: url, destination: Paths.clientJar(rootID), sha1: client.sha1, size: client.size))
        }
        items += LibraryPlanner.classpathLibraries(for: version).map(\.item)
        if let logging = version.logging?.client {
            items.append(DownloadItem(url: logging.file.url,
                                      destination: Paths.assets.appendingPathComponent("log_configs/\(logging.file.id)"),
                                      sha1: logging.file.sha1, size: logging.file.size))
        }
        if let indexRef = version.assetIndex {
            let indexItem = DownloadItem(url: indexRef.url, destination: Paths.assetIndexes.appendingPathComponent("\(indexRef.id).json"),
                                         sha1: indexRef.sha1, size: indexRef.size)
            if let taskID { update(taskID, phase: "Asset index", progress: 0.03) }
            try await downloader.fetch([indexItem]) { _ in }
            let index = try JSONDecoder().decode(AssetIndex.self, from: Data(contentsOf: indexItem.destination))
            items.append(indexItem)
            items += index.downloadItems()
        }
        return items
    }

    // MARK: Verify / repair

    func verify(_ id: String) async -> VerifyReport {
        tasks[id] = Job(id: id, phase: "Verifying", progress: 0, detail: "")
        defer { tasks[id] = nil }
        var report = VerifyReport()
        do {
            let resolved = try VersionResolver.resolve(id)
            let rootID = VersionResolver.rootVersionID(id)
            let items = try await requiredDownloads(for: resolved, rootID: rootID)
            let total = items.count
            let results: [(DownloadItem, VerifyResult)] = await Task.detached(priority: .userInitiated) {
                items.map { ($0, Downloader.verify($0)) }
            }.value
            report.checked = total
            for (item, result) in results {
                switch result {
                case .ok: break
                case .missing: report.missing.append(item.destination.lastPathComponent)
                case .corrupt: report.corrupt.append(item.destination.lastPathComponent)
                }
            }
        } catch {
            report.missing.append("version metadata (\(error.localizedDescription))")
        }
        return report
    }

    /// Re-downloads anything missing or corrupt (the downloader skips good files).
    func repair(_ id: String) async throws {
        try? FileManager.default.removeItem(at: Paths.versionJSON(id))
        try await install(id)
    }

    // MARK: Delete

    func delete(_ id: String) {
        try? FileManager.default.removeItem(at: Paths.versionDirectory(id))
        refreshInstalled()
        zlog.info("Deleted version \(id)")
    }

    /// Removes libraries and assets no installed version references any more.
    func collectGarbage() async -> Int64 {
        var keep = Set<String>()
        for id in installed {
            guard let resolved = try? VersionResolver.resolve(id) else { continue }
            let root = VersionResolver.rootVersionID(id)
            if let items = try? await requiredDownloads(for: resolved, rootID: root) {
                items.forEach { keep.insert($0.destination.standardizedFileURL.path) }
            }
        }
        var freed: Int64 = 0
        let fm = FileManager.default
        for base in [Paths.libraries, Paths.assetObjects] {
            guard let e = fm.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { continue }
            for case let url as URL in e.allObjects {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                if !keep.contains(url.standardizedFileURL.path) {
                    freed += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                    try? fm.removeItem(at: url)
                }
            }
        }
        return freed
    }

    private func update(_ id: String, phase: String, progress: Double, detail: String = "") {
        tasks[id] = Job(id: id, phase: phase, progress: progress, detail: detail)
    }
}
