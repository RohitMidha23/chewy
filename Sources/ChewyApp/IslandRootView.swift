import AppKit
import ChewyCore
import SwiftUI

// MARK: - Theme

enum IslandTheme {
    static let width: CGFloat = 462
    static let outerPadding: CGFloat = 20
    static let corner: CGFloat = 20
    static let sectionGap: CGFloat = 10

    static let ink = Color(red: 0.027, green: 0.030, blue: 0.038)
    /// Claude crushed-orange brand accent.
    static let accent = Color(red: 0.851, green: 0.467, blue: 0.341)
    /// Hotter ring color for extra-usage / critical attention.
    static let critical = Color(red: 0.96, green: 0.36, blue: 0.27)
    static let amber = Color(red: 0.98, green: 0.62, blue: 0.20)
}

// MARK: - Root

struct IslandRootView: View {
    @ObservedObject var model: ChewyModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    /// Reports the rendered content size so the host panel can morph to fit.
    var onHeightChange: ((CGFloat) -> Void)?

    /// Collapse to the notch pill only when idle.
    private var minimized: Bool { model.isMinimized }

    var body: some View {
        ZStack {
            if minimized {
                MinimizedPill(reduceMotion: reduceMotion)
                    .transition(.scale(scale: 0.55, anchor: .top).combined(with: .opacity))
            } else {
                fullIsland
                    .transition(.scale(scale: 0.92, anchor: .top).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity) // center the (possibly small) island in the panel
        .background(HeightReporter(onChange: onHeightChange))
        .environment(\.controlActiveState, .active) // render controls active in a non-key panel
        .scaleEffect(appeared || reduceMotion ? 1 : 0.97)
        .opacity(appeared || reduceMotion ? 1 : 0)
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: minimized)
        .animation(.easeOut(duration: 0.18), value: appeared)
        .onAppear { appeared = true; model.noteInteraction() }
        .onHover { hovering in
            if hovering { model.expandIsland() }
            model.noteInteraction()
        }
    }

    private var fullIsland: some View {
        VStack(spacing: IslandTheme.sectionGap) {
            HeaderBar(
                model: model,
                attentionLevel: attentionLevel,
                reduceMotion: reduceMotion
            )

            FooterBar(
                switchMessage: switchMessage,
                message: statusMessage,
                warning: model.envOverrideWarning,
                usageWarning: usageWarning
            )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(width: IslandTheme.width)
        .fixedSize(horizontal: false, vertical: true)
        .background(IslandShell(attentionLevel: attentionLevel, reduceMotion: reduceMotion))
        .padding(IslandTheme.outerPadding)
    }

    /// The strongest attention level currently in play, driven purely by proactive
    /// usage. Extra-usage (paying API rates) is always critical; otherwise rate-limit
    /// windows drive it (>=80% → attention, >=95% → critical).
    private var attentionLevel: AttentionLevel {
        guard let usage = model.usage else { return .quiet }
        if usage.inOverageNow { return .critical }
        let peak = usage.peakPercent
        if peak >= 95 { return .critical }
        if peak >= 80 { return .attention }
        return .quiet
    }

    /// Proactive usage line for the footer. Being IN overage right now (plan limit hit,
    /// paying API rates) is the loudest signal; otherwise warn at/above 80% of a window.
    private var usageWarning: UsageWarning? {
        guard let usage = model.usage else { return nil }

        // A concrete "switch to X" suffix when we have a recommendation.
        let switchTo: String = {
            guard let rec = model.accountRecommendation, let email = model.emailForRecommendation(rec) else {
                return ""
            }
            return " → switch to \(email) (\(rec.reason))"
        }()

        // 1) Currently paying API rates (a plan window exhausted) — flag loudest, and
        //    lead with WHICH limit is reached; cumulative cycle spend is secondary.
        if usage.inOverageNow {
            let what = usage.peakWindow.map { "\($0.label) limit reached" } ?? "Plan limit reached"
            let amount = usage.extraSpendThisCycle.map { String(format: " — on extra usage ($%.2f this cycle)", $0) }
                ?? " — on extra usage"
            let base = what + amount + "."
            let text = switchTo.isEmpty ? base + " Switch account." : base + switchTo
            return UsageWarning(text: text, critical: true)
        }

        // 2) Approaching a rate-limit window.
        guard let window = usage.peakWindow, usage.peakPercent >= 80 else { return nil }
        let rounded = Int(usage.peakPercent.rounded())
        let advice = switchTo.isEmpty ? (usage.peakPercent >= 95 ? "switch account now" : "switch account soon") : switchTo.trimmingCharacters(in: .whitespaces)
        return UsageWarning(text: "\(rounded)% of \(window.label) limit — \(advice)", critical: usage.peakPercent >= 95)
    }

    /// The auto-switch / no-viable-account outcome — the headline event, shown above
    /// even the proactive usage warning so the user always sees what the switcher did.
    private var switchMessage: String? {
        guard let message = model.lastSwitchMessage, !message.isEmpty else { return nil }
        return message
    }

    /// Generic status chatter — lowest priority; never echo the idle state.
    private var statusMessage: String? {
        let idle: Set<String> = ["Ready", "No unread agent messages", "No unread messages"]
        let message = model.lastMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, !idle.contains(message), message != switchMessage else { return nil }
        return message
    }
}

/// The mascot/ring intensity driven by the strongest pending event or usage state.
enum AttentionLevel: Int, Comparable {
    case quiet
    case attention
    case critical

    static func < (lhs: AttentionLevel, rhs: AttentionLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// A proactive usage warning surfaced in the footer (>=80% of a limit).
struct UsageWarning: Equatable {
    let text: String
    let critical: Bool
}

// MARK: - Liquid glass material

/// A live `NSVisualEffectView` blur that samples whatever sits behind the borderless
/// panel, giving the island a real frosted-glass backing.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.isEmphasized = true
        // Pin the island to dark rendering: its text is white-on-ink, so the glass
        // must never go light (e.g. hudWindow over a white desktop in light mode).
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.isEmphasized = true
    }
}

// MARK: - Shell

private struct IslandShell: View {
    let attentionLevel: AttentionLevel
    let reduceMotion: Bool
    @State private var glow = false

    private var active: Bool { attentionLevel != .quiet }
    private var accent: Color {
        attentionLevel == .critical ? IslandTheme.critical : IslandTheme.accent
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: IslandTheme.corner, style: .continuous)
        return ZStack {
            // Bottom layer: live frosted-glass blur of the desktop behind the panel.
            VisualEffectBackground()
                .clipShape(shape)
            // Translucent ink tint so the material reads through as glass depth.
            shape
                .fill(
                    LinearGradient(
                        colors: [
                            IslandTheme.ink.opacity(0.50),
                            IslandTheme.ink.opacity(0.54),
                            Color.black.opacity(0.58)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
            .overlay {
                // Brighter top highlight for the glass edge.
                RoundedRectangle(cornerRadius: IslandTheme.corner, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [.white.opacity(0.20), .white.opacity(0.05)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            }
            .overlay {
                // Accent ring. Critical holds a hotter, more opaque persistent ring.
                RoundedRectangle(cornerRadius: IslandTheme.corner, style: .continuous)
                    .stroke(accent.opacity(ringOpacity), lineWidth: attentionLevel == .critical ? 2 : 1.5)
            }
            // Soft lift, not a halo — a heavy dark shadow reads as a muddy outline
            // against dark desktops/windows.
            .shadow(color: .black.opacity(0.22), radius: 9, y: 3)
            .shadow(color: accent.opacity(active ? (glow ? 0.34 : 0.18) : 0), radius: 22, y: 0)
            .onAppear { startGlow() }
            .onChange(of: attentionLevel) { _ in startGlow() }
    }

    private var ringOpacity: Double {
        switch attentionLevel {
        case .quiet: return 0
        case .attention: return glow ? 0.55 : 0.22
        case .critical: return glow ? 0.85 : 0.55 // hotter persistent ring
        }
    }

    private func startGlow() {
        guard active, !reduceMotion else {
            glow = false
            return
        }
        let duration = attentionLevel == .critical ? 0.9 : 1.5
        withAnimation(.easeInOut(duration: duration).repeatForever(autoreverses: true)) {
            glow = true
        }
    }
}

// MARK: - Brand logos

/// Loads the real Claude / Codex brand icons bundled in Resources, cached.
@MainActor
enum BrandAsset {
    private static var cache: [AccountTool: NSImage] = [:]

    static func image(for tool: AccountTool) -> NSImage? {
        if let cached = cache[tool] { return cached }
        let name = tool == .claude ? "claude" : "codex"
        guard
            let url = Bundle.module.url(forResource: name, withExtension: "png"),
            let image = NSImage(contentsOf: url)
        else { return nil }
        cache[tool] = image
        return image
    }

    /// A copy sized for menu rows — system menus draw at the NSImage's own
    /// `size`, so we must shrink it here (a SwiftUI `.frame` is ignored there).
    static func menuIcon(for tool: AccountTool) -> NSImage? {
        guard let base = image(for: tool)?.copy() as? NSImage else { return nil }
        base.size = NSSize(width: 15, height: 15)
        // Codex mark is monochrome → template so it adapts to the menu's light/dark
        // appearance. Claude stays colored (orange reads on both).
        if tool == .codex { base.isTemplate = true }
        return base
    }
}

// MARK: - Mascot (the Chewy "bot")

/// The island's own mascot — NOT a tool logo. Breathing idle, blink, and an
/// attention/critical halo. Brand logos live on the account rows, not here.
private struct MascotGlyph: View {
    let attentionLevel: AttentionLevel
    let reduceMotion: Bool
    /// Idle breathing runs a repeatForever animation — the resting pill opts out
    /// so an idle island costs ~zero CPU. The occasional blink stays.
    var breathes: Bool = true
    /// Bumped by the host when an auto-switch lands: triggers a one-shot happy hop.
    var switchPulse: Int = 0

    @State private var blink = false
    @State private var breathe = false
    @State private var halo = false
    @State private var hopOffset: CGFloat = 0
    @State private var squint = false

    private var active: Bool { attentionLevel != .quiet }
    private var accent: Color {
        attentionLevel == .critical ? IslandTheme.critical : IslandTheme.accent
    }

    var body: some View {
        ZStack {
            if active {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(accent.opacity(attentionLevel == .critical ? 0.7 : 0.5),
                            lineWidth: attentionLevel == .critical ? 2.5 : 2)
                    .frame(width: 34, height: 34)
                    .scaleEffect(halo ? 1.14 : 0.9)
                    .opacity(halo ? (attentionLevel == .critical ? 0.2 : 0) : 0.75)
            }

            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(LinearGradient(colors: [accent.opacity(0.97), accent.opacity(0.80)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 26, height: 22)
                .scaleEffect(breathe ? 1.04 : 1.0)
                .overlay(alignment: .center) {
                    HStack(spacing: 6) { eye; eye }
                        .offset(y: active ? -1.5 : 0.5)
                }
                .shadow(color: accent.opacity(active ? 0.6 : 0.25), radius: active ? 9 : 4)
                .offset(y: hopOffset)
        }
        .frame(width: 34, height: 34)
        .task(id: active) { await runBlink() }
        .onAppear { startAnimations() }
        .onChange(of: attentionLevel) { _ in startAnimations() }
        .onChange(of: switchPulse) { _ in hop() }
    }

    private var eye: some View {
        Capsule(style: .continuous)
            .fill(Color.black.opacity(0.82))
            .frame(width: 4, height: eyeHeight)
    }

    private var eyeHeight: CGFloat {
        if blink { return 1.2 }
        if squint { return 2.4 } // happy squint mid-hop
        return active ? 7 : 5
    }

    private func startAnimations() {
        guard !reduceMotion else { breathe = false; halo = false; return }
        if breathes {
            withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) { breathe = true }
        } else {
            breathe = false
        }
        if active {
            let duration = attentionLevel == .critical ? 0.9 : 1.5
            withAnimation(.easeOut(duration: duration).repeatForever(autoreverses: false)) { halo = true }
        } else {
            halo = false
        }
    }

    /// One-shot celebratory hop + eye squint when an auto-switch lands.
    private func hop() {
        guard !reduceMotion else { return }
        Task { @MainActor in
            withAnimation(.interpolatingSpring(stiffness: 320, damping: 11)) { hopOffset = -7 }
            withAnimation(.easeInOut(duration: 0.1)) { squint = true }
            try? await Task.sleep(nanoseconds: 320_000_000)
            withAnimation(.spring(response: 0.32, dampingFraction: 0.55)) { hopOffset = 0 }
            try? await Task.sleep(nanoseconds: 500_000_000)
            withAnimation(.easeOut(duration: 0.15)) { squint = false }
        }
    }

    private func runBlink() async {
        guard !reduceMotion else { return }
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(Int.random(in: 2_600...4_400)) * 1_000_000)
            if Task.isCancelled { return }
            withAnimation(.easeInOut(duration: 0.08)) { blink = true }
            try? await Task.sleep(nanoseconds: 110_000_000)
            withAnimation(.easeInOut(duration: 0.12)) { blink = false }
        }
    }
}

// MARK: - Minimized pill (the "dynamic island" resting state)

/// The collapsed island: just the resting mascot, centered at the notch.
/// Hover or click to expand back to the full island. No repeatForever work here —
/// an idle pill should cost ~zero CPU (blink is a rare one-shot).
private struct MinimizedPill: View {
    let reduceMotion: Bool

    var body: some View {
        HStack(spacing: 8) {
            MascotGlyph(attentionLevel: .quiet, reduceMotion: reduceMotion, breathes: false)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(IslandShell(attentionLevel: .quiet, reduceMotion: reduceMotion))
        .padding(IslandTheme.outerPadding)
        .contentShape(Rectangle())
    }
}

// MARK: - Header

private struct HeaderBar: View {
    @ObservedObject var model: ChewyModel
    let attentionLevel: AttentionLevel
    let reduceMotion: Bool
    @State private var switchPulse = 0

    var body: some View {
        HStack(spacing: 11) {
            MascotGlyph(attentionLevel: attentionLevel, reduceMotion: reduceMotion, switchPulse: switchPulse)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                Text(statusSubtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(2) // the panel morphs height, so let long emails wrap
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            AccountMenu(model: model)
        }
        .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
        .onChange(of: model.lastSwitchMessage) { message in
            guard message != nil else { return }
            switchPulse += 1 // one-shot mascot hop per switch event
        }
    }

    private var profileCount: Int { model.profiles.count }

    private var statusTitle: String {
        switch attentionLevel {
        case .critical: return "Heads up"
        case .attention: return "Running low"
        case .quiet: return profileCount == 0 ? "Let's get set up" : "All clear"
        }
    }

    /// Active account + its rate-limit window. Falls back to setup/watching copy.
    private var statusSubtitle: String {
        guard profileCount > 0 else { return "Add a Claude or Codex account" }
        guard let active = model.activeProfile(for: .claude) else {
            return "Watching \(profileCount) account\(profileCount == 1 ? "" : "s")"
        }
        let email = model.accountManager.resolvedEmail(for: active) ?? active.name
        guard let snapshot = model.usageByAccount[active.id] else { return email }
        // Extra usage only begins AFTER a plan window is exhausted — so in overage the
        // limit is reached. Say that, rather than hiding it behind cumulative spend.
        if snapshot.inOverageNow {
            let what = snapshot.peakWindow.map { "\($0.label) limit reached" } ?? "limit reached"
            return "\(email) · \(what)"
        }
        if let window = snapshot.fiveHourWindow ?? snapshot.peakWindow {
            return "\(email) · \(Int(window.usedPercent.rounded()))% of \(window.label)"
        }
        return email
    }
}

// MARK: - Account menu

private struct AccountMenu: View {
    @ObservedObject var model: ChewyModel

    private var isEmpty: Bool { model.profiles.isEmpty }

    var body: some View {
        Menu {
            if isEmpty {
                // First run: the two add actions front and center — no empty sections.
                Button("Add Claude account…") { model.addClaude() }
                Button("Add Codex account…") { model.addCodex() }
                pendingLoginButton
            } else {
                section(title: "Claude", tool: .claude)
                Divider()
                section(title: "Codex", tool: .codex)
                Divider()
                Button("Add Claude account…") { model.addClaude() }
                Button("Add Codex account…") { model.addCodex() }
                pendingLoginButton
                if model.hasUnsignedAccounts {
                    Divider()
                    Button("Remove accounts that aren't signed in") { model.removeUnsignedAccounts() }
                }
                if model.accountManager.canRestoreOriginal() {
                    Divider()
                    Button("Restore original account") { model.restoreOriginal() }
                }
                Divider()
                Menu("Remove account") {
                    ForEach(model.profiles) { profile in
                        Button("Remove \(label(for: profile))…") { model.removeAccount(profile) }
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(isEmpty ? "Add account" : "Accounts").font(.system(size: 12, weight: .semibold))
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
            }
            // Literal fills (not a system control style) so it can never render in
            // the greyed inactive-window appearance of a non-key panel.
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(IslandTheme.accent, in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.22), lineWidth: 1))
            .shadow(color: IslandTheme.accent.opacity(0.4), radius: 5, y: 1)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// Shown while an add-account login has timed out but may still complete.
    @ViewBuilder
    private var pendingLoginButton: some View {
        if model.pendingLogin != nil {
            Button {
                model.finishPendingLogin()
            } label: {
                Label("I've finished signing in", systemImage: "checkmark.circle")
            }
        }
    }

    @ViewBuilder
    private func section(title: String, tool: AccountTool) -> some View {
        Section(title) {
            let profiles = model.profiles(for: tool)
            if profiles.isEmpty {
                Text("No accounts yet")
            } else {
                ForEach(profiles) { profile in
                    if model.reconnectNeeded.contains(profile.id) {
                        // A dead sign-in outranks usage: flag it natively, and offer
                        // an in-place re-authentication right below.
                        Button {
                            model.select(profile)
                        } label: {
                            Label("\(label(for: profile)) — sign-in expired",
                                  systemImage: "exclamationmark.triangle.fill")
                        }
                        Button {
                            model.reconnect(profile)
                        } label: {
                            Label("Reconnect \(reconnectLabel(for: profile))",
                                  systemImage: "arrow.uturn.forward")
                        }
                    } else {
                        // Native checkmark state for the active account; selecting a
                        // row performs the global swap. Real brand logo on each row
                        // (sized via NSImage.size).
                        Toggle(isOn: activeBinding(for: profile)) {
                            if let icon = BrandAsset.menuIcon(for: tool) {
                                Label {
                                    Text(rowText(for: profile))
                                } icon: {
                                    Image(nsImage: icon)
                                }
                            } else {
                                Text(rowText(for: profile))
                            }
                        }
                    }
                }
            }
        }
    }

    /// Menu-row binding: "on" mirrors the active account; turning a row on swaps
    /// to it (turning the active row "off" is a no-op — one account is always active).
    private func activeBinding(for profile: AccountProfile) -> Binding<Bool> {
        Binding(
            get: { isActive(profile) },
            set: { turnedOn in
                if turnedOn { model.select(profile) }
            }
        )
    }

    private func isActive(_ profile: AccountProfile) -> Bool {
        model.activeProfile(for: profile.tool)?.id == profile.id
    }

    /// Short label for the Reconnect action row (email when known, else the name).
    private func reconnectLabel(for profile: AccountProfile) -> String {
        model.accountManager.resolvedEmail(for: profile) ?? profile.name
    }

    /// Signed-in accounts show their email; un-signed stubs are clearly marked
    /// (and stay distinguishable from each other) instead of leaking internal names.
    private func label(for profile: AccountProfile) -> String {
        if let email = model.accountManager.resolvedEmail(for: profile) {
            return email
        }
        return "\(profile.name) · not signed in"
    }

    /// Row text: email + per-account usage. The active state renders as a native
    /// menu checkmark (Toggle), so no glyphs here — just a "(recommended)" tag
    /// carried in text, not color alone (WCAG 1.4.1).
    private func rowText(for profile: AccountProfile) -> String {
        var text = label(for: profile)
        if let usage = usageSuffix(for: profile) {
            text += "  —  \(usage)"
        }
        if !isActive(profile), model.accountRecommendation?.id == profile.id {
            text += "  (recommended)"
        }
        return text
    }

    /// Compact per-account usage for the dropdown: an over-limit flag when actually
    /// in overage, else the hottest window % + reset countdown. A Claude account
    /// whose usage we can't read (its stored token expired — idle >8h) is labeled
    /// honestly: idle that long means its 5-hour window has fully reset, and we
    /// never refresh idle tokens ourselves (single-use refresh tokens). Codex has
    /// no usage source wired, so its rows stay bare.
    private func usageSuffix(for profile: AccountProfile) -> String? {
        guard let snapshot = model.usageByAccount[profile.id] else {
            // Only signed-in Claude accounts get the "likely fresh" read — an
            // un-signed stub has no credential and its row already says so.
            guard profile.tool == .claude,
                  model.accountManager.hasVaultCredential(for: profile) else { return nil }
            // For an IDLE account unknown is expected (its token ages out; idle >8h
            // means the 5-hour window reset). For the ACTIVE account it's a tell —
            // the canonical token isn't working — so say that, not "fresh".
            return isActive(profile)
                ? "usage unreadable — sign-in may need attention"
                : "usage unknown · likely fresh"
        }
        if snapshot.inOverageNow {
            if let dollars = snapshot.extraSpendThisCycle {
                return String(format: "over limit · $%.0f/cycle", dollars)
            }
            return "over limit"
        }
        // Show the 5-hour (session) window — what users think in terms of — falling
        // back to the hottest window if 5h isn't reported.
        let window = snapshot.fiveHourWindow ?? snapshot.peakWindow
        let pct = window?.usedPercent ?? snapshot.peakPercent
        let label = window?.label ?? "5-hour"
        let pctText = "\(Int(pct.rounded()))% of \(label)"
        if let resets = UsageMonitor.shortTimeUntil(window?.resetsAt) {
            return "\(pctText) · resets \(resets)"
        }
        return pctText
    }
}

// MARK: - Footer

private struct FooterBar: View {
    var switchMessage: String?
    let message: String?
    let warning: String?
    var usageWarning: UsageWarning?

    var body: some View {
        if let warning {
            // env override warning takes priority, amber.
            HStack(spacing: 7) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(IslandTheme.amber)
                Text(warning)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(IslandTheme.amber.opacity(0.92))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let switchMessage {
            // The auto-switch outcome is the headline — show it above the usage warning.
            HStack(spacing: 7) {
                SwitchGlyph(message: switchMessage)
                Text(switchMessage)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let usageWarning {
            // Proactive usage warning: amber at >=80%, hotter at >=95%.
            let tint = usageWarning.critical ? IslandTheme.critical : IslandTheme.amber
            HStack(spacing: 7) {
                Image(systemName: usageWarning.critical ? "gauge.high" : "gauge.medium")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(tint)
                Text(usageWarning.text)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(tint.opacity(0.95))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let message {
            HStack(spacing: 7) {
                Circle()
                    .fill(IslandTheme.accent.opacity(0.8))
                    .frame(width: 4, height: 4)
                Text(message)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
                Spacer()
            }
            .frame(height: 18)
        }
    }
}

/// The footer glyph for a switch message: a checkmark springs in (0.6 → 1.0) to
/// celebrate the landed switch, then settles into the steady-state arrows after
/// ~1.2s. One-shot per message; static under Reduce Motion.
private struct SwitchGlyph: View {
    let message: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showCheck = false
    @State private var scale: CGFloat = 1

    var body: some View {
        Image(systemName: showCheck ? "checkmark.circle.fill" : "arrow.left.arrow.right")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(IslandTheme.accent)
            .scaleEffect(scale)
            .task(id: message) {
                guard !reduceMotion else {
                    showCheck = false
                    scale = 1
                    return
                }
                showCheck = true
                scale = 0.6
                withAnimation(.spring(response: 0.35, dampingFraction: 0.55)) { scale = 1.0 }
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                withAnimation(.easeInOut(duration: 0.2)) { showCheck = false }
            }
    }
}

// MARK: - Shared pieces

/// Reports the laid-out height back to the host so the panel can resize to fit.
private struct HeightReporter: View {
    let onChange: ((CGFloat) -> Void)?

    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { onChange?(proxy.size.height) }
                .onChange(of: proxy.size.height) { onChange?($0) }
        }
    }
}
