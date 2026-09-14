import AppKit
import Combine
import Foundation
import ServiceManagement

@MainActor
final class AppModel: ObservableObject {
    private static let loginItemUserDisabledKey = "launchAtLoginUserDisabled"

    enum ConnectionState: Equatable {
        case waitingForCodex
        case connecting
        case connected
        case stale(String)
        case unavailable(String)

        var message: String {
            switch self {
            case .waitingForCodex: "等待 Codex 启动"
            case .connecting: "正在连接 Codex…"
            case .connected: "实时更新中"
            case let .stale(message): message
            case let .unavailable(message): message
            }
        }
    }

    @Published private(set) var snapshot: RateLimitSnapshot?
    @Published private(set) var systemSnapshot: SystemMetricsSnapshot?
    @Published private(set) var connectionState: ConnectionState = .waitingForCodex
    @Published private(set) var codexRunning = false
    @Published var panelVisible = false {
        didSet {
            guard isStarted, oldValue != panelVisible else { return }
            systemMetrics.setInterval(panelVisible ? 1 : 5)
        }
    }
    @Published var selectedSystemMetric: SystemMetricKind {
        didSet {
            UserDefaults.standard.set(selectedSystemMetric.rawValue, forKey: "selectedSystemMetric")
        }
    }
    @Published private(set) var launchAtLoginStatus = SMAppService.mainApp.status

    private let client: CodexAppServerClienting
    private let monitor: CodexLifecycleMonitoring
    private let systemMetrics: SystemMetricsSampling
    private let launchAgentController: LaunchAtLoginControlling
    private var refreshTimer: Timer?
    private var reconnectWorkItem: DispatchWorkItem?
    private var reconnectAttempt = 0
    private var isStarted = false
    private let reconnectDelays: [TimeInterval] = [2, 5, 15, 30, 60]

    convenience init() {
        self.init(
            client: CodexAppServerClient(),
            monitor: CodexLifecycleMonitor(),
            systemMetrics: SystemMetricsSampler()
        )
    }

    init(
        client: CodexAppServerClienting,
        monitor: CodexLifecycleMonitoring,
        systemMetrics: SystemMetricsSampling,
        launchAgentController: LaunchAtLoginControlling = LaunchAgentController()
    ) {
        self.client = client
        self.monitor = monitor
        self.systemMetrics = systemMetrics
        self.launchAgentController = launchAgentController
        selectedSystemMetric = SystemMetricKind(
            rawValue: UserDefaults.standard.string(forKey: "selectedSystemMetric") ?? ""
        ) ?? .cpu
        configureCallbacks()
        configureSystemMetricsCallbacks()
    }

    var remainingPercent: Double? { snapshot?.mainRemainingPercent }

    var selectedTopApplications: [SystemApplicationMetric] {
        guard let systemSnapshot else { return [] }
        switch selectedSystemMetric {
        case .cpu: return systemSnapshot.topCPU
        case .memory: return systemSnapshot.topMemory
        case .network: return systemSnapshot.topNetwork
        }
    }

    var launchAtLoginEnabled: Bool {
        if launchAtLoginStatus == .notFound {
            return launchAgentController.isInstalled
        }
        return launchAtLoginStatus == .enabled || launchAtLoginStatus == .requiresApproval
    }

    var launchAtLoginRequiresApproval: Bool {
        launchAtLoginStatus == .requiresApproval
    }

    func start() {
        panelVisible = true
        isStarted = true
        systemMetrics.start(interval: 1)
        monitor.onRunningChanged = { [weak self] running in
            self?.handleCodexRunningChanged(running)
        }
        monitor.start()
        refreshLaunchAtLoginStatus()
        if ProcessInfo.processInfo.environment["CODEX_FUEL_GAUGE_DISABLE_LOGIN_ITEM"] != "1" {
            registerAtLoginOnFirstLaunch()
        }
        startRefreshTimer()
    }

    func stop() {
        isStarted = false
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        refreshTimer?.invalidate()
        refreshTimer = nil
        monitor.stop()
        client.stop()
        systemMetrics.stop()
    }

    func togglePanel() {
        if panelVisible {
            panelVisible = false
        } else {
            panelVisible = true
        }
    }

    func refresh() {
        guard codexRunning else { return }
        if case .unavailable = connectionState {
            reconnectNow()
        } else {
            client.refresh()
        }
    }

    func reconnectNow() {
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        reconnectAttempt = 0
        guard codexRunning else { return }
        connect()
    }

