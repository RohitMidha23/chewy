import AppKit
import Combine
import ChewyCore
import ServiceManagement
import SwiftUI

@main
struct ChewyMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var panelController: OverlayPanelController?
    private var model: ChewyModel?
    private var cancellables: Set<AnyCancellable> = []

    private static let amber = NSColor(red: 0.98, green: 0.62, blue: 0.20, alpha: 1.0)
    private static let red = NSColor(red: 0.96, green: 0.36, blue: 0.27, alpha: 1.0)

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let paths = try ChewyPaths.defaultPaths()
            let store = AccountProfileStore(paths: paths)
            let codexHomes = CodexHomeManager(paths: paths)
            let claudeProfiles = ClaudeProfileManager(paths: paths)
            let launcher = TerminalLauncher(paths: paths)
            let model = ChewyModel(
                store: store,
                codexHomes: codexHomes,
                claudeProfiles: claudeProfiles,
                launcher: launcher,
                paths: paths
            )
            self.model = model
            model.reload()

            let panelController = OverlayPanelController(model: model)
            self.panelController = panelController
            // Auto-switch state changes — surface the island; it dismisses itself
            // once the user has had a chance to see it.
            model.onAutoSwitch = { [weak panelController] in
                panelController?.show(reason: .selfInitiated)
            }
            // Extra-usage alerts — ALWAYS on, regardless of the toggle.
            model.onUsageAlert = { [weak panelController] in
                panelController?.show(reason: .selfInitiated)
            }
            configureStatusItem()
            // Menu-bar icon doubles as a usage meter for the active account.
            model.$usage
                .receive(on: RunLoop.main)
                .sink { [weak self] snapshot in self?.updateMeter(snapshot) }
                .store(in: &cancellables)
            updateMeter(model.usage)
            // Silent on start — unless there's nothing set up yet, in which case
            // surface the island so the "Let's get set up" empty state is seen.
            if model.profiles.isEmpty {
                panelController.show(reason: .user)
            }
        } catch {
            presentStartupError(error)
        }
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let image = Self.mascotTemplateImage()
            image.accessibilityDescription = "Chewy"
            button.image = image
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        self.statusItem = item
    }

    /// The island's mascot as a menu-bar template image: the rounded robot face
    /// with two punched-out eyes. Template rendering keeps it crisp and lets the
    /// meter drive the tint (system color when quiet, amber/red when it matters).
    private static func mascotTemplateImage() -> NSImage {
        let size = NSSize(width: 18, height: 15)
        let image = NSImage(size: size, flipped: false) { rect in
            let face = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                                    xRadius: 5, yRadius: 5)
            // Punch the eyes out of the face (even-odd) so they show the bar through.
            let eyeSize = NSSize(width: 2.6, height: 3.6)
            let eyeY = rect.midY - eyeSize.height / 2
            for eyeX in [rect.midX - 4.4, rect.midX + 1.8] {
                face.append(NSBezierPath(
                    roundedRect: NSRect(x: eyeX, y: eyeY, width: eyeSize.width, height: eyeSize.height),
                    xRadius: eyeSize.width / 2, yRadius: eyeSize.width / 2))
            }
            face.windingRule = .evenOdd
            NSColor.black.setFill()
            face.fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Left-click toggles the island; right-click (or control-click) opens the menu.
    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showContextMenu()
        } else {
            panelController?.toggle()
        }
    }

    private func showContextMenu() {
        guard let button = statusItem?.button else { return }
        let menu = NSMenu()

        let toggle = NSMenuItem(title: "Auto-switch accounts",
                                action: #selector(toggleAutoSwitch), keyEquivalent: "")
        toggle.target = self
        toggle.state = (model?.autoSwitchEnabled ?? true) ? .on : .off
        menu.addItem(toggle)
        let note = NSMenuItem(title: "Extra-usage alerts are always on", action: nil, keyEquivalent: "")
        note.isEnabled = false
        menu.addItem(note)

        let open = NSMenuItem(title: "Open Chewy", action: #selector(openIsland), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        let launch = NSMenuItem(title: "Launch at Login",
                                action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launch.target = self
        launch.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(launch)

        let log = NSMenuItem(title: "Show Log File", action: #selector(showLogFile), keyEquivalent: "")
        log.target = self
        menu.addItem(log)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Chewy",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        menu.addItem(.separator())
        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let version = NSMenuItem(title: "Chewy \(shortVersion ?? "dev")", action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(version)

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    @objc private func toggleAutoSwitch() {
        model?.autoSwitchEnabled.toggle()
    }

    /// Register/unregister the app as a login item. Only works from the installed
    /// .app bundle — from `swift run` the call throws, and we surface a friendly note.
    /// Reveal the diagnostics log (percentages, decisions, HTTP statuses — never tokens).
    @objc private func showLogFile() {
        guard let url = ChewyLog.currentFileURL else { return }
        if !FileManager.default.fileExists(atPath: url.path) {
            ChewyLog.info("log opened by user")
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
                model?.lastMessage = "Chewy won't launch at login."
            } else {
                try service.register()
                model?.lastMessage = "Chewy will launch at login."
            }
        } catch {
            model?.lastMessage = "Launch at Login needs the installed app (dist/Chewy.app) — \(error.localizedDescription)"
        }
    }

    @objc private func openIsland() {
        panelController?.show()
    }

    /// Drive the menu-bar icon as a usage meter for the active account: tint by
    /// severity and show a compact label (% used, or extra-usage spend).
    private func updateMeter(_ snapshot: UsageSnapshot?) {
        guard let button = statusItem?.button else { return }
        switch UsageMeter.level(for: snapshot) {
        // nil = system template tint, so at rest the icon matches every other
        // menu-bar item; color appears only when something needs attention.
        case .normal:   button.contentTintColor = nil
        case .warning:  button.contentTintColor = Self.amber
        case .critical: button.contentTintColor = Self.red
        }
        button.title = UsageMeter.label(for: snapshot).map { " \($0)" } ?? ""
    }

    private func presentStartupError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Chewy could not start"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .critical
        alert.runModal()
        NSApplication.shared.terminate(nil)
    }
}
