import static java.lang.foreign.ValueLayout.ADDRESS;
import static java.lang.foreign.ValueLayout.JAVA_INT;

import java.io.IOException;
import java.io.Reader;
import java.io.Writer;
import java.lang.foreign.Arena;
import java.lang.foreign.FunctionDescriptor;
import java.lang.foreign.Linker;
import java.lang.foreign.MemorySegment;
import java.lang.foreign.SymbolLookup;
import java.lang.invoke.MethodHandle;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.time.LocalDateTime;
import java.time.format.DateTimeFormatter;
import java.util.HexFormat;
import java.util.Locale;
import java.util.Properties;
import java.util.SplittableRandom;

/**
 * Host program for the GPU MD5 search (md5search.cu).
 *
 * Searches 32-character lowercase hex strings s for
 *   PREFIX : md5(s) starts with the same characters as s
 *   SUFFIX : md5(s) ends with the same characters as s
 *   ZEROS  : md5(s) starts with many '0' characters
 * and logs every result that beats or ties the best value seen so far.
 *
 * No dependencies: uses the Foreign Function & Memory API (Java 22+).
 *
 *   Windows: nvcc -O3 -arch=sm_89 -shared -o md5search.dll md5search.cu
 *   Linux:   nvcc -O3 -arch=sm_89 -Xcompiler -fPIC -shared -o libmd5search.so md5search.cu
 *   java --enable-native-access=ALL-UNNAMED Md5Search.java
 *
 * Settings can be overridden with system properties, e.g.
 *   java -Dmd5.load=50 --enable-native-access=ALL-UNNAMED Md5Search.java
 */
public class Md5Search {

    // ------------------------------------------------------------------
    // Configuration
    // ------------------------------------------------------------------

    /** Path to the CUDA library built from md5search.cu (.dll on Windows, .so on Linux). */
    static final String LIBRARY = System.getProperty("md5.lib",
            System.getProperty("os.name").toLowerCase(Locale.ROOT).startsWith("windows")
                    ? "md5search.dll" : "libmd5search.so");

    /** CUDA device number (0 = first GPU). */
    static final int GPU_DEVICE = Integer.getInteger("md5.device", 0);

    /**
     * Share of the GPU to use, in percent. This sets the number of GPU threads:
     * blocks = (number of SMs) * GPU_LOAD_PERCENT / 100, with 1024 threads per block.
     * On an RTX 4090 (128 SMs) 50% gives 64 blocks = 65,536 GPU threads, which
     * keeps half of the SMs idle.
     */
    static final int GPU_LOAD_PERCENT = Integer.getInteger("md5.load", 50);

    /** Never report below this level, so a fresh start does not flood the log. */
    static final int MIN_REPORT_LEVEL = Integer.getInteger("md5.minReport", 10);

    /** Starting best values when no state file exists yet. Ties are logged too. */
    static final int START_BEST_PREFIX = Integer.getInteger("md5.startPrefix", 12);
    static final int START_BEST_SUFFIX = Integer.getInteger("md5.startSuffix", 12);
    static final int START_BEST_ZEROS  = Integer.getInteger("md5.startZeros", 12);

    static final Path LOG_FILE   = Path.of(System.getProperty("md5.log", "md5search.log"));
    static final Path STATE_FILE = Path.of(System.getProperty("md5.state", "md5search-best.properties"));

    /** How often a progress line is printed to the console (ms). */
    static final long PROGRESS_INTERVAL_MS = Long.getLong("md5.progressMs", 60_000L);

    /** How often a progress line is also written to the log file (ms). */
    static final long PROGRESS_LOG_INTERVAL_MS = Long.getLong("md5.progressLogMs", 3_600_000L);

    /** Every kernel launch tests all 2^32 values of the last 8 hex characters. */
    static final long CANDIDATES_PER_LAUNCH = 1L << 32;

    static final int MAX_HITS = 1024;

    // ------------------------------------------------------------------
    // Best results, one per category
    // ------------------------------------------------------------------

    enum Kind {
        PREFIX("prefix match", "prefix"),
        SUFFIX("suffix match", "suffix"),
        ZEROS("leading zeros", "zeros");

        final String label;
        final String key;

        Kind(String label, String key) {
            this.label = label;
            this.key = key;
        }
    }

    private final int[] best = new int[Kind.values().length];
    private final String[] bestInput = new String[Kind.values().length];
    private final String[] bestHash = new String[Kind.values().length];

    // ------------------------------------------------------------------
    // Native library (Foreign Function & Memory API)
    // ------------------------------------------------------------------

