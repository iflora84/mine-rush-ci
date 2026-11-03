// Integer-only economy. Percentages are whole numbers (150 = 1.5x) and every
// add/multiply saturates instead of trapping, so a runaway save can't crash.

extension Int {
    func addingSaturated(_ other: Int) -> Int {
        let (value, overflow) = addingReportingOverflow(other)
        return overflow ? (other > 0 ? .max : .min) : value
    }

    func multipliedSaturated(_ other: Int) -> Int {
        let (value, overflow) = multipliedReportingOverflow(by: other)
        return overflow ? ((self < 0) == (other < 0) ? .max : .min) : value
    }

    /// `self * percent / 100`, saturating.
    func applyingPercent(_ percent: Int) -> Int {
        multipliedSaturated(percent) / 100
    }
}

// MARK: - Ledger

public enum Currency: String, Codable, Sendable {
    case coins, gems
}

public struct LedgerEntry: Codable, Equatable, Sendable {
    public let id: String
    public let currency: Currency
    /// Positive for income, negative for spending.
    public let amount: Int
}

/// Balances plus separate earned/spent totals per currency. Every transaction
/// carries a unique id; replaying an id is a no-op, so duplicate callbacks
/// (ads, purchases, double-taps on claim buttons) can't pay twice.
public struct CurrencyLedger: Codable, Sendable {
    public private(set) var coins = 0
    public private(set) var gems = 0
    public private(set) var coinsEarned = 0
    public private(set) var coinsSpent = 0
    public private(set) var gemsEarned = 0
    public private(set) var gemsSpent = 0
    /// Most recent entries, oldest first. Also the memory of processed ids.
    public private(set) var recent: [LedgerEntry] = []
    private var processedIDs: Set<String> = []

    static let idMemory = 5000

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case coins, gems, coinsEarned, coinsSpent, gemsEarned, gemsSpent, recent
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        coins = try c.decode(Int.self, forKey: .coins)
        gems = try c.decode(Int.self, forKey: .gems)
        coinsEarned = try c.decode(Int.self, forKey: .coinsEarned)
        coinsSpent = try c.decode(Int.self, forKey: .coinsSpent)
        gemsEarned = try c.decode(Int.self, forKey: .gemsEarned)
        gemsSpent = try c.decode(Int.self, forKey: .gemsSpent)
        recent = try c.decode([LedgerEntry].self, forKey: .recent)
        processedIDs = Set(recent.map(\.id))
    }

    public func balance(_ currency: Currency) -> Int {
        currency == .coins ? coins : gems
    }

    public func hasProcessed(_ id: String) -> Bool {
        processedIDs.contains(id)
    }

    @discardableResult
    public mutating func credit(_ amount: Int, _ currency: Currency, id: String) -> Bool {
        guard amount > 0, !processedIDs.contains(id) else { return false }
        switch currency {
        case .coins:
            coins = coins.addingSaturated(amount)
            coinsEarned = coinsEarned.addingSaturated(amount)
        case .gems:
            gems = gems.addingSaturated(amount)
            gemsEarned = gemsEarned.addingSaturated(amount)
        }
        record(LedgerEntry(id: id, currency: currency, amount: amount))
        return true
    }

    /// Continuous, time-based income (workers) whose idempotency comes from the
    /// caller's clock bookkeeping. Counted in totals but not kept as entries.
    public mutating func creditUntracked(_ amount: Int, _ currency: Currency) {
        guard amount > 0 else { return }
        switch currency {
        case .coins:
            coins = coins.addingSaturated(amount)
            coinsEarned = coinsEarned.addingSaturated(amount)
        case .gems:
            gems = gems.addingSaturated(amount)
            gemsEarned = gemsEarned.addingSaturated(amount)
        }
    }

    /// Fails without side effects when the balance is short or the id was used.
    @discardableResult
    public mutating func spend(_ amount: Int, _ currency: Currency, id: String) -> Bool {
        guard amount > 0, !processedIDs.contains(id), balance(currency) >= amount else { return false }
        switch currency {
        case .coins:
            coins -= amount
            coinsSpent = coinsSpent.addingSaturated(amount)
        case .gems:
            gems -= amount
            gemsSpent = gemsSpent.addingSaturated(amount)
        }
        record(LedgerEntry(id: id, currency: currency, amount: -amount))
        return true
    }

    private mutating func record(_ entry: LedgerEntry) {
        processedIDs.insert(entry.id)
        recent.append(entry)
        if recent.count > Self.idMemory {
            let dropped = recent.removeFirst()
            processedIDs.remove(dropped.id)
        }
    }
}

// MARK: - Upgrades

public enum UpgradeCategory: String, Codable, CaseIterable, Sendable {
    case coinProduction, puzzleTools, workerEconomy

