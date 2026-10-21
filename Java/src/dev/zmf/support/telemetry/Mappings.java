package dev.zmf.support.telemetry;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;

/**
 * Translates Mojang's human-readable names (net.minecraft.client.Minecraft,
 * Entity.getX ...) into the names the running game actually uses:
 * <ul>
 *   <li>vanilla 1.14.4+: obfuscated names, via the official client_mappings.txt
 *       Mojang publishes for each version;</li>
 *   <li>Fabric/Quilt: intermediary names, via obfuscated → intermediary from the
 *       net.fabricmc:intermediary jar already on the classpath;</li>
 *   <li>unobfuscated versions (or no mapping file): the names themselves.</li>
 * </ul>
 * Only the classes ZMF asks about are kept in memory.
 */
public final class Mappings {
    private final Map<String, String> namedToObfClass = new HashMap<>();
    // "namedClass#member" -> obfuscated member names (methods: no-arg only)
    private final Map<String, List<String>> namedToObfMember = new HashMap<>();
    // obf class -> intermediary class
    private final Map<String, String> obfToInterClass = new HashMap<>();
    // "obfClass#obfMember" -> intermediary member names
    private final Map<String, List<String>> obfToInterMember = new HashMap<>();
    private final Set<String> wanted;

    public Mappings(Set<String> wantedNamedClasses) {
        this.wanted = new HashSet<>(wantedNamedClasses);
    }

    public boolean hasOfficial() { return !namedToObfClass.isEmpty(); }
    public boolean hasIntermediary() { return !obfToInterClass.isEmpty(); }

    /** Parses a ProGuard-format client_mappings.txt. */
    public void loadOfficial(BufferedReader in) throws IOException {
        String line;
        String currentNamed = null;
        while ((line = in.readLine()) != null) {
            if (line.isEmpty() || line.startsWith("#")) continue;
            if (!line.startsWith(" ")) {
                // net.minecraft.client.Minecraft -> fgo:
                int arrow = line.indexOf(" -> ");
                if (arrow < 0) { currentNamed = null; continue; }
                String named = line.substring(0, arrow);
                currentNamed = wanted.contains(named) ? named : null;
                if (currentNamed != null) {
                    namedToObfClass.put(named, line.substring(arrow + 4, line.length() - (line.endsWith(":") ? 1 : 0)));
                }
                continue;
            }
            if (currentNamed == null) continue;
            String s = line.trim();
            int arrow = s.indexOf(" -> ");
            if (arrow < 0) continue;
            String left = s.substring(0, arrow);
            String obf = s.substring(arrow + 4);
            // strip "12:34:" line-number prefix of methods
            int colon = left.lastIndexOf(':');
            if (colon >= 0 && left.indexOf('(') > colon) left = left.substring(colon + 1);
            int space = left.indexOf(' ');
            if (space < 0) continue;
            String nameAndArgs = left.substring(space + 1);
            String name;
            if (nameAndArgs.endsWith("()")) {
                name = nameAndArgs.substring(0, nameAndArgs.length() - 2);
            } else if (nameAndArgs.contains("(")) {
                continue; // methods with parameters are never needed
            } else {
                name = nameAndArgs;
            }
            namedToObfMember.computeIfAbsent(currentNamed + "#" + name, k -> new ArrayList<>()).add(obf);
        }
    }

    /** Parses Fabric tiny v1 or v2 (columns: official, intermediary[, named]). */
    public void loadIntermediary(BufferedReader in) throws IOException {
        String header = in.readLine();
        if (header == null) return;
        boolean v2 = header.startsWith("tiny\t2");
        String line;
        String currentClass = null;
        while ((line = in.readLine()) != null) {
            String[] p = line.split("\t", -1);
            if (v2) {
                if (p.length >= 3 && p[0].equals("c")) {
                    currentClass = p[1];
                    obfToInterClass.put(p[1], p[2]);
                } else if (p.length >= 5 && p[0].isEmpty() && (p[1].equals("f") || p[1].equals("m")) && currentClass != null) {
                    if (p[1].equals("m") && !p[2].startsWith("()")) continue;
                    obfToInterMember.computeIfAbsent(currentClass + "#" + p[3], k -> new ArrayList<>()).add(p[4]);
                }
            } else {
                if (p.length >= 3 && p[0].equals("CLASS")) {
                    obfToInterClass.put(p[1], p[2]);
                } else if (p.length >= 5 && (p[0].equals("FIELD") || p[0].equals("METHOD"))) {
                    if (p[0].equals("METHOD") && !p[2].startsWith("()")) continue;
                    obfToInterMember.computeIfAbsent(p[1] + "#" + p[3], k -> new ArrayList<>()).add(p[4]);
                }
            }
        }
    }

    /** Runtime (binary) class name for a Mojang class name. */
    public String runtimeClass(String named) {
        String obf = namedToObfClass.get(named);
        if (obf == null) return named;
        String inter = obfToInterClass.get(obf.replace('.', '/'));
        return inter != null ? inter.replace('/', '.') : obf;
    }

    /** Candidate runtime names for a member of a Mojang class (best first). */
    public List<String> runtimeMember(String namedClass, String member) {
        List<String> out = new ArrayList<>();
        List<String> obfs = namedToObfMember.get(namedClass + "#" + member);
        String obfClass = namedToObfClass.get(namedClass);
        if (obfs != null) {
            for (String o : obfs) {
                List<String> inter = obfClass == null ? null : obfToInterMember.get(obfClass.replace('.', '/') + "#" + o);
                if (inter != null) out.addAll(inter);
                if (!hasIntermediary()) out.add(o);
            }
        }
        out.add(member); // unobfuscated builds / Mojang-mapped runtimes
        return out;
    }

    public static Mappings load(Set<String> wanted, String officialPath, String intermediaryJar) {
        Mappings m = new Mappings(wanted);
        if (officialPath != null && Files.isRegularFile(Paths.get(officialPath))) {
            try (BufferedReader r = Files.newBufferedReader(Paths.get(officialPath), StandardCharsets.UTF_8)) {
                m.loadOfficial(r);
            } catch (IOException e) {
                System.err.println("[ZMF] telemetry: cannot read mappings: " + e);
            }
        }
        if (intermediaryJar != null && Files.isRegularFile(Paths.get(intermediaryJar))) {
            try (ZipFile zip = new ZipFile(intermediaryJar)) {
                ZipEntry e = zip.getEntry("mappings/mappings.tiny");
                if (e != null) {
                    try (InputStream is = zip.getInputStream(e);
                         BufferedReader r = new BufferedReader(new InputStreamReader(is, StandardCharsets.UTF_8))) {
                        m.loadIntermediary(r);
                    }
                }
            } catch (IOException e) {
                System.err.println("[ZMF] telemetry: cannot read intermediary: " + e);
            }
        }
        return m;
    }
}