    private final Arena arena = Arena.ofShared();
    private MethodHandle mhInit;
    private MethodHandle mhSearch;
    private MethodHandle mhShutdown;
    private MemorySegment baseSeg;
    private MemorySegment outSeg;

    private final MessageDigest md5;
    private final SplittableRandom random = new SplittableRandom(new SecureRandom().nextLong());

    private volatile boolean running = true;
    private long totalCandidates = 0;
    private long totalGpuNanos = 0;
    private long launches = 0;

    private static final DateTimeFormatter TS = DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss");

    public Md5Search() throws Exception {
        md5 = MessageDigest.getInstance("MD5");
    }

    public static void main(String[] args) throws Throwable {
        new Md5Search().run();
    }

    void run() throws Throwable {
        loadState();
        loadLibrary();

        log("=== Md5Search started ===");
        logBests("Current best values");

        selfTest();

        final Thread mainThread = Thread.currentThread();
        Runtime.getRuntime().addShutdownHook(new Thread(() -> {
            running = false;
            try {
                mainThread.join(10_000); // let the current kernel launch finish
            } catch (InterruptedException ignored) {
            }
        }));

        searchLoop();

        mhShutdown.invokeExact();
        log(String.format(Locale.ROOT, "=== Md5Search stopped after %s candidates ===", sci(totalCandidates)));
        logBests("Best values");
    }

    // ------------------------------------------------------------------
    // Main search loop
    // ------------------------------------------------------------------

    private void searchLoop() throws Throwable {
        long startNanos = System.nanoTime();
        long nextProgress = System.currentTimeMillis() + PROGRESS_INTERVAL_MS;
        long nextProgressLog = System.currentTimeMillis() + PROGRESS_LOG_INTERVAL_MS;

        while (running) {
            String base = randomBase();
            int thrP = Math.max(best[Kind.PREFIX.ordinal()], MIN_REPORT_LEVEL);
            int thrS = Math.max(best[Kind.SUFFIX.ordinal()], MIN_REPORT_LEVEL);
            int thrZ = Math.max(best[Kind.ZEROS.ordinal()], MIN_REPORT_LEVEL);

            long t0 = System.nanoTime();
            int[][] hits = gpuSearch(base, thrP, thrS, thrZ);
            totalGpuNanos += System.nanoTime() - t0;
            totalCandidates += CANDIDATES_PER_LAUNCH;
            launches++;

            for (int[] hit : hits) {
                processHit(base, hit);
            }

            long now = System.currentTimeMillis();
            if (now >= nextProgress) {
                String line = progressLine(System.nanoTime() - startNanos);
                System.out.println(timestamp() + " " + line);
                nextProgress = now + PROGRESS_INTERVAL_MS;
                if (now >= nextProgressLog) {
                    appendLog(timestamp() + " PROGRESS " + line);
                    nextProgressLog = now + PROGRESS_LOG_INTERVAL_MS;
                }
            }
        }
    }

    /** Verify a GPU hit on the CPU and log it if it beats or ties a best value. */
    private void processHit(String base, int[] hit) throws IOException {
        String input = base + String.format("%08x", hit[0]);
        String hash = md5Hex(input);

        int[] counts = { prefixCount(input, hash), suffixCount(input, hash), zeroCount(hash) };

        if (counts[0] != hit[1] || counts[1] != hit[2] || counts[2] != hit[3]) {
            log(String.format("ERROR GPU/CPU mismatch for %s -> %s: GPU p=%d s=%d z=%d, CPU p=%d s=%d z=%d",
                    input, hash, hit[1], hit[2], hit[3], counts[0], counts[1], counts[2]));
        }

        for (Kind kind : Kind.values()) {
            int k = kind.ordinal();
            int count = counts[k];
            if (count < MIN_REPORT_LEVEL || count < best[k]) {
                continue;
            }
            if (count > best[k]) {
                log(String.format(Locale.ROOT, "NEW BEST %-13s %2d chars (previous %d): %s -> %s   [after %s candidates]",
                        kind.label, count, best[k], input, hash, sci(totalCandidates)));
                best[k] = count;
                bestInput[k] = input;
                bestHash[k] = hash;
                saveState();
            } else {
                log(String.format(Locale.ROOT, "TIE      %-13s %2d chars:               %s -> %s   [after %s candidates]",
                        kind.label, count, input, hash, sci(totalCandidates)));
            }
        }
    }

    // ------------------------------------------------------------------
    // Native calls
    // ------------------------------------------------------------------

