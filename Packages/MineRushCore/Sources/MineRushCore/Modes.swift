/// A move in an arcade mode. Items are Endless-only.
public enum ArcadeMove {
    case reveal(Coord), chord(Coord), flag(Coord)
    case item(PowerUp, Coord)
}

/// What a move did, for scoring feedback and screen effects.
public struct ArcadeOutcome: Equatable, Sendable {
    public var result = RevealResult.empty
    public var flag: FlagChange?
    public var points = 0
    public var comboTierUp: Int?
    public var radarMines: [Coord] = []
    /// Rush: seconds added (clear) or removed (mine).
    public var timeDelta: Double = 0
    /// Rush: a fresh board was dealt after this move.
    public var newBoard = false
    /// Endless: a life was spent on a mine.
    public var lostLife = false
}

private func applyBasic(_ move: ArcadeMove, to board: inout MinesweeperBoard, shield: Bool) -> (RevealResult, FlagChange?) {
    switch move {
    case .reveal(let c): return (board.reveal(c, shield: shield), nil)
    case .chord(let c): return (board.chord(c, shield: shield), nil)
    case .flag(let c): return (.empty, board.toggleFlag(c))
    case .item: return (.empty, nil)
    }
}

// MARK: - Rush

/// 60 seconds of small no-guess boards dealt back to back. Tiles score points
/// (multiplied by the combo), a clear adds time, a mine costs time and deals a
/// new board. Nothing ends the run except the clock.
public struct RushSession: Codable, Sendable {
    public static let duration = 60.0
    public static let clearBonusSeconds = 8.0
    public static let minePenaltySeconds = 10.0
    public static let clearPoints = 50
    public static let coinsPerPoint = 4
    public static let config = BoardConfig(rows: 9, cols: 8, mines: 10)

    public let id: String
    public private(set) var board: MinesweeperBoard
    public private(set) var timeLeft = RushSession.duration
    public private(set) var score = 0
    public private(set) var boardsCleared = 0
    public private(set) var combo = ComboTracker()
    private let seed: UInt64
    private var dealt = 0

    public init(id: String, seed: UInt64) {
        self.id = id
        self.seed = seed
        board = Self.deal(seed: seed, index: 0)
    }

    public var isOver: Bool { timeLeft <= 0 }
    public var coinReward: Int { score.multipliedSaturated(Self.coinsPerPoint) }

    static func deal(seed: UInt64, index: Int) -> MinesweeperBoard {
        var rng = SplitMix64(seed: seed &+ UInt64(index))
        let opening = Coord(row: config.rows / 2, col: config.cols / 2)
        return PuzzleSolver.generateBoard(config: config, seed: rng.next(), opening: opening, requireNoGuess: true)
    }

    /// Runs the clock. The combo window is real time too, so pass the same clock to `play`.
    public mutating func tick(_ seconds: Double) {
        guard seconds > 0 else { return }
        timeLeft = max(0, timeLeft - seconds)
    }

    @discardableResult
    public mutating func play(_ move: ArcadeMove, now: Double) -> ArcadeOutcome {
        var outcome = ArcadeOutcome()
        guard !isOver, !board.status.isOver else { return outcome }
        (outcome.result, outcome.flag) = applyBasic(move, to: &board, shield: false)

        if outcome.result.hitMine != nil {
            combo.reset()
            outcome.timeDelta = -Self.minePenaltySeconds
            timeLeft = max(0, timeLeft - Self.minePenaltySeconds)
            dealNext(&outcome)
            return outcome
        }
        outcome.comboTierUp = combo.register(revealed: outcome.result.revealed.count, at: now)
        outcome.points = outcome.result.revealed.count.applyingPercent(100 + combo.bonusPercent)
        if outcome.result.didWin {
            boardsCleared += 1
            outcome.points = outcome.points.addingSaturated(Self.clearPoints)
            outcome.timeDelta = Self.clearBonusSeconds
            timeLeft += Self.clearBonusSeconds
            dealNext(&outcome)
        }
        score = score.addingSaturated(outcome.points)
        return outcome
    }

    private mutating func dealNext(_ outcome: inout ArcadeOutcome) {
        dealt += 1
        board = Self.deal(seed: seed, index: dealt)
        outcome.newBoard = true
    }
}

// MARK: - Dark Mine

/// The whole site is dark. Only tiles near your last few digs are lit, so the
/// numbers you've already uncovered have to be remembered.
public struct DarkMineSession: Codable, Sendable {
    public static let config = BoardConfig(rows: 12, cols: 9, mines: 16)
    public static let lightRadius = 1
    public static let litDigs = 3
    public static let coinReward = 600

    public let id: String
    public private(set) var board: MinesweeperBoard
    public private(set) var recentDigs: [Coord] = []

    public init(id: String, seed: UInt64) {
        self.id = id
        let opening = Coord(row: Self.config.rows / 2, col: Self.config.cols / 2)
        board = PuzzleSolver.generateBoard(config: Self.config, seed: seed, opening: opening, requireNoGuess: true)
        recentDigs = [opening]
    }

    /// Tiles drawn normally; everything else is shown as darkness.
    public var litCells: Set<Coord> {
        if board.status.isOver { return Set(board.allCoords) }
        var lit = Set<Coord>()
        for dig in recentDigs {
            lit.formUnion(board.area(around: dig, radius: Self.lightRadius))
        }
        return lit
    }