    public var title: String {
        switch self {
        case .coinProduction: return "Coin Production"
        case .puzzleTools: return "Puzzle Tools"
        case .workerEconomy: return "Worker Economy"
        }
    }
}

public enum UpgradeID: String, Codable, CaseIterable, Sendable {
    case betterPickaxe, luckyGloves, treasureMagnet, comboCharm
    case mineScanner, safetyHelmet, smartFlags, extraSupplies
    case minerTraining, betterDrill, biggerStorage, teamEfficiency
}

public struct UpgradeDefinition: Sendable {
    public let id: UpgradeID
    public let category: UpgradeCategory
    public let name: String
    public let summary: String
    public let maxLevel: Int
    public let baseCost: Int
    /// Cost multiplier per level, in percent (115 = +15% per level).
    public let costGrowth: Int
    /// Effect added per level, in the unit `effectText` describes.
    public let perLevel: Int
    let effectText: @Sendable (Int) -> String

    public func cost(atLevel level: Int) -> Int {
        var cost = baseCost
        for _ in 0..<max(level, 0) {
            cost = cost.applyingPercent(costGrowth)
        }
        return cost
    }

    public func effect(atLevel level: Int) -> Int {
        perLevel.multipliedSaturated(min(max(level, 0), maxLevel))
    }

    public func effectDescription(atLevel level: Int) -> String {
        effectText(effect(atLevel: level))
    }
}

public enum UpgradeCatalog {
    public static let all: [UpgradeDefinition] = [
        UpgradeDefinition(id: .betterPickaxe, category: .coinProduction, name: "Better Pickaxe",
                          summary: "More coins for every safe tile you dig.",
                          maxLevel: 25, baseCost: 150, costGrowth: 128, perLevel: 10) { "+\($0)% tile coins" },
        UpgradeDefinition(id: .luckyGloves, category: .coinProduction, name: "Lucky Gloves",
                          summary: "Bigger payout when you clear a site.",
                          maxLevel: 20, baseCost: 300, costGrowth: 130, perLevel: 15) { "+\($0)% clear bonus" },
        UpgradeDefinition(id: .treasureMagnet, category: .coinProduction, name: "Treasure Magnet",
                          summary: "Treasure tiles are worth more.",
                          maxLevel: 15, baseCost: 400, costGrowth: 132, perLevel: 20) { "+\($0)% treasure" },
        UpgradeDefinition(id: .comboCharm, category: .coinProduction, name: "Combo Charm",
                          summary: "Win streaks boost the clear bonus harder.",
                          maxLevel: 10, baseCost: 600, costGrowth: 140, perLevel: 3) { "+\($0)% per streak win" },

        UpgradeDefinition(id: .mineScanner, category: .puzzleTools, name: "Mine Scanner",
                          summary: "Scan for a tile that is provably safe.",
                          maxLevel: 3, baseCost: 500, costGrowth: 300, perLevel: 1) { "\($0) scan(s) per site" },
        UpgradeDefinition(id: .safetyHelmet, category: .puzzleTools, name: "Safety Helmet",
                          summary: "Survive a mine hit in Expedition sites.",
                          maxLevel: 2, baseCost: 1500, costGrowth: 400, perLevel: 1) { "\($0) blast(s) blocked per site" },
        UpgradeDefinition(id: .smartFlags, category: .puzzleTools, name: "Smart Flags",
                          summary: "Satisfied numbers dim; faster long-press flagging.",
                          maxLevel: 2, baseCost: 250, costGrowth: 400, perLevel: 1) { $0 == 0 ? "Off" : "Level \($0)" },
        UpgradeDefinition(id: .extraSupplies, category: .puzzleTools, name: "Extra Supplies",
                          summary: "Extra scanner charges each site (needs Mine Scanner).",
                          maxLevel: 3, baseCost: 2000, costGrowth: 250, perLevel: 1) { "+\($0) scan(s) per site" },

        UpgradeDefinition(id: .minerTraining, category: .workerEconomy, name: "Miner Training",
                          summary: "Every worker digs faster.",
                          maxLevel: 25, baseCost: 800, costGrowth: 125, perLevel: 8) { "+\($0)% worker output" },
        UpgradeDefinition(id: .betterDrill, category: .workerEconomy, name: "Better Drill",
                          summary: "Bolt's machines produce more.",
                          maxLevel: 20, baseCost: 2500, costGrowth: 130, perLevel: 15) { "+\($0)% Bolt output" },
        UpgradeDefinition(id: .biggerStorage, category: .workerEconomy, name: "Bigger Storage",
                          summary: "Hold more offline earnings.",
                          maxLevel: 8, baseCost: 1200, costGrowth: 160, perLevel: 1) { "+\($0)h offline cap" },
        UpgradeDefinition(id: .teamEfficiency, category: .workerEconomy, name: "Team Efficiency",
                          summary: "Boosts the whole team's combined output.",
                          maxLevel: 20, baseCost: 3000, costGrowth: 135, perLevel: 5) { "+\($0)% team output" },
    ]

