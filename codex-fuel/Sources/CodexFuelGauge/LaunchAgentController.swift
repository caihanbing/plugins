import Foundation

protocol LaunchAtLoginControlling: AnyObject {
    var isInstalled: Bool { get }

    func install(bundleURL: URL) throws
    func uninstall() throws
}

enum LaunchAgentPlistBuilder {
    static let label = "com.codexfuelgauge.app"

    static func data(for bundleURL: URL) throws -> Data {
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": ["/usr/bin/open", "-a", bundleURL.path],
            "ProcessType": "Interactive",
            "RunAtLoad": true,
        ]
        return try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
    }
}

final class LaunchAgentController: LaunchAtLoginControlling {
    private let fileManager: FileManager
    private let launchAgentURL: URL

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        launchAgentURL = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(LaunchAgentPlistBuilder.label).plist")
    }

    var isInstalled: Bool {
        fileManager.fileExists(atPath: launchAgentURL.path)
    }

    func install(bundleURL: URL) throws {
        let directory = launchAgentURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try LaunchAgentPlistBuilder.data(for: bundleURL).write(to: launchAgentURL, options: .atomic)
    }

    func uninstall() throws {
        guard isInstalled else { return }
        try fileManager.removeItem(at: launchAgentURL)
    }
}
