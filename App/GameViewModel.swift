import Combine
import Foundation
import MineRushCore

enum PlayMode: String, CaseIterable, Identifiable {
    case expedition, classic, daily, arcade

    var id: String { rawValue }
    var title: String {
        switch self {
        case .expedition: return "Expedition"
        case .classic: return "Classic"
        case .daily: return "Daily"
        case .arcade: return "Arcade"
        }
    }
}

enum Difficulty: String, CaseIterable, Identifiable {
    case beginner, intermediate, expert

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var config: BoardConfig {
        switch self {
        case .beginner: return .beginner
        case .intermediate: return .intermediate
        case .expert: return .expert
        }
    }
}

struct RewardPop: Identifiable, Equatable {
    let id = UUID()
    let text: String
}

/// Drives the board for all three modes. The Expedition board lives in the
/// player's profile (so it's saved and paid through the ledger); Classic and
/// Daily boards are local and never touch the economy.
@MainActor
final class GameViewModel: ObservableObject, BoardHost {
    let store: PlayerStore

    @Published var mode: PlayMode = .expedition {
        didSet { if mode != oldValue { enterMode() } }
    }
    @Published var difficulty: Difficulty = .beginner {
        didSet { if difficulty != oldValue { newClassicBoard() } }
    }
    @Published var flagMode = false
    @Published private(set) var isPaused = false
    @Published private(set) var elapsedSeconds = 0
    @Published private(set) var isGenerating = false
    @Published private(set) var scannedCell: Coord?
    @Published private(set) var pop: RewardPop?
    @Published private(set) var message: String?
    /// A power-up waiting for the player to pick its target tile.
    @Published var armedItem: PowerUp?
    /// Effects for the full-screen overlay and the board scene.
    let fx = PassthroughSubject<FXEvent, Never>()

    @Published private var classicBoard: MinesweeperBoard
    @Published private var dailyBoard: MinesweeperBoard?
    private var dailyOriginal: MinesweeperBoard?
    let todayKey: String

    private var clock = GameClock()
    private var ticker: Timer?
    private var storeObserver: AnyCancellable?
    private var generation = 0
    private var started = false

