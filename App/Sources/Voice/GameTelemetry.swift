import Foundation

/// Receives position updates from the game's telemetry thread (via JNI) and
/// republishes them on the main queue.
final class GameTelemetry {
    static let shared = GameTelemetry()

    var onUpdate: ((VoiceWorldState) -> Void)?
    private let lock = NSLock()
    private var latest = VoiceWorldState()

    private init() {
        ZMFSetTelemetryHandler { world, x, y, z, yaw in
            let state = VoiceWorldState(world: world.map { String(cString: $0) }, x: x, y: y, z: z, yaw: yaw)
            GameTelemetry.shared.receive(state)
        }
    }

    var current: VoiceWorldState {
        lock.lock(); defer { lock.unlock() }
        return latest
    }

    private func receive(_ state: VoiceWorldState) {
        lock.lock()
        latest = state
        lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.onUpdate?(state) }
    }
}
