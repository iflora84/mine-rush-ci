import Combine
import Foundation
import MineRushCore

enum ArcadeKind: String, CaseIterable, Identifiable {
    case rush, dark, endless

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rush: return "Rush"
        case .dark: return "Dark Mine"
        case .endless: return "Endless Depth"
        }
    }

    var tagline: String {
        switch self {
        case .rush: return "60 seconds. Boards keep coming. Clears add time, mines cost it."
        case .dark: return "Only your last digs are lit. Remember the numbers."
        case .endless: return "Dig down forever. Mines get denser. Three lives. Power-ups allowed."
        }
    }
}

struct ArcadeResult: Equatable {
    let title: String
    let detail: String
    let coins: Int
    let isBest: Bool
}

/// Runs one arcade session at a time. Sessions are core-package structs; this
/// adds the clock, power-up spending, rewards and best scores.
@MainActor
final class ArcadeViewModel: ObservableObject, BoardHost {
    let store: PlayerStore
    let fx = PassthroughSubject<FXEvent, Never>()

    @Published private(set) var kind: ArcadeKind?
    @Published private(set) var rush: RushSession?
    @Published private(set) var dark: DarkMineSession?
    @Published private(set) var endless: EndlessSession?
    @Published private(set) var result: ArcadeResult?
    @Published private(set) var isStarting = false
    @Published private(set) var isPaused = false
    @Published var flagMode = false
    @Published var armedItem: PowerUp?

    private var ticker: Timer?
    private var lastTick = 0.0
    private var generation = 0
    private var storeObserver: AnyCancellable?

