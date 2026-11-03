/// Deterministic SplitMix64 generator. Swift's SystemRandomNumberGenerator
/// can't be seeded, and daily puzzles plus tests need reproducible boards.
public struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

public struct Coord: Hashable, Codable, Sendable {
    public let row: Int
    public let col: Int

    public init(row: Int, col: Int) {
        self.row = row
        self.col = col
    }
}

public struct BoardConfig: Hashable, Codable, Sendable {
    public let rows: Int
    public let cols: Int
    public let mines: Int

    /// Mines are clamped so the 3x3 first-click safe zone always fits.
    public init(rows: Int, cols: Int, mines: Int) {
        self.rows = max(rows, 3)
        self.cols = max(cols, 3)
        self.mines = min(max(mines, 1), self.rows * self.cols - 9)
    }

    /// Hand-authored layouts (tutorial, tests) skip the clamp; the mine count is whatever was placed.
    init(exactRows rows: Int, cols: Int, mines: Int) {
        self.rows = rows
        self.cols = cols
        self.mines = mines
    }

    public var cellCount: Int { rows * cols }
    public var safeCellCount: Int { cellCount - mines }

    public static let beginner = BoardConfig(rows: 9, cols: 9, mines: 10)
    public static let intermediate = BoardConfig(rows: 16, cols: 16, mines: 40)
    public static let expert = BoardConfig(rows: 30, cols: 16, mines: 99)
}

public enum CellState: String, Codable, Sendable {
    case hidden, flagged, revealed
}

public struct Cell: Hashable, Codable, Sendable {
    public var isMine = false
    public var adjacentMines = 0
    public var state = CellState.hidden
    /// A mine absorbed by a shield (Safety Helmet). Shown flagged and locked.
    public var isDefused = false
}

public enum GameStatus: Hashable, Codable, Sendable {
    /// Mines are not placed until the first reveal.
    case ready
    case playing
    case won
    case lost(triggered: Coord)

    public var isOver: Bool {
        switch self {
        case .won, .lost: return true
        case .ready, .playing: return false
        }
    }
}

public struct RevealResult: Equatable, Sendable {
    /// Safe cells that went from hidden to revealed during this move, in reveal order.
    public var revealed: [Coord] = []
    public var hitMine: Coord?
    /// A mine that would have ended the game but was absorbed by a shield.
    public var shieldedMine: Coord?
    public var didWin = false

    public static let empty = RevealResult()
}

public enum FlagChange: Equatable, Sendable {
    case placed, removed
}

public enum MineGenerator {
    /// Picks mine indices with every cell in the 3x3 block around `firstClick` kept safe.
    /// `accept` lets a puzzle validator reject layouts (e.g. ones that need a guess);
    /// rejected layouts are retried with a derived seed so results stay deterministic.
    public static func layout(
        config: BoardConfig,
        seed: UInt64,
        firstClick: Coord,
        maxAttempts: Int = 1,
        accept: ((Set<Int>) -> Bool)? = nil
    ) -> Set<Int> {
        var rng = SplitMix64(seed: seed)
        let excluded = Set(
            neighborhood(of: firstClick, rows: config.rows, cols: config.cols)
                .map { $0.row * config.cols + $0.col }
        )
        let candidates = (0..<config.cellCount).filter { !excluded.contains($0) }

        var best = Set<Int>()
        for _ in 0..<max(maxAttempts, 1) {
            var pool = candidates
            // Partial Fisher-Yates: the first `mines` slots are the picks.
            for i in 0..<config.mines {
                let j = Int.random(in: i..<pool.count, using: &rng)
                pool.swapAt(i, j)
            }
            best = Set(pool.prefix(config.mines))
            if accept?(best) ?? true { break }
        }
        return best
    }

    /// The cell itself plus its in-bounds neighbors.
    static func neighborhood(of c: Coord, rows: Int, cols: Int) -> [Coord] {
        var result: [Coord] = []
        for dr in -1...1 {
            for dc in -1...1 {
                let r = c.row + dr, col = c.col + dc
                if r >= 0, r < rows, col >= 0, col < cols {
                    result.append(Coord(row: r, col: col))
                }
            }
        }
        return result
    }
}

public struct MinesweeperBoard: Codable, Sendable {
    public let config: BoardConfig
    public let seed: UInt64
    public private(set) var cells: [Cell]
    public private(set) var status: GameStatus = .ready
    public private(set) var revealedSafeCount = 0
    public private(set) var flagCount = 0

    public init(config: BoardConfig, seed: UInt64) {
        self.config = config
        self.seed = seed
        cells = Array(repeating: Cell(), count: config.cellCount)
    }

    /// Builds a board with a fixed mine layout, already in play. Used for the
    /// tutorial and tests, where the first click must not reshuffle anything.
    public init(rows: Int, cols: Int, mines: Set<Coord>) {
        let inBounds = mines.filter { $0.row >= 0 && $0.row < rows && $0.col >= 0 && $0.col < cols }
        self.init(config: BoardConfig(exactRows: rows, cols: cols, mines: inBounds.count), seed: 0)
        placeMines(Set(inBounds.map { $0.row * cols + $0.col }))
    }

    /// A board whose mines were chosen up front (validated puzzles, daily seeds).
    public init(config: BoardConfig, seed: UInt64, mineIndices: Set<Int>) {
        self.init(config: config, seed: seed)
        placeMines(mineIndices.filter { $0 >= 0 && $0 < config.cellCount })
    }

