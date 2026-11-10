import SwiftUI
import AppKit

// MARK: - Shared card chrome

/// A titled card. `Form`'s grouped style kept centring bordered fields and
/// rendering their prompts as stray trailing labels, so the settings panes are
/// built from explicit cards instead.
struct SettingsCard<Content: View>: View {
    private let title: String
    private let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(.secondary)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }
}

/// Label above a full-width control (text fields, editors).
struct FormField<Content: View>: View {
    private let title: String
    private let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Label on the left, control on the right (pickers, toggles, sliders).
struct FormRow<Content: View>: View {
    private let title: String
    private let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
            Spacer(minLength: 12)
            content
        }
        .frame(maxWidth: .infinity)
    }
}

struct Hint: View {
    private let text: String
    private let color: Color

    init(_ text: String, color: Color = .secondary) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Settings root

final class SettingsTabState: ObservableObject {
    @Published var tab: Int
    init(tab: Int = 0) { self.tab = tab }
}

struct SettingsView: View {
    /// Set before the settings window is created (used by UI snapshots).
    static var initialTab: Int = 0

    @StateObject private var state = SettingsTabState(tab: SettingsView.initialTab)

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            if state.tab == 0 {
                GeneralSettingsView()
            } else {
                ProvidersSettingsView()
            }
        }
        .frame(minWidth: 700, minHeight: 520)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var tabBar: some View {
        HStack(spacing: 6) {
            tabButton("General", index: 0)
            tabButton("Providers", index: 1)
            Spacer()
            Text("OCR LaTeX")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func tabButton(_ title: String, index: Int) -> some View {
        Button {
            state.tab = index
        } label: {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(state.tab == index ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(
                            state.tab == index ? Color.accentColor.opacity(0.55) : Color.clear,
                            lineWidth: 1
                        )
                )
                .foregroundStyle(state.tab == index ? Color.primary : Color.secondary)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @EnvironmentObject private var model: AppModel

    private var shortcutBinding: Binding<(UInt32, UInt32)> {
        Binding(
            get: { (model.settings.hotkeyKeyCode, model.settings.hotkeyModifiers) },
            set: { newValue in
                model.settings.hotkeyKeyCode = newValue.0
                model.settings.hotkeyModifiers = newValue.1
            }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SettingsCard("Capture") {
                    FormRow("Global shortcut") {
                        HotkeyRecorderView(shortcut: shortcutBinding)
                            .frame(width: 150, height: 26)
                    }
                    Hint("Click the field, then press the key combination you want to use.")
                }

                SettingsCard("Prompt sent to the model") {
                    TextEditor(text: $model.settings.prompt)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color(nsColor: .textColor))
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .frame(minHeight: 150)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7)
                                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
                        )
                    HStack {
                        Button("Reset to default") {
                            model.settings.prompt = AppSettings.defaultPrompt
                        }
                        Spacer()
                        Text("\(model.settings.prompt.count) chars")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                SettingsCard("Reliability") {
                    FormRow("Fall back to other providers") {
                        Toggle("", isOn: $model.settings.fallbackEnabled)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                    Hint("If the selected provider fails (bad key, no vision support, server down), the other configured providers are tried in order.")
                }

                SettingsCard("Image output") {
                    FormRow("Background") {
                        Picker("", selection: $model.settings.pngTransparent) {
                            Text("Transparent").tag(true)
                            Text("White").tag(false)
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(width: 190)
                    }
                    FormRow("Formula text") {
                        Picker("", selection: $model.settings.whiteText) {
                            Text("Black (for light pages)").tag(false)
                            Text("White (dark mode)").tag(true)
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(width: 190)
                    }
                    if model.settings.whiteText && !model.settings.pngTransparent {
                        Hint("White text on a white background is invisible — switch the background to Transparent.", color: .orange)
                    }
                    FormRow("Resolution") {
                        Picker("", selection: $model.settings.pngScale) {
                            Text("2× (standard)").tag(2.0)
                            Text("3× (retina)").tag(3.0)
                            Text("4× (print)").tag(4.0)
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(width: 190)
                    }
                    FormRow("Padding") {
                        HStack(spacing: 10) {
                            Slider(value: $model.settings.pngPadding, in: 0...40, step: 2)
                                .frame(width: 190)
                            Text("\(Int(model.settings.pngPadding)) pt")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 52, alignment: .trailing)
                        }
                    }
                }

                SettingsCard("LaTeX output") {
                    FormRow("Compact form") {
                        Toggle("", isOn: $model.settings.compactLatex)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                    Hint("Collapses align/gather blocks into one expression and drops the & alignment markers. Matrices and cases keep their layout.")
                }

                SettingsCard("Startup") {
                    FormRow("Launch at login") {
                        Toggle("", isOn: $model.settings.launchAtLogin)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                }

                SettingsCard("Diagnostics") {
                    FormRow("Math renderer") {
                        Text(MathRenderer.shared.isReady ? "ready" : "loading…")
                            .foregroundStyle(MathRenderer.shared.isReady ? .green : .secondary)
                            .font(.caption)
                    }
                    HStack {
                        Button("Reset all settings and providers") {
                            let defaults = UserDefaults.standard
                            for key in ["providers.v1", "settings.v1", "activeProvider.v1"] {
                                defaults.removeObject(forKey: key)
                            }
                            model.showToast("Reset — restart the app to apply")
                        }
                        .foregroundStyle(.red)
                        Spacer()
                    }
                }
            }
            .padding(16)
        }
    }
}

// MARK: - Providers

final class ProviderEditorState: ObservableObject {
    @Published var selection: UUID?
    @Published var availableModels: [String] = []
    @Published var status: String = ""
    @Published var statusIsError = false
    @Published var isWorking = false
    @Published var revealsKey = false
}

struct ProvidersSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var state = ProviderEditorState()

    private var selectedProvider: LLMProvider? {
        guard let id = state.selection else { return nil }
        return model.providers.first(where: { $0.id == id })
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            detail
        }
        .onAppear {
            if state.selection == nil {
                state.selection = model.activeProviderID ?? model.providers.first?.id
            }
        }
        .onChange(of: state.selection) { _, _ in
            state.availableModels = []
            state.status = ""
            state.statusIsError = false
            state.revealsKey = false
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $state.selection) {
                ForEach(model.providers) { provider in
                    HStack(spacing: 7) {
                        Image(systemName: provider.id == model.activeProviderID ? "largecircle.fill.circle" : "circle")
                            .font(.system(size: 10))
                            .foregroundStyle(provider.id == model.activeProviderID ? Color.accentColor : Color.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(provider.name).lineLimit(1)
                            Text(provider.model.isEmpty ? "no model" : provider.model)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .tag(provider.id)
                }
            }
            .listStyle(.sidebar)

            Divider()
            HStack(spacing: 4) {
                Button {
                    model.addProvider()
                    if let last = model.providers.last { state.selection = last.id }
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)

                Button {
                    if let id = state.selection { model.removeProvider(id) }
                    state.selection = model.providers.first?.id
                } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(.borderless)
                .disabled(state.selection == nil || model.providers.count <= 1)

                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .frame(width: 230)
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let provider = selectedProvider {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SettingsCard("Provider") {
                        FormField("Name") {
                            TextField("", text: string(\.name), prompt: Text("Provider name"))
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: .infinity)
                        }
                        FormRow("Type") {
                            Picker("", selection: kindBinding) {
                                ForEach(ProviderKind.allCases) { kind in
                                    Text(kind.label).tag(kind)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .frame(width: 190)
                        }
                        FormField("Base URL") {
                            TextField(
                                "",
                                text: string(\.baseURL),
                                prompt: Text(provider.kind == .ollama ? "http://localhost:11434" : "https://api.openai.com/v1")
                            )
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(maxWidth: .infinity)
                        }
                        Hint(provider.kind == .ollama
                             ? "Ollama root URL — “/api/chat” is appended."
                             : "“/v1” is appended automatically unless the URL already contains it.")
                    }

                    SettingsCard("Model") {
                        FormField("Model ID") {
                            HStack(spacing: 6) {
                                TextField("", text: string(\.model), prompt: Text("e.g. gpt-4o-mini"))
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 12, design: .monospaced))
                                    .frame(maxWidth: .infinity)
                                Menu {
                                    if state.availableModels.isEmpty {
                                        Button("Fetch models first…") {}.disabled(true)
                                    } else {
                                        ForEach(state.availableModels, id: \.self) { name in
                                            Button(name) { set(\.model, name) }
                                        }
                                    }
                                } label: {
                                    Image(systemName: "chevron.down")
                                }
                                .menuStyle(.borderlessButton)
                                .frame(width: 24)
                            }
                        }

                        HStack(spacing: 8) {
                            Button("Fetch models") { fetchModels() }
                                .disabled(state.isWorking)
                            Button("Test this model") { testModel() }
                                .disabled(state.isWorking || provider.model.isEmpty)
                            if state.isWorking { ProgressView().controlSize(.small) }
                            Spacer()
                        }

                        if !state.status.isEmpty {
                            Text(state.status)
                                .font(.caption)
                                .foregroundStyle(state.statusIsError ? Color.red : Color.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        Hint("“Test this model” sends a small image to exactly this model and checks the answer.", color: Color.secondary.opacity(0.75))
                    }

                    SettingsCard("Authentication") {
                        FormField("API key") {
                            HStack(spacing: 6) {
                                if state.revealsKey {
                                    TextField("", text: string(\.apiKey), prompt: Text("sk-… (optional for local servers)"))
                                        .textFieldStyle(.roundedBorder)
                                        .font(.system(size: 12, design: .monospaced))
                                        .frame(maxWidth: .infinity)
                                } else {
                                    SecureField("", text: string(\.apiKey), prompt: Text("sk-… (optional for local servers)"))
                                        .textFieldStyle(.roundedBorder)
                                        .font(.system(size: 12, design: .monospaced))
                                        .frame(maxWidth: .infinity)
                                }
                                Button(state.revealsKey ? "Hide" : "Show") {
                                    state.revealsKey.toggle()
                                }
                                .controlSize(.small)
                            }
                        }
                        Hint("Stored in the macOS Keychain. Local servers like Ollama or LM Studio usually need no key.")
                    }

                    SettingsCard("Usage") {
                        FormRow("Use this provider for OCR") {
                            Toggle("", isOn: Binding(
                                get: { model.activeProviderID == provider.id },
                                set: { isOn in
                                    if isOn { model.activeProviderID = provider.id }
                                }
                            ))
                            .toggleStyle(.switch)
                            .labelsHidden()
                        }
                        HStack {
                            Button("Capture a test region") {
                                model.startCaptureFlow()
                            }
                            Spacer()
                        }
                    }
                }
                .padding(16)
            }
        } else {
            VStack {
                Spacer()
                Text("Select or create a provider")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: Bindings

    private func string(_ keyPath: WritableKeyPath<LLMProvider, String>) -> Binding<String> {
        Binding(
            get: { selectedProvider?[keyPath: keyPath] ?? "" },
            set: { newValue in set(keyPath, newValue) }
        )
    }

    private func set(_ keyPath: WritableKeyPath<LLMProvider, String>, _ value: String) {
        guard let id = state.selection, let index = model.providerIndex(for: id) else { return }
        model.providers[index][keyPath: keyPath] = value
    }

    private var kindBinding: Binding<ProviderKind> {
        Binding(
            get: { selectedProvider?.kind ?? .openAICompatible },
            set: { newKind in
                guard let id = state.selection, let index = model.providerIndex(for: id) else { return }
                let previous = model.providers[index].kind
                model.providers[index].kind = newKind
                // Give a sensible default URL when the type changes away from a configured one.
                let url = model.providers[index].baseURL
                if newKind == .ollama, url.contains("openai.com") {
                    model.providers[index].baseURL = "http://localhost:11434"
                } else if newKind == .openAICompatible, previous == .ollama, url.contains("11434") {
                    model.providers[index].baseURL = "https://api.openai.com/v1"
                }
            }
        )
    }

    // MARK: Actions

    private func fetchModels() {
        guard let provider = selectedProvider else { return }
        state.isWorking = true
        state.statusIsError = false
        state.status = "Fetching models…"
        Task {
            do {
                let models = try await model.fetchModels(for: provider)
                state.availableModels = models
                if models.isEmpty {
                    state.status = "No models found. Is the server running?"
                    state.statusIsError = true
                } else {
                    state.status = "Found \(models.count) model(s): " + models.prefix(4).joined(separator: ", ")
                }
            } catch {
                state.status = "Error: \(error.localizedDescription)"
                state.statusIsError = true
            }
            state.isWorking = false
        }
    }

    private func testModel() {
        guard let provider = selectedProvider else { return }
        state.isWorking = true
        state.statusIsError = false
        state.status = "Testing \(provider.model)…"
        Task {
            do {
                state.status = try await model.testProvider(provider)
            } catch {
                state.status = "Error: \(error.localizedDescription)"
                state.statusIsError = true
            }
            state.isWorking = false
        }
    }
}
