import AppKit
import Foundation

/// A published GitHub release with a downloadable `.app` zip.
struct UpdateRelease: Equatable {
    let tag: String
    let version: String
    let notes: String
    let pageURL: URL
    let assetURL: URL?
    let assetName: String?
    let assetSize: Int?

    var sizeText: String {
        guard let assetSize, assetSize > 0 else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(assetSize), countStyle: .file)
    }
}

private struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: String
        let size: Int

        enum CodingKeys: String, CodingKey {
            case name, size
            case browserDownloadURL = "browser_download_url"
        }
    }

    let tagName: String
    let body: String?
    let htmlURL: String
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case body, draft, prerelease, assets
        case tagName = "tag_name"
        case htmlURL = "html_url"
    }
}

enum UpdateError: LocalizedError {
    case badResponse
    case http(Int)
    case noAsset
    case readOnlyLocation(String)
    case unzip(String)
    case unexpectedVersion(found: String, expected: String)

    var errorDescription: String? {
        switch self {
        case .badResponse:
            return "The update server returned an unexpected response."
        case .http(let code):
            return "The update server returned HTTP \(code)."
        case .noAsset:
            return "The latest release has no downloadable zip."
        case .readOnlyLocation(let path):
            return "\(path) is not writable, so the app cannot replace itself. Download the release and move it into place manually."
        case .unzip(let message):
            return "Could not unpack the update: \(message)"
        case .unexpectedVersion(let found, let expected):
            return "The downloaded bundle reports version \(found), expected \(expected)."
        }
    }
}

/// Reads the GitHub releases feed for this repository, downloads the zip and
/// swaps the app bundle out through a detached helper script. No external
/// framework: the repo is public, so the anonymous API is enough.
@MainActor
final class UpdateService: ObservableObject {
    static let shared = UpdateService()

    /// Owner/name of the repository that publishes releases.
    static let repository = "namikemen/ocr-latex"

    private enum Keys {
        static let lastCheck = "update.lastCheck.v1"
    }

    /// Minimum time between automatic (silent) checks.
    private let autoCheckInterval: TimeInterval = 12 * 60 * 60

    @Published private(set) var available: UpdateRelease?
    @Published private(set) var status: String = ""
    @Published private(set) var isWorking = false

    private var didAutoCheck = false

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    var hasUpdate: Bool { available != nil }

    // MARK: - Checking

    /// Called once at launch. Honours the preference and a cool-down so a
    /// frequently restarted app does not hammer the API.
    func checkInBackgroundIfDue(settings: AppSettings) {
        guard settings.autoUpdateCheck, !didAutoCheck else { return }
        didAutoCheck = true

        let last = UserDefaults.standard.object(forKey: Keys.lastCheck) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) >= autoCheckInterval else { return }

