// MARK: - Power-ups

public enum PowerUp: String, Codable, CaseIterable, Sendable {
    /// Opens a 3x3; mines inside are defused.
    case dynamite
    /// Shows the mines in a 5x5 for a few seconds.
    case radar
    /// Doubles coins for 30 seconds.
    case magnet
    /// Flags every mine in one row.
    case xray

    public var name: String {
        switch self {
        case .dynamite: return "Dynamite"
        case .radar: return "Radar Pulse"
        case .magnet: return "Coin Magnet"
        case .xray: return "X-Ray"
        }
    }

    public var summary: String {
        switch self {
        case .dynamite: return "Blast open a 3x3. Mines inside are defused."
        case .radar: return "Reveal every mine in a 5x5 for 3 seconds."
        case .magnet: return "Double all coins for 30 seconds."
        case .xray: return "Flag every mine in a whole row."
        }
    }

    /// Whether using it needs a tile picked on the board.
    public var needsTarget: Bool { self != .magnet }

    /// Coin price in the shop. Higher than a typical payout so buying isn't a coin loop.
    public var price: Int {
        switch self {
        case .dynamite: return 600
        case .radar: return 400
        case .magnet: return 900
        case .xray: return 800
        }
    }

    public static let radarRadius = 2
    public static let radarSeconds = 3.0
    public static let magnetSeconds = 30.0
}

public struct Inventory: Codable, Equatable, Sendable {
    private var counts: [String: Int] = [:]

    public init() {}

    /// What every new player starts with, so the items are discovered early.
    public static var starter: Inventory {
        var inv = Inventory()
        for item in PowerUp.allCases { inv.add(item, 2) }
        return inv
    }

    public subscript(_ item: PowerUp) -> Int {
        counts[item.rawValue] ?? 0
    }

    public mutating func add(_ item: PowerUp, _ amount: Int = 1) {
        counts[item.rawValue] = self[item].addingSaturated(max(amount, 0))
    }

    /// Takes one if available.
    public mutating func use(_ item: PowerUp) -> Bool {
        guard self[item] > 0 else { return false }
        counts[item.rawValue] = self[item] - 1
        return true
    }
}

// MARK: - Combo

/// Counts digging moves made in quick succession. Each tier boosts coins and
/// drives the bigger screen effects.
public struct ComboTracker: Codable, Equatable, Sendable {
    /// Seconds allowed between moves before the combo drops.
    public static let window = 3.0
    public static let tierThresholds = [5, 10, 20]
    public static let tierBonusPercent = [0, 50, 100, 200]

    public private(set) var count = 0
    private var lastAt: Double?

    public init() {}

    public var tier: Int {
        Self.tierThresholds.filter { count >= $0 }.count
    }

    public var bonusPercent: Int {
        Self.tierBonusPercent[tier]
    }

    public func isAlive(at now: Double) -> Bool {
        guard let lastAt else { return false }
        return now - lastAt <= Self.window
    }

    /// Registers a move that opened tiles. Returns the new tier when it just went up.
    @discardableResult
    public mutating func register(revealed: Int, at now: Double) -> Int? {
        guard revealed > 0 else { return nil }
        if !isAlive(at: now) { count = 0 }
        let before = tier
        count += 1
        lastAt = now
        return tier > before ? tier : nil
    }

    public mutating func reset() {
        count = 0
        lastAt = nil
    }
}

// MARK: - Bosses

public struct BossDefinition: Sendable {
    public let zone: ZoneID
    public let name: String
    public let title: String
}

/// Every tenth site in a zone is a boss site: a bigger board whose health bar
/// is the safe tiles left to dig. No hidden rules, so it stays a fair puzzle.
public enum BossCatalog {
    public static let interval = 10
    public static let rewardMultiplier = 5
    public static let itemDrops = 3

    public static func boss(for zone: ZoneID) -> BossDefinition {
        switch zone {
        case .sunnyQuarry: return BossDefinition(zone: zone, name: "Boulder Bruno", title: "Quarry Crusher")
        case .crystalCaves: return BossDefinition(zone: zone, name: "Prisma", title: "Crystal Wyrm")
        case .volcanoVault: return BossDefinition(zone: zone, name: "Magmus", title: "Lava Golem")
        }
    }

    /// `clears` is the number already cleared in the zone, so sites 10, 20, ... are bosses.
    public static func isBossSite(clears: Int) -> Bool {
        (clears + 1) % interval == 0
    }

    public static func config(for zone: ZoneID) -> BoardConfig {
        let hardest = ZoneCatalog.definition(zone).boardConfig(clears: .max)
        return BoardConfig(rows: hardest.rows + 4, cols: hardest.cols, mines: (hardest.rows + 4) * hardest.cols * 18 / 100)
    }

    public static func health(of board: MinesweeperBoard) -> (left: Int, total: Int) {
        (board.config.safeCellCount - board.revealedSafeCount, board.config.safeCellCount)
    }
}

/// Picks item drops deterministically from a run id, so replays and tests agree.
enum ItemDrops {
    static func roll(seed: String, count: Int) -> [PowerUp] {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in seed.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01B3
        }
        var rng = SplitMix64(seed: hash)
        return (0..<count).map { _ in PowerUp.allCases[Int.random(in: 0..<PowerUp.allCases.count, using: &rng)] }
    }
}
