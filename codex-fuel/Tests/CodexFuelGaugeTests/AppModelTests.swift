import Foundation
import ServiceManagement
import Testing
@testable import CodexFuelGauge

@Suite("App model system monitoring")
@MainActor
struct AppModelTests {
    @Test("Starting the app shows the panel and starts system metrics at one second")
    func startsVisibleWithForegroundSampling() {
        let client = FakeCodexClient()
        let monitor = FakeCodexLifecycleMonitor()
        let metrics = FakeSystemMetricsSampler()
        let model = AppModel(client: client, monitor: monitor, systemMetrics: metrics, launchAgentController: FakeLaunchAgentController())

        model.start()

        #expect(model.panelVisible)
        #expect(metrics.startedIntervals == [1])
        #expect(!model.codexRunning)

        model.stop()
        #expect(metrics.stopCount == 1)
    }

    @Test("Hiding the panel switches metrics to five second sampling")
    func hidesWithBackgroundSampling() {
        let metrics = FakeSystemMetricsSampler()
        let model = AppModel(
            client: FakeCodexClient(),
            monitor: FakeCodexLifecycleMonitor(),
            systemMetrics: metrics,
            launchAgentController: FakeLaunchAgentController()
        )

        model.start()
        model.togglePanel()

        #expect(!model.panelVisible)
        #expect(metrics.intervalChanges == [5])
    }

    @Test("Codex lifecycle does not force a manually hidden panel visible")
    func codexLifecycleDoesNotShowHiddenPanel() {
        let client = FakeCodexClient()
        let monitor = FakeCodexLifecycleMonitor()
        let metrics = FakeSystemMetricsSampler()
        let model = AppModel(client: client, monitor: monitor, systemMetrics: metrics, launchAgentController: FakeLaunchAgentController())

        model.start()
        model.togglePanel()
        monitor.emit(running: true)

        #expect(!model.panelVisible)
        model.stop()
    }

    @Test("Stopping Codex clears quota but leaves the dashboard visible")
    func stoppingCodexLeavesDashboardVisible() {
        let monitor = FakeCodexLifecycleMonitor()
        let model = AppModel(
            client: FakeCodexClient(),
            monitor: monitor,
            systemMetrics: FakeSystemMetricsSampler(),
            launchAgentController: FakeLaunchAgentController()
        )

        model.start()
        monitor.emit(running: true)
        monitor.emit(running: false)

        #expect(model.panelVisible)
        #expect(model.snapshot == nil)
        #expect(model.connectionState == .waitingForCodex)
        model.stop()
    }

    @Test("Selected top metric persists and defaults to CPU")
    func persistsSelectedTopMetric() {
        let key = "selectedSystemMetric"
        UserDefaults.standard.removeObject(forKey: key)

        let first = AppModel(
            client: FakeCodexClient(),
            monitor: FakeCodexLifecycleMonitor(),
            systemMetrics: FakeSystemMetricsSampler(),
            launchAgentController: FakeLaunchAgentController()
        )
        #expect(first.selectedSystemMetric == .cpu)
        first.selectedSystemMetric = .network

        let second = AppModel(
            client: FakeCodexClient(),
            monitor: FakeCodexLifecycleMonitor(),
            systemMetrics: FakeSystemMetricsSampler(),
            launchAgentController: FakeLaunchAgentController()
        )
        #expect(second.selectedSystemMetric == .network)
        UserDefaults.standard.removeObject(forKey: key)
    }

    @Test("Login item registration retries after failure unless user disabled it")
    func loginItemRegistrationPolicyRetriesUnregisteredItems() {
        #expect(AppModel.shouldAttemptInitialLoginItemRegistration(status: .notRegistered, userDisabled: false))
        #expect(AppModel.shouldAttemptInitialLoginItemRegistration(status: .notFound, userDisabled: false))
        #expect(!AppModel.shouldAttemptInitialLoginItemRegistration(status: .notRegistered, userDisabled: true))
        #expect(!AppModel.shouldAttemptInitialLoginItemRegistration(status: .enabled, userDisabled: false))
    }
}

private final class FakeSystemMetricsSampler: SystemMetricsSampling {
    var onSnapshot: ((SystemMetricsSnapshot) -> Void)?
    var startedIntervals: [TimeInterval] = []
    var intervalChanges: [TimeInterval] = []
    var stopCount = 0

    func start(interval: TimeInterval) {
        startedIntervals.append(interval)
    }

    func setInterval(_ interval: TimeInterval) {
        intervalChanges.append(interval)
    }

    func stop() {
        stopCount += 1
    }
}

@MainActor
private final class FakeCodexLifecycleMonitor: CodexLifecycleMonitoring {
    var onRunningChanged: ((Bool) -> Void)?
    var isRunning = false

    func start() {}
    func stop() {}

    func emit(running: Bool) {
        isRunning = running
        onRunningChanged?(running)
    }
}

private final class FakeCodexClient: CodexAppServerClienting {
    var onSnapshot: ((RateLimitSnapshot) -> Void)?
    var onBucketUpdate: ((LimitBucket) -> Void)?
    var onConnected: (() -> Void)?
    var onDisconnected: ((String) -> Void)?

    func start(binaryURL: URL) {}
    func stop() {}
    func refresh() {}
}

private final class FakeLaunchAgentController: LaunchAtLoginControlling {
    var isInstalled = false

    func install(bundleURL: URL) throws {
        isInstalled = true
    }

    func uninstall() throws {
        isInstalled = false
    }
}
