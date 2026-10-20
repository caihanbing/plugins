import AppKit
import Combine
import SwiftUI

@MainActor
final class PanelDragCoordinator {
    private weak var window: NSWindow?
    private var previousMouseLocation: NSPoint?

    func setWindow(_ window: NSWindow?) {
        guard self.window !== window else { return }
        self.window = window
        endDrag()
    }

    func updateDrag() {
        guard let window else { return }
        let mouseLocation = NSEvent.mouseLocation
        guard let previousMouseLocation else {
            self.previousMouseLocation = mouseLocation
            return
        }

        window.setFrameOrigin(NSPoint(
            x: window.frame.origin.x + mouseLocation.x - previousMouseLocation.x,
            y: window.frame.origin.y + mouseLocation.y - previousMouseLocation.y
        ))
        self.previousMouseLocation = mouseLocation
    }

    func endDrag() {
        previousMouseLocation = nil
    }
}

@MainActor
final class FloatingPanelController: NSObject, NSWindowDelegate {
    private enum Layout {
        static let width: CGFloat = 420
        static let compactHeight: CGFloat = 560
    }

    private let panel: NSPanel
    private let model: AppModel
    private let dragCoordinator = PanelDragCoordinator()
    private var cancellables = Set<AnyCancellable>()

    init(model: AppModel) {
        self.model = model
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Layout.width, height: Layout.compactHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.delegate = self
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = true
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        panel.contentView = NSHostingView(rootView: GaugeRootView(model: model, dragCoordinator: dragCoordinator))

        restorePosition()

        model.$panelVisible
            .removeDuplicates()
            .sink { [weak self] visible in
                self?.setVisible(visible)
            }
            .store(in: &cancellables)

    }

    func windowDidMove(_ notification: Notification) {
        UserDefaults.standard.set(NSStringFromPoint(panel.frame.origin), forKey: "floatingPanelOrigin")
    }

    private func setVisible(_ visible: Bool) {
        if visible {
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }

    private func restorePosition() {
        if let stored = UserDefaults.standard.string(forKey: "floatingPanelOrigin") {
            let origin = NSPointFromString(stored)
            let candidate = NSRect(origin: origin, size: panel.frame.size)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(candidate) }) {
                panel.setFrameOrigin(origin)
                return
            }
        }

        guard let visibleFrame = NSScreen.main?.visibleFrame else {
            panel.center()
            return
        }
        panel.setFrameOrigin(NSPoint(
            x: visibleFrame.maxX - Layout.width - 24,
            y: visibleFrame.maxY - Layout.compactHeight - 24
        ))
    }
}
