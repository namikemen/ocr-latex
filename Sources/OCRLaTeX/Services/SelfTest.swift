import AppKit
import Foundation

/// Headless verification: renders a few formulas through the real MathJax →
/// SVG → PNG pipeline. Run with:
///   ./dist/OCR\ LaTeX.app/Contents/MacOS/OCRLaTeX --selftest /tmp/out.png
@MainActor
enum SelfTest {
    static func run() {
        if CommandLine.arguments.contains("--llmtest") {
            runLLMPlumbingTest()
            return
        }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)

        let args = CommandLine.arguments
        let basePath: String
        if let index = args.firstIndex(of: "--selftest"),
           index + 1 < args.count,
           !args[index + 1].hasPrefix("-") {
            basePath = args[index + 1]
        } else {
            basePath = NSTemporaryDirectory() + "ocrlatex-selftest.png"
        }

        let formulas: [(String, String)] = [
            ("integral", "\\int_{-\\infty}^{\\infty} e^{-x^2}\\,dx = \\sqrt{\\pi}"),
            ("matrix", "\\begin{pmatrix} a & b \\\\ c & d \\end{pmatrix}^{-1} = \\frac{1}{ad-bc}\\begin{pmatrix} d & -b \\\\ -c & a \\end{pmatrix}"),
            ("laplace", "\\mathcal{L}\\{f(t)\\} = F(s) = \\int_0^{\\infty} e^{-st} f(t)\\,dt"),
            ("series", "\\sum_{n=1}^{\\infty}\\frac{1}{n^2} = \\frac{\\pi^2}{6}")
        ]

        var finished = false

        Task { @MainActor in
            let renderer = MathRenderer.shared
            await renderer.waitUntilReady()
            print("renderer ready: \(renderer.isReady)")

            for (index, item) in formulas.enumerated() {
                let whiteText = item.0 == "series"
                let transparent = whiteText ? true : (index % 2 == 0)
                let path = basePath.replacingOccurrences(of: ".png", with: "-\(index)-\(item.0).png")
                if let data = await renderer.pngData(
                    latex: item.1,
                    scale: 3,
                    padding: 16,
                    transparent: transparent,
                    whiteText: whiteText
                ) {
                    try? data.write(to: URL(fileURLWithPath: path))
                    print("wrote \(path) (\(data.count) bytes, transparent: \(transparent), whiteText: \(whiteText))")
                } else {
                    print("FAILED \(item.0)")
                }
            }

            let previewOK = await renderer.preview(latex: formulas[3].1, transparentBackground: true, whiteText: true)
            print("preview: \(previewOK ? "ok" : "failed")")

            // LLM plumbing sanity checks
            let provider = LLMProvider(name: "t", kind: .openAICompatible, baseURL: "https://api.openai.com/v1", model: "x")
            print("endpoint(openai): \(LLMService.endpoint(provider, "/chat/completions")?.absoluteString ?? "nil")")
            let ollama = LLMProvider(name: "o", kind: .ollama, baseURL: "http://localhost:11434", model: "x")
            print("endpoint(ollama): \(LLMService.endpoint(ollama, "/api/chat")?.absoluteString ?? "nil")")
            print("clean: \(LatexCleaner.clean("```latex\n$$ x^2 $$\n```"))")

            finished = true
        }

