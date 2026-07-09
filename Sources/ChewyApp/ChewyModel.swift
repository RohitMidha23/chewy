import AppKit
import ChewyCore
import SwiftUI

/// Outcome of a credential swap — typed so success/failure is testable and only
/// success announces / charges episode state.
enum SwapOutcome {
    case switched(email: String?)
    case failed(String)
}

@MainActor
final class ChewyModel: NSObject, ObservableObject {
    @Published private(set) var profiles: [AccountProfile] = []
    @Published var lastMessage: String = "Ready"
    @Published private(set) var activeProfileIDs: [AccountTool: AccountProfile.ID] = [:]

    /// Latest proactive usage snapshot for the active Claude account, if polled.
    /// Kept on failure (never cleared) so a transient network blip doesn't flicker.
    @Published private(set) var usage: UsageSnapshot?

    /// Whether the background auto-switcher may re-point the canonical credential when
    /// the active account crosses its 5-hour limit. Default ON — auto-switching is the
    /// point of the tool. Persisted under a fresh key (never the old notifications key).
    @Published var autoSwitchEnabled: Bool = UserDefaults.standard.object(forKey: "ci.autoSwitchEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoSwitchEnabled, forKey: "ci.autoSwitchEnabled") }
    }

    /// Fires when an auto-switch (or no-viable-account) state change happens, so the
    /// app can surface the island. Main-actor typed: handlers touch AppKit.
    var onAutoSwitch: (@MainActor () -> Void)?
    /// The most recent switch message, if any. Published so the UI can animate
    /// (mascot hop, footer glyph) when a switch lands.
    @Published private(set) var lastSwitchMessage: String?
    private var lastAutoSwitchAt: Date?
    /// Episode throttle for the no-viable-account message, keyed by the verified
    /// canonical accountUuid — re-arms when the active recovers (.stay) or identity changes.
    private var noViableEpisodeKey: String?

    private let store: AccountProfileStore
    private let codexHomes: CodexHomeManager
    private let claudeProfiles: ClaudeProfileManager
    private let launcher: TerminalLauncher
    private let homeURL: URL

    /// Proactive usage polling: fetches each Claude account's limits so we can warn
    /// BEFORE a session/extra-usage limit is hit. Never logs the token/body.
    private let usageFetcher: UsageFetching
    private var usageTimer: Timer?
    private let usagePollInterval: TimeInterval = 60 // refresh usage every minute
    private static let usageLaunchDelay: TimeInterval = 5

    /// Last-known usage persisted across restarts (percentages only — no secrets),
    /// so the switcher's candidate picker keeps its memory instead of treating every
    /// idle account as an equal unknown after a relaunch.
    private let usageCacheURL: URL
    private var usageFetchedAt: [AccountProfile.ID: Date] = [:]

    /// The credential-engine orchestrator (vault + swap manager + store).
    let accountManager: AccountManager

    /// Accounts whose sign-in is dead (a swap's post-write read-back mismatched) and that
    /// the user must re-authenticate. Surfaced in the menu + footer.
    @Published private(set) var reconnectNeeded: Set<AccountProfile.ID> = []

    /// If a shell env var overrides the canonical swap, a warning string; else nil.
    var envOverrideWarning: String? {
        accountManager.envOverrideWarning()
    }

    init(
        store: AccountProfileStore,
        codexHomes: CodexHomeManager,
        claudeProfiles: ClaudeProfileManager,
        launcher: TerminalLauncher,
        paths: ChewyPaths,
        homeURL: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
        usageFetcher: UsageFetching = LiveUsageFetcher()
    ) {
        self.store = store
        self.usageFetcher = usageFetcher
        self.codexHomes = codexHomes
        self.claudeProfiles = claudeProfiles
        self.launcher = launcher
        self.homeURL = homeURL
        self.usageCacheURL = paths.appSupportDirectory
            .appendingPathComponent("usage-cache.json", isDirectory: false)
        let accountManager = AccountManager(
            store: store,
            codexHomes: codexHomes,
            claudeProfiles: claudeProfiles,
            launcher: launcher,
            paths: paths,
            homeURL: homeURL
        )
        self.accountManager = accountManager
    }

