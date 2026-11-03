import Combine
import Foundation
import MineRushCore
import UIKit

enum PlayMode: String, CaseIterable, Identifiable {
    case expedition, classic, daily

    var id: String { rawValue }
    var title: String {
        switch self {
        case .expedition: return "Expedition"
        case .classic: return "Classic"
        case .daily: return "Daily"
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
final class GameViewModel: ObservableObject {
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

    @Published private var classicBoard: MinesweeperBoard
    @Published private var dailyBoard: MinesweeperBoard?
    private var dailyOriginal: MinesweeperBoard?
    let todayKey: String

    private var clock = GameClock()
    private var ticker: Timer?
    private var storeObserver: AnyCancellable?
    private var generation = 0
    private var started = false
    private let haptics = UIImpactFeedbackGenerator(style: .light)

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
        }
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

    func isTreasure(_ c: Coord) -> Bool {
        guard let run, run.treasureCells.contains(c) else { return false }
        return run.board[c].state == .revealed
    }

    var dailyDoneToday: Bool {
        store.profile.daily.lastCompletedDay == todayKey
    }

    // MARK: Input

    func tap(_ c: Coord) {
        guard let board, canPlay else { return }
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
            store.mutate { $0.startExpedition(in: zone, board: board) }
            isGenerating = false
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
        switch mode {
        case .expedition:
            if let run = store.profile.activeRun {
                store.selectedZone = run.zone
            } else {
                startSite(in: store.selectedZone)
            }
        case .daily:
            loadDaily()
        case .classic:
            break
        }
    }

    // MARK: Moves

    private func perform(_ move: ExpeditionRun.Move) {
        let result: RevealResult
        let flag: FlagChange?
        switch mode {
        case .expedition:
            guard let outcome = store.mutate(save: false, { $0.playExpedition(move) }) else { return }
            result = outcome.result
            flag = outcome.flag
            scannedCell = outcome.scanned
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
        }
        react(to: result, flag: flag)
    }

    private static func apply(_ move: ExpeditionRun.Move, to board: inout MinesweeperBoard) -> (RevealResult, FlagChange?) {
        switch move {
        case .reveal(let c): return (board.reveal(c), nil)
        case .chord(let c): return (board.chord(c), nil)
        case .flag(let c): return (.empty, board.toggleFlag(c))
        case .scan: return (.empty, nil)
        }
    }

    private func react(to result: RevealResult, flag: FlagChange?) {
        if flag != nil { haptics.impactOccurred() }
        guard let board else { return }
        if board.status == .playing, !clock.isRunning { startClock() }

        if result.hitMine != nil {
            stopClock()
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            if mode == .expedition { store.save() }
        } else if result.didWin {
            stopClock()
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            settleWin(board)
        } else if !result.revealed.isEmpty {
            haptics.impactOccurred(intensity: 0.5)
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
