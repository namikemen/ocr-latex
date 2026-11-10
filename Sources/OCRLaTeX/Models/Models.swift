import AppKit
import Carbon.HIToolbox

// MARK: - Provider

enum ProviderKind: String, Codable, CaseIterable, Identifiable {
    case openAICompatible = "openai"
    case ollama = "ollama"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .openAICompatible: return "OpenAI-compatible"
        case .ollama: return "Ollama"
        }
    }
}

struct LLMProvider: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String = "New Provider"
    var kind: ProviderKind = .openAICompatible
    var baseURL: String = "https://api.openai.com/v1"
    var model: String = ""
    var temperature: Double = 0
    var maxTokens: Int = 4096

    /// Transient: lives in the Keychain, never in UserDefaults.
    var apiKey: String = ""

    enum CodingKeys: String, CodingKey {
        case id, name, kind, baseURL, model, temperature, maxTokens
    }

    var displayName: String {
        let m = model.isEmpty ? "no model" : model
        return "\(name) · \(m)"
    }

    static var seeds: [LLMProvider] {
        [
            LLMProvider(
                name: "Ollama (local)",
                kind: .ollama,
                baseURL: "http://localhost:11434",
                model: ""
            ),
            LLMProvider(
                name: "OpenAI",
                kind: .openAICompatible,
                baseURL: "https://api.openai.com/v1",
                model: "gpt-4o-mini"
            )
        ]
    }
}

// MARK: - Settings

struct AppSettings: Codable, Equatable {
    var prompt: String = AppSettings.defaultPrompt
    var hotkeyKeyCode: UInt32 = UInt32(kVK_ANSI_L)
    var hotkeyModifiers: UInt32 = UInt32(cmdKey | shiftKey)
    var pngScale: Double = 3
    var pngTransparent: Bool = true
    var pngPadding: Double = 12
    /// White glyphs, for pasting into dark slides/documents.
    var whiteText: Bool = false
    /// Collapse align/gather environments into one compact expression.
    var compactLatex: Bool = true
    /// Retry with the other configured providers when the selected one fails.
    var fallbackEnabled: Bool = true
    var launchAtLogin: Bool = false

    static let defaultPrompt = """
    You are a precise OCR engine that converts images of mathematical content into LaTeX.

    Rules:
    - Output ONLY LaTeX source. No markdown code fences, no explanation, no preamble.
    - Use a single display equation. For multi-line content use an aligned/gather environment.
    - Preserve every symbol exactly: subscripts, superscripts, fractions, roots, integrals, sums, \
    matrices, cases, accents, Greek letters and spacing.
    - Inline prose inside the equation must be wrapped in \\text{...}.
    - If the image contains several unrelated lines, separate them with \\\\ inside one align block.
    - Never invent content that is not visible in the image.
    """

    init() {}

    enum CodingKeys: String, CodingKey {
        case prompt, hotkeyKeyCode, hotkeyModifiers, pngScale, pngTransparent, pngPadding
        case whiteText, compactLatex, fallbackEnabled, launchAtLogin
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        prompt = (try? c.decodeIfPresent(String.self, forKey: .prompt)) ?? defaults.prompt
        hotkeyKeyCode = (try? c.decodeIfPresent(UInt32.self, forKey: .hotkeyKeyCode)) ?? defaults.hotkeyKeyCode
        hotkeyModifiers = (try? c.decodeIfPresent(UInt32.self, forKey: .hotkeyModifiers)) ?? defaults.hotkeyModifiers
        pngScale = (try? c.decodeIfPresent(Double.self, forKey: .pngScale)) ?? defaults.pngScale
        pngTransparent = (try? c.decodeIfPresent(Bool.self, forKey: .pngTransparent)) ?? defaults.pngTransparent
        pngPadding = (try? c.decodeIfPresent(Double.self, forKey: .pngPadding)) ?? defaults.pngPadding
        whiteText = (try? c.decodeIfPresent(Bool.self, forKey: .whiteText)) ?? defaults.whiteText
        compactLatex = (try? c.decodeIfPresent(Bool.self, forKey: .compactLatex)) ?? defaults.compactLatex
        fallbackEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .fallbackEnabled)) ?? defaults.fallbackEnabled
        launchAtLogin = (try? c.decodeIfPresent(Bool.self, forKey: .launchAtLogin)) ?? defaults.launchAtLogin
    }
}

// MARK: - Hotkey helpers

enum Hotkey {
    static let cmd = UInt32(cmdKey)
    static let shift = UInt32(shiftKey)
    static let option = UInt32(optionKey)
    static let control = UInt32(controlKey)

    static func describe(keyCode: UInt32, modifiers: UInt32) -> String {
        var s = ""
        if modifiers & control != 0 { s += "⌃" }
        if modifiers & option != 0 { s += "⌥" }
        if modifiers & shift != 0 { s += "⇧" }
        if modifiers & cmd != 0 { s += "⌘" }
        s += keyName(keyCode)
        return s
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= cmd }
        if flags.contains(.shift) { m |= shift }
        if flags.contains(.option) { m |= option }
        if flags.contains(.control) { m |= control }
        return m
    }

    static func keyName(_ code: UInt32) -> String {
        if let s = keyNames[code] { return s }
        return "key\(code)"
    }

    static let keyNames: [UInt32: String] = [
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H",
        34: "I", 38: "J", 40: "K", 37: "L", 46: "M", 45: "N", 31: "O", 35: "P",
        12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X",
        16: "Y", 6: "Z",
        18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8",
        25: "9", 29: "0",
        49: "Space", 36: "Return", 48: "Tab", 53: "Esc", 51: "Delete",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        27: "-", 24: "=", 33: "[", 30: "]", 41: ";", 39: "'", 43: ",",
        47: ".", 44: "/", 42: "\\", 50: "`"
    ]
}

// MARK: - Copy format

enum CopyFormat: CaseIterable, Identifiable {
    case raw
    case inline
    case display
    case paren
    case bracket

    var id: String { title }

    var title: String {
        switch self {
        case .raw: return "LaTeX"
        case .inline: return "$…$"
        case .display: return "$$…$$"
        case .paren: return "\\(…\\)"
        case .bracket: return "\\[…\\]"
        }
    }

    func wrap(_ latex: String) -> String {
        switch self {
        case .raw: return latex
        case .inline: return "$\(latex)$"
        case .display: return "$$\n\(latex)\n$$"
        case .paren: return "\\(\(latex)\\)"
        case .bracket: return "\\[\n\(latex)\n\\]"
        }
    }
}