        let deadline = Date().addingTimeInterval(45)
        while !finished && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        exit(finished ? 0 : 1)
    }

    /// Exercises the HTTP layer against a mock OpenAI/Ollama server.
    private static func runLLMPlumbingTest() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)

        var finished = false
        var failures: [String] = []

        Task { @MainActor in
            let image = DemoContent.makeImage()
            let base = ProcessInfo.processInfo.environment["MOCK_BASE"] ?? "http://127.0.0.1:8765"

            // 1. OpenAI-compatible chat completions
            do {
                let provider = LLMProvider(
                    name: "mock",
                    kind: .openAICompatible,
                    baseURL: base + "/v1",
                    model: "mock-vision"
                )
                let result = try await LLMService.ocr(image: image, provider: provider, prompt: "test prompt")
                print("openai-compat result: \(result)")
                if result != "\\frac{a}{b}" { failures.append("openai-compat unexpected result") }
            } catch {
                print("openai-compat error: \(error.localizedDescription)")
                failures.append("openai-compat threw")
            }

            // 2. Ollama /api/chat
            do {
                let provider = LLMProvider(name: "mock", kind: .ollama, baseURL: base, model: "llava")
                let result = try await LLMService.ocr(image: image, provider: provider, prompt: "test prompt")
                print("ollama result: \(result)")
                if result != "\\sum_{i=1}^{n} i" { failures.append("ollama unexpected result") }
            } catch {
                print("ollama error: \(error.localizedDescription)")
                failures.append("ollama threw")
            }

            // 3. Model listing
            do {
                let ollama = LLMProvider(name: "m", kind: .ollama, baseURL: base, model: "")
                let models = try await LLMService.listModels(provider: ollama)
                print("ollama models: \(models)")
                if !models.contains(where: { $0.hasPrefix("llava") }) { failures.append("ollama model listing") }

                let openai = LLMProvider(name: "m", kind: .openAICompatible, baseURL: base + "/v1", model: "")
                let chatModels = try await LLMService.listModels(provider: openai)
                print("openai models: \(chatModels)")
                if !chatModels.contains("mock-vision") { failures.append("openai model listing") }
            } catch {
                print("model listing error: \(error.localizedDescription)")
                failures.append("model listing threw")
            }

            // 4. Error surface
            do {
                let provider = LLMProvider(name: "bad", kind: .openAICompatible, baseURL: base + "/v1", model: "boom")
                _ = try await LLMService.ocr(image: image, provider: provider, prompt: "p")
                failures.append("error path did not throw")
            } catch {
                print("expected error: \(error.localizedDescription)")
            }

            // 5. Per-model probe (the "Test this model" button)
            do {
                let provider = LLMProvider(name: "mock", kind: .openAICompatible, baseURL: base + "/v1", model: "mock-vision")
                let message = try await LLMService.ping(provider: provider)
                print("ping openai: \(message)")
                if !message.contains("vision works") { failures.append("openai probe did not validate the image") }
            } catch {
                print("ping openai error: \(error.localizedDescription)")
                failures.append("openai probe threw")
            }

            do {
                let provider = LLMProvider(name: "mock", kind: .ollama, baseURL: base, model: "llava")
                let message = try await LLMService.ping(provider: provider)
                print("ping ollama: \(message)")
                if !message.contains("vision works") { failures.append("ollama probe did not validate the image") }
            } catch {
                print("ping ollama error: \(error.localizedDescription)")
                failures.append("ollama probe threw")
            }

            // 6. A model that cannot see images must fail loudly for that model only
            do {
                let provider = LLMProvider(name: "t", kind: .openAICompatible, baseURL: base + "/v1", model: "text-only")
                _ = try await LLMService.ping(provider: provider)
                failures.append("text-only model was reported as working")
            } catch {
                print("no-vision error: \(error.localizedDescription)")
                if !error.localizedDescription.contains("does not support images") {
                    failures.append("vision error text not surfaced")
                }
            }

            // 7. Empty model
            do {
                _ = try await LLMService.ping(provider: LLMProvider(name: "e", kind: .openAICompatible, baseURL: base + "/v1", model: ""))
                failures.append("empty model was accepted")
            } catch {
                print("empty model error: \(error.localizedDescription)")
            }

            // 8. Compact LaTeX output
            let compactCases: [(String, String)] = [
                ("\\begin{align*}\nx_{1} &= x = x_{4}\n\\end{align*}", "x_{1} = x = x_{4}"),
                ("\\begin{align*} a &= 1 \\\\ b &= 2 \\end{align*}", "a = 1, b = 2"),
                ("\\begin{pmatrix} a & b \\\\ c & d \\end{pmatrix}", "\\begin{pmatrix} a & b \\\\ c & d \\end{pmatrix}"),
                ("$$\\begin{aligned} E &= mc^2 \\end{aligned}$$", "E = mc^2")
            ]
            for (input, expected) in compactCases {
                let got = LatexCleaner.clean(input)
                if got != expected {
                    print("compact FAILED: \(got) != \(expected)")
                    failures.append("compact: \(expected)")
                }
            }
            if LatexCleaner.clean("\\begin{align*} a &= 1 \\\\ b &= 2 \\end{align*}", compact: false)
                .contains("begin{align*}") == false {
                failures.append("compact:false did not preserve the environment")
            }

            // 8b. Compact output through a real OCR round-trip
            do {
                let provider = LLMProvider(name: "align", kind: .openAICompatible, baseURL: base + "/v1", model: "align")
                let compacted = try await LLMService.ocr(image: image, provider: provider, prompt: "p")
                let raw = try await LLMService.ocr(image: image, provider: provider, prompt: "p", compact: false)
                print("ocr compact: \(compacted)")
                if compacted != "x_{1} = x = x_{4}" { failures.append("ocr compact output") }
                if !raw.contains("begin{align*}") { failures.append("ocr compact:false") }
            } catch {
                print("ocr compact error: \(error.localizedDescription)")
                failures.append("ocr compact threw")
            }

            // 9. Fallback chain
            let activeP = LLMProvider(name: "active", model: "m1")
            let emptyP = LLMProvider(name: "empty", model: "")
            let backupP = LLMProvider(name: "backup", model: "m2")
            let chainOn = AppModel.ocrChain(providers: [emptyP, activeP, backupP], active: activeP, fallback: true)
            let chainOff = AppModel.ocrChain(providers: [emptyP, activeP, backupP], active: activeP, fallback: false)
            let chainNone = AppModel.ocrChain(providers: [emptyP], active: emptyP, fallback: true)
            print("chain on: \(chainOn.map(\.name)), off: \(chainOff.map(\.name)), none: \(chainNone.count)")
            if chainOn.map(\.name) != ["active", "backup"] { failures.append("fallback chain order") }
            if chainOff.map(\.name) != ["active"] { failures.append("fallback disabled chain") }
            if !chainNone.isEmpty { failures.append("empty chain should be empty") }

            // 10. Runtime fallback: a failing provider must not stop the next one
            do {
                let bad = LLMProvider(name: "bad", kind: .openAICompatible, baseURL: base + "/v1", model: "boom")
                let good = LLMProvider(name: "good", kind: .openAICompatible, baseURL: base + "/v1", model: "mock-vision")
                var answer: String?
                var used: String?
                for provider in [bad, good] {
                    if let text = try? await LLMService.ocr(image: image, provider: provider, prompt: "p") {
                        answer = text
                        used = provider.name
                        break
                    }
                }
                print("runtime fallback: \(used ?? "none") -> \(answer ?? "nil")")
                if used != "good" || answer != "\\frac{a}{b}" { failures.append("runtime fallback") }
            }

            finished = true
        }

        let deadline = Date().addingTimeInterval(30)
        while !finished && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }

        if !finished { print("llmtest timed out") }
        if failures.isEmpty {
            print("LLM PLUMBING OK")
            exit(0)
        } else {
            print("LLM PLUMBING FAILED: \(failures.joined(separator: ", "))")
            exit(1)
        }
    }
}
