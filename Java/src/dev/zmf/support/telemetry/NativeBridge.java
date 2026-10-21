package dev.zmf.support.telemetry;

/**
 * Implemented by the iOS host (ZMFJVMBridge registers it with RegisterNatives).
 * world == null means the player left the world.
 */
public final class NativeBridge {
    private NativeBridge() {}

    public static native void publish(String world, double x, double y, double z, float yaw);
}
