import Foundation

// MARK: - Zones

public enum ZoneID: String, Codable, CaseIterable, Sendable {
    case sunnyQuarry, crystalCaves, volcanoVault
}

public struct ZoneDefinition: Sendable {
    public let id: ZoneID
    public let name: String
    public let tagline: String
    public let rewardMultiplierPercent: Int
    /// Clears needed in the previous zone. Zones are never sold for money.
    public let unlock: (zone: ZoneID, clears: Int)?
    public let collectibles: [String]
    let cols: Int
    let rows: ClosedRange<Int>
    /// Mine density in percent, from first to fully-ramped board.
    let density: ClosedRange<Int>
    /// Clears it takes to ramp from easiest to hardest board.
    let rampClears: Int

    /// Board for the given number of clears already made in this zone.
    public func boardConfig(clears: Int) -> BoardConfig {
        let t = min(max(clears, 0), rampClears)
        let rowCount = rows.lowerBound + (rows.upperBound - rows.lowerBound) * t / rampClears
        let percent = density.lowerBound + (density.upperBound - density.lowerBound) * t / rampClears
        return BoardConfig(rows: rowCount, cols: cols, mines: max(rowCount * cols * percent / 100, 1))
    }
}

public enum ZoneCatalog {
    public static let all: [ZoneDefinition] = [
        ZoneDefinition(id: .sunnyQuarry, name: "Sunny Quarry", tagline: "Bright grass and gold veins.",
                       rewardMultiplierPercent: 100, unlock: nil,
                       collectibles: ["Gold Nugget", "Lucky Clover", "Old Lantern", "Sun Stone"],
                       cols: 9, rows: 9...12, density: 12...16, rampClears: 10),
        ZoneDefinition(id: .crystalCaves, name: "Crystal Caves", tagline: "Glowing turquoise crystals.",
                       rewardMultiplierPercent: 250, unlock: (.sunnyQuarry, 10),
                       collectibles: ["Aqua Crystal", "Glow Shroom", "Echo Shell", "Prism Geode"],
                       cols: 10, rows: 12...15, density: 14...18, rampClears: 15),
        ZoneDefinition(id: .volcanoVault, name: "Volcano Vault", tagline: "Lava crystals and ancient machines.",
                       rewardMultiplierPercent: 600, unlock: (.crystalCaves, 15),
                       collectibles: ["Ember Ruby", "Clockwork Cog", "Dragon Scale", "Magma Heart"],
                       cols: 12, rows: 14...18, density: 16...20, rampClears: 20),
    ]

    public static func definition(_ id: ZoneID) -> ZoneDefinition {
        all.first { $0.id == id }!
    }
}

// MARK: - Workers

public enum WorkerID: String, Codable, CaseIterable, Sendable {
    case milo, pip, bolt
}

public struct WorkerDefinition: Sendable {
    public let id: WorkerID
    public let name: String
    public let role: String
    /// Milli-coins per second added by each level.
    public let rateMilliPerLevel: Int
    public let baseCost: Int
    public let costGrowth: Int
    public let unlockText: String

    public func cost(toReachLevel level: Int) -> Int {
        var cost = baseCost
        for _ in 1..<max(level, 1) {
            cost = cost.applyingPercent(costGrowth)
        }
        return cost
    }
}

public enum WorkerCatalog {
    public static let all: [WorkerDefinition] = [
        WorkerDefinition(id: .milo, name: "Milo", role: "Rookie Miner",
                         rateMilliPerLevel: 2_000, baseCost: 400, costGrowth: 118,
                         unlockText: "Clear 3 Expedition sites"),
        WorkerDefinition(id: .pip, name: "Pip", role: "Treasure Collector",
                         rateMilliPerLevel: 6_000, baseCost: 6_000, costGrowth: 120,
                         unlockText: "Unlock Crystal Caves"),
        WorkerDefinition(id: .bolt, name: "Bolt", role: "Machine Operator",
                         rateMilliPerLevel: 15_000, baseCost: 40_000, costGrowth: 122,
                         unlockText: "Unlock Volcano Vault"),
    ]

