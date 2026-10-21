import Foundation

struct AssetIndex: Codable {
    struct Object: Codable { let hash: String; let size: Int64 }
    let objects: [String: Object]
    /// Pre-1.7 indexes ("legacy") expect files copied to assets/virtual/<id>.
    let virtual: Bool?
    /// Very old versions (pre-1.6) read a resources/ folder in the game dir.
    let map_to_resources: Bool?

    static let resourceBase = "https://resources.download.minecraft.net/"

    func downloadItems() -> [DownloadItem] {
        objects.values.map { obj in
            let prefix = String(obj.hash.prefix(2))
            return DownloadItem(
                url: URL(string: "\(Self.resourceBase)\(prefix)/\(obj.hash)")!,
                destination: Paths.assetObjects.appendingPathComponent(prefix).appendingPathComponent(obj.hash),
                sha1: obj.hash,
                size: obj.size)
        }
    }

    /// Materialize legacy virtual / resource-mapped layouts from the object store.
    func materializeLegacyLayout(indexID: String, gameDirectory: URL) {
        let fm = FileManager.default
        let target: URL?
        if map_to_resources == true {
            target = gameDirectory.appendingPathComponent("resources", isDirectory: true)
        } else if virtual == true {
            target = Paths.assets.appendingPathComponent("virtual/\(indexID)", isDirectory: true)
        } else {
            target = nil
        }
        guard let target else { return }
        for (name, obj) in objects {
            let dest = target.appendingPathComponent(name)
            if fm.fileExists(dest) { continue }
            let src = Paths.assetObjects.appendingPathComponent(String(obj.hash.prefix(2))).appendingPathComponent(obj.hash)
            try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.copyItem(at: src, to: dest)
        }
    }
}