    public static func definition(_ id: UpgradeID) -> UpgradeDefinition {
        all.first { $0.id == id }!
    }
}

/// Upgrade levels keyed by raw id so unknown ids from newer saves survive a round trip.
public struct UpgradeLevels: Codable, Equatable, Sendable {
    private var levels: [String: Int] = [:]

    public init() {}

    public subscript(_ id: UpgradeID) -> Int {
        get { levels[id.rawValue] ?? 0 }
        set { levels[id.rawValue] = newValue }
    }

    public func effect(_ id: UpgradeID) -> Int {
        UpgradeCatalog.definition(id).effect(atLevel: self[id])
    }
}

public enum PurchaseOutcome: Equatable, Sendable {
    case purchased(newLevel: Int, cost: Int)
    case maxed
    case locked(reason: String)
    case insufficientFunds(cost: Int)
}

public enum UpgradeService {
    public static func nextCost(_ id: UpgradeID, levels: UpgradeLevels) -> Int? {
        let def = UpgradeCatalog.definition(id)
        return levels[id] >= def.maxLevel ? nil : def.cost(atLevel: levels[id])
    }

    public static func lockReason(_ id: UpgradeID, levels: UpgradeLevels) -> String? {
        if id == .extraSupplies, levels[.mineScanner] == 0 { return "Requires Mine Scanner" }
        return nil
    }

    /// `purchaseID` makes the purchase idempotent (e.g. "upgrade:betterPickaxe:3").
    public static func purchase(_ id: UpgradeID, levels: inout UpgradeLevels, ledger: inout CurrencyLedger) -> PurchaseOutcome {
        if let reason = lockReason(id, levels: levels) { return .locked(reason: reason) }
        guard let cost = nextCost(id, levels: levels) else { return .maxed }
        let txID = "upgrade:\(id.rawValue):\(levels[id] + 1)"
        guard ledger.spend(cost, .coins, id: txID) else { return .insufficientFunds(cost: cost) }
        levels[id] += 1
        return .purchased(newLevel: levels[id], cost: cost)
    }
}

// MARK: - Rewards

/// Tunable base values. Placeholders until simulation-based balancing.
public struct EconomyConfig: Codable, Equatable, Sendable {
    public var safeTileReward = 10
    public var correctFlagReward = 25
    public var completionReward = 200
    public var treasureReward = 150
    public var streakStepPercent = 10
    public var streakMaxSteps = 10
    public var treasureTilesPerBoard = 2

    public init() {}

    public static let standard = EconomyConfig()
}

public struct RewardCalculator: Sendable {
    public let config: EconomyConfig
    public let upgrades: UpgradeLevels
    public let zoneMultiplierPercent: Int

    public init(config: EconomyConfig = .standard, upgrades: UpgradeLevels, zoneMultiplierPercent: Int) {
        self.config = config
        self.upgrades = upgrades
        self.zoneMultiplierPercent = zoneMultiplierPercent
    }

    public func tiles(_ count: Int) -> Int {
        config.safeTileReward
            .multipliedSaturated(max(count, 0))
            .applyingPercent(100 + upgrades.effect(.betterPickaxe))
            .applyingPercent(zoneMultiplierPercent)
    }

    public func treasure() -> Int {
        config.treasureReward
            .applyingPercent(100 + upgrades.effect(.treasureMagnet))
            .applyingPercent(zoneMultiplierPercent)
    }

    public func correctFlags(_ count: Int) -> Int {
        config.correctFlagReward
            .multipliedSaturated(max(count, 0))
            .applyingPercent(zoneMultiplierPercent)
    }

    /// `streak` counts the win being paid, so the first win in a row is 1.
    public func completion(streak: Int) -> Int {
        let steps = min(max(streak - 1, 0), config.streakMaxSteps)
        let streakPercent = steps * (config.streakStepPercent + upgrades.effect(.comboCharm))
        return config.completionReward
            .applyingPercent(100 + upgrades.effect(.luckyGloves))
            .applyingPercent(100 + streakPercent)
            .applyingPercent(zoneMultiplierPercent)
    }

    public var scannerCharges: Int {
        upgrades[.mineScanner] == 0 ? 0 : upgrades.effect(.mineScanner) + upgrades.effect(.extraSupplies)
    }

    public var helmetCharges: Int {
        upgrades.effect(.safetyHelmet)
    }
}
