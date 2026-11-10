import SwiftUI
import AppKit

struct ResultView: View {
    @EnvironmentObject private var model: AppModel
    @FocusState private var editorFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            previewArea
            Divider()
            editorArea
            if let error = model.lastError {
                errorBanner(error)
            }
            Divider()
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) { toast }
        .onExitCommand { PanelController.shared.close() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            if let image = model.capturedImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 54, height: 40)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                    )
                    .help("Captured region")
            }

            Picker("", selection: Binding(
                get: { model.activeProviderID ?? UUID() },
                set: { model.activeProviderID = $0 }
            )) {
                ForEach(model.providers) { provider in
                    Text(provider.displayName).tag(provider.id)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 280)

            if let used = model.lastUsedProviderName,
               used != model.activeProvider?.name {
                Text("via \(used)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if model.isBusy {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(model.busyLabel).font(.caption).foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button {
                model.startCaptureFlow()
            } label: {
                Image(systemName: "viewfinder")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 26, height: 24)
                    .background(Circle().fill(Color.primary.opacity(0.07)))
            }
            .buttonStyle(.plain)
            .help("Capture a new region (\(Hotkey.describe(keyCode: model.settings.hotkeyKeyCode, modifiers: model.settings.hotkeyModifiers)))")
            .disabled(model.isBusy)

            Button {
                model.rerun()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 26, height: 24)
                    .background(Circle().fill(Color.primary.opacity(0.07)))
            }
            .buttonStyle(.plain)
            .help("Run recognition again with the current model")
            .disabled(model.isBusy || model.capturedImage == nil)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: Preview

    private var previewArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .textBackgroundColor))
            MathPreviewView()
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .opacity(model.latex.isEmpty ? 0 : 1)

            if model.latex.isEmpty && !model.isBusy {
                VStack(spacing: 6) {
                    Image(systemName: "function")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("Nothing recognised yet")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(height: 190)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: Editor

    private var editorArea: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("LaTeX")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if !model.latex.isEmpty {
                    Text("\(model.latex.count) chars")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            TextEditor(text: $model.latex)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color(nsColor: .textColor))
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
                )
                .frame(minHeight: 110, maxHeight: 190)
                .focused($editorFocused)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    // MARK: Error

    private func errorBanner(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.caption)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
            }
            if model.showPermissionHelp {
                HStack(spacing: 8) {
                    Button("Open System Settings") {
                        ScreenCapture.openPermissionSettings()
                    }
                    .controlSize(.small)
                    Button("Try Again") {
                        model.startCaptureFlow()
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Text("Copy")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                ForEach([CopyFormat.raw, .inline, .display], id: \.self) { format in
                    Button {
                        model.copy(format)
                    } label: {
                        Text(format.title)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .frame(minWidth: 34)
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.latex.isEmpty)
                }

                Menu {
                    Button(CopyFormat.paren.title) { model.copy(.paren) }
                    Button(CopyFormat.bracket.title) { model.copy(.bracket) }
                    Divider()
                    Button("Save PNG…") { model.savePNGToFile() }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 30)

                Spacer()

                Button {
                    model.copyPNG()
                } label: {
                    Label("Copy PNG", systemImage: "photo.on.rectangle")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.latex.isEmpty || model.isBusy)
            }

            HStack(spacing: 10) {
                Text("PNG")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Picker("", selection: Binding(
                    get: { model.settings.pngTransparent },
                    set: { model.settings.pngTransparent = $0 }
                )) {
                    Text("Transparent").tag(true)
                    Text("White").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 158)

                Picker("", selection: Binding(
                    get: { model.settings.pngScale },
                    set: { model.settings.pngScale = $0 }
                )) {
                    Text("2×").tag(2.0)
                    Text("3×").tag(3.0)
                    Text("4×").tag(4.0)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 112)

                Text("Text")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Picker("", selection: Binding(
                    get: { model.settings.whiteText },
                    set: { model.settings.whiteText = $0 }
                )) {
                    Text("Black").tag(false)
                    Text("White").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 116)
                .help("White renders the formula for dark slides and documents")

                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: Toast

    private var toast: some View {
        Group {
            if let toast = model.toast {
                Text(toast)
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
                    .padding(.bottom, 78)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: model.toast)
    }
}
