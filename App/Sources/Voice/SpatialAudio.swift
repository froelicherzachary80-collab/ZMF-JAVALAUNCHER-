import Foundation

/// Converts Minecraft coordinates into listener-relative audio space.
///
/// Minecraft: +x east, +y up, +z south; yaw 0 faces south (+z), 90 faces west.
/// AVAudioEnvironmentNode: listener at the origin facing -z, +x to the right.
enum SpatialAudio {
    struct Vector: Equatable { var x: Double; var y: Double; var z: Double }

    static func relative(listener: (x: Double, y: Double, z: Double, yaw: Double),
                         source: (x: Double, y: Double, z: Double)) -> Vector {
        let t = listener.yaw * .pi / 180
        let forward = (x: -sin(t), z: cos(t))
        let right = (x: -cos(t), z: -sin(t))
        let dx = source.x - listener.x, dy = source.y - listener.y, dz = source.z - listener.z
        let localRight = dx * right.x + dz * right.z
        let localForward = dx * forward.x + dz * forward.z
        return Vector(x: localRight, y: dy, z: -localForward)
    }

    /// Linear-in-dB style falloff that reaches silence at `range` blocks, like
    /// in-game sounds: full volume within 4 blocks.
    static func gain(distance: Double, range: Double) -> Double {
        if distance <= 4 { return 1 }
        if distance >= range { return 0 }
        let t = (distance - 4) / (range - 4)
        return pow(1 - t, 2)
    }
}
