import AppKit
import Foundation

@MainActor
protocol CodexLifecycleMonitoring: AnyObject {
    var onRunningChanged: ((Bool) -> Void)? { get set }
    var isRunning: Bool { get }

    func start()
    func stop()
}

@MainActor
final class CodexLifecycleMonitor: CodexLifecycleMonitoring {
    static let bundleIdentifier = "com.openai.codex"

    var onRunningChanged: ((Bool) -> Void)?

    private var observers: [NSObjectProtocol] = []
    private(set) var isRunning = false

    func start() {
        guard observers.isEmpty else { return }

        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                self?.handle(notification)
            }
        })
        observers.append(center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                self?.handle(notification)
            }
        })

        updateRunningState()
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach(center.removeObserver)
        observers.removeAll()
    }

    private func handle(_ notification: Notification) {
        guard
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
            application.bundleIdentifier == Self.bundleIdentifier
        else { return }
        updateRunningState()
    }

    private func updateRunningState() {
        let newValue = !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).isEmpty
        guard newValue != isRunning else { return }
        isRunning = newValue
        onRunningChanged?(newValue)
    }
}
