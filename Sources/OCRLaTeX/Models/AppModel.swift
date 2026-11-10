import AppKit
import Combine
import ServiceManagement

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    // MARK: Published state

    @Published var providers: [LLMProvider] = [] { didSet { saveProvidersIfLoaded() } }
    @Published var settings: AppSettings = AppSettings() { didSet { saveSettingsIfLoaded() } }
    @Published var activeProviderID: UUID? {
        didSet { UserDefaults.standard.set(activeProviderID?.uuidString, forKey: Keys.activeProvider) }
    }

    @Published var latex: String = "" { didSet { schedulePreview() } }
    @Published var capturedImage: NSImage?
    @Published var isBusy = false
    @Published var busyLabel = ""
    @Published var lastError: String?
    @Published var showPermissionHelp = false
    @Published var toast: String?
    @Published var needsSetup = false
    /// Which provider actually produced the current result (differs from the
    /// selected one when the fallback chain was used).
    @Published var lastUsedProviderName: String?

    // MARK: Private

    private enum Keys {
        static let providers = "providers.v1"
        static let settings = "settings.v1"
        static let activeProvider = "activeProvider.v1"
    }

    private var didLoad = false
    private var savedSecrets: [UUID: String] = [:]
    private var registeredHotkey: (UInt32, UInt32)?
    private var appliedLaunchAtLogin: Bool?
    private var previewTask: Task<Void, Never>?
    private var secretsTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var lastPreviewSignature: String = ""

    private init() {
        load()
        didLoad = true
    }

    // MARK: Computed

    var activeProvider: LLMProvider? {
        if let id = activeProviderID, let match = providers.first(where: { $0.id == id }) {
            return match
        }
        return providers.first
    }

    var isConfigured: Bool {
        guard let provider = activeProvider else { return false }
        return !provider.model.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: Lifecycle

    func bootstrap() {
        registerHotkey(force: true)
        applyLaunchAtLogin()
        NSLog("OCRLaTeX: shortcut %@ (%@)", Hotkey.describe(keyCode: settings.hotkeyKeyCode, modifiers: settings.hotkeyModifiers), HotkeyManager.shared.registered ? "registered" : "FAILED")
        Task { await MathRenderer.shared.waitUntilReady() }
        needsSetup = !isConfigured
    }

    func registerHotkey(force: Bool = false) {
        let current = (settings.hotkeyKeyCode, settings.hotkeyModifiers)
        if !force, let last = registeredHotkey, last == current, HotkeyManager.shared.registered { return }
        registeredHotkey = current
        let ok = HotkeyManager.shared.register(
            keyCode: settings.hotkeyKeyCode,
            modifiers: settings.hotkeyModifiers
        )
        if !ok {
            lastError = "The shortcut \(Hotkey.describe(keyCode: settings.hotkeyKeyCode, modifiers: settings.hotkeyModifiers)) is already used by another app. Pick a different one in Settings."
        } else if lastError?.hasPrefix("The shortcut") == true {
            lastError = nil
        }
    }

    // MARK: Capture flow

    func startCaptureFlow() {
        Task { await captureFlow(fromClipboard: false) }
    }

    func captureFromClipboard() {
        Task { await captureFlow(fromClipboard: true) }
    }

    private func captureFlow(fromClipboard: Bool) async {
        guard !isBusy else { return }
        lastError = nil
        showPermissionHelp = false

        if fromClipboard {
            guard let image = ScreenCapture.imageFromPasteboard() else {
                lastError = "No image found on the clipboard."
                PanelController.shared.show()
                return
            }
            capturedImage = image
            latex = ""
            PanelController.shared.show()
            await runOCR()
            return
        }

        if !ScreenCapture.hasPermission() {
            _ = ScreenCapture.requestPermission()
            showPermissionHelp = true
            lastError = "Screen Recording permission is required. Enable “OCR LaTeX” in System Settings → Privacy & Security → Screen Recording, then try again."
            PanelController.shared.show()
            return
        }

        guard let image = await ScreenCapture.captureInteractiveRegion() else {
            return // cancelled with Esc
        }
        capturedImage = image
        latex = ""
        PanelController.shared.show()
        await runOCR()
    }

    func runOCR() async {
        guard let image = capturedImage else { return }
        guard let active = activeProvider else {
            lastError = "No LLM provider configured. Open Settings and add one."
            PanelController.shared.show()
            return
        }

        let configured = providers.filter { !$0.model.trimmingCharacters(in: .whitespaces).isEmpty }
        let chain = Self.ocrChain(providers: providers, active: active, fallback: settings.fallbackEnabled)

        guard !chain.isEmpty else {
            if configured.isEmpty {
                lastError = "No provider has a model selected. Open Settings → Providers."
            } else {
                lastError = "Provider “\(active.name)” has no model selected. Open Settings → Providers."
            }
            PanelController.shared.show()
            return
        }

        isBusy = true
        busyLabel = "Reading \(chain[0].name)…"
        lastError = nil
        showPermissionHelp = false
        lastUsedProviderName = nil

        var failures: [String] = []
        var produced: String?

        for (offset, provider) in chain.enumerated() {
            if offset > 0 {
                busyLabel = "Trying \(provider.name)… (\(offset + 1)/\(chain.count))"
            }
            do {
                let result = try await LLMService.ocr(
                    image: image,
                    provider: provider,
                    prompt: settings.prompt,
                    compact: settings.compactLatex
                )
                produced = result
                lastUsedProviderName = provider.name
                if provider.id != active.id {
                    showToast("\(active.name) failed — used \(provider.name)")
                }
                break
            } catch {
                failures.append("\(provider.name): \(error.localizedDescription)")
            }
        }

        if let produced {
            latex = produced
        } else if failures.count == 1 {
            lastError = failures[0]
        } else {
            lastError = "All \(chain.count) providers failed.\n" + failures.joined(separator: "\n")
        }

        isBusy = false
        busyLabel = ""
    }

    func rerun() {
        Task { await runOCR() }
    }

    /// Providers to try, in order: the selected one first, then (optionally)
    /// every other provider that has a model. Pure so `--llmtest` can verify it.
    static func ocrChain(providers: [LLMProvider], active: LLMProvider?, fallback: Bool) -> [LLMProvider] {
        let usable = providers.filter { !$0.model.trimmingCharacters(in: .whitespaces).isEmpty }
        var chain: [LLMProvider] = []
        if let active, !active.model.trimmingCharacters(in: .whitespaces).isEmpty {
            chain.append(active)
        }
        if fallback {
            for provider in usable where !chain.contains(where: { $0.id == provider.id }) {
                chain.append(provider)
            }
        }
        return chain
    }

    // MARK: Preview

    private func schedulePreview() {
        previewTask?.cancel()
        let current = latex
        let transparent = settings.pngTransparent
        let white = settings.whiteText
        previewTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard !Task.isCancelled else { return }
            let signature = "\(transparent)|\(white)|\(current)"
            if let self, self.lastPreviewSignature == signature { return }
            await MathRenderer.shared.preview(latex: current, transparentBackground: transparent, whiteText: white)
            self?.lastPreviewSignature = signature
        }
    }

    func refreshPreview() async {
        lastPreviewSignature = ""
        await MathRenderer.shared.preview(
            latex: latex,
            transparentBackground: settings.pngTransparent,
            whiteText: settings.whiteText
        )
        lastPreviewSignature = "\(settings.pngTransparent)|\(settings.whiteText)|\(latex)"
    }

    // MARK: Copy

    func copy(_ format: CopyFormat) {
        guard !latex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Clipboard.copy(text: format.wrap(latex))
        showToast("Copied \(format.title)")
    }

    func copyPNG() {
        guard !latex.isEmpty else { return }
        Task {
            isBusy = true
            busyLabel = "Rendering PNG…"
            let data = await MathRenderer.shared.pngData(
                latex: latex,
                scale: settings.pngScale,
                padding: settings.pngPadding,
                transparent: settings.pngTransparent,
                whiteText: settings.whiteText
            )
            isBusy = false
            busyLabel = ""
            if let data {
                Clipboard.copy(pngData: data)
                showToast(settings.pngTransparent ? "Transparent PNG copied" : "PNG copied")
            } else {
                lastError = "Could not render the formula as an image."
            }
        }
    }

    func savePNGToFile() {
        guard !latex.isEmpty else { return }
        Task {
            isBusy = true
            busyLabel = "Rendering PNG…"
            let data = await MathRenderer.shared.pngData(
                latex: latex,
                scale: settings.pngScale,
                padding: settings.pngPadding,
                transparent: settings.pngTransparent,
                whiteText: settings.whiteText
            )
            isBusy = false
            busyLabel = ""
            guard let data else {
                lastError = "Could not render the formula as an image."
                return
            }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.png]
            panel.nameFieldStringValue = "formula.png"
            if panel.runModal() == .OK, let url = panel.url {
                try? data.write(to: url)
                showToast("Saved \(url.lastPathComponent)")
            }
        }
    }

    func showToast(_ text: String) {
        toastTask?.cancel()
        toast = text
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    // MARK: Provider helpers

    func providerIndex(for id: UUID) -> Int? {
        providers.firstIndex(where: { $0.id == id })
    }

    func addProvider() {
        var provider = LLMProvider(name: "New Provider")
        provider.model = ""
        providers.append(provider)
        activeProviderID = provider.id
    }

    func duplicateProvider(_ id: UUID) {
        guard let index = providerIndex(for: id) else { return }
        var copy = providers[index]
        copy.id = UUID()
        copy.name += " copy"
        providers.insert(copy, at: index + 1)
    }

    func removeProvider(_ id: UUID) {
        Keychain.delete(account: id.uuidString)
        savedSecrets[id] = nil
        providers.removeAll { $0.id == id }
        if activeProviderID == id {
            activeProviderID = providers.first?.id
        }
    }

    func updateProvider(_ provider: LLMProvider) {
        guard let index = providerIndex(for: provider.id) else { return }
        providers[index] = provider
    }

    func fetchModels(for provider: LLMProvider) async throws -> [String] {
        try await LLMService.listModels(provider: provider)
    }

    func testProvider(_ provider: LLMProvider) async throws -> String {
        try await LLMService.ping(provider: provider)
    }

    // MARK: Persistence

    private func load() {
        let defaults = UserDefaults.standard

        if let data = defaults.data(forKey: Keys.providers),
           let list = try? JSONDecoder().decode([LLMProvider].self, from: data) {
            providers = list
        }
        if providers.isEmpty {
            providers = LLMProvider.seeds
        }

        if let data = defaults.data(forKey: Keys.settings),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = decoded
        }

        if let idString = defaults.string(forKey: Keys.activeProvider),
           let id = UUID(uuidString: idString),
           providers.contains(where: { $0.id == id }) {
            activeProviderID = id
        } else {
            activeProviderID = providers.first?.id
        }

        for index in providers.indices {
            let account = providers[index].id.uuidString
            let secret = Keychain.get(account: account) ?? ""
            providers[index].apiKey = secret
            savedSecrets[providers[index].id] = secret
        }
        didLoad = true
    }

    private func saveProvidersIfLoaded() {
        guard didLoad else { return }
        if let data = try? JSONEncoder().encode(providers) {
            UserDefaults.standard.set(data, forKey: Keys.providers)
        }
        // Keychain writes are debounced: the field updates on every keystroke.
        secretsTask?.cancel()
        secretsTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            self?.flushSecrets()
        }
    }

    func flushSecrets() {
        guard didLoad else { return }
        for provider in providers where savedSecrets[provider.id] != provider.apiKey {
            Keychain.set(provider.apiKey, account: provider.id.uuidString)
            savedSecrets[provider.id] = provider.apiKey
        }
    }

    private func saveSettingsIfLoaded() {
        guard didLoad else { return }
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Keys.settings)
        }
        registerHotkey()
        applyLaunchAtLogin()
        schedulePreview()
    }

    // MARK: Launch at login

    private func applyLaunchAtLogin() {
        guard #available(macOS 13.0, *) else { return }
        if appliedLaunchAtLogin == settings.launchAtLogin { return }
        appliedLaunchAtLogin = settings.launchAtLogin
        let service = SMAppService.mainApp
        do {
            if settings.launchAtLogin {
                if service.status != .enabled { try service.register() }
            } else {
                if service.status == .enabled { try service.unregister() }
            }
        } catch {
            NSLog("OCRLaTeX: launch-at-login failed: \(error)")
        }
    }
}
