import AppKit
import SwiftUI

@MainActor
final class OverlayPanelController: NSObject {
    /// Why the panel was surfaced (kept for telemetry/behavior tweaks; dismissal no
    /// longer depends on it — EVERY surfacing fully disappears after ~10s without
    /// interaction: 7s expanded → pill → 3s → gone. Interaction resets the clock).
    enum ShowReason {
        case user
        case selfInitiated
    }

    private let model: ChewyModel
    private lazy var panel: NSPanel = makePanel()
    private var lastReportedHeight: CGFloat = 0
    private var showReason: ShowReason = .user
    private var dismissTimer: Timer?
    /// Pill lingers this long after the idle collapse, then the panel hides fully
    /// (7s idle-to-pill + 3s ≈ the 10s no-interaction budget).
    private let pillLingerSeconds: TimeInterval = 3

    init(model: ChewyModel) {
        self.model = model
        super.init()
        model.onMinimizedChange = { [weak self] minimized in
            if minimized {
                self?.scheduleSelfDismissIfNeeded()
            } else {
                self?.cancelSelfDismiss()
            }
        }
        // In-island forms (Add account, Remove account) need keystrokes. The panel is
        // non-activating, so it can take key status Spotlight-style without dragging
        // the whole app to the front; hand it back when the form closes.
        model.onKeyboardNeeded = { [weak self] needed in
            self?.setKeyboardCapture(needed)
        }
    }

    private func setKeyboardCapture(_ needed: Bool) {
        if needed {
            show(reason: .user)
            panel.makeKey()
        } else if panel.isKeyWindow {
            // orderOut resigns key (focus returns to the previously key app window);
            // re-show without taking key so the island stays visible.
            let wasVisible = panel.isVisible
            panel.orderOut(nil)
            if wasVisible { panel.orderFrontRegardless() }
        }
    }

    @objc func toggle() {
        if panel.isVisible {
            hide()
        } else {
            show(reason: .user)
        }
    }

    @objc func show() {
        show(reason: .user)
    }

    func show(reason: ShowReason) {
        // A user-opened panel never downgrades to self-dismissing just because an
        // automatic event lands while it's already open.
        showReason = (panel.isVisible && showReason == .user) ? .user : reason
        cancelSelfDismiss()
        panel.alphaValue = 1
        model.expandIsland() // open expanded and (re)start the idle-to-minimize countdown
        positionPanel()
        panel.orderFrontRegardless()
    }

    private func hide() {
        cancelSelfDismiss()
        panel.orderOut(nil)
        panel.alphaValue = 1
    }

    // MARK: - Idle dismiss

    /// Called when the island collapses to the pill: the pill lingers briefly,
    /// then the panel goes away entirely — no permanent pill, ever. Left-click
    /// the menu-bar icon (or the next event) brings it back.
    private func scheduleSelfDismissIfNeeded() {
        guard panel.isVisible else { return }
        dismissTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: pillLingerSeconds, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.dismissAfterIdle()
            }
        }
        timer.tolerance = 0.5
        dismissTimer = timer
    }

    private func cancelSelfDismiss() {
        dismissTimer?.invalidate()
        dismissTimer = nil
    }

    private func dismissAfterIdle() {
        dismissTimer = nil
        guard panel.isVisible, model.isMinimized else { return }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            hide()
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                // Bail if something re-surfaced or expanded the panel mid-fade.
                guard self.model.isMinimized, self.dismissTimer == nil else {
                    self.panel.alphaValue = 1
                    return
                }
                self.panel.orderOut(nil)
                self.panel.alphaValue = 1
            }
        })
    }

    private func makePanel() -> NSPanel {
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: 184),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true // only text entry makes the island key

        let root = IslandRootView(model: model) { [weak self] height in
            self?.applyContentHeight(height)
        }
        let hosting = NSHostingView(rootView: root)
        // Keep the hosting view transparent so the .behindWindow visual-effect
        // material composites against the desktop, not an opaque backing layer.
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = .clear
        panel.contentView = hosting
        return panel
    }

    /// The island grows downward from a fixed top edge, so a state change feels like
    /// the Dynamic Island morphing rather than the whole panel jumping around.
    private func applyContentHeight(_ height: CGFloat) {
        let rounded = (height * 2).rounded() / 2
        guard rounded > 1, abs(rounded - lastReportedHeight) > 0.5 else { return }
        lastReportedHeight = rounded

        guard let screen = panel.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let topEdge = visible.maxY
        let x = visible.midX - panelWidth / 2
        let target = NSRect(x: x, y: topEdge - rounded, width: panelWidth, height: rounded)

        if panel.isVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(target, display: true)
            }
        } else {
            panel.setFrame(target, display: false)
        }
    }

    private func positionPanel() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let height = lastReportedHeight > 1 ? lastReportedHeight : panel.frame.height
        let x = visible.midX - panelWidth / 2
        let y = visible.maxY - height
        panel.setFrame(NSRect(x: x, y: y, width: panelWidth, height: height), display: true)
    }

    private var panelWidth: CGFloat {
        IslandTheme.width + IslandTheme.outerPadding * 2
    }
}

/// A borderless panel refuses key status by default, which is why nothing typed
/// into an in-island text field ever arrived. Allow it explicitly; the
/// `.nonactivatingPanel` style keeps the rest of the app in the background.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
