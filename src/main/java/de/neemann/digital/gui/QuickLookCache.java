/*
 * Copyright (c) 2026 Helmut Neemann.
 * Use of this source code is governed by the GPL v3 license
 * that can be found in the LICENSE file.
 */
package de.neemann.digital.gui;

import de.neemann.digital.cli.CircuitLoader;
import de.neemann.digital.core.element.ElementAttributes;
import de.neemann.digital.draw.elements.Circuit;
import de.neemann.digital.draw.graphics.Export;
import de.neemann.digital.draw.graphics.GraphicSVG;
import de.neemann.gui.Screen;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.io.File;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.StandardCopyOption;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.concurrent.CompletableFuture;

/**
 * Handles Quick Look preview SVG cache for macOS.
 */
public final class QuickLookCache {
    private static final Logger LOGGER = LoggerFactory.getLogger(QuickLookCache.class);
    private static final String CACHE_DIR_NAME = "com.neemann.digital.quicklook";
    private static final long FOURTEEN_DAYS_MILLIS = 14L * 24L * 60L * 60L * 1000L;
    private static final int PADDING = 20;

    private QuickLookCache() {
    }

    /**
     * Returns the user cache directory for Quick Look SVGs.
     *
     * @return the cache directory
     */
    public static File getCacheDir() {
        String userHome = System.getProperty("user.home");
        return new File(userHome, "Library/Caches/" + CACHE_DIR_NAME);
    }

    /**
     * Calculates the SHA-256 hash of the canonical absolute path of a circuit file.
     *
     * @param file the circuit file
     * @return the hex string of the SHA-256 hash
     */
    public static String getCacheKey(File file) {
        String path;
        try {
            path = file.getCanonicalFile().getAbsolutePath();
        } catch (IOException e) {
            path = file.getAbsolutePath();
        }
        return sha256(path);
    }

    /**
     * Computes the SHA-256 hex digest of a string.
     *
     * @param input the input string
     * @return hex digest string
     */
    public static String sha256(String input) {
        try {
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            byte[] hash = digest.digest(input.getBytes(StandardCharsets.UTF_8));
            StringBuilder hexString = new StringBuilder();
            for (byte b : hash) {
                String hex = Integer.toHexString(0xff & b);
                if (hex.length() == 1) {
                    hexString.append('0');
                }
                hexString.append(hex);
            }
            return hexString.toString();
        } catch (NoSuchAlgorithmException e) {
            throw new RuntimeException("SHA-256 not available", e);
        }
    }

    /**
     * Hook called asynchronously on file save.
     *
     * @param file the saved circuit file
     */
    public static void onSaveAsync(File file) {
        onSaveAsync(file, null);
    }

    /**
     * Hook called asynchronously on file save, reusing an existing in-memory circuit.
     *
     * @param file    the saved circuit file
     * @param circuit the in-memory circuit, or null to load from disk
     */
    public static void onSaveAsync(File file, Circuit circuit) {
        if (!Screen.isMac() || file == null) {
            return;
        }
        Circuit circuitCopy = (circuit != null) ? circuit.createShallowCopy() : null;
        CompletableFuture.runAsync(() -> {
            try {
                exportToCache(file, circuitCopy);
            } catch (Exception e) {
                LOGGER.debug("Could not export Quick Look preview cache: " + e.getMessage());
            }
        });
    }

    /**
     * Hook called asynchronously on file load in GUI.
     * Checks if cached SVG is already present and fresh before triggering export.
     *
     * @param file    the loaded circuit file
     * @param circuit the in-memory circuit, or null to load from disk
     */
    public static void onLoadAsync(File file, Circuit circuit) {
        if (!Screen.isMac() || file == null) {
            return;
        }
        File cacheDir = getCacheDir();
        String key = getCacheKey(file);
        File targetFile = new File(cacheDir, key + ".svg");
        if (targetFile.exists() && targetFile.lastModified() >= file.lastModified()) {
            return; // Cache already exists and is up to date, skip redundant export
        }
        onSaveAsync(file, circuit);
    }

