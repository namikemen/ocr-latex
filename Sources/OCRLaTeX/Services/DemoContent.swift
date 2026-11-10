import AppKit

/// Renders a fake "screenshot" so the result panel can be inspected with `--demo`.
enum DemoContent {
    static func makeImage() -> NSImage {
        let size = NSSize(width: 520, height: 190)
        let image = NSImage(size: size)
        image.lockFocus()

        NSColor(calibratedWhite: 0.98, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()

        let text = "∫₀¹ x² dx = 1/3"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont(name: "Times New Roman", size: 54) ?? NSFont.systemFont(ofSize: 54),
            .foregroundColor: NSColor.black
        ]
        let textSize = text.size(withAttributes: attributes)
        text.draw(
            at: NSPoint(x: (size.width - textSize.width) / 2, y: (size.height - textSize.height) / 2),
            withAttributes: attributes
        )

        image.unlockFocus()
        return image
    }
}
