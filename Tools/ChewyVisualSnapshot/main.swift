import AppKit
import SwiftUI

// A faithful mirror of the rebuilt IslandRootView (the focused auto-switcher) used
// only to render verification screenshots. The app target can't be imported here, so
// the presentational pieces are duplicated. Brand accent is Claude crushed-orange #D97757.
//
// The island now shows: a mascot, a usage-driven status line (active account + its
// 5-hour usage), the Accounts dropdown, and a footer that surfaces auto-switch / no-
// viable-account messages. There is no attention "hero" / "Jump in" anymore.

/// Mirrors the app's liquid-glass material so the snapshot stays representative.
/// In the offscreen bitmap this renders as the material's base tint (no live desktop).
private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = true
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

private enum Theme {
    static let width: CGFloat = 462
    static let ink = Color(red: 0.027, green: 0.030, blue: 0.038)
    static let accent = Color(red: 0.851, green: 0.467, blue: 0.341)
    static let critical = Color(red: 0.96, green: 0.36, blue: 0.27)
    static let amber = Color(red: 0.98, green: 0.62, blue: 0.20)
}

private enum Level {
    case quiet
    case attention
    case critical

    var active: Bool { self != .quiet }
    var accent: Color { self == .critical ? Theme.critical : Theme.accent }
}

/// One island state: a usage-driven status line plus an optional footer message.
private struct IslandCard: View {
    let level: Level
    let title: String
    let subtitle: String
    var footer: String?
    var warning: String?

    var body: some View {
        VStack(spacing: 10) {
            header
            footerBar
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(width: Theme.width)
        .fixedSize(horizontal: false, vertical: true)
        .background(shell)
        .padding(20)
    }

    // MARK: Shell

    private var shell: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        // The bitmap snapshot can't sample a live desktop blur, so we mirror only the
        // glass tint + brighter edge here (the material's base tint is what shows).
        return shape
            .fill(LinearGradient(
                colors: [Theme.ink.opacity(0.50), Theme.ink.opacity(0.54), Color.black.opacity(0.58)],
                startPoint: .top, endPoint: .bottom))
            .background(VisualEffectBackground().clipShape(shape))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(LinearGradient(colors: [.white.opacity(0.20), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom), lineWidth: 1)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(level.accent.opacity(ringOpacity), lineWidth: level == .critical ? 2 : 1.5)
            }
            .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
            .shadow(color: level.accent.opacity(level.active ? 0.26 : 0), radius: 22)
    }

    private var ringOpacity: Double {
        switch level {
        case .quiet: return 0
        case .attention: return 0.42
        case .critical: return 0.7
        }
    }

    // MARK: Mascot

    private func mascot() -> some View {
        ZStack {
            if level.active {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(level.accent.opacity(level == .critical ? 0.7 : 0.5), lineWidth: level == .critical ? 2.5 : 2)
                    .frame(width: 34, height: 34)
            }
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(LinearGradient(colors: [level.accent.opacity(0.97), level.accent.opacity(0.80)], startPoint: .top, endPoint: .bottom))
                .frame(width: 26, height: 22)
                .overlay {
                    HStack(spacing: 6) { eye; eye }.offset(y: level.active ? -1.5 : 0.5)
                }
                .shadow(color: level.accent.opacity(level.active ? 0.6 : 0.25), radius: level.active ? 9 : 4)
        }
        .frame(width: 34, height: 34)
    }

    private var eye: some View {
        Capsule(style: .continuous).fill(Color.black.opacity(0.82)).frame(width: 4, height: level.active ? 7 : 5)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 11) {
            mascot()
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                Text(subtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            accountMenuLabel
        }
        .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
    }

