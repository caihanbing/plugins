import Foundation
import Testing
@testable import CodexFuelGauge

@Suite("Codex binary locator")
struct CodexBinaryLocatorTests {
    @Test("Keeps locating the legacy resource path")
    func locatesLegacyResourcePath() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let expected = fixture.app.appendingPathComponent("Contents/Resources/codex")
        try makeExecutable(at: expected)

        let located = CodexBinaryLocator.locate(
            appURL: fixture.app,
            homeDirectory: fixture.root,
            fileManager: .default
        )

        #expect(located?.path == expected.path)
    }

    @Test("Prefers the official current wrapper when all layouts exist")
    func prefersCurrentWrapperPath() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let legacy = fixture.app.appendingPathComponent("Contents/Resources/codex")
        let wrapper = fixture.app.appendingPathComponent("Contents/Resources/codex-cli/bin/codex")
        let nested = fixture.app.appendingPathComponent(
            "Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
        )
        try makeExecutable(at: legacy)
        try makeExecutable(at: wrapper)
        try makeExecutable(at: nested)

        let located = CodexBinaryLocator.locate(
            appURL: fixture.app,
            homeDirectory: fixture.root,
            fileManager: .default
        )

        #expect(located?.path == wrapper.path)
    }

    @Test("Locates the current Codex CLI wrapper path")
    func locatesCurrentWrapperPath() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let expected = fixture.app.appendingPathComponent("Contents/Resources/codex-cli/bin/codex")
        try makeExecutable(at: expected)

        let located = CodexBinaryLocator.locate(
            appURL: fixture.app,
            homeDirectory: fixture.root,
            fileManager: .default
        )

        #expect(located?.path == expected.path)
    }

    @Test("Falls back to the current nested Codex CLI binary")
    func locatesCurrentNestedBinaryPath() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let expected = fixture.app.appendingPathComponent(
            "Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
        )
        try makeExecutable(at: expected)

        let located = CodexBinaryLocator.locate(
            appURL: fixture.app,
            homeDirectory: fixture.root,
            fileManager: .default
        )

        #expect(located?.path == expected.path)
    }

    @Test("Falls back to the nested binary when the wrapper is not executable")
    func fallsBackToNestedBinaryWhenWrapperIsNotExecutable() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let wrapper = fixture.app.appendingPathComponent("Contents/Resources/codex-cli/bin/codex")
        let nested = fixture.app.appendingPathComponent(
            "Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
        )
        try makeFile(at: wrapper, permissions: 0o644)
        try makeExecutable(at: nested)

        let located = CodexBinaryLocator.locate(
            appURL: fixture.app,
            homeDirectory: fixture.root,
            fileManager: .default,
            applicationURLs: [],
            cliURLs: []
        )

        #expect(located?.path == nested.path)
    }

    @Test("Returns no path when no candidate is executable")
    func returnsNilWhenNoCandidateIsExecutable() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let located = CodexBinaryLocator.locate(
            appURL: fixture.app,
            homeDirectory: fixture.root,
            fileManager: .default,
            applicationURLs: [],
            cliURLs: []
        )

        #expect(located == nil)
    }

    @Test("Locates an injected fallback application when bundle lookup is unavailable")
    func locatesInjectedFallbackApplicationWithoutBundleLookup() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let fallbackApp = fixture.root.appendingPathComponent("Applications/ChatGPT.app")
        let expected = fallbackApp.appendingPathComponent("Contents/Resources/codex-cli/bin/codex")
        try makeExecutable(at: expected)

        let located = CodexBinaryLocator.locate(
            appURL: nil,
            homeDirectory: fixture.root,
            fileManager: .default,
            applicationURLs: [fallbackApp],
            cliURLs: []
        )

        #expect(located?.path == expected.path)
    }
}

private extension CodexBinaryLocatorTests {
    func makeFixture() throws -> (root: URL, app: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexFuelGaugeLocatorTests-\(UUID().uuidString)", isDirectory: true)
        let app = root.appendingPathComponent("ChatGPT.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        return (root, app)
    }

    func makeExecutable(at url: URL) throws {
        try makeFile(at: url, permissions: 0o755)
    }

    func makeFile(at url: URL, permissions: Int) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data())
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }
}
