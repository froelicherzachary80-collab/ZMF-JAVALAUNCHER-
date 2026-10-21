package dev.zmf.support.telemetry;

/**
 * Background thread that samples the local player ~10 times per second and
 * hands the result to the iOS host (ZMF Voice) through a JNI method the host
 * registers. Enabled by -Dzmf.telemetry=true; never throws into the game.
 */
public final class Telemetry implements Runnable {
    private final String playerUuid;
    private volatile boolean running = true;

    private Telemetry(String playerUuid) { this.playerUuid = playerUuid; }

    public static void start() {
        Thread t = new Thread(new Telemetry(System.getProperty("zmf.playerUuid")), "ZMF-Telemetry");
        t.setDaemon(true);
        t.setPriority(Thread.MIN_PRIORITY);
        t.start();
    }

    @Override
    public void run() {
        Mappings mappings = Mappings.load(GameProbe.CLASSES, System.getProperty("zmf.mappings"), System.getProperty("zmf.intermediary"));
        System.out.println("[ZMF] telemetry: official mappings=" + mappings.hasOfficial() + " intermediary=" + mappings.hasIntermediary());
        GameProbe probe = null;
        boolean wasInWorld = false;
        while (running) {
            try {
                Thread.sleep(100);
                if (probe == null) {
                    ClassLoader gameLoader = findGameClassLoader(mappings);
                    if (gameLoader == null) continue;
                    probe = new GameProbe(mappings, gameLoader, playerUuid);
                }
                GameProbe.Sample s = probe.sample();
                if (s != null) {
                    NativeBridge.publish(s.world, s.x, s.y, s.z, s.yaw);
                    wasInWorld = true;
                } else if (wasInWorld) {
                    NativeBridge.publish(null, 0, 0, 0, 0);
                    wasInWorld = false;
                }
            } catch (InterruptedException e) {
                return;
            } catch (UnsatisfiedLinkError e) {
                System.out.println("[ZMF] telemetry: host bridge not available, stopping");
                return;
            } catch (Throwable t) {
                // keep sampling; the game must never be affected
            }
        }
    }

    /** The loader that defined Minecraft's classes (system loader, or Fabric's Knot loader). */
    static ClassLoader findGameClassLoader(Mappings mappings) {
        String mc = mappings.runtimeClass(GameProbe.MINECRAFT);
        for (Thread t : Thread.getAllStackTraces().keySet()) {
            ClassLoader l = t.getContextClassLoader();
            if (l == null) continue;
            try {
                Class.forName(mc, false, l);
                return l;
            } catch (Throwable ignored) {
                // not this one
            }
        }
        return null;
    }
}
