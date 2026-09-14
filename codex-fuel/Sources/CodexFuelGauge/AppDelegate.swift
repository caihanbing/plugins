import AppKit
import Combine

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private var panelController: FloatingPanelController?
    private var statusItem: NSStatusItem?
    private var cancellable: AnyCancellable?

    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let updatedLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let toggleItem = NSMenuItem(title: "", action: #selector(togglePanel), keyEquivalent: "")
    private let refreshItem = NSMenuItem(title: "刷新 Codex 额度", action: #selector(refresh), keyEquivalent: "r")
    private let reconnectItem = NSMenuItem(title: "重新连接", action: #selector(reconnect), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "登录时自动运行", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
    private let loginSettingsItem = NSMenuItem(title: "在系统设置中批准登录项…", action: #selector(openLoginSettings), keyEquivalent: "")

    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
        _ = delegate
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        panelController = FloatingPanelController(model: model)
        configureStatusItem()
        configureMenu()

        cancellable = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.refreshStatusItem()
            }
        }

        model.start()
        refreshStatusItem()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "gauge.with.needle", accessibilityDescription: "Codex Fuel Gauge")
        item.button?.image?.isTemplate = true
        statusItem = item
    }

    private func configureMenu() {
        guard let statusItem else { return }
        statusLine.isEnabled = false
        updatedLine.isEnabled = false

        [toggleItem, refreshItem, reconnectItem, loginItem, loginSettingsItem].forEach { $0.target = self }
        let menu = NSMenu()
        menu.addItem(statusLine)
        menu.addItem(updatedLine)
        menu.addItem(.separator())
        menu.addItem(toggleItem)
        menu.addItem(refreshItem)
        menu.addItem(reconnectItem)
        menu.addItem(.separator())
        menu.addItem(loginItem)
        menu.addItem(loginSettingsItem)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出 Codex Fuel Gauge", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
    }

    private func refreshStatusItem() {
        guard let statusItem else { return }

        if let snapshot = model.snapshot, let menuTitle = snapshot.menuTitle {
            statusItem.button?.title = " \(menuTitle)"
            statusItem.button?.setAccessibilityLabel(
                "Codex 额度：\(snapshot.menuAccessibilityTitle ?? menuTitle)"
            )
        } else if let cpu = model.systemSnapshot?.cpuPercent {
            statusItem.button?.title = " CPU \(Int(cpu.rounded()))%"
            statusItem.button?.setAccessibilityLabel("CPU 使用率 \(Int(cpu.rounded()))%")
        } else {
            statusItem.button?.title = " --"
            statusItem.button?.setAccessibilityLabel("Codex Fuel Gauge，暂无额度或 CPU 数据")
        }

        statusLine.title = model.connectionState.message
        if let snapshot = model.snapshot {
            let updated = snapshot.receivedAt.formatted(date: .omitted, time: .shortened)
            updatedLine.title = "上次额度更新：\(updated)"
            updatedLine.isHidden = false
        } else {
            updatedLine.isHidden = true
        }

        toggleItem.title = model.panelVisible ? "隐藏油表" : "显示油表"
        toggleItem.isEnabled = true
        refreshItem.isEnabled = model.codexRunning
        reconnectItem.isEnabled = model.codexRunning
        loginItem.state = model.launchAtLoginEnabled ? .on : .off
        loginSettingsItem.isHidden = !model.launchAtLoginRequiresApproval
    }

    @objc private func togglePanel() {
        model.togglePanel()
    }

    @objc private func refresh() {
        model.refresh()
    }

    @objc private func reconnect() {
        model.reconnectNow()
    }

    @objc private func toggleLaunchAtLogin() {
        model.setLaunchAtLogin(enabled: !model.launchAtLoginEnabled)
    }

    @objc private func openLoginSettings() {
        model.openLoginItemSettings()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

}
