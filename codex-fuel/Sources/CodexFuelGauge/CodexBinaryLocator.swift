import AppKit
import Foundation

enum CodexBinaryLocator {
    private static let bundledRelativePaths = [
        "Contents/Resources/codex-cli/bin/codex",
        "Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
        "Contents/Resources/codex",
    ]

    static func locate() -> URL? {
        locate(
            appURL: NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex"),
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            fileManager: .default
        )
    }

    static func locate(
        appURL: URL?,
        homeDirectory: URL,
        fileManager: FileManager,
        applicationURLs: [URL]? = nil,
        cliURLs: [URL]? = nil
    ) -> URL? {
        var candidates: [URL] = []

        if let appURL {
            candidates.append(contentsOf: bundledCandidates(for: appURL))
        }

        let fixedApplicationURLs = applicationURLs ?? [
            URL(fileURLWithPath: "/Applications/ChatGPT.app"),
            homeDirectory.appendingPathComponent("Applications/ChatGPT.app"),
        ]
        for applicationURL in fixedApplicationURLs where applicationURL != appURL {
            candidates.append(contentsOf: bundledCandidates(for: applicationURL))
        }

        candidates.append(contentsOf: cliURLs ?? [
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex"),
        ])

        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    private static func bundledCandidates(for applicationURL: URL) -> [URL] {
        bundledRelativePaths.map { applicationURL.appendingPathComponent($0) }
    }
}