    private void loadLibrary() throws Throwable {
        Linker linker = Linker.nativeLinker();
        SymbolLookup lib = SymbolLookup.libraryLookup(Path.of(LIBRARY).toAbsolutePath(), arena);

        mhInit = linker.downcallHandle(lib.find("md5_init").orElseThrow(),
                FunctionDescriptor.of(JAVA_INT, JAVA_INT, JAVA_INT, ADDRESS, JAVA_INT));
        mhSearch = linker.downcallHandle(lib.find("md5_search").orElseThrow(),
                FunctionDescriptor.of(JAVA_INT, ADDRESS, JAVA_INT, JAVA_INT, JAVA_INT, ADDRESS, JAVA_INT));
        mhShutdown = linker.downcallHandle(lib.find("md5_shutdown").orElseThrow(),
                FunctionDescriptor.ofVoid());

        baseSeg = arena.allocate(JAVA_INT, 6);
        outSeg = arena.allocate(JAVA_INT, 4L * MAX_HITS);

        MemorySegment info = arena.allocate(512);
        int blocks = (int) mhInit.invokeExact(GPU_DEVICE, GPU_LOAD_PERCENT, info, 512);
        String infoText = info.getString(0);
        if (blocks <= 0) {
            throw new IllegalStateException("GPU init failed (" + blocks + "): " + infoText);
        }
        log("GPU: " + infoText);
    }

    /** Returns hits as {n, prefix, suffix, zeros}. */
    private int[][] gpuSearch(String base, int thrP, int thrS, int thrZ) throws Throwable {
        byte[] b = base.getBytes(StandardCharsets.US_ASCII);
        for (int i = 0; i < 6; i++) {
            int w = (b[4 * i] & 0xff) | (b[4 * i + 1] & 0xff) << 8
                  | (b[4 * i + 2] & 0xff) << 16 | (b[4 * i + 3] & 0xff) << 24;
            baseSeg.setAtIndex(JAVA_INT, i, w);
        }
        int count = (int) mhSearch.invokeExact(baseSeg, thrP, thrS, thrZ, outSeg, MAX_HITS);
        if (count < 0) {
            throw new IllegalStateException("CUDA error " + (-count) + " in md5_search");
        }
        if (count > MAX_HITS) {
            log("WARNING " + count + " hits in one launch, only " + MAX_HITS + " returned");
        }
        int n = Math.min(count, MAX_HITS);
        int[][] hits = new int[n][4];
        for (int i = 0; i < n; i++) {
            for (int j = 0; j < 4; j++) {
                hits[i][j] = outSeg.getAtIndex(JAVA_INT, 4L * i + j);
            }
        }
        return hits;
    }

    // ------------------------------------------------------------------
    // Self-test: the two known 12-character results must be found
    // ------------------------------------------------------------------

    private void selfTest() throws Throwable {
        String prefixInput = "54db1011d76dc70a0a9df3ff3e0b390f"; // prefix 12
        String suffixInput = "df12c1434cec7850a7900ce027af4b78"; // suffix 12

        long t0 = System.nanoTime();
        boolean okP = findsKnown(prefixInput, 12, 0, 0, 1);
        boolean okS = findsKnown(suffixInput, 0, 12, 0, 2);
        double seconds = (System.nanoTime() - t0) / 1e9;

        if (!okP || !okS) {
            log("SELF-TEST FAILED (prefix " + okP + ", suffix " + okS + ") - stopping");
            mhShutdown.invokeExact();
            System.exit(1);
        }
        log(String.format(Locale.ROOT, "Self-test OK: found both known 12-char results, %.1f GH/s at %d%% load",
                2.0 * CANDIDATES_PER_LAUNCH / seconds / 1e9, GPU_LOAD_PERCENT));
    }

    private boolean findsKnown(String input, int thrP, int thrS, int thrZ, int field) throws Throwable {
        int expectedN = Integer.parseUnsignedInt(input.substring(24), 16);
        for (int[] hit : gpuSearch(input.substring(0, 24), thrP, thrS, thrZ)) {
            if (hit[0] == expectedN && hit[field] == 12) {
                return true;
            }
        }
        return false;
    }

    // ------------------------------------------------------------------
    // Scoring (CPU reference, used to verify every GPU hit)
    // ------------------------------------------------------------------

    static int prefixCount(String s, String h) {
        int i = 0;
        while (i < 32 && s.charAt(i) == h.charAt(i)) i++;
        return i;
    }

    static int suffixCount(String s, String h) {
        int i = 0;
        while (i < 32 && s.charAt(31 - i) == h.charAt(31 - i)) i++;
        return i;
    }

