package dev.zmf.support;

import java.io.File;
import java.io.FileOutputStream;
import java.io.PrintStream;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.util.Arrays;

/**
 * Entry point the iOS host starts inside the JVM. It records the environment,
 * installs a crash handler that writes a report the launcher can show, then
 * hands control to the real main class (vanilla, Fabric Knot, ...).
 *
 * Usage: Bootstrap <main class> [game arguments...]
 */
public final class Bootstrap {
    private Bootstrap() {}

    public static void main(String[] args) throws Throwable {
        if (args.length == 0) {
            System.err.println("[ZMF] Bootstrap: missing main class");
            System.exit(2);
        }
        String mainClass = args[0];
        String[] gameArgs = Arrays.copyOfRange(args, 1, args.length);

        System.out.println("[ZMF] Java " + System.getProperty("java.version")
                + " (" + System.getProperty("java.vm.name") + ", " + System.getProperty("java.vm.info") + ")");
        System.out.println("[ZMF] os=" + System.getProperty("os.name") + " " + System.getProperty("os.arch")
                + " maxMemory=" + (Runtime.getRuntime().maxMemory() >> 20) + "MB");
        System.out.println("[ZMF] main class: " + mainClass);

        final String crashFile = System.getProperty("zmf.crashFile");
        Thread.setDefaultUncaughtExceptionHandler((thread, error) -> writeCrash(crashFile, thread.getName(), error));

        try {
            Class<?> cls = Class.forName(mainClass, true, ClassLoader.getSystemClassLoader());
            Method main = cls.getMethod("main", String[].class);
            main.invoke(null, (Object) gameArgs);
        } catch (InvocationTargetException e) {
            writeCrash(crashFile, Thread.currentThread().getName(), e.getCause());
            throw e.getCause();
        } catch (Throwable t) {
            writeCrash(crashFile, Thread.currentThread().getName(), t);
            throw t;
        }
    }

    static void writeCrash(String path, String thread, Throwable error) {
        error.printStackTrace();
        if (path == null) return;
        try (PrintStream out = new PrintStream(new FileOutputStream(new File(path), true), true, "UTF-8")) {
            out.println("---- ZMF Java Launcher crash ----");
            out.println("time: " + new java.util.Date());
            out.println("thread: " + thread);
            out.println("java: " + System.getProperty("java.version") + " " + System.getProperty("java.vm.name"));
            error.printStackTrace(out);
        } catch (Exception ignored) {
            // Nothing else we can do; the stack trace already went to the log.
        }
    }
}
