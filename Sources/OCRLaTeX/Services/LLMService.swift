import AppKit
import Foundation

struct LLMError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum LLMService {

    // MARK: Endpoints

    static func normalizedBase(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    static func endpoint(_ provider: LLMProvider, _ path: String) -> URL? {
        let base = normalizedBase(provider.baseURL)
        if base.isEmpty { return nil }
        switch provider.kind {
        case .openAICompatible:
            if base.hasSuffix("/chat/completions") {
                return URL(string: base)
            }
            var root = base
            if !root.contains("/v1") { root += "/v1" }
            return URL(string: root + path)
        case .ollama:
            var root = base
            if root.hasSuffix("/v1") { root = String(root.dropLast(3)) }
            while root.hasSuffix("/") { root.removeLast() }
            return URL(string: root + path)
        }
    }

    // MARK: Image encoding

    static func pngData(from image: NSImage, maxDimension: CGFloat = 1800) -> Data? {
        // Prefer the bitmap pixel size: NSImage.size can be points on Retina captures.
        var sourceSize = image.size
        if let rep = image.representations.first,
           rep.pixelsWide > 0, rep.pixelsHigh > 0 {
            sourceSize = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        guard sourceSize.width > 1, sourceSize.height > 1 else { return nil }

        let longest = max(sourceSize.width, sourceSize.height)
        let target: NSSize
        if longest > maxDimension {
            let ratio = maxDimension / longest
            target = NSSize(width: (sourceSize.width * ratio).rounded(), height: (sourceSize.height * ratio).rounded())
        } else {
            target = sourceSize
        }

        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(target.width),
            pixelsHigh: Int(target.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        guard let rep else { return nil }
        rep.size = target

        NSGraphicsContext.saveGraphicsState()
        if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = ctx
            ctx.imageInterpolation = .high
            image.draw(in: NSRect(origin: .zero, size: target))
        }
        NSGraphicsContext.restoreGraphicsState()

        return rep.representation(using: .png, properties: [:])
    }

    // MARK: Requests

    private static func request(
        provider: LLMProvider,
        method: String = "POST",
        path: String,
        body: [String: Any]?,
        timeout: TimeInterval = 180
    ) throws -> URLRequest {
        guard let url = endpoint(provider, path) else {
            throw LLMError(message: "Invalid base URL: \(provider.baseURL)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if !provider.apiKey.isEmpty {
            req.setValue("Bearer \(provider.apiKey)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        }
        return req
    }

    private static func send(_ req: URLRequest) async throws -> Any {
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw LLMError(message: "No HTTP response")
        }
        if !(200...299).contains(http.statusCode) {
            let text = String(data: data, encoding: .utf8) ?? ""
            let trimmed = text.count > 600 ? String(text.prefix(600)) + "…" : text
            throw LLMError(message: "HTTP \(http.statusCode): \(trimmed)")
        }
        do {
            return try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            let text = String(data: data, encoding: .utf8) ?? "<binary>"
            throw LLMError(message: "Unexpected response: \(String(text.prefix(400)))")
        }
    }

    // MARK: Vision request

    /// Sends one image + prompt to the provider and returns the raw text reply.
    private static func visionText(
        image: NSImage,
        provider: LLMProvider,
        systemPrompt: String?,
        userText: String,
        maxTokens: Int
    ) async throws -> String {
        guard !provider.model.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw LLMError(message: "No model selected for “\(provider.name)”.")
        }
        guard let png = pngData(from: image) else {
            throw LLMError(message: "Could not encode the screenshot.")
        }
        let base64 = png.base64EncodedString()

        let json: Any
        switch provider.kind {
        case .openAICompatible:
            var messages: [[String: Any]] = []
            if let systemPrompt, !systemPrompt.isEmpty {
                messages.append(["role": "system", "content": systemPrompt])
            }
            messages.append([
                "role": "user",
                "content": [
                    ["type": "text", "text": userText],
                    ["type": "image_url", "image_url": ["url": "data:image/png;base64,\(base64)"]]
                ]
            ])
            let body: [String: Any] = [
                "model": provider.model,
                "temperature": provider.temperature,
                "max_tokens": maxTokens,
                "stream": false,
                "messages": messages
            ]
            json = try await send(request(provider: provider, path: "/chat/completions", body: body))

        case .ollama:
            var content = userText
            if let systemPrompt, !systemPrompt.isEmpty {
                content = systemPrompt + "\n\n" + userText
            }
            let body: [String: Any] = [
                "model": provider.model,
                "stream": false,
                "options": [
                    "temperature": provider.temperature,
                    "num_predict": maxTokens
                ],
                "messages": [
                    ["role": "user", "content": content, "images": [base64]]
                ]
            ]
            json = try await send(request(provider: provider, path: "/api/chat", body: body))
        }

        guard let text = extractContent(json) else {
            throw LLMError(message: "The provider returned an empty result.")
        }
        return text
    }

    // MARK: OCR

    static func ocr(
        image: NSImage,
        provider: LLMProvider,
        prompt: String,
        compact: Bool = true
    ) async throws -> String {
        let raw = try await visionText(
            image: image,
            provider: provider,
            systemPrompt: prompt,
            userText: "Transcribe this image into LaTeX.",
            maxTokens: provider.maxTokens
        )
        let cleaned = LatexCleaner.clean(raw, compact: compact)
        if cleaned.isEmpty {
            throw LLMError(message: "The provider returned an empty result.")
        }
        return cleaned
    }

    /// Sends a tiny probe image to one specific model, so "Test" proves that
    /// this exact model answers and can actually see images.
    static func ping(provider: LLMProvider) async throws -> String {
        guard !provider.model.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw LLMError(message: "Enter a model ID first.")
        }
        let probe = probeImage()
        let reply = try await visionText(
            image: probe,
            provider: provider,
            systemPrompt: "You solve the arithmetic shown in an image. Reply with digits only, no words.",
            userText: "Solve the arithmetic in this image. Reply with the number only.",
            maxTokens: 24
        )
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        guard !trimmed.isEmpty else {
            throw LLMError(message: "Model \(provider.model) answered with nothing.")
        }
        if trimmed.contains("4") {
            return "✓ \(provider.model) answered “\(trimmed.prefix(40))” — vision works."
        }
        return "✓ \(provider.model) replied “\(trimmed.prefix(60))” — but ignored the image."
    }

    /// Small white image with "2 + 2 = ?" used by `ping`.
    private static func probeImage() -> NSImage {
        let size = NSSize(width: 240, height: 90)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        let text = "2 + 2 = ?"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont(name: "Helvetica-Bold", size: 42) ?? NSFont.boldSystemFont(ofSize: 42),
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

    private static func extractContent(_ json: Any) -> String? {
        if let dict = json as? [String: Any] {
            // OpenAI: choices[0].message.content
            if let choices = dict["choices"] as? [[String: Any]],
               let first = choices.first,
               let message = first["message"] as? [String: Any] {
                if let s = message["content"] as? String { return s }
                if let parts = message["content"] as? [[String: Any]] {
                    let joined = parts.compactMap { $0["text"] as? String }.joined()
                    if !joined.isEmpty { return joined }
                }
            }
            // Compat shims: choices[0].text
            if let choices = dict["choices"] as? [[String: Any]],
               let text = choices.first?["text"] as? String {
                return text
            }
            // Ollama: message.content / response
            if let message = dict["message"] as? [String: Any], let s = message["content"] as? String {
                return s
            }
            if let s = dict["response"] as? String { return s }
        }
        return nil
    }

    // MARK: Models

    static func listModels(provider: LLMProvider) async throws -> [String] {
        switch provider.kind {
        case .ollama:
            let base = normalizedBase(provider.baseURL)
            var root = base.hasSuffix("/v1") ? String(base.dropLast(3)) : base
            while root.hasSuffix("/") { root.removeLast() }
            guard let url = URL(string: root + "/api/tags") else {
                throw LLMError(message: "Invalid base URL")
            }
            var req = URLRequest(url: url)
            req.timeoutInterval = 15
            let json = try await send(req)
            guard let dict = json as? [String: Any],
                  let models = dict["models"] as? [[String: Any]] else { return [] }
            return models.compactMap { $0["name"] as? String ?? $0["model"] as? String }.sorted()

        case .openAICompatible:
            guard let url = endpoint(provider, "/models") else {
                throw LLMError(message: "Invalid base URL")
            }
            var req = URLRequest(url: url)
            req.timeoutInterval = 20
            if !provider.apiKey.isEmpty {
                req.setValue("Bearer \(provider.apiKey)", forHTTPHeaderField: "Authorization")
            }
            let json = try await send(req)
            guard let dict = json as? [String: Any],
                  let data = dict["data"] as? [[String: Any]] else { return [] }
            return data.compactMap { $0["id"] as? String }.sorted()
        }
    }

}