        Task { await check(interactive: false) }
    }

    /// Interactive check: always runs, reports the outcome in an alert.
    func checkInteractively() async {
        guard !isWorking else { return }
        NSApp.activate(ignoringOtherApps: true)
        let release = await check(interactive: true)

        let alert = NSAlert()
        if let release, isNewer(release.version, than: currentVersion) {
            alert.messageText = "OCR LaTeX \(release.version) is available"
            alert.informativeText = "You have \(currentVersion).\n\n" + preview(release.notes)
            alert.addButton(withTitle: "Download & Install")
            alert.addButton(withTitle: "Release Notes")
            alert.addButton(withTitle: "Later")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                Task { await downloadAndInstall(release) }
            case .alertSecondButtonReturn:
                NSWorkspace.shared.open(release.pageURL)
            default:
                break
            }
            return
        }

        if release == nil, status.hasPrefix("Could not") {
            alert.alertStyle = .warning
            alert.messageText = "Update check failed"
            alert.informativeText = status
        } else {
            alert.messageText = "You're up to date"
            alert.informativeText = "OCR LaTeX \(currentVersion) is the latest version."
        }
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Fetches the newest release and updates `available` / `status`.
    @discardableResult
    func check(interactive: Bool) async -> UpdateRelease? {
        if interactive {
            guard !isWorking else { return available }
            isWorking = true
            status = "Checking…"
        }

        defer {
            if interactive { isWorking = false }
            UserDefaults.standard.set(Date(), forKey: Keys.lastCheck)
        }

        do {
            let release = try await fetchLatest()
            guard let release else {
                available = nil
                status = "No releases published yet"
                return nil
            }
            let newer = isNewer(release.version, than: currentVersion)
            available = newer ? release : nil
            status = newer
                ? "\(release.version) available"
                : "up to date (\(currentVersion))"
            return release
        } catch {
            // A silent background check failing is not worth surfacing.
            if interactive { status = "Could not check: \(error.localizedDescription)" }
            NSLog("OCRLaTeX: update check failed: %@", error.localizedDescription)
            return nil
        }
    }

    private func fetchLatest() async throws -> UpdateRelease? {
        guard let url = URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest") else {
            throw UpdateError.badResponse
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("OCRLaTeX/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UpdateError.badResponse }
        // 404 simply means nothing has been released yet.
        if http.statusCode == 404 { return nil }
        guard http.statusCode == 200 else { throw UpdateError.http(http.statusCode) }

        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard !release.draft, !release.prerelease else { return nil }
        guard let pageURL = URL(string: release.htmlURL) else { return nil }

        let asset = release.assets.first { $0.name.lowercased().hasSuffix(".zip") }
        return UpdateRelease(
            tag: release.tagName,
            version: normalisedVersion(release.tagName),
            notes: release.body ?? "",
            pageURL: pageURL,
            assetURL: asset.flatMap { URL(string: $0.browserDownloadURL) },
            assetName: asset?.name,
            assetSize: asset?.size
        )
    }

    // MARK: - Installing

    /// Confirmation sheet for a known update.
    func promptInstall(_ release: UpdateRelease) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Update to OCR LaTeX \(release.version)?"
        let size = release.sizeText.isEmpty ? "" : " (\(release.sizeText))"
        alert.informativeText = "The app downloads the new build\(size), replaces itself and relaunches.\n\n"
            + "macOS will ask for Screen Recording permission again, because each ad-hoc signed build is a new identity.\n\n"
            + preview(release.notes)
        alert.addButton(withTitle: "Download & Install")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await downloadAndInstall(release) }
    }

    /// Downloads, unpacks, then hands the bundle swap to a helper process that
    /// waits for this app to quit before touching the bundle on disk.
    func downloadAndInstall(_ release: UpdateRelease) async {
        guard !isWorking else { return }
        guard let assetURL = release.assetURL else {
            presentError(UpdateError.noAsset)
            return
        }
        let target = Bundle.main.bundleURL
        let parent = target.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            presentError(UpdateError.readOnlyLocation(parent.path))
            return
        }

        isWorking = true
        defer { isWorking = false }
        status = "Downloading \(release.sizeText)…"

        do {
            let (downloaded, _) = try await URLSession.shared.download(from: assetURL)
            status = "Unpacking…"

            let staging = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ocrlatex-update-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: staging) }

            let zip = staging.appendingPathComponent("update.zip")
            try FileManager.default.moveItem(at: downloaded, to: zip)
            try unzip(zip, into: staging)

            guard let staged = findApp(in: staging) else {
                throw UpdateError.unzip("no .app bundle in the archive")
            }
            let found = Bundle(url: staged)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
            guard found == release.version else {
                throw UpdateError.unexpectedVersion(found: found, expected: release.version)
            }

            // Keep the staged bundle after the defer removes the staging root.
            let handoff = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ocrlatex-staged-\(UUID().uuidString).app")
            try FileManager.default.moveItem(at: staged, to: handoff)

            status = "Restarting…"
            try spawnInstaller(staged: handoff, target: target)
            available = nil
            NSApp.terminate(nil)
        } catch {
            presentError(error)
        }
    }

    private func unzip(_ zip: URL, into directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zip.path, directory.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            throw UpdateError.unzip(String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "ditto failed")
        }
    }

    private func findApp(in directory: URL) -> URL? {
        guard let e = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            return nil
        }
        for case let url as URL in e where url.pathExtension == "app" {
            return url
        }
        return nil
    }

    /// Writes a small shell script that waits for this process to exit, swaps
    /// the bundle and reopens the app.
    private func spawnInstaller(staged: URL, target: URL) throws {
        let script = """
        #!/bin/bash
        APP_PID="$1"
        TARGET="$2"
        STAGED="$3"

        while kill -0 "$APP_PID" 2>/dev/null; do sleep 0.2; done
        sleep 0.4

        BACKUP="$TARGET.old"
        rm -rf "$BACKUP"
        if [ -d "$TARGET" ]; then
          mv "$TARGET" "$BACKUP" || exit 1
        fi

        if /usr/bin/ditto "$STAGED" "$TARGET"; then
          /usr/bin/xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null
          rm -rf "$BACKUP"
        else
          rm -rf "$TARGET"
          [ -d "$BACKUP" ] && mv "$BACKUP" "$TARGET"
        fi

        rm -rf "$STAGED"
        /usr/bin/open "$TARGET"
        rm -f "$0"
        """

        let scriptURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ocrlatex-update-\(UUID().uuidString).sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            scriptURL.path,
            String(ProcessInfo.processInfo.processIdentifier),
            target.path,
            staged.path
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    // MARK: - Helpers

    private func presentError(_ error: Error) {
        status = "Could not update: \(error.localizedDescription)"
        NSLog("OCRLaTeX: update failed: %@", error.localizedDescription)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Update failed"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func preview(_ notes: String) -> String {
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.count <= 500 { return trimmed }
        return String(trimmed.prefix(500)) + "…"
    }

    /// Strips a leading `v` and any pre-release suffix.
    func normalisedVersion(_ tag: String) -> String {
        var v = tag.trimmingCharacters(in: .whitespaces)
        if v.hasPrefix("v") || v.hasPrefix("V") { v.removeFirst() }
        if let dash = v.firstIndex(where: { $0 == "-" || $0 == "+" }) {
            v = String(v[v.startIndex..<dash])
        }
        return v
    }

    /// Numeric component comparison, so 1.10.0 is newer than 1.9.4.
    func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = normalisedVersion(candidate).split(separator: ".").map { Int($0) ?? 0 }
        let b = normalisedVersion(current).split(separator: ".").map { Int($0) ?? 0 }
        let count = max(a.count, b.count)
        for index in 0..<count {
            let lhs = index < a.count ? a[index] : 0
            let rhs = index < b.count ? b[index] : 0
            if lhs != rhs { return lhs > rhs }
        }
        return false
    }
}
