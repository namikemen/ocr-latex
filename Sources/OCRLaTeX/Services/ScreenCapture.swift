import AppKit
import CoreGraphics

enum ScreenCapture {
    /// True when the app already has Screen Recording permission.
    static func hasPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Triggers the system prompt once. Returns the (possibly stale) permission state.
    @discardableResult
    static func requestPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static func openPermissionSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    /// Runs the native interactive region selector. Returns nil when cancelled.
    static func captureInteractiveRegion() async -> NSImage? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let path = NSTemporaryDirectory() + "ocrlatex-capture-\(UUID().uuidString).png"
                defer { try? FileManager.default.removeItem(atPath: path) }

                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                // -i interactive, -x no sound, -o no shadow, -t png
                process.arguments = ["-i", "-x", "-o", "-t", "png", path]

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: nil)
                    return
                }
                process.waitUntilExit()

                guard process.terminationStatus == 0,
                      let image = NSImage(contentsOfFile: path),
                      image.size.width > 1, image.size.height > 1 else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: image)
            }
        }
    }

    static func imageFromPasteboard() -> NSImage? {
        let pb = NSPasteboard.general
        if let objects = pb.readObjects(forClasses: [NSImage.self], options: nil),
           let image = objects.first as? NSImage {
            return image
        }
        if let data = pb.data(forType: .png), let image = NSImage(data: data) {
            return image
        }
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            for url in urls {
                if let image = NSImage(contentsOf: url) { return image }
            }
        }
        return nil
    }
}
