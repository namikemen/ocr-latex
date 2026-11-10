import SwiftUI
import AppKit

// MARK: - Settings window

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "OCR LaTeX Settings"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView().environmentObject(AppModel.shared))
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Development helper used by `--settings-snapshot`.
    func snapshotSelf(to path: String) {
        guard let window, let view = window.contentView else { return }
        view.layoutSubtreeIfNeeded()
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: path))
                print("settings snapshot: wrote \(path) \(rep.pixelsWide)x\(rep.pixelsHigh)")
            }
        }
        NSApp.terminate(nil)
    }
}

// MARK: - Hotkey recorder

struct HotkeyRecorderView: NSViewRepresentable {
    @Binding var shortcut: (UInt32, UInt32)

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.keyCode = shortcut.0
        view.modifiers = shortcut.1
        view.onChange = { code, mods in
            shortcut = (code, mods)
        }
        return view
    }

    func updateNSView(_ nsView: RecorderView, context: Context) {
        if !nsView.isRecording {
            nsView.keyCode = shortcut.0
            nsView.modifiers = shortcut.1
        }
        nsView.onChange = { code, mods in
            shortcut = (code, mods)
        }
        nsView.needsDisplay = true
    }
}

final class RecorderView: NSView {
    var keyCode: UInt32 = UInt32(0x25)
    var modifiers: UInt32 = 0
    var onChange: ((UInt32, UInt32) -> Void)?

    private(set) var isRecording = false {
        didSet { needsDisplay = true }
    }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        isRecording = true
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        needsDisplay = true
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        if event.keyCode == 53 { // esc cancels
            isRecording = false
            window?.makeFirstResponder(nil)
            return
        }
        let mods = Hotkey.carbonModifiers(from: event.modifierFlags)
        guard mods != 0 else {
            NSSound.beep()
            return
        }
        keyCode = UInt32(event.keyCode)
        modifiers = mods
        isRecording = false
        onChange?(keyCode, modifiers)
        window?.makeFirstResponder(nil)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        let fill = isRecording
            ? NSColor.controlAccentColor.withAlphaComponent(0.20)
            : NSColor.quaternaryLabelColor.withAlphaComponent(0.35)
        fill.setFill()
        path.fill()

        let stroke = isRecording ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor
        stroke.setStroke()
        path.lineWidth = 1
        path.stroke()

        let text = isRecording ? "Press keys…" : Hotkey.describe(keyCode: keyCode, modifiers: modifiers)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.labelColor
        ]
        let size = text.size(withAttributes: attributes)
        let point = NSPoint(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2
        )
        text.draw(at: point, withAttributes: attributes)
    }
}