    init(store: PlayerStore) {
        self.store = store
        classicBoard = MinesweeperBoard(config: Difficulty.beginner.config, seed: .random(in: .min ... .max))
        todayKey = DailyChallenge.dayKey(for: Date())
        storeObserver = store.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    /// Kicks off the first board. Called from a view task, not init, because init
    /// runs during a SwiftUI update where publishing changes isn't allowed.
    func start() {
        guard !started else { return }
        started = true
        enterMode()
    }

    // MARK: State for the views

    var board: MinesweeperBoard? {
        switch mode {
        case .expedition: return store.profile.activeRun?.board
        case .classic: return classicBoard
        case .daily: return dailyBoard
        case .arcade: return nil // ArcadeViewModel owns arcade boards
        }
    }

    var snapshot: BoardSnapshot? {
        guard let board else { return nil }
        return BoardSnapshot(
            board: board,
            treasures: run?.treasureCells.filter { board[$0].state == .revealed } ?? [],
            scanned: scannedCell,
            dimSatisfied: smartFlagsLevel > 0
        )
    }

    var run: ExpeditionRun? {
        mode == .expedition ? store.profile.activeRun : nil
    }

    var isRunInProgress: Bool {
        guard let run = store.profile.activeRun else { return false }
        return !run.board.status.isOver
    }

    /// Smart Flags is an Expedition upgrade; Classic and Daily stay unassisted.
    var smartFlagsLevel: Int {
        mode == .expedition ? store.profile.upgrades[.smartFlags] : 0
    }

    var longPressDuration: Double {
        smartFlagsLevel >= 2 ? 0.18 : 0.3
    }

    var dailyDoneToday: Bool {
        store.profile.daily.lastCompletedDay == todayKey
    }

    /// Wall-clock seconds, saved with the run so Magnet survives a relaunch.
    static var now: Double { Date().timeIntervalSince1970 }

    var inventory: Inventory { store.profile.inventory }

    /// Live combo count (0 once the window lapses). Redrawn by the clock ticker.
    var comboCount: Int {
        guard let run, run.combo.isAlive(at: Self.now) else { return 0 }
        return run.combo.count
    }

    var magnetSecondsLeft: Int {
        guard let until = run?.magnetUntil, !(run?.board.status.isOver ?? true) else { return 0 }
        return max(0, Int((until - Self.now).rounded(.up)))
    }

    var boss: BossDefinition? {
        guard let run, run.isBoss else { return nil }
        return BossCatalog.boss(for: run.zone)
    }

    // MARK: Input

    func tap(_ c: Coord) {
        guard let board, canPlay else { return }
        if let item = armedItem {
            armedItem = nil
            perform(.item(item, c))
            return
        }
        let cell = board[c]
        if cell.state == .revealed {
            perform(.chord(c))
        } else if flagMode {
            perform(.flag(c))
        } else if cell.state == .hidden {
            perform(.reveal(c))
        }
    }

    func longPress(_ c: Coord) {
        guard let board, canPlay else { return }
        if armedItem != nil {
            tap(c)
            return
        }
        if flagMode, board[c].state == .hidden {
            perform(.reveal(c))
        } else {
            perform(.flag(c))
        }
    }

    func scan() {
        guard mode == .expedition, canPlay else { return }
        perform(.scan)
        if scannedCell == nil { message = "No tile is certain yet. Read the numbers." }
    }

    /// Magnet fires at once; the others arm and wait for a tile tap.
    func useItem(_ item: PowerUp) {
        guard mode == .expedition, canPlay else { return }
        guard inventory[item] > 0 else {
            message = "Out of \(item.name). Find more by clearing sites or buy them in Upgrades."
            return
        }
        if item.needsTarget {
            armedItem = armedItem == item ? nil : item
        } else {
            perform(.item(item, Coord(row: 0, col: 0)))
        }
    }

    private var canPlay: Bool {
        !isPaused && !isGenerating && board?.status.isOver == false
    }

    // MARK: Boards

    /// Expedition: a fresh site (abandoning an unfinished one breaks the streak).
    /// Classic: a new random board. Daily: replay today's board.
    func restart() {
        switch mode {
        case .expedition: startSite(in: store.selectedZone)
        case .classic: newClassicBoard()
        case .daily:
            dailyBoard = dailyOriginal
            resetSession()
        case .arcade:
            break
        }
    }

    func startSite(in zone: ZoneID) {
        store.selectedZone = zone
        let spec = store.profile.nextSiteSpec(in: zone)
        let seed = UInt64.random(in: .min ... .max)
        generation += 1
        let ticket = generation
        isGenerating = true
        resetSession()
        Task {
            let board = await Task.detached(priority: .userInitiated) {
                PuzzleSolver.generateBoard(config: spec.config, seed: seed, opening: spec.opening, requireNoGuess: true)
            }.value
            guard ticket == generation else { return }
            let run = store.mutate { $0.startExpedition(in: zone, board: board) }
            isGenerating = false
            if run.isBoss { fx.send(FXEvent(.bossIntro(BossDefinitionRef(BossCatalog.boss(for: zone))))) }
        }
    }

    private func newClassicBoard() {
        classicBoard = MinesweeperBoard(config: difficulty.config, seed: .random(in: .min ... .max))
        resetSession()
    }

    private func loadDaily() {
        guard dailyOriginal == nil else { return }
        generation += 1
        let ticket = generation
        let day = todayKey
        isGenerating = true
        Task {
            let board = await Task.detached(priority: .userInitiated) {
                DailyChallenge.board(forDay: day)
            }.value
            guard ticket == generation else { return }
            dailyOriginal = board
            dailyBoard = board
            isGenerating = false
        }
    }

    private func enterMode() {
        generation += 1 // drop any board still generating for the previous mode
        isGenerating = false
        resetSession()
        armedItem = nil
        switch mode {
        case .expedition:
            if let run = store.profile.activeRun {
                store.selectedZone = run.zone
            } else {
                startSite(in: store.selectedZone)
            }
        case .daily:
            loadDaily()
        case .classic, .arcade:
            break
        }
    }

    // MARK: Moves

    private func perform(_ move: ExpeditionRun.Move) {
        let result: RevealResult
        let flag: FlagChange?
        switch mode {
        case .expedition:
            let now = Self.now
            guard let outcome = store.mutate(save: false, { $0.playExpedition(move, now: now) }) else { return }
            result = outcome.result
            flag = outcome.flag
            scannedCell = outcome.scanned
            emitEffects(for: outcome, move: move)
            if outcome.tileCoins > 0 { showPop("+\(outcome.tileCoins.compact)") }
            if !outcome.treasures.isEmpty { message = "Treasure found!" }
            if result.shieldedMine != nil { message = "Your helmet blocked a blast!" }
        case .classic:
            let applied = Self.apply(move, to: &classicBoard)
            result = applied.0
            flag = applied.1
        case .daily:
            guard var board = dailyBoard else { return }
            let applied = Self.apply(move, to: &board)
            dailyBoard = board
            result = applied.0
            flag = applied.1
        case .arcade:
            return
        }
        react(to: result, flag: flag)
    }

    private func emitEffects(for outcome: ExpeditionRun.MoveOutcome, move: ExpeditionRun.Move) {
        if case .item(let item, let c) = move, outcome.usedItem != nil {
            switch item {
            case .dynamite: fx.send(FXEvent(.blast(c)))
            case .radar: fx.send(FXEvent(.radar(center: c, mines: outcome.radarMines)))
            case .xray: fx.send(FXEvent(.xray(row: c.row)))
            case .magnet: fx.send(FXEvent(.magnet))
            }
        }
        if let tier = outcome.comboTierUp {
            fx.send(FXEvent(.combo(tier: tier, count: run?.combo.count ?? 0)))
        }
        if outcome.result.revealed.count >= 25 {
            fx.send(FXEvent(.bigOpen(outcome.result.revealed.count)))
        }
        if outcome.result.didWin, let boss {
            fx.send(FXEvent(.bossDefeated(boss.name)))
        }
        if !outcome.drops.isEmpty {
            fx.send(FXEvent(.drops(outcome.drops)))
        }
    }

    private static func apply(_ move: ExpeditionRun.Move, to board: inout MinesweeperBoard) -> (RevealResult, FlagChange?) {
        switch move {
        case .reveal(let c): return (board.reveal(c), nil)
        case .chord(let c): return (board.chord(c), nil)
        case .flag(let c): return (.empty, board.toggleFlag(c))
        case .scan, .item: return (.empty, nil) // Expedition-only tools
        }
    }

    /// Sound, haptics and animation come from BoardScene diffing the board;
    /// this only handles the clock and the economy side of a move.
    private func react(to result: RevealResult, flag: FlagChange?) {
        guard let board else { return }
        if board.status == .playing, !clock.isRunning { startClock() }

        if result.hitMine != nil {
            stopClock()
            if mode == .expedition { store.save() }
        } else if result.didWin {
            stopClock()
            settleWin(board)
        }
    }

    private func settleWin(_ board: MinesweeperBoard) {
        switch mode {
        case .expedition:
            store.save()
            if let run { message = "Site cleared! +\(run.coinsThisRun.compact) coins" }
        case .classic:
            let seconds = elapsedSeconds
            let best = store.mutate { $0.recordClassicWin(config: board.config, seconds: seconds) }
            message = best ? "New best time: \(durationText(seconds))!" : "Cleared in \(durationText(seconds))"
        case .daily:
            let seconds = elapsedSeconds
            let firstToday = store.mutate { $0.recordDailyWin(day: todayKey, seconds: seconds) }
            message = firstToday
                ? "Daily cleared! Streak: \(store.profile.daily.streak)"
                : "Cleared again in \(durationText(seconds))"
        case .arcade:
            break
        }
    }

    // MARK: Pause & clock

    func togglePause() {
        isPaused ? resume() : pause()
    }

    func pause() {
        guard board?.status == .playing, !isPaused else { return }
        isPaused = true
        stopClock()
    }

    private func resume() {
        isPaused = false
        if board?.status == .playing { startClock() }
    }

    func clearMessage() {
        message = nil
    }

    private func showPop(_ text: String) {
        let next = RewardPop(text: text)
        pop = next
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            if pop == next { pop = nil }
        }
    }

    private func resetSession() {
        stopClock()
        clock = GameClock()
        elapsedSeconds = 0
        isPaused = false
        scannedCell = nil
        message = nil
    }

    private func startClock() {
        clock.start(at: Date().timeIntervalSinceReferenceDate)
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func stopClock() {
        clock.pause(at: Date().timeIntervalSinceReferenceDate)
        ticker?.invalidate()
        ticker = nil
        tick()
    }

    private func tick() {
        elapsedSeconds = Int(clock.elapsed(at: Date().timeIntervalSinceReferenceDate))
    }
}