    @discardableResult
    public mutating func play(_ move: ArcadeMove) -> ArcadeOutcome {
        var outcome = ArcadeOutcome()
        guard !board.status.isOver else { return outcome }
        (outcome.result, outcome.flag) = applyBasic(move, to: &board, shield: false)
        switch move {
        case .reveal(let c), .chord(let c), .flag(let c):
            recentDigs.removeAll { $0 == c }
            recentDigs.append(c)
            if recentDigs.count > Self.litDigs { recentDigs.removeFirst() }
        case .item:
            break
        }
        return outcome
    }
}

// MARK: - Endless Depth

/// A 9-wide shaft that keeps extending downward as you dig. Mines get denser
/// with depth; three lives (each mine hit costs one). Score is the deepest row
/// reached. New rows are added well before you reach them, and the newest
/// chunk stays sealed from floods, so every number you see is final.
public struct EndlessSession: Codable, Sendable {
    public static let cols = 9
    public static let chunkRows = 12
    public static let startChunks = 3
    public static let lives = 3
    public static let coinsPerRow = 15

    public let id: String
    public private(set) var board: MinesweeperBoard
    public private(set) var livesLeft = EndlessSession.lives
    public private(set) var deepestRow = 0
    public private(set) var combo = ComboTracker()
    private let seed: UInt64
    private var chunks = 0

    public init(id: String, seed: UInt64) {
        self.id = id
        self.seed = seed
        let opening = Coord(row: 1, col: Self.cols / 2)
        var mines = Set<Int>()
        for chunk in 0..<Self.startChunks {
            for i in Self.chunkMines(seed: seed, chunk: chunk) {
                let index = chunk * Self.chunkRows * Self.cols + i
                let c = Coord(row: index / Self.cols, col: index % Self.cols)
                if abs(c.row - opening.row) > 1 || abs(c.col - opening.col) > 1 { mines.insert(index) }
            }
        }
        let config = BoardConfig(exactRows: Self.startChunks * Self.chunkRows, cols: Self.cols, mines: mines.count)
        board = MinesweeperBoard(config: config, seed: seed, mineIndices: mines)
        chunks = Self.startChunks
        board.sealRows(from: (chunks - 1) * Self.chunkRows)
        board.reveal(opening)
        deepestRow = board.allCoords.filter { board[$0].state == .revealed }.map(\.row).max() ?? 0
        extend(toCover: deepestRow)
    }

    public var isOver: Bool { livesLeft == 0 || board.status.isOver }
    public var depth: Int { deepestRow + 1 }
    public var coinReward: Int { depth.multipliedSaturated(Self.coinsPerRow) }

    /// Density rises from 12% to a 24% cap, one point per chunk.
    static func density(chunk: Int) -> Int {
        min(12 + chunk, 24)
    }

    static func chunkMines(seed: UInt64, chunk: Int) -> Set<Int> {
        var rng = SplitMix64(seed: seed ^ (UInt64(chunk + 1) &* 0x9E37_79B9_7F4A_7C15))
        let cells = chunkRows * cols
        let count = cells * density(chunk: chunk) / 100
        var picks = Set<Int>()
        while picks.count < count {
            picks.insert(Int.random(in: 0..<cells, using: &rng))
        }
        return picks
    }

    @discardableResult
    public mutating func play(_ move: ArcadeMove, now: Double) -> ArcadeOutcome {
        var outcome = ArcadeOutcome()
        guard !isOver else { return outcome }
        if case .reveal(let c) = move { extend(toCover: c.row) }
        if case .chord(let c) = move { extend(toCover: c.row + 1) }
        if case .item(_, let c) = move { extend(toCover: c.row + PowerUp.radarRadius) }

        switch move {
        case .item(let item, let c):
            switch item {
            case .dynamite: outcome.result = board.blast(c)
            case .xray: outcome.result = board.defuseMines(in: board.row(c.row))
            case .radar: outcome.radarMines = board.mines(in: board.area(around: c, radius: PowerUp.radarRadius))
            case .magnet: break // coins don't scale in Endless; the shop hides it here
            }
        default:
            (outcome.result, outcome.flag) = applyBasic(move, to: &board, shield: livesLeft > 1)
        }

        if outcome.result.shieldedMine != nil || outcome.result.hitMine != nil {
            livesLeft -= 1
            outcome.lostLife = true
            combo.reset()
        } else {
            outcome.comboTierUp = combo.register(revealed: outcome.result.revealed.count, at: now)
        }
        if let deepest = outcome.result.revealed.map(\.row).max(), deepest > deepestRow {
            outcome.points = deepest - deepestRow
            deepestRow = deepest
        }
        extend(toCover: deepestRow)
        return outcome
    }

    /// Keeps at least two full chunks below `row`: one open, one sealed.
    private mutating func extend(toCover row: Int) {
        while board.rows - row <= 2 * Self.chunkRows {
            board.appendRows(Self.chunkRows, mineIndices: Self.chunkMines(seed: seed, chunk: chunks), sealedRows: Self.chunkRows)
            chunks += 1
        }
    }
}
