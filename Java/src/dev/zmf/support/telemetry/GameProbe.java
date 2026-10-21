package dev.zmf.support.telemetry;

import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.lang.reflect.Modifier;
import java.util.Arrays;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Set;

/**
 * Reads the local player's world, position and facing from the running
 * Minecraft client by reflection, using {@link Mappings} so the same code works
 * across versions and with or without Fabric. Every lookup is optional: when
 * something cannot be resolved the probe reports "not in world" rather than
 * failing the game.
 */
public final class GameProbe {
    static final String MINECRAFT = "net.minecraft.client.Minecraft";
    static final String SERVER_DATA = "net.minecraft.client.multiplayer.ServerData";
    static final String ENTITY = "net.minecraft.world.entity.Entity";
    static final String LEVEL = "net.minecraft.world.level.Level";
    static final String RESOURCE_KEY = "net.minecraft.resources.ResourceKey";

    public static final Set<String> CLASSES = new HashSet<>(Arrays.asList(MINECRAFT, SERVER_DATA, ENTITY, LEVEL, RESOURCE_KEY));

    /** Snapshot of the local player's state. */
    public static final class Sample {
        public final String world; // "<server key>|<dimension>"
        public final double x, y, z;
        public final float yaw;

        Sample(String world, double x, double y, double z, float yaw) {
            this.world = world; this.x = x; this.y = y; this.z = z; this.yaw = yaw;
        }
    }

    private final Mappings mappings;
    private final ClassLoader loader;
    private Class<?> minecraftClass;
    private Object minecraft;
    private final String localKey;

    public GameProbe(Mappings mappings, ClassLoader loader, String playerUuid) {
        this.mappings = mappings;
        this.loader = loader;
        this.localKey = "local:" + (playerUuid == null ? "player" : playerUuid);
    }

    /** Returns null when the player is not in a world (menus, loading). */
    public Sample sample() {
        try {
            Object mc = minecraft();
            if (mc == null) return null;
            Object player = get(mc, MINECRAFT, "player");
            Object level = get(mc, MINECRAFT, "level");
            if (player == null || level == null) return null;

            double x = number(player, "getX", "x");
            double y = number(player, "getY", "y");
            double z = number(player, "getZ", "z");
            float yaw = (float) number(player, "getYRot", "yRot");

            Object server = call(mc, MINECRAFT, "getCurrentServer");
            String key = server != null ? normalizeAddress(String.valueOf(get(server, SERVER_DATA, "ip"))) : localKey;
            return new Sample(key + "|" + dimension(level), x, y, z, yaw);
        } catch (Throwable t) {
            return null;
        }
    }

    private Object minecraft() throws Exception {
        if (minecraft != null) return minecraft;
        if (minecraftClass == null) minecraftClass = Class.forName(mappings.runtimeClass(MINECRAFT), false, loader);
        Object mc = callStatic(minecraftClass, MINECRAFT, "getInstance");
        if (mc == null) mc = getStatic(minecraftClass, MINECRAFT, "instance");
        minecraft = mc;
        return mc;
    }

    private double number(Object entity, String method, String field) throws Exception {
        Object v = call(entity, ENTITY, method);
        if (v == null) v = get(entity, ENTITY, field);
        return v instanceof Number ? ((Number) v).doubleValue() : Double.NaN;
    }

    private String dimension(Object level) {
        try {
            Object key = call(level, LEVEL, "dimension");
            if (key != null) {
                Object loc = call(key, RESOURCE_KEY, "location");
                return String.valueOf(loc != null ? loc : key);
            }
        } catch (Throwable ignored) {
            // older versions: fall through
        }
        return "dimension";
    }

    /** "Play.Example.net" → "play.example.net:25565"; keeps explicit ports. */
    public static String normalizeAddress(String address) {
        String a = address == null ? "" : address.trim().toLowerCase(Locale.ROOT);
        if (a.endsWith(".")) a = a.substring(0, a.length() - 1);
        if (a.startsWith("[")) return a.contains("]:") ? a : a + ":25565";
        int colon = a.lastIndexOf(':');
        if (colon > 0 && a.indexOf(':') == colon) {
            String host = a.substring(0, colon);
            if (host.endsWith(".")) host = host.substring(0, host.length() - 1);
            return host + a.substring(colon);
        }
        return a + ":25565";
    }

    // --- reflection helpers ---------------------------------------------------

    private Object get(Object target, String namedClass, String field) throws Exception {
        Field f = findField(target.getClass(), mappings.runtimeMember(namedClass, field));
        return f == null ? null : f.get(target);
    }

    private Object getStatic(Class<?> cls, String namedClass, String field) throws Exception {
        Field f = findField(cls, mappings.runtimeMember(namedClass, field));
        return f == null || !Modifier.isStatic(f.getModifiers()) ? null : f.get(null);
    }

    private Object call(Object target, String namedClass, String method) throws Exception {
        Method m = findMethod(target.getClass(), mappings.runtimeMember(namedClass, method), false);
        return m == null ? null : m.invoke(target);
    }

    private Object callStatic(Class<?> cls, String namedClass, String method) throws Exception {
        Method m = findMethod(cls, mappings.runtimeMember(namedClass, method), true);
        return m == null ? null : m.invoke(null);
    }

    private static Field findField(Class<?> cls, List<String> names) {
        for (String name : names) {
            for (Class<?> c = cls; c != null; c = c.getSuperclass()) {
                try {
                    Field f = c.getDeclaredField(name);
                    f.setAccessible(true);
                    return f;
                } catch (NoSuchFieldException ignored) {
                    // try superclass
                } catch (RuntimeException ignored) {
                    return null; // module access denied
                }
            }
        }
        return null;
    }

    private static Method findMethod(Class<?> cls, List<String> names, boolean wantStatic) {
        for (String name : names) {
            for (Class<?> c = cls; c != null; c = c.getSuperclass()) {
                try {
                    Method m = c.getDeclaredMethod(name);
                    if (Modifier.isStatic(m.getModifiers()) != wantStatic || m.getReturnType() == void.class) continue;
                    m.setAccessible(true);
                    return m;
                } catch (NoSuchMethodException ignored) {
                    // try superclass
                } catch (RuntimeException ignored) {
                    return null;
                }
            }
        }
        return null;
    }
}