    func setLaunchAtLogin(enabled: Bool) {
        UserDefaults.standard.set(!enabled, forKey: Self.loginItemUserDisabledKey)
        do {
            if enabled {
                if SMAppService.mainApp.status == .notFound {
                    try launchAgentController.install(bundleURL: Bundle.main.bundleURL)
                } else if SMAppService.mainApp.status == .notRegistered {
                    try SMAppService.mainApp.register()
                    UserDefaults.standard.set(true, forKey: "didAttemptInitialLoginItemRegistration")
                }
            } else {
                try launchAgentController.uninstall()
                if SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            NSLog("Codex Fuel Gauge login item error: %@", error.localizedDescription)
        }
        refreshLaunchAtLoginStatus()
    }

    func openLoginItemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private func configureCallbacks() {
        client.onConnected = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.connectionState = .connected
                self.reconnectAttempt = 0
            }
        }
        client.onSnapshot = { [weak self] snapshot in
            DispatchQueue.main.async {
                guard let self else { return }
                self.snapshot = snapshot
                self.connectionState = .connected
                self.reconnectAttempt = 0
                if let remaining = snapshot.mainRemainingPercent {
                    NSLog("Codex Fuel Gauge updated: %.0f%% remaining", remaining)
                }
            }
        }
        client.onBucketUpdate = { [weak self] bucket in
            DispatchQueue.main.async {
                guard let self else { return }
                if self.snapshot == nil {
                    let result = RateLimitsResult(
                        rateLimits: bucket,
                        rateLimitsByLimitId: nil,
                        rateLimitResetCredits: nil
                    )
                    self.snapshot = RateLimitSnapshot(result: result)
                } else {
                    self.snapshot?.merge(bucket: bucket)
                }
                self.connectionState = .connected
            }
        }
        client.onDisconnected = { [weak self] message in
            DispatchQueue.main.async {
                self?.handleDisconnect(message)
            }
        }
    }

    private func configureSystemMetricsCallbacks() {
        systemMetrics.onSnapshot = { [weak self] snapshot in
            DispatchQueue.main.async {
                self?.systemSnapshot = snapshot
            }
        }
    }

    private func handleCodexRunningChanged(_ running: Bool) {
        codexRunning = running
        if running {
            reconnectAttempt = 0
            connect()
        } else {
            reconnectWorkItem?.cancel()
            reconnectWorkItem = nil
            client.stop()
            snapshot = nil
            connectionState = .waitingForCodex
        }
    }

    private func connect() {
        guard codexRunning else { return }
        guard let binaryURL = CodexBinaryLocator.locate() else {
            connectionState = .unavailable("未找到 Codex 可执行文件")
            scheduleReconnect()
            return
        }
        connectionState = .connecting
        client.start(binaryURL: binaryURL)
    }

    private func handleDisconnect(_ message: String) {
        guard codexRunning else { return }
        NSLog("Codex Fuel Gauge connection issue: %@", message)
        connectionState = snapshot == nil ? .unavailable(message) : .stale("数据已过期 · \(message)")
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard codexRunning, reconnectWorkItem == nil else { return }
        let delay = reconnectDelays[min(reconnectAttempt, reconnectDelays.count - 1)]
        reconnectAttempt += 1
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.reconnectWorkItem = nil
            self.connect()
        }
        reconnectWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.codexRunning else { return }
                self.client.refresh()
                if let receivedAt = self.snapshot?.receivedAt, Date().timeIntervalSince(receivedAt) > 90 {
                    self.connectionState = .stale("数据已超过 90 秒未更新")
                }
            }
        }
    }

    private func registerAtLoginOnFirstLaunch() {
        let status = SMAppService.mainApp.status
        let userDisabled = UserDefaults.standard.bool(forKey: Self.loginItemUserDisabledKey)
        guard Self.shouldAttemptInitialLoginItemRegistration(status: status, userDisabled: userDisabled) else { return }

        do {
            if status == .notFound {
                try launchAgentController.install(bundleURL: Bundle.main.bundleURL)
            } else {
                try SMAppService.mainApp.register()
            }
            UserDefaults.standard.set(true, forKey: "didAttemptInitialLoginItemRegistration")
        } catch {
            NSLog("Codex Fuel Gauge initial login item registration error: %@", error.localizedDescription)
        }
    }

    static func shouldAttemptInitialLoginItemRegistration(
        status: SMAppService.Status,
        userDisabled: Bool
    ) -> Bool {
        !userDisabled && (status == .notRegistered || status == .notFound)
    }

    private func refreshLaunchAtLoginStatus() {
        launchAtLoginStatus = SMAppService.mainApp.status
    }
}
