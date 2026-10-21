package dev.zmf.support;

import java.io.FileOutputStream;
import java.io.OutputStreamWriter;
import java.io.Writer;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.List;
import java.util.stream.IntStream;

/**
 * Runtime self-test: executes real bytecode (collections, lambdas/streams,
 * java.security, threads) inside the embedded JVM and writes a JSON result the
 * launcher displays. Usage: SelfTest <output.json>
 */
public final class SelfTest {
    private SelfTest() {}

    public static void main(String[] args) throws Exception {
        long start = System.nanoTime();

        long primes = IntStream.rangeClosed(2, 200_000).filter(SelfTest::isPrime).count();

        MessageDigest sha = MessageDigest.getInstance("SHA-256");
        byte[] digest = sha.digest("ZMF Java Launcher".getBytes(StandardCharsets.UTF_8));
        StringBuilder hex = new StringBuilder();
        for (byte b : digest) hex.append(String.format("%02x", b));

        List<Thread> threads = new ArrayList<>();
        final long[] sums = new long[4];
        for (int t = 0; t < sums.length; t++) {
            final int idx = t;
            Thread th = new Thread(() -> {
                long s = 0;
                for (int i = 0; i < 1_000_000; i++) s += i % (idx + 2);
                sums[idx] = s;
            });
            threads.add(th);
            th.start();
        }
        for (Thread th : threads) th.join();

        double ms = (System.nanoTime() - start) / 1e6;
        String json = "{"
                + "\"ok\":true,"
                + "\"javaVersion\":\"" + esc(System.getProperty("java.version")) + "\","
                + "\"vmName\":\"" + esc(System.getProperty("java.vm.name")) + "\","
                + "\"vmInfo\":\"" + esc(System.getProperty("java.vm.info")) + "\","
                + "\"osName\":\"" + esc(System.getProperty("os.name")) + "\","
                + "\"osArch\":\"" + esc(System.getProperty("os.arch")) + "\","
                + "\"primesBelow200k\":" + primes + ","
                + "\"sha256\":\"" + hex + "\","
                + "\"threadSums\":[" + sums[0] + "," + sums[1] + "," + sums[2] + "," + sums[3] + "],"
                + "\"elapsedMs\":" + String.format(java.util.Locale.ROOT, "%.1f", ms)
                + "}";
        System.out.println("[ZMF] self-test " + json);
        if (args.length > 0) {
            try (Writer w = new OutputStreamWriter(new FileOutputStream(args[0]), StandardCharsets.UTF_8)) {
                w.write(json);
            }
        }
    }

    static boolean isPrime(int n) {
        if (n < 4) return n > 1;
        if (n % 2 == 0) return false;
        for (int i = 3; (long) i * i <= n; i += 2) if (n % i == 0) return false;
        return true;
    }

    static String esc(String s) {
        return s == null ? "" : s.replace("\\", "\\\\").replace("\"", "\\\"");
    }
}
