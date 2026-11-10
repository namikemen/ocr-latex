import AppKit
import SwiftUI
import WebKit

@MainActor
final class PanelController {
    static let shared = PanelController()

    private var panel: NSPanel?
    private var hasPositioned = false

    func show() {
        let panel = self.panel ?? build()
        self.panel = panel

        NSApp.activate(ignoringOtherApps: true)
        if !hasPositioned {
            position(panel)
            hasPositioned = true
        }
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel?.orderOut(nil)
    }

    /// Development helper: rasterises the panel content view to a PNG.
    func snapshotSelf(to path: String) {
        guard let panel, let view = panel.contentView else {
            print("snapshot: no panel")
            return
        }
        // An inactive window draws label/text colour dimmed, which makes the
        // LaTeX editor look disabled in the PNG. Activate first.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        view.layoutSubtreeIfNeeded()
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: path))
                print("snapshot: wrote \(path) \(rep.pixelsWide)x\(rep.pixelsHigh)")
            }
        }

        // Also snapshot the web view on its own: cacheDisplay can leave stale
        // compositing layers behind, which makes verification misleading.
        let webView = MathRenderer.shared.webView
        webView.evaluateJavaScript("JSON.stringify({children: document.getElementById('preview').childElementCount, mjx: document.querySelectorAll('mjx-container').length, html: document.getElementById('preview').innerHTML.slice(0,80)})") { value, _ in
            if let value { print("snapshot: DOM \(value)") }
            let config = WKSnapshotConfiguration()
            config.afterScreenUpdates = true
            webView.takeSnapshot(with: config) { image, error in
                if let image,
                   let tiff = image.tiffRepresentation,
                   let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: path + ".webview.png"))
                    print("snapshot: wrote web view")
                } else {
                    print("snapshot: web view failed \(String(describing: error))")
                }
                NSApp.terminate(nil)
            }
        }
    }

    private func build() -> NSPanel {
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 700),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "OCR LaTeX"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 580, height: 560)
        panel.backgroundColor = .windowBackgroundColor

        let host = NSHostingView(rootView: ResultView().environmentObject(AppModel.shared))
        host.translatesAutoresizingMaskIntoConstraints = true
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        panel.setContentSize(NSSize(width: 660, height: 700))
        return panel
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else {
            panel.center()
            return
        }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2 + 40
        )
        panel.setFrameOrigin(origin)
    }
}

/// NSPanel subclass that can always become key (needed for text editing).
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