    public static func definition(_ id: WorkerID) -> WorkerDefinition {
        all.first { $0.id == id }!
    }

    /// Pip finds a treasure chest for every this many seconds of production.
    public static let pipChestInterval = 600
    /// A chest is worth this many seconds of total team output.
    public static let pipChestSeconds = 120
    public static let boltTeamBonusPerLevel = 2
    public static let baseOfflineCapHours = 4
}

public struct WorkerLevels: Codable, Equatable, Sendable {
    private var levels: [String: Int] = [:]

    public init() {}

    public subscript(_ id: WorkerID) -> Int {
        get { levels[id.rawValue] ?? 0 }
        set { levels[id.rawValue] = newValue }
    }
}

public enum WorkerService {
    /// Total team output in milli-coins per second.
    public static func teamRateMilli(_ workers: WorkerLevels, upgrades: UpgradeLevels) -> Int {
        WorkerID.allCases.reduce(0) { $0.addingSaturated(rateMilli($1, workers: workers, upgrades: upgrades)) }
    }

    /// One worker's share of the team output, team-wide bonuses included.
    public static func rateMilli(_ id: WorkerID, workers: WorkerLevels, upgrades: UpgradeLevels) -> Int {
        let def = WorkerCatalog.definition(id)
        var percent = 100 + upgrades.effect(.minerTraining)
        if id == .bolt { percent += upgrades.effect(.betterDrill) }
        let teamPercent = 100 + upgrades.effect(.teamEfficiency)
            + workers[.bolt] * WorkerCatalog.boltTeamBonusPerLevel
        return def.rateMilliPerLevel
            .multipliedSaturated(workers[id])
            .applyingPercent(percent)
            .applyingPercent(teamPercent)
    }

    public static func isUnlocked(_ id: WorkerID, profile: PlayerProfile) -> Bool {
        switch id {
        case .milo: return profile.expeditionWins >= 3
        case .pip: return profile.isZoneUnlocked(.crystalCaves)
        case .bolt: return profile.isZoneUnlocked(.volcanoVault)
        }
    }

    public static func nextCost(_ id: WorkerID, workers: WorkerLevels) -> Int {
        WorkerCatalog.definition(id).cost(toReachLevel: workers[id] + 1)
    }
}

// MARK: - Offline earnings

public struct OfflineReward: Codable, Equatable, Sendable {
    /// Unique per absence so the claim can only be banked once.
    public let id: String
    public let seconds: Int
    public let coins: Int
    public let chests: Int
    public let wasCapped: Bool
}

public enum OfflineEarnings {
    /// Shorter absences are paid silently through normal accrual instead of a panel.
    public static let minimumSeconds = 60

    /// `lastActive` and `now` are Unix seconds. A clock that went backwards pays nothing.
    public static func compute(
        lastActive: Double,
        now: Double,
        rateMilli: Int,
        pipHired: Bool,
        capHours: Int
    ) -> OfflineReward? {
        guard lastActive.isFinite, now.isFinite, rateMilli > 0 else { return nil }
        let elapsed = now - lastActive
        guard elapsed >= Double(minimumSeconds) else { return nil }
        let cap = max(capHours, 0) * 3600
        let seconds = elapsed >= Double(cap) ? cap : Int(elapsed)
        let chests = pipHired ? seconds / WorkerCatalog.pipChestInterval : 0
        let base = rateMilli.multipliedSaturated(seconds) / 1000
        let chestCoins = rateMilli.multipliedSaturated(WorkerCatalog.pipChestSeconds).multipliedSaturated(chests) / 1000
        return OfflineReward(
            id: "offline:\(Int(lastActive))",
            seconds: seconds,
            coins: base.addingSaturated(chestCoins),
            chests: chests,
            wasCapped: seconds == cap
        )
    }
}