    func reload() {
        do {
            // One-time v2 migration: backfill identity + import per-home creds into the
            // vault. Guarded so it runs once per machine.
            runMigrationIfNeeded()

            profiles = try store.loadProfiles()
            syncActiveProfiles()
            // Seed the usage picture from the persisted cache (pruned to the 5-hour
            // horizon) so the first auto-switch after a relaunch picks with memory.
            let cached = UsageCache.load(from: usageCacheURL)
            usageByAccount = cached.snapshotsByAccount
            usageFetchedAt = cached.entries.mapValues(\.fetchedAt)
            lastMessage = profiles.isEmpty ? "Add Claude or Codex accounts" : "Ready"
            startUsagePolling()
        } catch {
            lastMessage = error.localizedDescription
        }
    }

    // MARK: - One-time migration

    private static let migrationDefaultsKey = "chewy.didMigrateV2"

    private func runMigrationIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.migrationDefaultsKey) else {
            return
        }
        // Backfill identity + import per-home creds into the vault using the SAME
        // canonical parser + capture/persist path the live capture uses, so the
        // vault is keyed identically across capture and migration. Best-effort; never throws.
        _ = accountManager.migrateLegacyProfiles()
        // Flag complete ONLY after the work above completes.
        UserDefaults.standard.set(true, forKey: Self.migrationDefaultsKey)
    }

    /// Add a Claude account: prompt for a name, then login → capture → vault via
    /// AccountManager. Refreshes the profile list when capture completes.
    func addClaude(name: String? = nil) {
        addAccount(tool: .claude, name: name)
    }

    /// Add a Codex account: prompt for a name, then login → capture → vault.
    func addCodex(name: String? = nil) {
        addAccount(tool: .codex, name: name)
    }

    /// A login attempt that timed out but can still be completed: the user finishes
    /// signing in in Terminal, then taps "I've finished signing in" in the menu.
    struct PendingLogin: Equatable {
        let tool: AccountTool
        let slug: String
        let name: String
    }

    /// Set when an add-account poll times out; drives the menu's finish action.
    @Published private(set) var pendingLogin: PendingLogin?

    private func addAccount(tool: AccountTool, name: String?) {
        let resolved = name ?? promptForName(tool: tool)
        guard let resolved else { return }
        // Mirror AccountManager's name/slug derivation BEFORE the login starts, so a
        // timed-out attempt can be finished later against the same staging home.
        let trimmed = resolved.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? tool.rawValue.capitalized : trimmed
        let expectedSlug = try? store.uniqueSlug(for: finalName, tool: tool)
        Task { @MainActor in
            let message = await accountManager.addAccount(tool: tool, name: finalName) { [weak self] update in
                self?.lastMessage = update
            }
            self.lastMessage = message
            self.profiles = (try? self.store.loadProfiles()) ?? self.profiles
            self.syncActiveProfiles()
            if let expectedSlug, message.hasPrefix("Sign-in timed out") {
                self.pendingLogin = PendingLogin(tool: tool, slug: expectedSlug, name: finalName)
            }
        }
    }

    /// Manual fallback for a timed-out login: capture the staged sign-in the bounded
    /// poll missed. Clears the pending state only when the account actually landed.
    func finishPendingLogin() {
        guard let pending = pendingLogin else { return }
        Task { @MainActor in
            let message = await accountManager.finishPendingLogin(
                tool: pending.tool, slug: pending.slug, name: pending.name
            )
            self.lastMessage = message
            self.profiles = (try? self.store.loadProfiles()) ?? self.profiles
            self.syncActiveProfiles()
            // Success ⇔ a profile now exists for the pending slug (or the capture
            // deduped into an existing profile and reported "Added …").
            let landed = self.profiles.contains { $0.tool == pending.tool && $0.slug == pending.slug }
            if landed || message.hasPrefix("Added") {
                self.pendingLogin = nil
                await self.pollUsage()
            }
        }
    }

    /// Remove an account's saved sign-in from this Mac (vault credential + profile),
    /// after an explicit confirm. The CANONICAL credential is deliberately untouched —
    /// removing a profile never signs the user out of live CLI sessions.
    func removeAccount(_ profile: AccountProfile) {
        let email = accountManager.resolvedEmail(for: profile) ?? profile.name
        let alert = NSAlert()
        alert.messageText = "Remove \(email)?"
        alert.informativeText = "Removes the saved sign-in from this Mac's Keychain. Your live CLI sessions are untouched."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        accountManager.removeAccount(profile)
        usageByAccount.removeValue(forKey: profile.id)
        reconnectNeeded.remove(profile.id)
        profiles = (try? store.loadProfiles()) ?? profiles.filter { $0.id != profile.id }
        syncActiveProfiles()
        lastMessage = "Removed \(email)."
    }

    /// Modal name prompt; returns nil if cancelled.
    private func promptForName(tool: AccountTool) -> String? {
        let alert = NSAlert()
        alert.messageText = "Add \(tool.rawValue.capitalized) account"
        alert.informativeText = "Name this account the way you think of it — Personal, Work, or a client. A Terminal window will open so you can sign in; Chewy captures it when you finish."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Sign in")
        alert.addButton(withTitle: "Cancel")

        let nameField = NSTextField(string: tool.rawValue.capitalized)
        nameField.placeholderString = "Account name"
        nameField.setFrameSize(NSSize(width: 360, height: 24))
        alert.accessoryView = labeled("Name", field: nameField)

        guard alert.runModal() == .alertFirstButtonReturn else {
            return nil
        }
        return nameField.stringValue
    }

    func profiles(for tool: AccountTool) -> [AccountProfile] {
        profiles.filter { $0.tool == tool }
    }

    /// An account is "unsigned" if it never completed login (no resolvable email)
    /// and isn't a pasted-token profile. These are leftover stubs worth clearing.
    private func isUnsigned(_ profile: AccountProfile) -> Bool {
        accountManager.resolvedEmail(for: profile) == nil && profile.credentialReference == nil
    }

    var hasUnsignedAccounts: Bool {
        profiles.contains(where: isUnsigned)
    }

    func removeUnsignedAccounts() {
        let ids = Set(profiles.filter(isUnsigned).map(\.id))
        guard !ids.isEmpty else { return }
        do {
            profiles = try store.removeProfiles(ids: ids)
            syncActiveProfiles()
            lastMessage = "Removed \(ids.count) account\(ids.count == 1 ? "" : "s") that weren't signed in."
        } catch {
            lastMessage = error.localizedDescription
        }
    }

    func activeProfile(for tool: AccountTool) -> AccountProfile? {
        // Source of truth for Claude: who the canonical credential actually points at,
        // not the app's stored selection (which can drift if the user switched
        // elsewhere or state got stale). Match by accountUuid, then email.
        if tool == .claude, let match = resolvedActiveClaude() {
            return match
        }
        guard let id = activeProfileIDs[tool] else {
            return profiles(for: tool).first
        }
        return profiles.first { $0.id == id }
    }

    /// The Claude profile the canonical credential actually points at, resolved
    /// DIRECTLY (nil ⇒ canonical matches no managed profile ⇒ not managed by us).
    private func resolvedActiveClaude() -> AccountProfile? {
        let identity = accountManager.canonicalClaudeIdentity()
        return ActiveAccountResolver.resolve(
            profiles: profiles(for: .claude),
            canonicalAccountUuid: identity.accountUuid,
            canonicalEmail: identity.email,
            emailFor: { accountManager.resolvedEmail(for: $0) }
        )
    }

    /// Select an account: perform the global canonical swap (NOT a launch). For the UI,
    /// fire-and-forget through `selectOutcome` and surface the result.
    func select(_ profile: AccountProfile) {
        activeProfileIDs[profile.tool] = profile.id
        Task { @MainActor in
            switch await selectOutcome(profile) {
            case .switched(let email):
                lastMessage = "Now using \(email ?? profile.name). Applies to new sessions."
                reconnectNeeded.remove(profile.id)
            case .failed:
                // The swap's read-back didn't confirm this account (dead token / mismatch).
                // Prompt the user to reconnect it rather than falsely claiming success.
                reconnectNeeded.insert(profile.id)
                let email = accountManager.resolvedEmail(for: profile) ?? profile.name
                surfaceReconnect("Couldn't switch — Reconnect \(email)")
            }
        }
    }

    /// Perform the swap and return a typed outcome. On success, re-reads the confirmed
    /// canonical identity and re-polls usage so visible usage comes only from the
    /// confirmed active account (never optimistically set to the target).
    func selectOutcome(_ profile: AccountProfile) async -> SwapOutcome {
        let message = await accountManager.select(profile)
        // The landing account's access token is usually hours expired — the heal in
        // pollUsage refreshes it via the CLI so new sessions and the usage read work
        // IMMEDIATELY. Arm the heal gate (our own swap cannot race a live session:
        // the landing account was idle) and reset its cooldown.
        lastCanonicalHealAt = nil
        healArmedBySwap = true
        // `select` returns a human status; treat a thrown error as failure. Re-read the
        // canonical identity to confirm the swap landed on this account.
        await pollUsage()
        if profile.tool == .claude {
            let identity = accountManager.canonicalClaudeIdentity()
            guard let match = resolvedActiveClaude(), match.id == profile.id else {
                return .failed(message)
            }
            return .switched(email: identity.email ?? accountManager.resolvedEmail(for: profile))
        }
        return .switched(email: accountManager.resolvedEmail(for: profile))
    }

    /// Restore the user's original (system-default) identity through the swap path.
    func restoreOriginal() {
        usage = nil
        Task { @MainActor in
            let message = await accountManager.restoreOriginal()
            self.lastMessage = message
            await self.pollUsage()
        }
    }

    // MARK: Usage polling (proactive)

    /// Start the recurring usage poll: once shortly after launch, then every minute.
    private func startUsagePolling() {
        subscribeToWake()
        guard usageTimer == nil else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.usageLaunchDelay * 1_000_000_000))
            await self.pollUsage()
        }
        let timer = Timer.scheduledTimer(withTimeInterval: usagePollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.pollUsage()
            }
        }
        timer.tolerance = 10 // let the system coalesce wakeups; exact cadence doesn't matter
        usageTimer = timer
    }

    // MARK: Wake-from-sleep

    private var wakeObserver: NSObjectProtocol?

    /// On wake, the pre-sleep usage picture is stale (windows may have reset, or
    /// filled up, hours ago). Clear it and re-poll immediately so a stale 96%
    /// never triggers a spurious auto-switch or alert.
    private func subscribeToWake() {
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleWake()
            }
        }
    }

    private func handleWake() {
        usage = nil
        usageByAccount = [:]
        wasInOverage = false
        Task { @MainActor in
            await self.pollUsage()
        }
    }

    /// Single-flight + cooldown for the canonical heal, so overlapping polls don't
    /// stack CLI invocations and a dead canonical isn't hammered every minute.
    private var canonicalHealInFlight = false
    private var lastCanonicalHealAt: Date?
    private static let canonicalHealCooldown: TimeInterval = 300
    /// Heal-safety inputs (HealGate): a heal is armed by OUR OWN swap (the landing
    /// account was idle — no live session can be racing its token chain), or by the
    /// canonical staying byte-stable across polls (no live refresher attached).
    private var healArmedBySwap = false
    private var lastCanonicalHash: String?
    private var canonicalStablePolls = 0

    /// Poll usage for EVERY Claude account so the dropdown shows per-account usage and
    /// can recommend / auto-switch. Per-account success updates that account; failures
    /// keep the prior value. Then run the auto-switch planner on the fresh picture.
    private func pollUsage() async {
        // Fold any canonical change into ITS OWNER's vault entry FIRST — attributed by
        // the canonical's own identity, not by who the app thinks is active. This is
        // what makes a manual `/login` inside any Claude session stick (previously a
        // login as a "non-active" account was silently thrown away).
        let canonicalHash = accountManager.captureCanonicalDrift()
        if let canonicalHash, canonicalHash == lastCanonicalHash {
            canonicalStablePolls += 1
        } else {
            canonicalStablePolls = 0
        }
        lastCanonicalHash = canonicalHash

        // Follow reality: if the canonical now points at a different managed account
        // (the user re-logged-in themselves), adopt it as active and lift its
        // quarantine — a fresh manual sign-in supersedes a stale dead-token verdict.
        if let resolved = resolvedActiveClaude() {
            if activeProfile(for: .claude)?.id != resolved.id {
                accountManager.noteCanonicalActive(resolved)
                syncActiveProfiles()
            }
            if reconnectNeeded.contains(resolved.id),
               accountManager.usageToken(for: resolved, isActive: true) != nil {
                reconnectNeeded.remove(resolved.id)
                lastSwitchMessage = nil // drop any stale "Reconnect …" headline
            }
        }

        let activeClaudeID = activeProfile(for: .claude)?.id
        var byAccount = usageByAccount
        for profile in profiles where profile.tool == .claude {
            let isActive = profile.id == activeClaudeID
            guard let token = accountManager.usageToken(for: profile, isActive: isActive) else { continue }
            if let snapshot = await usageFetcher.fetchClaude(accessToken: token) {
                byAccount[profile.id] = snapshot
                usageFetchedAt[profile.id] = Date()
            }
        }

        // HEAL: if the ACTIVE account's usage is unreadable, the canonical access
        // token has usually expired (e.g. right after switching onto an idle
        // account). Delegate a refresh to the official CLI against the canonical
        // store — no staging, nothing to strand — then re-capture and retry once.
        // A signed-out canonical means the restored refresh token is dead: surface
        // Reconnect and stop treating that account as a viable switch target.
        if let activeClaudeID, byAccount[activeClaudeID] == nil,
           let active = profiles.first(where: { $0.id == activeClaudeID }),
           HealGate.shouldHeal(
               armedBySwap: healArmedBySwap,
               stablePolls: canonicalStablePolls,
               inFlight: canonicalHealInFlight,
               lastHealAt: lastCanonicalHealAt,
               cooldown: Self.canonicalHealCooldown,
               now: Date()
           ) {
            canonicalHealInFlight = true
            defer { canonicalHealInFlight = false }
            lastCanonicalHealAt = Date()
            healArmedBySwap = false
            switch await accountManager.healCanonicalClaude() {
            case .healthy:
                // The CLI refreshed (or confirmed) the canonical — capture the
                // rotation into its owner's vault entry and retry the read once.
                accountManager.captureCanonicalDrift()
                if let token = accountManager.usageToken(for: active, isActive: true),
                   let snapshot = await usageFetcher.fetchClaude(accessToken: token) {
                    byAccount[activeClaudeID] = snapshot
                    usageFetchedAt[activeClaudeID] = Date()
                    reconnectNeeded.remove(activeClaudeID)
                }
            case .signedOut:
                reconnectNeeded.insert(activeClaudeID)
                let email = accountManager.resolvedEmail(for: active) ?? active.name
                surfaceReconnect("Sign-in expired — Reconnect \(email)")
            case .unknown:
                break // no signal (CLI missing/hung) — keep the prior picture
            }
        }

        let liveIDs = Set(profiles.map(\.id))
        byAccount = byAccount.filter { liveIDs.contains($0.key) }
        usageByAccount = byAccount
        persistUsageCache()
        if let activeClaudeID, let active = byAccount[activeClaudeID] {
            usage = active
            // Extra-usage alerts are ALWAYS on. Fire once on entering overage.
            if active.inOverageNow && !wasInOverage {
                onUsageAlert?()
            }
            wasInOverage = active.inOverageNow
        }
        evaluateAutoSwitch()
    }

    /// Write the last-known usage (percentages only — never secrets) to disk so a
    /// relaunch doesn't forget which idle account was freshest.
    private func persistUsageCache() {
        var entries: [UUID: UsageCache.Entry] = [:]
        for (id, snapshot) in usageByAccount {
            entries[id] = UsageCache.Entry(snapshot: snapshot, fetchedAt: usageFetchedAt[id] ?? Date())
        }
        UsageCache(entries: entries).save(to: usageCacheURL)
    }

    /// Re-authenticate an account whose sign-in expired: re-run login → capture in place,
    /// refresh the profile/usage picture, and clear its reconnect flag on success.
    func reconnect(_ profile: AccountProfile) {
        Task { @MainActor in
            let message = await accountManager.reconnect(profile) { [weak self] update in
                self?.lastMessage = update
            }
            self.lastMessage = message
            self.profiles = (try? self.store.loadProfiles()) ?? self.profiles
            self.syncActiveProfiles()
            // Re-resolve the profile from the freshly-loaded list (a captured object can
            // go stale across reconnect) before deciding to clear the badge. Match by id,
            // falling back to accountId. Clear only on genuine success: a usable
            // (unexpired) token, or the account having become active.
            let reloaded = self.profiles.first(where: { $0.id == profile.id })
                ?? self.profiles.first(where: {
                    CredentialSwapManager.accountId(for: $0) == CredentialSwapManager.accountId(for: profile)
                })
            if let reloaded {
                if self.accountManager.usageToken(for: reloaded, isActive: false) != nil
                    || self.activeProfile(for: .claude)?.id == reloaded.id {
                    self.reconnectNeeded.remove(reloaded.id)
                    // Drop the stale "Couldn't switch — Reconnect …" headline; the
                    // poll below re-evaluates and will announce the real outcome.
                    self.lastSwitchMessage = nil
                }
            }
            await self.pollUsage()
        }
    }

    /// Surface a reconnect prompt as the headline footer message (ranks above usage).
    private func surfaceReconnect(_ message: String) {
        lastSwitchMessage = message
        lastMessage = message
        onAutoSwitch?()
    }

    private var wasInOverage = false

    /// Build the planner inputs from confirmed canonical identity + fresh usage, then act.
    private func evaluateAutoSwitch() {
        let identity = accountManager.canonicalClaudeIdentity()
        let match = ActiveAccountResolver.resolve(
            profiles: profiles(for: .claude),
            canonicalAccountUuid: identity.accountUuid,
            canonicalEmail: identity.email,
            emailFor: { accountManager.resolvedEmail(for: $0) }
        )
        let inputs = AutoSwitchInputs.build(
            activeMatch: match,
            claudeProfiles: profiles(for: .claude),
            usageByAccount: usageByAccount,
            excluding: reconnectNeeded, // never switch onto a known-dead sign-in
            lastSwitchAt: lastAutoSwitchAt,
            now: Date()
        )
        switch AutoSwitchPlanner.plan(inputs) {
        case .switchTo(let id, let reason):
            guard autoSwitchEnabled, let target = profiles.first(where: { $0.id == id }) else { return }
            // Arm the cooldown synchronously: pollUsage() fires every 60s and the swap is
            // async, so without this a second poll mid-swap could spawn a duplicate switch.
            lastAutoSwitchAt = Date()
            Task { @MainActor in
                switch await self.selectOutcome(target) {
                case .switched(let email):
                    self.lastSwitchMessage = "New sessions now use \(email ?? target.name) — \(reason)"
                    self.lastMessage = self.lastSwitchMessage ?? self.lastMessage
                    self.onAutoSwitch?()
                case .failed:
                    // The swap didn't take (read-back mismatch / dead token) — release the
                    // cooldown so the next poll can retry, and prompt the user to reconnect
                    // the target. Never announce success.
                    self.lastAutoSwitchAt = nil
                    self.reconnectNeeded.insert(target.id)
                    let email = self.accountManager.resolvedEmail(for: target) ?? target.name
                    self.surfaceReconnect("Couldn't switch — Reconnect \(email)")
                }
            }
        case .noViableAccount(let allKnownMaxed):
            // Throttle once per episode, keyed by the verified canonical accountUuid.
            let key = identity.accountUuid ?? identity.email ?? "unknown"
            guard noViableEpisodeKey != key else { return }
            noViableEpisodeKey = key
            lastSwitchMessage = allKnownMaxed
                ? "All accounts are at their usage limits"
                : "No other account to switch to — add one"
            lastMessage = lastSwitchMessage ?? lastMessage
            onAutoSwitch?()
        case .stay:
            // Active recovered (or is fine) — re-arm the no-viable episode.
            noViableEpisodeKey = nil
        }
    }

    /// Called when the active account ENTERS extra (API-rate) usage. Always fires.
    /// Main-actor typed: handlers touch AppKit.
    var onUsageAlert: (@MainActor () -> Void)?

    /// Latest usage snapshot per account id, for the dropdown.
    @Published private(set) var usageByAccount: [AccountProfile.ID: UsageSnapshot] = [:]

    /// The best Claude account to switch TO right now (most headroom, not on extra
    /// usage, accounting for imminent window resets), or nil if staying put is fine.
    var accountRecommendation: AccountAdvisor.Recommendation? {
        let claude = profiles.filter { $0.tool == .claude }
        guard claude.count > 1 else { return nil }
        let candidates = claude.map { AccountAdvisor.Candidate(id: $0.id, usage: usageByAccount[$0.id]) }
        return AccountAdvisor.recommend(
            candidates: candidates,
            activeId: activeProfile(for: .claude)?.id,
            now: Date()
        )
    }

    /// Email of the recommended account, for surfacing in warnings.
    func emailForRecommendation(_ recommendation: AccountAdvisor.Recommendation) -> String? {
        guard let profile = profiles.first(where: { $0.id == recommendation.id }) else { return nil }
        return accountManager.resolvedEmail(for: profile) ?? profile.name
    }

    // MARK: Idle minimize

    /// Fired when the island collapses to (true) or expands from (false) the pill,
    /// so the host panel can auto-dismiss self-initiated surfacings after a grace
    /// period. Main-actor typed: handlers touch AppKit.
    var onMinimizedChange: (@MainActor (Bool) -> Void)?

    /// Whether the island has collapsed to the notch pill (idle).
    @Published private(set) var isMinimized = false {
        didSet {
            guard isMinimized != oldValue else { return }
            onMinimizedChange?(isMinimized)
        }
    }
    private var idleTimer: Timer?
    private let idleSeconds: TimeInterval = 7

    /// Expand the island and restart the idle countdown.
    func expandIsland() {
        isMinimized = false
        restartIdleTimer()
    }

    /// Record any interaction (hover/click) — keeps the island open and resets the timer.
    func noteInteraction() {
        restartIdleTimer()
    }

    private func restartIdleTimer() {
        idleTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: idleSeconds, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.isMinimized = true
            }
        }
        timer.tolerance = 0.5
        idleTimer = timer
    }

    private func syncActiveProfiles() {
        for tool in AccountTool.allCases {
            let toolProfiles = profiles(for: tool)

            // Prefer the persisted active account id from the swap engine.
            if let activeAccountID = accountManager.activeAccountID(for: tool),
               let match = toolProfiles.first(where: { CredentialSwapManager.accountId(for: $0) == activeAccountID }) {
                activeProfileIDs[tool] = match.id
                continue
            }

            if let activeID = activeProfileIDs[tool], toolProfiles.contains(where: { $0.id == activeID }) {
                continue
            }
            activeProfileIDs[tool] = toolProfiles.first {
                ProfileDisplayState.authState(for: $0, hasVaultCredential: accountManager.hasVaultCredential(for: $0)).isReady
            }?.id ?? toolProfiles.first?.id
        }
    }

    private func labeled(_ label: String, field: NSView) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 3

        let text = NSTextField(labelWithString: label)
        text.font = .systemFont(ofSize: 11, weight: .medium)
        text.textColor = .secondaryLabelColor

        field.setFrameSize(NSSize(width: 360, height: 24))
        stack.addArrangedSubview(text)
        stack.addArrangedSubview(field)
        return stack
    }
}
