import AppKit
import WebKit
import SwiftUI

enum AppResources {
    static func url(_ name: String, ext: String) -> URL? {
        if let url = Bundle.main.url(forResource: name, withExtension: ext) {
            return url
        }
        let fm = FileManager.default
        var candidates: [String] = []
        candidates.append(fm.currentDirectoryPath + "/Sources/OCRLaTeX/Resources/\(name).\(ext)")
        if let exec = Bundle.main.executableURL {
            let base = exec.deletingLastPathComponent()
            candidates.append(base.appendingPathComponent("../../Sources/OCRLaTeX/Resources/\(name).\(ext)").standardized.path)
            candidates.append(base.appendingPathComponent("\(name).\(ext)").path)
            candidates.append(base.deletingLastPathComponent().appendingPathComponent("Resources/\(name).\(ext)").path)
        }
        for path in candidates where fm.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }
}

/// Offscreen WKWebView + MathJax (SVG output). Renders previews and exports
/// self-contained SVG that we rasterise with AppKit at any scale.
@MainActor
final class MathRenderer: NSObject, ObservableObject {
    static let shared = MathRenderer()

    let webView: WKWebView
    @Published private(set) var isReady = false
    private var rendererError: String?

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.suppressesIncrementalRendering = true
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 260), configuration: config)
        super.init()
        load()
    }

    private func load() {
        guard let url = AppResources.url("template", ext: "html") else {
            rendererError = "Missing template.html resource"
            NSLog("OCRLaTeX: \(rendererError!)")
            return
        }
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    func waitUntilReady(timeout: TimeInterval = 25) async {
        if isReady { return }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = try? await webView.evaluateJavaScript("Boolean(window.__mjReady)"),
               let ready = value as? Bool, ready {
                isReady = true
                return
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func jsLiteral(_ string: String) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: [string], options: [.fragmentsAllowed]),
           let text = String(data: data, encoding: .utf8) {
            return String(text.dropFirst().dropLast())
        }
        return "\"\""
    }

    @discardableResult
    func preview(latex: String, transparentBackground: Bool, whiteText: Bool) async -> Bool {
        await waitUntilReady()
        let backdrop: String
        if whiteText {
            backdrop = transparentBackground ? "checkerDark" : "dark"
        } else {
            backdrop = transparentBackground ? "checker" : "white"
        }
        let color = whiteText ? "white" : "black"
        let script = "preview(\(jsLiteral(latex)), \(jsLiteral(backdrop)), \(jsLiteral(color)))"
        guard let value = try? await webView.evaluateJavaScript(script),
              let dict = value as? [String: Any] else { return false }
        return (dict["ok"] as? Bool) ?? false
    }

    /// Renders `latex` and returns PNG data at `scale`x with optional transparency.
    func pngData(
        latex: String,
        scale: CGFloat = 3,
        padding: CGFloat = 12,
        transparent: Bool = true,
        whiteText: Bool = false
    ) async -> Data? {
        await waitUntilReady()
        let color = whiteText ? "white" : "black"
        let script = "svgFor(\(jsLiteral(latex)), \(jsLiteral(color)))"
        guard let value = try? await webView.evaluateJavaScript(script),
              let dict = value as? [String: Any],
              (dict["ok"] as? Bool) == true,
              let svg = dict["svg"] as? String,
              let svgData = svg.data(using: .utf8),
              let vectorImage = NSImage(data: svgData) else {
            return nil
        }

        var size = vectorImage.size
        if size.width < 1 || size.height < 1 {
            size = NSSize(width: max(1, size.width), height: max(1, size.height))
        }

        let pad = max(0, padding)
        let pointSize = NSSize(width: size.width + pad * 2, height: size.height + pad * 2)
        let pixelWidth = Int(ceil(pointSize.width * scale))
        let pixelHeight = Int(ceil(pointSize.height * scale))
        guard pixelWidth > 0, pixelHeight > 0,
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: pixelWidth,
                pixelsHigh: pixelHeight,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
              ) else { return nil }

        rep.size = pointSize

        NSGraphicsContext.saveGraphicsState()
        if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = ctx
            ctx.imageInterpolation = .high
            ctx.shouldAntialias = true
            if !transparent {
                NSColor.white.setFill()
                NSRect(origin: .zero, size: pointSize).fill()
            }
            vectorImage.draw(in: NSRect(x: pad, y: pad, width: size.width, height: size.height))
        }
        NSGraphicsContext.restoreGraphicsState()

        return rep.representation(using: .png, properties: [:])
    }
}

// MARK: - SwiftUI bridge

struct MathPreviewView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView {
        MathRenderer.shared.webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