// MARK: - Daily challenge

public enum DailyChallenge {
    public static let config = BoardConfig.intermediate
    public static let opening = Coord(row: 8, col: 8)

    /// "2026-11-02" in the given calendar's time zone.
    public static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// FNV-1a over the key, so every player gets the same board on the same day.
    public static func seed(forDay key: String) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in "minerush-daily-\(key)".utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01B3
        }
        return hash
    }

    public static func board(forDay key: String) -> MinesweeperBoard {
        PuzzleSolver.generateBoard(config: config, seed: seed(forDay: key), opening: opening, requireNoGuess: true)
    }

    /// True when `next` is the calendar day after `previous`.
    public static func isConsecutive(_ previous: String, _ next: String) -> Bool {
        let fmt = DateFormatter()
        fmt.calendar = Calendar(identifier: .gregorian)
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.dateFormat = "yyyy-MM-dd"
        guard let a = fmt.date(from: previous), let b = fmt.date(from: next) else { return false }
        return Int(b.timeIntervalSince(a).rounded()) == 86_400
    }
}

// MARK: - Expedition run

/// Pays one Expedition board. The opening reveal is free (it isn't deduction),
/// tiles are paid at most once, and the clear bonus settles exactly once.
public struct ExpeditionRun: Codable, Sendable {
    public let id: String
    public let zone: ZoneID
    /// Every tenth site: a bigger board with a boss whose health is the safe tiles left.
    public let isBoss: Bool
    public private(set) var board: MinesweeperBoard
    public let treasureCells: Set<Coord>
    public private(set) var foundTreasures: [Coord] = []
    public private(set) var scannerCharges: Int
    public private(set) var helmetCharges: Int
    public private(set) var coinsThisRun = 0
    public private(set) var moveCount = 0
    public private(set) var isSettled = false
    public private(set) var combo = ComboTracker()
    /// Coin Magnet doubles coins until this time.
    public private(set) var magnetUntil: Double?

    public init(id: String, zone: ZoneID, board: MinesweeperBoard, scannerCharges: Int, helmetCharges: Int,
                treasureCount: Int, isBoss: Bool = false) {
        self.id = id
        self.zone = zone
        self.isBoss = isBoss
        self.board = board
        self.scannerCharges = scannerCharges
        self.helmetCharges = helmetCharges
        var rng = SplitMix64(seed: board.seed ^ 0x7EA5)
        let candidates = board.allCoords.filter { !board[$0].isMine && board[$0].state == .hidden }
        var picks = Set<Coord>()
        while picks.count < min(treasureCount, candidates.count) {
            picks.insert(candidates[Int.random(in: 0..<candidates.count, using: &rng)])
        }
        treasureCells = picks
    }

    public enum Move {
        case reveal(Coord), chord(Coord), flag(Coord), scan
        /// The coordinate is the target tile (X-ray uses its row; Magnet ignores it).
        case item(PowerUp, Coord)
    }

    public struct MoveOutcome: Equatable, Sendable {
        public var result = RevealResult.empty
        public var flag: FlagChange?
        public var tileCoins = 0
        public var treasures: [Coord] = []
        public var scanned: Coord?
        public var usedItem: PowerUp?
        /// Radar Pulse: mines to show briefly.
        public var radarMines: [Coord] = []
        /// Set when this move pushed the combo into a higher tier.
        public var comboTierUp: Int?
        /// Combo plus Magnet bonus applied to this move's coins, in percent.
        public var bonusPercent = 0
        /// Power-ups awarded for clearing the site.
        public var drops: [PowerUp] = []

        public init() {}
    }

    public func isMagnetActive(at now: Double) -> Bool {
        (magnetUntil ?? -.infinity) > now
    }