    private var accountMenuLabel: some View {
        HStack(spacing: 5) {
            Text("Accounts").font(.system(size: 12, weight: .semibold))
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Theme.accent, in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.30), lineWidth: 1))
        .shadow(color: Theme.accent.opacity(0.35), radius: 5, y: 1)
    }

    // MARK: Footer

    @ViewBuilder
    private var footerBar: some View {
        if let warning {
            HStack(spacing: 7) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.amber)
                Text(warning)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.amber.opacity(0.92))
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let footer {
            // The auto-switch / no-viable outcome — headline event, arrow glyph.
            HStack(spacing: 7) {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.accent)
                Text(footer)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Mock of the collapsed notch pill.
private struct PillMock: View {
    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(LinearGradient(colors: [Theme.accent.opacity(0.97), Theme.accent.opacity(0.80)], startPoint: .top, endPoint: .bottom))
                .frame(width: 26, height: 22)
                .overlay {
                    HStack(spacing: 6) {
                        Capsule().fill(.black.opacity(0.82)).frame(width: 4, height: 5)
                        Capsule().fill(.black.opacity(0.82)).frame(width: 4, height: 5)
                    }.offset(y: 0.5)
                }
            Circle().fill(Theme.accent.opacity(0.85)).frame(width: 5, height: 5)
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .background {
            let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
            shape
                .fill(LinearGradient(
                    colors: [Theme.ink.opacity(0.50), Theme.ink.opacity(0.54), Color.black.opacity(0.58)],
                    startPoint: .top, endPoint: .bottom))
                .background(VisualEffectBackground().clipShape(shape))
                .overlay(shape.stroke(LinearGradient(colors: [.white.opacity(0.20), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
        }
        .padding(20)
    }
}

/// Mock of the account dropdown rows (logos sized as in the live NSMenu, 15px).
/// Each row shows the account's 5-hour usage; the recommended account carries a
/// blue dot AND the word "(recommended)" — never color alone.
private struct MenuMock: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("CLAUDE").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            row("claude", "alice@example.com  —  over limit  ✓")
            row("claude", "bob@example.com  —  62% of 5-hour · resets 1h 10m")
            row("claude", "casey@example.com  —  3% of 5-hour  (recommended)")
            Text("CODEX").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            row("codex", "alice@example.com  ✓")
        }
        .padding(16)
        .frame(width: 380, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.92)))
        .padding(20)
    }

    private func row(_ asset: String, _ text: String) -> some View {
        HStack(spacing: 9) {
            if let img = NSImage(contentsOfFile: "Sources/ChewyApp/Resources/\(asset).png") {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).frame(width: 15, height: 15)
            }
            Text(text).font(.system(size: 13)).foregroundStyle(.black)
        }
    }
}

private struct Gallery: View {
    var body: some View {
        VStack(spacing: 0) {
            PillMock()
            MenuMock()
            // Quiet idle — active account with healthy headroom.
            IslandCard(
                level: .quiet,
                title: "All clear",
                subtitle: "alice@example.com · 42% of 5-hour"
            )
            // Just auto-switched — the island surfaces the switch, new fresh account active.
            IslandCard(
                level: .quiet,
                title: "All clear",
                subtitle: "casey@example.com · 3% of 5-hour",
                footer: "New sessions now use casey@example.com — the previous account hit its 5-hour limit"
            )
            // Running low — approaching the 5-hour limit, recommendation in the footer.
            IslandCard(
                level: .attention,
                title: "Running low",
                subtitle: "alice@example.com · 88% of 5-hour",
                warning: "88% of 5-hour limit — switch to bob@example.com (most headroom)"
            )
            // In overage — the 5-hour limit is reached; the limit leads, dollars are
            // secondary context (not the headline).
            IslandCard(
                level: .critical,
                title: "Heads up",
                subtitle: "dana@example.com · 5-hour limit reached",
                warning: "5-hour limit reached — on extra usage ($42.00 this cycle). → switch to alice@example.com (likely fresh)"
            )
            // No viable account — every account is over the limit.
            IslandCard(
                level: .critical,
                title: "Heads up",
                subtitle: "alice@example.com · 5-hour limit reached",
                footer: "All accounts are at their 5-hour limit"
            )
            // First run — empty.
            IslandCard(
                level: .quiet,
                title: "Let's get set up",
                subtitle: "Add a Claude or Codex account"
            )
        }
        .padding(.vertical, 16)
        .frame(width: Theme.width + 40)
        .background(Color(white: 0.16))
    }
}

@main
private struct SnapshotMain {
    static func main() throws {
        let outputPath = CommandLine.arguments.dropFirst().first ?? "screenshots/chewy.png"
        let hostingView = NSHostingView(rootView: Gallery())
        hostingView.frame = NSRect(x: 0, y: 0, width: Theme.width + 40, height: 900)
        hostingView.layoutSubtreeIfNeeded()
        let fitting = hostingView.fittingSize
        hostingView.frame = NSRect(x: 0, y: 0, width: fitting.width, height: fitting.height)
        hostingView.layoutSubtreeIfNeeded()

        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            throw SnapshotError.renderFailed
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)

        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw SnapshotError.renderFailed
        }

        let url = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        print(url.path)
    }
}

private enum SnapshotError: Error {
    case renderFailed
}
