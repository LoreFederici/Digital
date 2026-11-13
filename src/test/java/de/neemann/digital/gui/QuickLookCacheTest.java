/*
 * Copyright (c) 2026 Helmut Neemann.
 * Use of this source code is governed by the GPL v3 license
 * that can be found in the LICENSE file.
 */
package de.neemann.digital.gui;

import de.neemann.digital.cli.SVGExport;
import de.neemann.digital.draw.elements.Circuit;
import de.neemann.digital.draw.library.ElementLibrary;
import de.neemann.digital.draw.shapes.ShapeFactory;
import junit.framework.TestCase;

import java.io.File;
import java.nio.file.Files;

/**
 * Tests for QuickLookCache and SVGExport.
 */
public class QuickLookCacheTest extends TestCase {

    private File testDig;

    @Override
    protected void setUp() throws Exception {
        super.setUp();
        testDig = new File("src/main/dig/combinatorial/FullAdder.dig");
        assertTrue(testDig.exists());
    }

    public void testGetCacheKey() {
        String key = QuickLookCache.getCacheKey(testDig);
        assertNotNull(key);
        assertEquals(64, key.length());
        // Verify key is lowercase hexadecimal
        assertTrue(key.matches("^[0-9a-f]{64}$"));

        // Verify SHA256 consistency
        String hash1 = QuickLookCache.sha256("test/path");
        String hash2 = QuickLookCache.sha256("test/path");
        assertEquals(hash1, hash2);
    }

    public void testExportCircuitSvg() throws Exception {
        File tempSvg = File.createTempFile("quicklook_test_", ".svg");
        try {
            QuickLookCache.exportCircuitSvg(testDig, tempSvg);
            assertTrue(tempSvg.exists());
            assertTrue(tempSvg.length() > 0);

            String content = new String(Files.readAllBytes(tempSvg.toPath()));
            assertTrue("Should contain svg opening tag", content.contains("<svg"));
            assertTrue("Should contain viewBox", content.contains("viewBox="));
            assertTrue("Should contain closing tag", content.contains("</svg>"));
            assertFalse("Should not contain grid", content.contains("grid"));
        } finally {
            tempSvg.delete();
        }
    }

    public void testExportCircuitSvgWithInMemoryCircuit() throws Exception {
        File tempSvg = File.createTempFile("quicklook_circuit_test_", ".svg");
        try {
            Circuit circuit = Circuit.loadCircuit(testDig, new ShapeFactory(new ElementLibrary(), true));
            QuickLookCache.exportCircuitSvg(circuit, tempSvg);
            assertTrue(tempSvg.exists());
            assertTrue(tempSvg.length() > 0);

            String content = new String(Files.readAllBytes(tempSvg.toPath()));
            assertTrue("Should contain svg opening tag", content.contains("<svg"));
            assertTrue("Should contain viewBox", content.contains("viewBox="));
            assertTrue("Should contain closing tag", content.contains("</svg>"));
        } finally {
            tempSvg.delete();
        }
    }

    public void testSVGExportRunHeadless() throws Exception {
        File tempSvg = File.createTempFile("quicklook_headless_", ".svg");
        try {
            int code = SVGExport.runHeadless(new String[]{testDig.getPath(), tempSvg.getPath()});
            assertEquals(0, code);
            assertTrue(tempSvg.exists());
            assertTrue(tempSvg.length() > 0);
        } finally {
            tempSvg.delete();
        }

        // Test single argument mode (exporting directly to hashed cache file)
        File cacheDir = QuickLookCache.getCacheDir();
        String key = QuickLookCache.getCacheKey(testDig);
        File cachedSvg = new File(cacheDir, key + ".svg");
        try {
            int code = SVGExport.runHeadless(new String[]{testDig.getPath()});
            assertEquals(0, code);
            assertTrue(cachedSvg.exists());
            assertTrue(cachedSvg.length() > 0);
        } finally {
            cachedSvg.delete();
        }
    }

    public void testCleanupCache() throws Exception {
        File tempDir = Files.createTempDirectory("ql_cache_cleanup_test").toFile();
        try {
            File recentFile = new File(tempDir, "recent.svg");
            File oldFile = new File(tempDir, "old.svg");
            File recentTmp = new File(tempDir, "recent.svg.tmp.123");
            File oldTmp = new File(tempDir, "old.svg.tmp.456");
            Files.write(recentFile.toPath(), "<svg></svg>".getBytes());
            Files.write(oldFile.toPath(), "<svg></svg>".getBytes());
            Files.write(recentTmp.toPath(), "<svg></svg>".getBytes());
            Files.write(oldTmp.toPath(), "<svg></svg>".getBytes());

            // Set oldFile modified to 20 days ago, oldTmp to 2 hours ago
            long twentyDaysAgo = System.currentTimeMillis() - (20L * 24L * 60L * 60L * 1000L);
            oldFile.setLastModified(twentyDaysAgo);
            long twoHoursAgo = System.currentTimeMillis() - (2L * 60L * 60L * 1000L);
            oldTmp.setLastModified(twoHoursAgo);

            long svgCutoff = System.currentTimeMillis() - (14L * 24L * 60L * 60L * 1000L);
            long tmpCutoff = System.currentTimeMillis() - (60L * 60L * 1000L);
            File[] files = tempDir.listFiles((dir, name) -> name.endsWith(".svg") || name.contains(".tmp."));
            assertNotNull(files);
            for (File f : files) {
                if (f.getName().contains(".tmp.")) {
                    if (f.lastModified() < tmpCutoff) {
                        f.delete();
                    }
                } else if (f.lastModified() < svgCutoff) {
                    f.delete();
                }
            }

            assertTrue(recentFile.exists());
            assertFalse(oldFile.exists());
            assertTrue(recentTmp.exists());
            assertFalse(oldTmp.exists());
        } finally {
            for (File f : tempDir.listFiles()) {
                f.delete();
            }
            tempDir.delete();
        }
    }
}