    /// Applies a move to the board and prices it. Banking is the caller's job,
    /// keyed by `ledgerID(forMove:)` so a replayed move can't pay twice.
    public mutating func play(_ move: Move, rewards: RewardCalculator, now: Double = 0) -> MoveOutcome {
        var outcome = MoveOutcome()
        guard !board.status.isOver else { return outcome }
        let shield = helmetCharges > 0
        switch move {
        case .reveal(let c):
            outcome.result = board.reveal(c, shield: shield)
        case .chord(let c):
            outcome.result = board.chord(c, shield: shield)
        case .flag(let c):
            outcome.flag = board.toggleFlag(c)
            return outcome
        case .item(let item, let c):
            outcome.usedItem = item
            switch item {
            case .dynamite:
                outcome.result = board.blast(c)
            case .xray:
                outcome.result = board.defuseMines(in: board.row(c.row))
            case .radar:
                outcome.radarMines = board.mines(in: board.area(around: c, radius: PowerUp.radarRadius))
                return outcome
            case .magnet:
                magnetUntil = max(magnetUntil ?? now, now) + PowerUp.magnetSeconds
                return outcome
            }
        case .scan:
            guard scannerCharges > 0, let hint = PuzzleSolver.hint(for: board) else { return outcome }
            scannerCharges -= 1
            outcome.scanned = hint
            outcome.result = board.reveal(hint)
            // Scans are free help, not digging: paying them would let players farm
            // fresh charges by restarting sites.
            moveCount += 1
            return outcome
        }
        if outcome.result.shieldedMine != nil { helmetCharges -= 1 }
        moveCount += 1
        if outcome.result.hitMine != nil || outcome.result.shieldedMine != nil {
            combo.reset()
        } else {
            outcome.comboTierUp = combo.register(revealed: outcome.result.revealed.count, at: now)
        }
        outcome.bonusPercent = combo.bonusPercent + (isMagnetActive(at: now) ? 100 : 0)
        let treasureSet = treasureCells
        outcome.treasures = outcome.result.revealed.filter { treasureSet.contains($0) }
        foundTreasures += outcome.treasures
        outcome.tileCoins = rewards.tiles(outcome.result.revealed.count)
            .addingSaturated(rewards.treasure().multipliedSaturated(outcome.treasures.count))
            .applyingPercent(100 + outcome.bonusPercent)
        coinsThisRun = coinsThisRun.addingSaturated(outcome.tileCoins)
        return outcome
    }

    public var ledgerIDForLastMove: String { "run:\(id):move:\(moveCount)" }
    public var ledgerIDForClear: String { "run:\(id):clear" }

    /// Clear bonus plus verified flags. Returns nil unless the board is won and unsettled.
    public mutating func settleWin(streak: Int, rewards: RewardCalculator) -> Int? {
        guard board.status == .won, !isSettled else { return nil }
        isSettled = true
        let coins = rewards.completion(streak: streak)
            .multipliedSaturated(isBoss ? BossCatalog.rewardMultiplier : 1)
            .addingSaturated(rewards.correctFlags(board.correctFlagCount))
        coinsThisRun = coinsThisRun.addingSaturated(coins)
        return coins
    }
}

// MARK: - Player profile

public struct DailyRecord: Codable, Equatable, Sendable {
    public var lastCompletedDay: String?
    public var streak = 0
    public var bestStreak = 0
    public var bestSeconds: [String: Int] = [:]
}

