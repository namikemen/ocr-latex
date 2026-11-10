import AppKit
import SwiftUI

@main
enum Launcher {
    static func main() {
        if CommandLine.arguments.contains("--selftest") ||
           CommandLine.arguments.contains("--llmtest") ||
           CommandLine.arguments.contains("--updatetest") {
            SelfTest.run()
            return
        }
        OCRLaTeXApp.main()
    }
}

@MainActor
struct OCRLaTeXApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent().environmentObject(model)
        } label: {
            if let image = menuBarImage {
                Image(nsImage: image)
            } else {
                Image(systemName: "text.viewfinder")
            }
        }
        .menuBarExtraStyle(.menu)
    }

    private var menuBarImage: NSImage? {
        guard let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png"),
              let img = NSImage(contentsOf: url) else {
            return nil
        }
        img.size = NSSize(width: 18, height: 18)
        return img
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let model = AppModel.shared
        model.bootstrap()

        HotkeyManager.shared.onTrigger = {
            Task { @MainActor in
                AppModel.shared.startCaptureFlow()
            }
        }

        if model.needsSetup {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                SettingsWindowController.shared.show()
            }
        }

        if CommandLine.arguments.contains("--demo") {
            model.showPermissionHelp = false
            model.latex = "\\int_0^1 x^2 \\, dx = \\frac{1}{3}"
            model.capturedImage = DemoContent.makeImage()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                PanelController.shared.show()
                if let index = CommandLine.arguments.firstIndex(of: "--ui-snapshot"),
                   index + 1 < CommandLine.arguments.count {
                    let path = CommandLine.arguments[index + 1]
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                        PanelController.shared.snapshotSelf(to: path)
                    }
                }
            }
        }

        if CommandLine.arguments.contains("--settings-providers") {
            SettingsView.initialTab = 1
        }

        if let index = CommandLine.arguments.firstIndex(of: "--settings-snapshot"),
           index + 1 < CommandLine.arguments.count {
            let path = CommandLine.arguments[index + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                SettingsWindowController.shared.show()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    SettingsWindowController.shared.snapshotSelf(to: path)
                }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.flushSecrets()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { SettingsWindowController.shared.show() }
        return true
    }
}

// MARK: - Menu bar content

struct MenuContent: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var updates = UpdateService.shared

    var body: some View {
        Button("Capture Region…") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                model.startCaptureFlow()
            }
        }
        Button("Capture from Clipboard") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                model.captureFromClipboard()
            }
        }

        if !model.latex.isEmpty {
            Button("Show Last Result") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    PanelController.shared.show()
                }
            }
            Button("Copy Last LaTeX") {
                model.copy(.raw)
            }
        }

        Divider()

        Menu("Model") {
            ForEach(model.providers) { provider in
                Button {
                    model.activeProviderID = provider.id
                } label: {
                    Text((model.activeProviderID == provider.id ? "✓ " : "   ") + provider.displayName)
                }
            }
            if model.providers.isEmpty {
                Text("No providers configured")
            }
        }

        Button("Settings…") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                SettingsWindowController.shared.show()
            }
        }
        .keyboardShortcut(",", modifiers: .command)

        Divider()

        if let update = updates.available {
            Button("Update to \(update.version)…") {
                updates.promptInstall(update)
            }
        }
        Button(updates.isWorking ? "Checking for Updates…" : "Check for Updates…") {
            Task { await updates.checkInteractively() }
        }
        .disabled(updates.isWorking)

        Divider()

        Button("Quit OCR LaTeX") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}