    init(store: PlayerStore) {
        self.store = store
        storeObserver = store.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    static var now: Double { Date().timeIntervalSince1970 }

    var board: MinesweeperBoard? {
        switch kind {
        case .rush: return rush?.board
        case .dark: return dark?.board
        case .endless: return endless?.board
        case nil: return nil
        }
    }

    var snapshot: BoardSnapshot? {
        guard let board else { return nil }
        return BoardSnapshot(board: board, lit: kind == .dark ? dark?.litCells : nil)
    }

    let longPressDuration = 0.3

    var isRunning: Bool {
        switch kind {
        case .rush: return rush.map { !$0.isOver } ?? false
        case .dark: return dark.map { !$0.board.status.isOver } ?? false
        case .endless: return endless.map { !$0.isOver } ?? false
        case nil: return false
        }
    }

    var comboCount: Int {
        let combo: ComboTracker?
        switch kind {
        case .rush: combo = rush?.combo
        case .endless: combo = endless?.combo
        default: combo = nil
        }
        guard let combo, combo.isAlive(at: Self.now) else { return 0 }
        return combo.count
    }

    var inventory: Inventory { store.profile.inventory }

    func best(for kind: ArcadeKind) -> String {
        switch kind {
        case .rush: return store.profile.rushBest > 0 ? "Best \(store.profile.rushBest)" : "No score yet"
        case .dark: return store.profile.darkWins > 0 ? "\(store.profile.darkWins) cleared" : "Not cleared yet"
        case .endless: return store.profile.endlessBestDepth > 0 ? "Best \(store.profile.endlessBestDepth)m" : "No dive yet"
        }
    }

    // MARK: Session lifecycle

    func start(_ next: ArcadeKind) {
        stopTicker()
        generation += 1
        let ticket = generation
        kind = next
        result = nil
        rush = nil
        dark = nil
        endless = nil
        armedItem = nil
        isPaused = false
        isStarting = true
        let seed = UInt64.random(in: .min ... .max)
        let id = "\(next.rawValue)-\(seed)"
        Task {
            // Rush and Dark Mine validate their boards, which can take a moment.
            switch next {
            case .rush:
                let session = await Task.detached(priority: .userInitiated) { RushSession(id: id, seed: seed) }.value
                guard ticket == generation else { return }
                rush = session
                startTicker()
            case .dark:
                let session = await Task.detached(priority: .userInitiated) { DarkMineSession(id: id, seed: seed) }.value
                guard ticket == generation else { return }
                dark = session
            case .endless:
                let session = await Task.detached(priority: .userInitiated) { EndlessSession(id: id, seed: seed) }.value
                guard ticket == generation else { return }
                endless = session
            }
            isStarting = false
        }
    }

    /// Leaves to the mode picker. A dive in progress is banked; Rush and Dark Mine are forfeited.
    func leave() {
        if kind == .endless, isRunning { finish() }
        stopTicker()
        generation += 1
        kind = nil
        rush = nil
        dark = nil
        endless = nil
        result = nil
        isStarting = false
    }

    /// Endless only: stop diving and collect.
    func cashOut() {
        guard kind == .endless, isRunning else { return }
        finish()
    }

    func pause() {
        guard isRunning, !isPaused else { return }
        isPaused = true
        stopTicker()
    }

    func togglePause() {
        if isPaused {
            isPaused = false
            if kind == .rush { startTicker() }
        } else {
            pause()
        }
    }

    // MARK: Input

    func tap(_ c: Coord) {
        guard let board, canPlay else { return }
        if let item = armedItem {
            armedItem = nil
            play(.item(item, c), spending: item)
            return
        }
        let cell = board[c]
        if cell.state == .revealed {
            play(.chord(c))
        } else if flagMode {
            play(.flag(c))
        } else if cell.state == .hidden {
            play(.reveal(c))
        }
    }

    func longPress(_ c: Coord) {
        guard let board, canPlay else { return }
        if armedItem != nil { return tap(c) }
        if flagMode, board[c].state == .hidden {
            play(.reveal(c))
        } else {
            play(.flag(c))
        }
    }

    /// Endless only; Magnet does nothing there, so it's not offered.
    func useItem(_ item: PowerUp) {
        guard kind == .endless, canPlay, item != .magnet, inventory[item] > 0 else { return }
        armedItem = armedItem == item ? nil : item
    }

    private var canPlay: Bool {
        !isPaused && !isStarting && result == nil && isRunning
    }

    private func play(_ move: ArcadeMove, spending item: PowerUp? = nil) {
        let now = Self.now
        var outcome = ArcadeOutcome()
        switch kind {
        case .rush:
            guard var session = rush else { return }
            outcome = session.play(move, now: now)
            rush = session
            if outcome.timeDelta != 0 { fx.send(FXEvent(.timeBonus(outcome.timeDelta))) }
            if rush?.isOver == true { finish() }
        case .dark:
            guard var session = dark else { return }
            outcome = session.play(move)
            dark = session
            if session.board.status.isOver { finish() }
        case .endless:
            guard var session = endless else { return }
            if let item {
                guard store.mutate(save: false, { $0.inventory.use(item) }) else { return }
            }
            outcome = session.play(move, now: now)
            endless = session
            if case .item(let used, let c) = move {
                switch used {
                case .dynamite: fx.send(FXEvent(.blast(c)))
                case .radar: fx.send(FXEvent(.radar(center: c, mines: outcome.radarMines)))
                case .xray: fx.send(FXEvent(.xray(row: c.row)))
                case .magnet: break
                }
            }
            if outcome.lostLife, !session.isOver { fx.send(FXEvent(.lifeLost(session.livesLeft))) }
            if session.isOver { finish() }
        case nil:
            return
        }
        if let tier = outcome.comboTierUp {
            fx.send(FXEvent(.combo(tier: tier, count: comboCount)))
        }
        if outcome.result.revealed.count >= 25 {
            fx.send(FXEvent(.bigOpen(outcome.result.revealed.count)))
        }
    }

    private func finish() {
        stopTicker()
        armedItem = nil
        switch kind {
        case .rush:
            guard let session = rush else { return }
            let coins = session.coinReward
            let best = store.mutate { profile -> Bool in
                profile.bankModeReward(id: session.id, coins: coins)
                return profile.recordRush(score: session.score)
            }
            result = ArcadeResult(title: "Time's up!", detail: "Score \(session.score) · \(session.boardsCleared) boards cleared",
                                  coins: coins, isBest: best)
        case .dark:
            guard let session = dark else { return }
            if session.board.status == .won {
                let coins = DarkMineSession.coinReward
                store.mutate { profile in
                    profile.bankModeReward(id: session.id, coins: coins)
                    profile.recordDarkWin()
                }
                result = ArcadeResult(title: "Out of the dark!", detail: "Cleared from memory", coins: coins, isBest: false)
            } else {
                result = ArcadeResult(title: "Lost in the dark", detail: "Try again: watch the numbers before the light moves on.",
                                      coins: 0, isBest: false)
            }
        case .endless:
            guard let session = endless else { return }
            let coins = session.coinReward
            let best = store.mutate { profile -> Bool in
                profile.bankModeReward(id: session.id, coins: coins)
                return profile.recordEndless(depth: session.depth)
            }
            result = ArcadeResult(title: session.livesLeft == 0 ? "Out of lives!" : "Cashed out",
                                  detail: "Reached \(session.depth)m deep", coins: coins, isBest: best)
        case nil:
            return
        }
        if result?.isBest == true { fx.send(FXEvent(.newBest)) }
    }

    // MARK: Rush clock

    private func startTicker() {
        stopTicker()
        lastTick = Self.now
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func tick() {
        let now = Self.now
        let dt = now - lastTick
        lastTick = now
        guard var session = rush, !session.isOver else { return }
        session.tick(dt)
        rush = session
        if session.isOver { finish() }
    }
}