public struct PlayerProfile: Codable, Sendable {
    public var ledger = CurrencyLedger()
    public var upgrades = UpgradeLevels()
    public var workers = WorkerLevels()
    public var zoneClears: [String: Int] = [:]
    public var expeditionWins = 0
    public var expeditionStreak = 0
    public var bestExpeditionStreak = 0
    public var collectibles: [String: Int] = [:]
    /// Best Classic times in seconds, keyed by "rowsxcols-mines".
    public var classicBest: [String: Int] = [:]
    public var classicWins = 0
    public var daily = DailyRecord()
    /// Unix seconds of the last time passive income was settled.
    public var lastActiveAt: Double?
    public var passiveMilliRemainder = 0
    public var pendingOffline: OfflineReward?
    public var tutorialCompleted = false
    public var runCounter = 0
    /// The Expedition site in progress, saved so it survives the app being killed.
    public var activeRun: ExpeditionRun?
    public var inventory = Inventory.starter
    public var itemPurchases = 0
    public var bossesDefeated = 0
    public var rushBest = 0
    public var endlessBestDepth = 0
    public var darkWins = 0

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case ledger, upgrades, workers, zoneClears, expeditionWins, expeditionStreak, bestExpeditionStreak
        case collectibles, classicBest, classicWins, daily, lastActiveAt, passiveMilliRemainder
        case pendingOffline, tutorialCompleted, runCounter, activeRun
        case inventory, itemPurchases, bossesDefeated, rushBest, endlessBestDepth, darkWins
    }

    /// Every field is optional on decode so saves from older builds keep loading
    /// when fields are added. A broken in-progress board drops only the board.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ledger = try c.decodeIfPresent(CurrencyLedger.self, forKey: .ledger) ?? CurrencyLedger()
        upgrades = try c.decodeIfPresent(UpgradeLevels.self, forKey: .upgrades) ?? UpgradeLevels()
        workers = try c.decodeIfPresent(WorkerLevels.self, forKey: .workers) ?? WorkerLevels()
        zoneClears = try c.decodeIfPresent([String: Int].self, forKey: .zoneClears) ?? [:]
        expeditionWins = try c.decodeIfPresent(Int.self, forKey: .expeditionWins) ?? 0
        expeditionStreak = try c.decodeIfPresent(Int.self, forKey: .expeditionStreak) ?? 0
        bestExpeditionStreak = try c.decodeIfPresent(Int.self, forKey: .bestExpeditionStreak) ?? 0
        collectibles = try c.decodeIfPresent([String: Int].self, forKey: .collectibles) ?? [:]
        classicBest = try c.decodeIfPresent([String: Int].self, forKey: .classicBest) ?? [:]
        classicWins = try c.decodeIfPresent(Int.self, forKey: .classicWins) ?? 0
        daily = try c.decodeIfPresent(DailyRecord.self, forKey: .daily) ?? DailyRecord()
        lastActiveAt = try c.decodeIfPresent(Double.self, forKey: .lastActiveAt)
        passiveMilliRemainder = try c.decodeIfPresent(Int.self, forKey: .passiveMilliRemainder) ?? 0
        pendingOffline = try c.decodeIfPresent(OfflineReward.self, forKey: .pendingOffline)
        tutorialCompleted = try c.decodeIfPresent(Bool.self, forKey: .tutorialCompleted) ?? false
        runCounter = try c.decodeIfPresent(Int.self, forKey: .runCounter) ?? 0
        activeRun = (try? c.decodeIfPresent(ExpeditionRun.self, forKey: .activeRun)) ?? nil
        inventory = try c.decodeIfPresent(Inventory.self, forKey: .inventory) ?? .starter
        itemPurchases = try c.decodeIfPresent(Int.self, forKey: .itemPurchases) ?? 0
        bossesDefeated = try c.decodeIfPresent(Int.self, forKey: .bossesDefeated) ?? 0
        rushBest = try c.decodeIfPresent(Int.self, forKey: .rushBest) ?? 0
        endlessBestDepth = try c.decodeIfPresent(Int.self, forKey: .endlessBestDepth) ?? 0
        darkWins = try c.decodeIfPresent(Int.self, forKey: .darkWins) ?? 0
    }

    public func clears(in zone: ZoneID) -> Int {
        zoneClears[zone.rawValue] ?? 0
    }

    public func isZoneUnlocked(_ zone: ZoneID) -> Bool {
        guard let req = ZoneCatalog.definition(zone).unlock else { return true }
        return isZoneUnlocked(req.zone) && clears(in: req.zone) >= req.clears
    }

    public func rewards(in zone: ZoneID, config: EconomyConfig = .standard) -> RewardCalculator {
        RewardCalculator(config: config, upgrades: upgrades, zoneMultiplierPercent: ZoneCatalog.definition(zone).rewardMultiplierPercent)
    }

    public var teamRateMilli: Int {
        WorkerService.teamRateMilli(workers, upgrades: upgrades)
    }

    public var offlineCapHours: Int {
        WorkerCatalog.baseOfflineCapHours + upgrades.effect(.biggerStorage)
    }

    // MARK: Expedition

    /// Board size and opening for the next site in `zone`. Lets the app generate
    /// the (slow, validated) board off the main thread before starting the run.
    public func nextSiteSpec(in zone: ZoneID) -> (config: BoardConfig, opening: Coord, isBoss: Bool) {
        let isBoss = BossCatalog.isBossSite(clears: clears(in: zone))
        let boardConfig = isBoss
            ? BossCatalog.config(for: zone)
            : ZoneCatalog.definition(zone).boardConfig(clears: clears(in: zone))
        return (boardConfig, Coord(row: boardConfig.rows / 2, col: boardConfig.cols / 2), isBoss)
    }

    /// Generates the board inline and starts the site. Fine for tests; the app
    /// generates in the background and calls `startExpedition(in:board:)`.
    @discardableResult
    public mutating func startExpedition(in zone: ZoneID, seed: UInt64, config: EconomyConfig = .standard) -> ExpeditionRun {
        let spec = nextSiteSpec(in: zone)
        let board = PuzzleSolver.generateBoard(config: spec.config, seed: seed, opening: spec.opening, requireNoGuess: true)
        return startExpedition(in: zone, board: board, config: config)
    }

    /// Starts a site on a ready board and makes it the active run. Walking away
    /// from an unfinished site counts as a loss for the win streak.
    @discardableResult
    public mutating func startExpedition(in zone: ZoneID, board: MinesweeperBoard, config: EconomyConfig = .standard) -> ExpeditionRun {
        if let current = activeRun, !current.board.status.isOver {
            expeditionStreak = 0
        }
        runCounter += 1
        let calc = rewards(in: zone, config: config)
        let run = ExpeditionRun(
            id: "\(runCounter)-\(board.seed)",
            zone: zone,
            board: board,
            scannerCharges: calc.scannerCharges,
            helmetCharges: calc.helmetCharges,
            treasureCount: config.treasureTilesPerBoard,
            isBoss: BossCatalog.isBossSite(clears: clears(in: zone))
        )
        activeRun = run
        return run
    }

    /// Plays a move on the active run. Nil when there's no site in progress.
    @discardableResult
    public mutating func playExpedition(_ move: ExpeditionRun.Move, now: Double = 0,
                                        config: EconomyConfig = .standard) -> ExpeditionRun.MoveOutcome? {
        guard var run = activeRun else { return nil }
        let outcome = play(move, in: &run, now: now, config: config)
        activeRun = run
        return outcome
    }

    /// Plays a move, banks its coins, and settles the board if it ended.
    @discardableResult
    public mutating func play(_ move: ExpeditionRun.Move, in run: inout ExpeditionRun, now: Double = 0,
                              config: EconomyConfig = .standard) -> ExpeditionRun.MoveOutcome {
        if case .item(let item, _) = move {
            // Spend the item only when it can actually be used.
            guard !run.board.status.isOver, inventory.use(item) else { return ExpeditionRun.MoveOutcome() }
        }
        let calc = rewards(in: run.zone, config: config)
        var outcome = run.play(move, rewards: calc, now: now)
        if outcome.tileCoins > 0 {
            ledger.credit(outcome.tileCoins, .coins, id: run.ledgerIDForLastMove)
        }
        let items = ZoneCatalog.definition(run.zone).collectibles
        for t in outcome.treasures {
            let name = items[(t.row * 31 + t.col) % items.count]
            collectibles[name, default: 0] += 1
        }
        if outcome.result.didWin {
            expeditionStreak += 1
            bestExpeditionStreak = max(bestExpeditionStreak, expeditionStreak)
            if let bonus = run.settleWin(streak: expeditionStreak, rewards: calc) {
                ledger.credit(bonus, .coins, id: run.ledgerIDForClear)
                expeditionWins += 1
                zoneClears[run.zone.rawValue, default: 0] += 1
                if run.isBoss { bossesDefeated += 1 }
                outcome.drops = ItemDrops.roll(seed: run.id, count: run.isBoss ? BossCatalog.itemDrops : 1)
                for item in outcome.drops { inventory.add(item) }
            }
        } else if outcome.result.hitMine != nil {
            expeditionStreak = 0
        }
        return outcome
    }

    // MARK: Classic & daily

    public mutating func recordClassicWin(config: BoardConfig, seconds: Int) -> Bool {
        classicWins += 1
        let key = "\(config.rows)x\(config.cols)-\(config.mines)"
        guard seconds < classicBest[key] ?? .max else { return false }
        classicBest[key] = seconds
        return true
    }

    /// Records a daily completion once per day. Returns false for repeats.
    public mutating func recordDailyWin(day: String, seconds: Int) -> Bool {
        guard daily.lastCompletedDay != day else { return false }
        if let last = daily.lastCompletedDay, DailyChallenge.isConsecutive(last, day) {
            daily.streak += 1
        } else {
            daily.streak = 1
        }
        daily.bestStreak = max(daily.bestStreak, daily.streak)
        daily.lastCompletedDay = day
        daily.bestSeconds[day] = seconds
        return true
    }

    // MARK: Arcade modes

    /// Pays a finished Rush / Dark Mine / Endless session once, keyed by its id.
    @discardableResult
    public mutating func bankModeReward(id: String, coins: Int) -> Bool {
        ledger.credit(coins, .coins, id: "mode:\(id)")
    }

    /// Returns true for a new best.
    public mutating func recordRush(score: Int) -> Bool {
        guard score > rushBest else { return false }
        rushBest = score
        return true
    }

    public mutating func recordEndless(depth: Int) -> Bool {
        guard depth > endlessBestDepth else { return false }
        endlessBestDepth = depth
        return true
    }

    public mutating func recordDarkWin() {
        darkWins += 1
    }

    // MARK: Items

    public mutating func buyItem(_ item: PowerUp) -> PurchaseOutcome {
        guard ledger.spend(item.price, .coins, id: "item:\(item.rawValue):\(itemPurchases + 1)") else {
            return .insufficientFunds(cost: item.price)
        }
        itemPurchases += 1
        inventory.add(item)
        return .purchased(newLevel: inventory[item], cost: item.price)
    }

    // MARK: Upgrades & workers

    public mutating func buyUpgrade(_ id: UpgradeID) -> PurchaseOutcome {
        UpgradeService.purchase(id, levels: &upgrades, ledger: &ledger)
    }

    public mutating func hireOrUpgrade(_ id: WorkerID, now: Double) -> PurchaseOutcome {
        guard WorkerService.isUnlocked(id, profile: self) else {
            return .locked(reason: WorkerCatalog.definition(id).unlockText)
        }
        // Settle income at the old rate first so the upgrade isn't applied retroactively.
        settleTime(now: now)
        let cost = WorkerService.nextCost(id, workers: workers)
        guard ledger.spend(cost, .coins, id: "worker:\(id.rawValue):\(workers[id] + 1)") else {
            return .insufficientFunds(cost: cost)
        }
        workers[id] += 1
        return .purchased(newLevel: workers[id], cost: cost)
    }

    // MARK: Passive income

    /// Settles worker income up to `now`. Short gaps are paid straight away; a gap
    /// of a minute or more becomes a capped welcome-back reward that must be claimed.
    /// A clock that moved backwards pays nothing and restarts from `now`.
    /// Returns the reward when one was just created.
    @discardableResult
    public mutating func settleTime(now: Double) -> OfflineReward? {
        guard now.isFinite else { return nil }
        guard let last = lastActiveAt, last.isFinite else {
            lastActiveAt = now
            return nil
        }
        // Clock moved backwards: pay nothing and keep the high-water mark, so
        // winding the clock forward and back can't mint repeat offline rewards.
        guard now >= last else { return nil }
        let elapsed = now - last
        lastActiveAt = now
        if elapsed >= Double(OfflineEarnings.minimumSeconds), pendingOffline == nil {
            pendingOffline = OfflineEarnings.compute(
                lastActive: last, now: now, rateMilli: teamRateMilli,
                pipHired: workers[.pip] > 0, capHours: offlineCapHours
            )
            return pendingOffline
        }
        let seconds = min(elapsed, Double(offlineCapHours * 3600))
        let total = passiveMilliRemainder.addingSaturated(teamRateMilli.multipliedSaturated(Int(seconds * 1000)) / 1000)
        passiveMilliRemainder = total % 1000
        ledger.creditUntracked(total / 1000, .coins)
        return nil
    }

    /// Banks the pending offline reward once. `multiplier` is for the rewarded-ad double.
    @discardableResult
    public mutating func claimOfflineReward(multiplier: Int = 1) -> Int {
        guard let reward = pendingOffline else { return 0 }
        pendingOffline = nil
        let coins = reward.coins.multipliedSaturated(max(multiplier, 1))
        return ledger.credit(coins, .coins, id: reward.id) ? coins : 0
    }
}

