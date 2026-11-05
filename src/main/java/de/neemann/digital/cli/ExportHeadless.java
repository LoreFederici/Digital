/*
 * Copyright (c) 2026 Helmut Neemann.
 * Use of this source code is governed by the GPL v3 license
 * that can be found in the LICENSE file.
 */
package de.neemann.digital.cli;

import de.neemann.digital.cli.cli.Argument;
import de.neemann.digital.cli.cli.BasicCommand;
import de.neemann.digital.cli.cli.CLIException;
import de.neemann.digital.gui.QuickLookCache;

import java.io.File;
import java.io.IOException;

/**
 * Headless SVG export command for Quick Look and external tools.
 */
public class ExportHeadless extends BasicCommand {
    private final Argument<String> input;
    private final Argument<String> output;

    /**
     * Creates a new instance.
     */
    public ExportHeadless() {
        super("export-headless");
        input = addArgument(new Argument<>("in", "", false));
        output = addArgument(new Argument<>("out", "", true));
    }

    @Override
    protected void execute() throws CLIException {
        try {
            File inputFile = new File(input.get());
            String outPath = output.get();
            if (outPath == null || outPath.trim().isEmpty()) {
                QuickLookCache.exportToCache(inputFile);
            } else {
                QuickLookCache.exportCircuitSvg(inputFile, new File(outPath));
            }
        } catch (IOException e) {
            throw new CLIException("Error exporting SVG: " + e.getMessage(), e);
        }
    }

    /**
     * Executes headless export and returns status code.
     *
     * @param args arguments (&lt;input.dig&gt; [&lt;output.svg&gt;])
     * @return exit code (0 for success)
     */
    public static int runHeadless(String[] args) {
        if (args.length < 1) {
            System.err.println("Usage: ExportHeadless <input.dig> [output.svg]");
            return 1;
        }
        try {
            File inputFile = new File(args[0]);
            if (args.length == 1 || args[1] == null || args[1].trim().isEmpty()) {
                QuickLookCache.exportToCache(inputFile);
            } else {
                QuickLookCache.exportCircuitSvg(inputFile, new File(args[1]));
            }
            return 0;
        } catch (Exception e) {
            System.err.println("Export failed: " + e.getMessage());
            e.printStackTrace(System.err);
            return 2;
        }
    }

    /**
     * Standalone main method taking &lt;input.dig&gt; &lt;output.svg&gt;.
     *
     * @param args arguments
     */
    public static void main(String[] args) {
        int code = runHeadless(args);
        if (code != 0) {
            System.exit(code);
        }
    }
}
