//
//  PreviewProvider.swift
//  DigitalQuickLook
//
//  Provides native Quick Look preview for Digital (.dig) circuit files on macOS.
//

import Foundation
import QuickLookUI
import UniformTypeIdentifiers
import CryptoKit
import CoreGraphics

@objc(DigitalQuickLookPreviewProvider)
public class PreviewProvider: QLPreviewProvider, QLPreviewingController {

    private static let cacheSubdir = "Library/Caches/com.neemann.digital.quicklook"

    private static let isDebugEnabled: Bool = {
        return ProcessInfo.processInfo.environment["DIGITAL_QL_DEBUG"] == "1"
    }()

    private static func logMsg(_ msg: String, isError: Bool = false) {
        guard isDebugEnabled || isError else { return }
        let dir = resolveCacheDirectory()
        let logFile = dir.appendingPathComponent("quicklook_debug.log")
        let str = "\(Date()): \(msg)\n"
        if let data = str.data(using: .utf8) {
            if let handle = try? FileHandle(forWritingTo: logFile) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: logFile)
            }
        }
    }

    public func providePreview(for request: QLFilePreviewRequest, completionHandler: @escaping (QLPreviewReply?, Error?) -> Void) {
        let digUrl = request.fileURL.resolvingSymlinksInPath().standardized
        let canonicalPath = digUrl.path
        Self.logMsg("providePreview: requested for \(canonicalPath)")

        // 1. Calculate SHA-256 hash of canonical absolute path
        let pathData = Data(canonicalPath.utf8)
        let hashBytes = SHA256.hash(data: pathData)
        let hashString = hashBytes.map { String(format: "%02x", $0) }.joined()

        // 2. Locate SVG cache file
        let cacheDir = Self.resolveCacheDirectory()
        let svgURL = cacheDir.appendingPathComponent("\(hashString).svg")
        Self.logMsg("svgURL: \(svgURL.path)")

        // 3. Compare modification times
        let digDate = Self.modificationDate(for: digUrl)
        var needGeneration = true

        if FileManager.default.fileExists(atPath: svgURL.path) {
            let svgDate = Self.modificationDate(for: svgURL)
            if svgDate >= digDate {
                needGeneration = false
            }
        }

        // 4. Generate on-demand if missing or outdated using bundled helper
        if needGeneration {
            Self.logMsg("needGeneration=true, calling generateSvg...")
            let success = Self.generateSvg(from: digUrl, to: svgURL)
            Self.logMsg("generateSvg returned: \(success)")
        }

        // 5. Load SVG data and return data-based HTML preview
        var svgData: Data?
        if FileManager.default.fileExists(atPath: svgURL.path) {
            svgData = try? Data(contentsOf: svgURL)
        }

        if let data = svgData,
           let svgString = String(data: data, encoding: .utf8),
           !svgString.isEmpty {
            let parsedSize = Self.parseSvgSize(from: svgString)
            let displaySize = Self.displaySize(for: parsedSize)
            let htmlString = Self.wrapSvgInHtml(svgString, title: digUrl.lastPathComponent)
            let htmlData = Data(htmlString.utf8)

            let reply = QLPreviewReply(dataOfContentType: .html, contentSize: displaySize) { _ in
                return htmlData
            }
            reply.title = digUrl.lastPathComponent
            Self.logMsg("providePreview: returning HTML reply successfully")
            completionHandler(reply, nil)
            return
        }

        Self.logMsg("providePreview: failed to find or generate SVG", isError: true)
        let error = NSError(domain: "de.neemann.digital.quicklook", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Quick Look preview could not be generated for \(digUrl.lastPathComponent)"
        ])
        completionHandler(nil, error)
    }

    // MARK: - HTML Wrapper & SVG Sizing

    private static let viewBoxRegex: NSRegularExpression? = {
        let pattern = #"viewBox\s*=\s*["']\s*([0-9.-]+)\s+([0-9.-]+)\s+([0-9.-]+)\s+([0-9.-]+)\s*["']"#
        return try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
    }()

    public static func parseSvgSize(from svgString: String) -> CGSize {
        // Match viewBox="minX minY width height"
        if let regex = viewBoxRegex,
           let match = regex.firstMatch(in: svgString, range: NSRange(svgString.startIndex..., in: svgString)) {
            if let wRange = Range(match.range(at: 3), in: svgString),
               let hRange = Range(match.range(at: 4), in: svgString),
               let width = Double(svgString[wRange]),
               let height = Double(svgString[hRange]),
               width > 10 && height > 10 {
                return CGSize(width: width, height: height)
            }
        }
        return CGSize(width: 800, height: 600)
    }

    public static func displaySize(for originalSize: CGSize) -> CGSize {
        var w = originalSize.width
        var h = originalSize.height
        if w <= 0 || h <= 0 {
            return CGSize(width: 800, height: 600)
        }
        let maxDim: CGFloat = 1100
        let minDim: CGFloat = 450
        let aspect = w / h
        if max(w, h) > maxDim {
            if w > h {
                w = maxDim
                h = maxDim / aspect
            } else {
                h = maxDim
                w = maxDim * aspect
            }
        } else if min(w, h) < minDim {
            if w < h {
                w = minDim
                h = minDim / aspect
            } else {
                h = minDim
                w = minDim * aspect
            }
        }
        return CGSize(width: round(w), height: round(h))
    }

    public static func wrapSvgInHtml(_ svgContent: String, title: String) -> String {
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>\(title)</title>
        <style>
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }
        html, body {
            width: 100vw;
            height: 100vh;
            overflow: hidden;
            background-color: #ffffff;
            display: flex;
            align-items: center;
            justify-content: center;
        }
        svg {
            max-width: 95vw;
            max-height: 95vh;
            width: 100% !important;
            height: 100% !important;
            object-fit: contain;
            display: block;
            margin: auto;
        }
        </style>
        </head>
        <body>
        \(svgContent)
        </body>
        </html>
        """
    }

    // MARK: - Cache Directory Resolution

    public static func resolveCacheDirectory() -> URL {
        var baseHome: URL?

        // Inside sandboxed extension, getpwuid gives actual user home outside container
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            let homePath = String(cString: dir)
            if !homePath.isEmpty {
                baseHome = URL(fileURLWithPath: homePath)
            }
        }

        if baseHome == nil {
            baseHome = FileManager.default.homeDirectoryForCurrentUser
        }

        let cacheDir = baseHome!.appendingPathComponent(cacheSubdir)
        if !FileManager.default.fileExists(atPath: cacheDir.path) {
            try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true, attributes: nil)
        }
        return cacheDir
    }

    // MARK: - File Timestamp

    public static func modificationDate(for url: URL) -> Date {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let date = attrs[.modificationDate] as? Date else {
            return Date.distantPast
        }
        return date
    }

    // MARK: - Bundled Helper Execution

    @_silgen_name("jni_export_circuit_svg")
    private static func jni_export_circuit_svg(
        _ jvmDylibPath: UnsafePointer<CChar>?,
        _ jarPath: UnsafePointer<CChar>?,
        _ digPath: UnsafePointer<CChar>?,
        _ svgPath: UnsafePointer<CChar>?,
        _ errBuf: UnsafeMutablePointer<CChar>?,
        _ errBufLen: Int32
    ) -> Int32

    public static func findJvmAndJar() -> (jvm: URL, jar: URL)? {
        let appexUrl = Bundle(for: PreviewProvider.self).bundleURL
        let pluginsDir = appexUrl.deletingLastPathComponent()
        let contentsDir = pluginsDir.deletingLastPathComponent()

        let jvmInApp = contentsDir.appendingPathComponent("runtime/Contents/Home/lib/server/libjvm.dylib")
        let jarInApp = contentsDir.appendingPathComponent("app/Digital.jar")
        if FileManager.default.fileExists(atPath: jvmInApp.path) && FileManager.default.fileExists(atPath: jarInApp.path) {
            logMsg("findJvmAndJar: found inside app bundle: \(jvmInApp.path)")
            return (jvmInApp, jarInApp)
        }

        let stdJvm = URL(fileURLWithPath: "/Applications/Digital.app/Contents/runtime/Contents/Home/lib/server/libjvm.dylib")
        let stdJar = URL(fileURLWithPath: "/Applications/Digital.app/Contents/app/Digital.jar")
        if FileManager.default.fileExists(atPath: stdJvm.path) && FileManager.default.fileExists(atPath: stdJar.path) {
            logMsg("findJvmAndJar: found in /Applications: \(stdJvm.path)")
            return (stdJvm, stdJar)
        }

        logMsg("findJvmAndJar: not found")
        return nil
    }

    public static func findBundledCli() -> URL? {
        // 1. Environment override (for testing)
        if let envCli = ProcessInfo.processInfo.environment["DIGITAL_CLI"] {
            let url = URL(fileURLWithPath: envCli)
            if FileManager.default.fileExists(atPath: url.path) {
                logMsg("findBundledCli: found DIGITAL_CLI env override: \(url.path)")
                return url
            }
        }

        // 2. Resolve relative to PreviewProvider bundle:
        // DigitalQuickLook.appex is located in Digital.app/Contents/PlugIns/
        let appexUrl = Bundle(for: PreviewProvider.self).bundleURL
        let pluginsDir = appexUrl.deletingLastPathComponent()
        let contentsDir = pluginsDir.deletingLastPathComponent()

        let cliInApp = contentsDir.appendingPathComponent("MacOS/digital-cli")
        logMsg("findBundledCli: checking cliInApp: \(cliInApp.path), fileExists=\(FileManager.default.fileExists(atPath: cliInApp.path))")
        if FileManager.default.fileExists(atPath: cliInApp.path) {
            return cliInApp
        }

        let binInApp = contentsDir.appendingPathComponent("app/bin/digital")
        if FileManager.default.fileExists(atPath: binInApp.path) {
            return binInApp
        }

        // 3. Fallback to /Applications/Digital.app
        let standardAppCli = URL(fileURLWithPath: "/Applications/Digital.app/Contents/MacOS/digital-cli")
        if FileManager.default.fileExists(atPath: standardAppCli.path) {
            logMsg("findBundledCli: found standardAppCli: \(standardAppCli.path)")
            return standardAppCli
        }

        let standardAppBin = URL(fileURLWithPath: "/Applications/Digital.app/Contents/app/bin/digital")
        if FileManager.default.fileExists(atPath: standardAppBin.path) {
            logMsg("findBundledCli: found standardAppBin: \(standardAppBin.path)")
            return standardAppBin
        }

        logMsg("findBundledCli: could not find any CLI executable")
        return nil
    }

    public static func generateSvg(from digUrl: URL, to svgUrl: URL) -> Bool {
        let dir = svgUrl.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        }

        // Method A: In-process JNI (sandbox-safe, no posix_spawn restrictions)
        if let (jvmUrl, jarUrl) = findJvmAndJar() {
            logMsg("generateSvg: invoking JNI with jvm=\(jvmUrl.path), jar=\(jarUrl.path), in=\(digUrl.path), out=\(svgUrl.path)")
            var errBuf = [CChar](repeating: 0, count: 512)
            let res = jni_export_circuit_svg(jvmUrl.path, jarUrl.path, digUrl.path, svgUrl.path, &errBuf, Int32(errBuf.count))
            let errMsg = String(cString: errBuf)
            logMsg("generateSvg: JNI returned code=\(res), err=\(errMsg)", isError: res != 0)
            if res == 0 && FileManager.default.fileExists(atPath: svgUrl.path) {
                return true
            }
        }

        // Method B: Subprocess fallback via CLI (when running unsandboxed or in test environments)
        guard let cliUrl = findBundledCli() else {
            logMsg("generateSvg: cliUrl is nil", isError: true)
            return false
        }
        logMsg("generateSvg: invoking CLI \(cliUrl.path) with in=\(digUrl.path) out=\(svgUrl.path)")

        let process = Process()
        process.executableURL = cliUrl
        process.arguments = ["export-headless", "-in", digUrl.path, "-out", svgUrl.path]

        var env = ProcessInfo.processInfo.environment
        env["JAVA_AWT_HEADLESS"] = "true"
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            logMsg("generateSvg: exit code=\(process.terminationStatus) output=\(output)", isError: process.terminationStatus != 0)
            if process.terminationStatus == 0 && FileManager.default.fileExists(atPath: svgUrl.path) {
                return true
            }
        } catch {
            logMsg("generateSvg: process.run failed: \(error)", isError: true)
        }

        // Fallback: try "svg" command instead of "export-headless"
        logMsg("generateSvg: trying fallback svg command...")
        let fallbackProcess = Process()
        fallbackProcess.executableURL = cliUrl
        fallbackProcess.arguments = ["svg", "-dig", digUrl.path, "-svg", svgUrl.path]
        fallbackProcess.environment = env

        do {
            try fallbackProcess.run()
            fallbackProcess.waitUntilExit()
            let ok = fallbackProcess.terminationStatus == 0 && FileManager.default.fileExists(atPath: svgUrl.path)
            logMsg("generateSvg: fallback exited with \(fallbackProcess.terminationStatus), fileExists=\(ok)", isError: !ok)
            return ok
        } catch {
            logMsg("generateSvg: fallback process.run failed: \(error)", isError: true)
            return false
        }
    }
}