    /**
     * Exports the given circuit file to the cache directory atomically.
     *
     * @param file the circuit file
     * @throws IOException on error writing SVG
     */
    public static void exportToCache(File file) throws IOException {
        exportToCache(file, null);
    }

    /**
     * Exports the given circuit to the cache directory atomically.
     *
     * @param file    the circuit file
     * @param circuit the in-memory circuit, or null to load from disk
     * @throws IOException on error writing SVG
     */
    public static void exportToCache(File file, Circuit circuit) throws IOException {
        File cacheDir = getCacheDir();
        if (!cacheDir.exists() && !cacheDir.mkdirs()) {
            throw new IOException("Could not create cache directory: " + cacheDir);
        }
        String key = getCacheKey(file);
        File targetFile = new File(cacheDir, key + ".svg");
        File tempFile = new File(cacheDir, key + ".svg.tmp." + System.nanoTime());

        try {
            if (circuit != null) {
                exportCircuitSvg(circuit, tempFile);
            } else {
                exportCircuitSvg(file, tempFile);
            }
            try {
                Files.move(tempFile.toPath(), targetFile.toPath(),
                        StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
            } catch (IOException e) {
                // Fallback to standard replace if atomic move fails
                Files.move(tempFile.toPath(), targetFile.toPath(), StandardCopyOption.REPLACE_EXISTING);
            }
        } finally {
            if (tempFile.exists()) {
                tempFile.delete();
            }
        }
    }

    /**
     * Exports an in-memory circuit to SVG format with padding.
     *
     * @param circuit the in-memory circuit
     * @param svgFile the output SVG file
     * @throws IOException on error
     */
    public static void exportCircuitSvg(Circuit circuit, File svgFile) throws IOException {
        ElementAttributes attr = new ElementAttributes();
        new Export(circuit, o -> new GraphicSVG(o, attr), false, PADDING).export(svgFile);
    }

    /**
     * Exports a circuit file to SVG format with padding.
     *
     * @param digFile the input circuit file
     * @param svgFile the output SVG file
     * @throws IOException on error
     */
    public static void exportCircuitSvg(File digFile, File svgFile) throws IOException {
        boolean ieee = true;
        try {
            ieee = Settings.getInstance().get(de.neemann.digital.core.element.Keys.SETTINGS_IEEE_SHAPES);
        } catch (Exception e) {
            // Default to true if settings are unavailable
        }
        exportCircuitSvg(digFile, svgFile, ieee);
    }

    /**
     * Exports a circuit file to SVG format with padding and explicit IEEE shape choice.
     *
     * @param digFile    the input circuit file
     * @param svgFile    the output SVG file
     * @param ieeeShapes true for IEEE/ANSI curved shapes, false for IEC rectangular shapes
     * @throws IOException on error
     */
    public static void exportCircuitSvg(File digFile, File svgFile, boolean ieeeShapes) throws IOException {
        CircuitLoader loader = new CircuitLoader(digFile, ieeeShapes);
        Circuit circuit = loader.getCircuit();
        ElementAttributes attr = new ElementAttributes();
        new Export(circuit, o -> new GraphicSVG(o, attr), false, PADDING).export(svgFile);
    }

    /**
     * Cleans up SVG files older than 14 days in background.
     */
    public static void cleanUpCacheAsync() {
        if (!Screen.isMac()) {
            return;
        }
        CompletableFuture.runAsync(() -> {
            try {
                File cacheDir = getCacheDir();
                if (!cacheDir.isDirectory()) {
                    return;
                }
                long cutoff = System.currentTimeMillis() - FOURTEEN_DAYS_MILLIS;
                File[] files = cacheDir.listFiles((dir, name) -> name.endsWith(".svg") || name.contains(".tmp."));
                if (files != null) {
                    for (File f : files) {
                        if (f.lastModified() < cutoff) {
                            f.delete();
                        }
                    }
                }
            } catch (Exception e) {
                LOGGER.debug("Cache cleanup error: " + e.getMessage());
            }
        });
    }
}