// MARK: - Persistence

/// Versioned envelope so future releases can migrate old saves.
struct SaveEnvelope: Codable {
    static let currentVersion = 1
    var version: Int
    var savedAt: Double
    var profile: PlayerProfile
}

private struct VersionProbe: Decodable {
    var version: Int
}

public enum SaveError: Error, Equatable {
    case unsupportedVersion(Int)
}

/// Writes the profile atomically and keeps the previous good save as a backup,
/// so a crash mid-write or a corrupted file falls back instead of wiping progress.
public struct SaveRepository {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    var primaryURL: URL { directory.appendingPathComponent("profile.json") }
    var backupURL: URL { directory.appendingPathComponent("profile.backup.json") }

    public func save(_ profile: PlayerProfile, now: Double) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(SaveEnvelope(version: SaveEnvelope.currentVersion, savedAt: now, profile: profile))
        if (try? Self.decode(Data(contentsOf: primaryURL))) != nil {
            try? FileManager.default.removeItem(at: backupURL)
            try? FileManager.default.copyItem(at: primaryURL, to: backupURL)
        }
        try data.write(to: primaryURL, options: .atomic)
    }

    public enum LoadSource: Equatable {
        case primary, backup, fresh
    }

    public func load() -> (profile: PlayerProfile, source: LoadSource) {
        if let data = try? Data(contentsOf: primaryURL), let profile = try? Self.decode(data) {
            return (profile, .primary)
        }
        if let data = try? Data(contentsOf: backupURL), let profile = try? Self.decode(data) {
            return (profile, .backup)
        }
        return (PlayerProfile(), .fresh)
    }

    static func decode(_ data: Data) throws -> PlayerProfile {
        let version = try JSONDecoder().decode(VersionProbe.self, from: data).version
        guard version == SaveEnvelope.currentVersion else { throw SaveError.unsupportedVersion(version) }
        return try SaveMigration.migrate(JSONDecoder().decode(SaveEnvelope.self, from: data))
    }
}

enum SaveMigration {
    static func migrate(_ envelope: SaveEnvelope) throws -> PlayerProfile {
        switch envelope.version {
        case 1: return envelope.profile
        default: throw SaveError.unsupportedVersion(envelope.version)
        }
    }
}
