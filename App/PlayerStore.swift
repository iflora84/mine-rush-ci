import Foundation
import MineRushCore

/// Owns the player's profile: loading, saving, and settling worker income.
/// Everything that changes progress goes through `mutate` so it gets saved.
@MainActor
final class PlayerStore: ObservableObject {
    @Published private(set) var profile: PlayerProfile
    @Published var selectedZone: ZoneID = .sunnyQuarry

    private let repository: SaveRepository
    private var ticker: Timer?
    private var lastSaveAt = 0.0

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        repository = SaveRepository(directory: base.appendingPathComponent("MineRush", isDirectory: true))
        profile = repository.load().profile
        selectedZone = profile.activeRun?.zone ?? .sunnyQuarry
    }

    var now: Double { Date().timeIntervalSince1970 }

    // MARK: Lifecycle

    func becameActive() {
        profile.settleTime(now: now)
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func resignedActive() {
        ticker?.invalidate()
        ticker = nil
        profile.settleTime(now: now)
        save()
    }

    private func tick() {
        profile.settleTime(now: now)
        if now - lastSaveAt > 30 { save() }
    }

    // MARK: Changes

    /// Board moves pass `save: false`; they're saved when the site ends, every
    /// 30 seconds, and when the app leaves the foreground.
    @discardableResult
    func mutate<T>(save shouldSave: Bool = true, _ change: (inout PlayerProfile) -> T) -> T {
        let result = change(&profile)
        if shouldSave { save() }
        return result
    }

    func save() {
        lastSaveAt = now
        try? repository.save(profile, now: now)
    }

    func buyUpgrade(_ id: UpgradeID) -> PurchaseOutcome {
        mutate { $0.buyUpgrade(id) }
    }

    func hireOrUpgrade(_ worker: WorkerID) -> PurchaseOutcome {
        let time = now
        return mutate { $0.hireOrUpgrade(worker, now: time) }
    }

    func claimOfflineReward() {
        mutate { $0.claimOfflineReward() }
    }
}

extension Int {
    /// 950, 12.3K, 4.5M, ...
    var compact: String {
        let units: [(Double, String)] = [(1e12, "T"), (1e9, "B"), (1e6, "M"), (1e3, "K")]
        let value = Double(self)
        for (size, suffix) in units where abs(value) >= size {
            let scaled = value / size
            return scaled >= 100 ? "\(Int(scaled))\(suffix)" : String(format: "%.1f%@", scaled, suffix)
        }
        return "\(self)"
    }
}

/// "2h 05m", "45s".
func durationText(_ seconds: Int) -> String {
    let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
    if h > 0 { return String(format: "%dh %02dm", h, m) }
    if m > 0 { return String(format: "%dm %02ds", m, s) }
    return "\(s)s"
}
