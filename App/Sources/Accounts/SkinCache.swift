import UIKit

/// Downloads the player's skin texture and renders the face (base layer plus
/// hat overlay) with nearest-neighbour scaling for the launcher UI.
enum SkinCache {
    private static func url(_ id: String) -> URL { Paths.launcherData.appendingPathComponent("skin-\(id).png") }

    static func remove(_ id: String) { try? FileManager.default.removeItem(at: url(id)) }

    static func skin(for account: MinecraftAccount) async -> UIImage? {
        let local = url(account.id)
        if let img = UIImage(contentsOfFile: local.path) { return img }
        guard let remote = account.skinURL,
              let data = try? await HTTP.get(remote.scheme == "http" ? URL(string: remote.absoluteString.replacingOccurrences(of: "http://", with: "https://"))! : remote),
              let img = UIImage(data: data) else { return nil }
        try? data.write(to: local)
        return img
    }

    static func face(from skin: UIImage, size: CGFloat) -> UIImage? {
        guard let cg = skin.cgImage, cg.width >= 64 else { return nil }
        let unit = cg.width / 64
        guard let base = cg.cropping(to: CGRect(x: 8 * unit, y: 8 * unit, width: 8 * unit, height: 8 * unit)),
              let hat = cg.cropping(to: CGRect(x: 40 * unit, y: 8 * unit, width: 8 * unit, height: 8 * unit)) else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format).image { ctx in
            ctx.cgContext.interpolationQuality = .none
            // UIKit's context is flipped relative to CGImage drawing.
            ctx.cgContext.translateBy(x: 0, y: size)
            ctx.cgContext.scaleBy(x: 1, y: -1)
            let rect = CGRect(x: 0, y: 0, width: size, height: size)
            ctx.cgContext.draw(base, in: rect)
            ctx.cgContext.draw(hat, in: rect)
        }
    }
}
