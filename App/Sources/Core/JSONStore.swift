import Foundation

/// Small helper for Codable documents persisted under ZMF/launcher.
enum JSONStore {
    static func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        let url = Paths.launcherData.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            zlog.warn("Could not decode \(name): \(error)")
            return nil
        }
    }

    static func save<T: Encodable>(_ value: T, to name: String) {
        Paths.ensureLayout()
        let url = Paths.launcherData.appendingPathComponent(name)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(value).write(to: url, options: .atomic)
        } catch {
            zlog.error("Could not save \(name): \(error)")
        }
    }
}
