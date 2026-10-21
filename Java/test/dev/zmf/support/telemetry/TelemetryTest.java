package dev.zmf.support.telemetry;

import java.io.BufferedReader;
import java.io.StringReader;
import java.nio.file.Files;
import java.nio.file.Paths;

/** Minimal assertion-based tests (run by scripts/test-java.sh and CI). */
public final class TelemetryTest {
    static int checks = 0;

    static void check(boolean ok, String what) {
        checks++;
        if (!ok) throw new AssertionError("FAILED: " + what);
        System.out.println("ok - " + what);
    }

    public static void main(String[] args) throws Exception {
        String res = args[0];
        String official = new String(Files.readAllBytes(Paths.get(res, "client_mappings.txt")), "UTF-8");
        String tiny = new String(Files.readAllBytes(Paths.get(res, "mappings.tiny")), "UTF-8");

        // Vanilla: Mojang names -> obfuscated
        Mappings vanilla = new Mappings(GameProbe.CLASSES);
        vanilla.loadOfficial(new BufferedReader(new StringReader(official)));
        check(vanilla.runtimeClass(GameProbe.MINECRAFT).equals("zz.a"), "class resolves to obfuscated name");
        check(vanilla.runtimeMember(GameProbe.ENTITY, "getX").get(0).equals("x1"), "method resolves to obfuscated name");
        check(vanilla.runtimeClass("net.minecraft.SomethingElse").equals("net.minecraft.SomethingElse"), "unwanted classes are not retained");
        GameProbe.Sample s = new GameProbe(vanilla, TelemetryTest.class.getClassLoader(), "u1").sample();
        check(s != null, "vanilla probe reads a sample");
        check(s.world.equals("play.example.net:25565|minecraft:the_nether"), "vanilla world key: " + s.world);
        check(s.x == 12.5 && s.y == 64 && s.z == -3 && s.yaw == 90f, "vanilla position and yaw");

        // Fabric: Mojang names -> obfuscated -> intermediary
        Mappings fabric = new Mappings(GameProbe.CLASSES);
        fabric.loadOfficial(new BufferedReader(new StringReader(official)));
        fabric.loadIntermediary(new BufferedReader(new StringReader(tiny)));
        check(fabric.runtimeClass(GameProbe.MINECRAFT).equals("net.minecraft.class_310"), "class resolves to intermediary");
        GameProbe.Sample f = new GameProbe(fabric, TelemetryTest.class.getClassLoader(), "u2").sample();
        check(f != null, "fabric probe reads a sample");
        check(f.world.equals("local:u2|minecraft:overworld"), "singleplayer world key: " + f.world);
        check(f.x == 1 && f.y == 2 && f.z == 3 && f.yaw == -45f, "fabric position and yaw");

        // No mappings at all: unknown class -> no sample, no exception
        GameProbe none = new GameProbe(new Mappings(GameProbe.CLASSES), TelemetryTest.class.getClassLoader(), null);
        check(none.sample() == null, "missing game classes yield no sample");

        check(GameProbe.normalizeAddress("Play.Example.NET.").equals("play.example.net:25565"), "address normalization");
        check(GameProbe.normalizeAddress("mc.x.org:25570").equals("mc.x.org:25570"), "explicit port kept");
        check(GameProbe.normalizeAddress("[::1]").equals("[::1]:25565"), "ipv6 literal");
        System.out.println(checks + " checks passed");
    }
}