    static int zeroCount(String h) {
        int i = 0;
        while (i < 32 && h.charAt(i) == '0') i++;
        return i;
    }

    private String md5Hex(String s) {
        return HexFormat.of().formatHex(md5.digest(s.getBytes(StandardCharsets.US_ASCII)));
    }

    private String randomBase() {
        return String.format("%016x%08x", random.nextLong(), random.nextInt());
    }

    // ------------------------------------------------------------------
    // Progress
    // ------------------------------------------------------------------

    private String progressLine(long elapsedNanos) {
        double rate = totalCandidates / (totalGpuNanos / 1e9);               // while kernels run
        double wall = totalCandidates / (elapsedNanos / 1e9);                // overall
        StringBuilder sb = new StringBuilder(String.format(Locale.ROOT,
                "%s candidates, %.1f GH/s (%.1f GH/s overall), running %s | expected time to beat:",
                sci(totalCandidates), rate / 1e9, wall / 1e9, human(elapsedNanos / 1e9)));
        for (Kind kind : Kind.values()) {
            int next = Math.max(best[kind.ordinal()], MIN_REPORT_LEVEL - 1) + 1;
            double seconds = Math.pow(16, next) / wall;
            sb.append(String.format(Locale.ROOT, " %s %d=%s", kind.key, next, human(seconds)));
        }
        return sb.toString();
    }

    private static String sci(long n) {
        return String.format(Locale.ROOT, "%.3e", (double) n);
    }

    private static String human(double seconds) {
        if (seconds < 120) return String.format(Locale.ROOT, "%.0fs", seconds);
        if (seconds < 7200) return String.format(Locale.ROOT, "%.0fmin", seconds / 60);
        if (seconds < 172800) return String.format(Locale.ROOT, "%.1fh", seconds / 3600);
        if (seconds < 3.15e7 * 2) return String.format(Locale.ROOT, "%.1fd", seconds / 86400);
        return String.format(Locale.ROOT, "%.1fy", seconds / 3.15e7);
    }

    // ------------------------------------------------------------------
    // Logging and persisted best values
    // ------------------------------------------------------------------

    private void logBests(String title) throws IOException {
        for (Kind kind : Kind.values()) {
            int k = kind.ordinal();
            log(String.format("%s: %-13s %2d chars  %s%s", title, kind.label, best[k],
                    bestInput[k] == null ? "(start value)" : bestInput[k],
                    bestHash[k] == null ? "" : " -> " + bestHash[k]));
        }
    }

    private void log(String message) throws IOException {
        String line = timestamp() + " " + message;
        System.out.println(line);
        appendLog(line);
    }

    private static void appendLog(String line) throws IOException {
        Files.writeString(LOG_FILE, line + System.lineSeparator(), StandardCharsets.UTF_8,
                StandardOpenOption.CREATE, StandardOpenOption.APPEND);
    }

    private static String timestamp() {
        return LocalDateTime.now().format(TS);
    }

    private void loadState() throws IOException {
        int[] start = { START_BEST_PREFIX, START_BEST_SUFFIX, START_BEST_ZEROS };
        Properties p = new Properties();
        if (Files.exists(STATE_FILE)) {
            try (Reader r = Files.newBufferedReader(STATE_FILE)) {
                p.load(r);
            }
        }
        for (Kind kind : Kind.values()) {
            int k = kind.ordinal();
            best[k] = Integer.parseInt(p.getProperty(kind.key + ".best", String.valueOf(start[k])));
            bestInput[k] = p.getProperty(kind.key + ".input");
            bestHash[k] = p.getProperty(kind.key + ".md5");
        }
    }

    private void saveState() throws IOException {
        Properties p = new Properties();
        for (Kind kind : Kind.values()) {
            int k = kind.ordinal();
            p.setProperty(kind.key + ".best", String.valueOf(best[k]));
            if (bestInput[k] != null) p.setProperty(kind.key + ".input", bestInput[k]);
            if (bestHash[k] != null) p.setProperty(kind.key + ".md5", bestHash[k]);
        }
        Path tmp = STATE_FILE.resolveSibling(STATE_FILE.getFileName() + ".tmp");
        try (Writer w = Files.newBufferedWriter(tmp)) {
            p.store(w, "Md5Search best values");
        }
        Files.move(tmp, STATE_FILE, java.nio.file.StandardCopyOption.REPLACE_EXISTING,
                java.nio.file.StandardCopyOption.ATOMIC_MOVE);
    }
}
