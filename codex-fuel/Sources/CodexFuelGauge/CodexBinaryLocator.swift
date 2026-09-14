import AppKit
import Foundation

enum CodexBinaryLocator {
    static func locate() -> URL? {
        var candidates: [URL] = []

        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") {
            candidates.append(appURL.appendingPathComponent("Contents/Resources/codex"))
        }

        candidates.append(contentsOf: [
            URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex"),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications/ChatGPT.app/Contents/Resources/codex"),
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex"),
        ])

        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}