    public var rows: Int { config.rows }
    public var cols: Int { config.cols }
    public var minesRemaining: Int { config.mines - flagCount }

    public subscript(_ c: Coord) -> Cell {
        cells[index(c)]
    }

    public func contains(_ c: Coord) -> Bool {
        c.row >= 0 && c.row < rows && c.col >= 0 && c.col < cols
    }

    public func neighbors(of c: Coord) -> [Coord] {
        MineGenerator.neighborhood(of: c, rows: rows, cols: cols).filter { $0 != c }
    }

    public var allCoords: [Coord] {
        (0..<config.cellCount).map(coord)
    }

    // MARK: Moves

    @discardableResult
    public mutating func reveal(_ c: Coord, shield: Bool = false) -> RevealResult {
        guard contains(c), !status.isOver, self[c].state == .hidden else { return .empty }
        if status == .ready {
            placeMines(MineGenerator.layout(config: config, seed: seed, firstClick: c))
        }

        var result = RevealResult()
        if self[c].isMine {
            if shield {
                defuse(c)
                result.shieldedMine = c
            } else {
                cells[index(c)].state = .revealed
                status = .lost(triggered: c)
                result.hitMine = c
            }
            return result
        }
        floodReveal(from: c, into: &result)
        checkWin(&result)
        return result
    }

    /// Reveals all unflagged neighbors of a revealed number whose flag count matches it.
    /// A wrong flag makes this lose, exactly like the classic rule.
    @discardableResult
    public mutating func chord(_ c: Coord, shield: Bool = false) -> RevealResult {
        guard contains(c), status == .playing else { return .empty }
        let cell = self[c]
        guard cell.state == .revealed, cell.adjacentMines > 0 else { return .empty }
        let around = neighbors(of: c)
        let flags = around.filter { self[$0].state == .flagged }.count
        guard flags == cell.adjacentMines else { return .empty }

        var result = RevealResult()
        for n in around where self[n].state == .hidden {
            if self[n].isMine, shield, result.shieldedMine == nil {
                defuse(n)
                result.shieldedMine = n
                continue
            }
            if self[n].isMine {
                cells[index(n)].state = .revealed
                status = .lost(triggered: n)
                result.hitMine = n
                return result
            }
            floodReveal(from: n, into: &result)
        }
        checkWin(&result)
        return result
    }

    @discardableResult
    public mutating func toggleFlag(_ c: Coord) -> FlagChange? {
        guard contains(c), !status.isOver, !self[c].isDefused else { return nil }
        let i = index(c)
        switch cells[i].state {
        case .hidden:
            cells[i].state = .flagged
            flagCount += 1
            return .placed
        case .flagged:
            cells[i].state = .hidden
            flagCount -= 1
            return .removed
        case .revealed:
            return nil
        }
    }

    /// Player-placed flags that sit on a mine (defused mines don't count).
    public var correctFlagCount: Int {
        cells.filter { $0.state == .flagged && $0.isMine && !$0.isDefused }.count
    }

    /// Flags that sit on a safe cell. Only meaningful to show once the game is over.
    public var wrongFlags: [Coord] {
        allCoords.filter { self[$0].state == .flagged && !self[$0].isMine }
    }

    public var mineCoords: [Coord] {
        allCoords.filter { self[$0].isMine }
    }

    // MARK: Internals

    func index(_ c: Coord) -> Int { c.row * cols + c.col }
    func coord(_ i: Int) -> Coord { Coord(row: i / cols, col: i % cols) }

    private mutating func defuse(_ c: Coord) {
        let i = index(c)
        cells[i].state = .flagged
        cells[i].isDefused = true
        flagCount += 1
    }

    private mutating func placeMines(_ mineIndices: Set<Int>) {
        for i in mineIndices { cells[i].isMine = true }
        for i in cells.indices where !cells[i].isMine {
            cells[i].adjacentMines = neighbors(of: coord(i)).filter { cells[index($0)].isMine }.count
        }
        status = .playing
    }

    /// Iterative flood fill so huge empty regions can't overflow the stack.
    /// Flagged cells are never opened by a flood.
    private mutating func floodReveal(from start: Coord, into result: inout RevealResult) {
        var queue = [start]
        var head = 0
        while head < queue.count {
            let c = queue[head]
            head += 1
            let i = index(c)
            guard cells[i].state == .hidden, !cells[i].isMine else { continue }
            cells[i].state = .revealed
            revealedSafeCount += 1
            result.revealed.append(c)
            if cells[i].adjacentMines == 0 {
                queue.append(contentsOf: neighbors(of: c).filter { cells[index($0)].state == .hidden })
            }
        }
    }

    private mutating func checkWin(_ result: inout RevealResult) {
        guard revealedSafeCount == config.safeCellCount else { return }
        status = .won
        result.didWin = true
    }
}

/// Pausable game timer driven by caller-supplied timestamps (seconds), so it
/// stays testable and survives backgrounding without a running Timer.
public struct GameClock: Codable, Sendable {
    private var accumulated: Double = 0
    private var runningSince: Double?

    public init() {}

    public var isRunning: Bool { runningSince != nil }

    public mutating func start(at now: Double) {
        if runningSince == nil { runningSince = now }
    }

    public mutating func pause(at now: Double) {
        guard let since = runningSince else { return }
        accumulated += max(0, now - since)
        runningSince = nil
    }

    public func elapsed(at now: Double) -> Double {
        accumulated + (runningSince.map { max(0, now - $0) } ?? 0)
    }
}
