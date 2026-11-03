import Foundation
import XCTest
@testable import MineRushCore

final class PowerUpTests: XCTestCase {
    private func c(_ row: Int, _ col: Int) -> Coord { Coord(row: row, col: col) }

    //   . . . .
    //   . M . .
    //   . . . .
    //   . . . M
    private func board() -> MinesweeperBoard {
        MinesweeperBoard(rows: 4, cols: 4, mines: [c(1, 1), c(3, 3)])
    }

    // MARK: Engine

    func testDynamiteDefusesMinesAndOpensTheRest() {
        var b = board()
        let result = b.blast(c(1, 1))
        XCTAssertNil(result.hitMine)
        XCTAssertEqual(result.defused, [c(1, 1)])
        XCTAssertTrue(b[c(1, 1)].isDefused)
        for p in b.area(around: c(1, 1), radius: 1) where p != c(1, 1) {
            XCTAssertEqual(b[p].state, .revealed, "\(p)")
        }
        XCTAssertEqual(b.flagCount, 1)
        XCTAssertEqual(b.status, .playing)
    }

    func testDynamiteClearsWrongFlagsAndKeepsFlagCountRight() {
        var b = board()
        b.toggleFlag(c(0, 0)) // wrong
        b.toggleFlag(c(1, 1)) // right
        b.blast(c(1, 1))
        XCTAssertEqual(b[c(0, 0)].state, .revealed)
        XCTAssertTrue(b[c(1, 1)].isDefused)
        XCTAssertEqual(b.flagCount, 1)
        XCTAssertEqual(b.minesRemaining, 1)
    }

    func testXRayFlagsOnlyTheChosenRow() {
        var b = board()
        let result = b.defuseMines(in: b.row(1))
        XCTAssertEqual(result.defused, [c(1, 1)])
        XCTAssertFalse(b[c(3, 3)].isDefused)
        XCTAssertNil(b.toggleFlag(c(1, 1)), "x-rayed mines stay locked")
    }

    func testRadarReadsMinesWithoutChangingBoard() {
        let b = board()
        XCTAssertEqual(Set(b.mines(in: b.area(around: c(2, 2), radius: 2))), [c(1, 1), c(3, 3)])
        XCTAssertEqual(b.mines(in: b.area(around: c(0, 3), radius: 1)), [])
        XCTAssertEqual(b.flagCount, 0)
    }

    func testAppendRowsFixesBorderNumbersAndSeals() {
        var b = MinesweeperBoard(rows: 3, cols: 3, mines: [])
        XCTAssertEqual(b[c(2, 1)].adjacentMines, 0)
        b.appendRows(2, mineIndices: [1], sealedRows: 1) // mine at (3, 1)
        XCTAssertEqual(b.rows, 5)
        XCTAssertEqual(b.config.mines, 1)
        for col in 0..<3 { XCTAssertEqual(b[c(2, col)].adjacentMines, 1) }
        XCTAssertTrue(b[c(3, 1)].isMine)
        XCTAssertEqual(b.floodLimitRow, 4)
    }

    func testFloodStopsAtSealedRows() {
        var b = MinesweeperBoard(rows: 6, cols: 3, mines: [c(5, 2)])
        b.sealRows(from: 3)
        let result = b.reveal(c(0, 0))
        XCTAssertEqual(result.revealed.count, 9)
        XCTAssertTrue(result.revealed.allSatisfy { $0.row < 3 })
    }

    // MARK: Combo

    func testComboTiersAndTimeout() {
        var combo = ComboTracker()
        XCTAssertNil(combo.register(revealed: 0, at: 0))
        XCTAssertEqual(combo.count, 0)
        for t in 0..<4 { XCTAssertNil(combo.register(revealed: 1, at: Double(t))) }
        XCTAssertEqual(combo.register(revealed: 1, at: 4), 1)
        XCTAssertEqual(combo.bonusPercent, 50)
        XCTAssertTrue(combo.isAlive(at: 6.9))
        XCTAssertNil(combo.register(revealed: 3, at: 10), "too slow: combo restarts")
        XCTAssertEqual(combo.count, 1)
        XCTAssertEqual(combo.tier, 0)
    }

    // MARK: Expedition items

    private func run(_ board: MinesweeperBoard, boss: Bool = false) -> ExpeditionRun {
        ExpeditionRun(id: boss ? "boss" : "r", zone: .sunnyQuarry, board: board, scannerCharges: 0, helmetCharges: 0,
                      treasureCount: 0, isBoss: boss)
    }

    func testItemsAreSpentOnlyWhenOwned() {
        var p = PlayerProfile()
        XCTAssertEqual(p.inventory[.dynamite], 2, "new players start with two of each")
        var r = run(board())
        let used = p.play(.item(.dynamite, c(1, 1)), in: &r)
        XCTAssertEqual(used.usedItem, .dynamite)
        XCTAssertEqual(used.result.defused, [c(1, 1)])
        XCTAssertEqual(p.inventory[.dynamite], 1)
        XCTAssertGreaterThan(used.tileCoins, 0)

        p.inventory = Inventory()
        let none = p.play(.item(.xray, c(3, 0)), in: &r)
        XCTAssertNil(none.usedItem)
        XCTAssertFalse(r.board[c(3, 3)].isDefused)
    }

    func testMagnetDoublesCoinsForThirtySeconds() {
        var p = PlayerProfile()
        var r = run(board())
        p.play(.item(.magnet, c(0, 0)), in: &r, now: 0)
        XCTAssertEqual(p.play(.reveal(c(0, 0)), in: &r, now: 1).tileCoins, 20)
        XCTAssertEqual(p.play(.reveal(c(0, 1)), in: &r, now: 40).tileCoins, 10)
    }

    func testComboBoostsExpeditionCoins() {
        var p = PlayerProfile()
        var r = run(board())
        let singles = [c(0, 0), c(0, 1), c(0, 2), c(1, 0), c(2, 0)]
        var last = ExpeditionRun.MoveOutcome()
        for (t, cell) in singles.enumerated() {
            last = p.play(.reveal(cell), in: &r, now: Double(t))
        }
        XCTAssertEqual(last.comboTierUp, 1)
        XCTAssertEqual(last.bonusPercent, 50)
        XCTAssertEqual(last.tileCoins, 15)
        XCTAssertEqual(p.play(.reveal(c(2, 2)), in: &r, now: 100).bonusPercent, 0, "combo expired")
    }

    func testRadarAndMagnetDoNotCountAsDigging() {
        var p = PlayerProfile()
        var r = run(board())
        let radar = p.play(.item(.radar, c(2, 2)), in: &r)
        XCTAssertEqual(Set(radar.radarMines), [c(1, 1), c(3, 3)])
        XCTAssertEqual(radar.tileCoins, 0)
        XCTAssertEqual(r.combo.count, 0)
        XCTAssertEqual(p.inventory[.radar], 1)
    }

    func testClearsDropItemsAndBossesPayFiveTimes() {
        let tiny = MinesweeperBoard(rows: 3, cols: 4, mines: [c(2, 3)])
        var p = PlayerProfile()
        var normal = run(tiny)
        let win = p.play(.reveal(c(0, 0)), in: &normal)
        XCTAssertEqual(win.drops.count, 1)
        XCTAssertEqual(p.inventory[win.drops[0]], 3)
        XCTAssertEqual(p.ledger.coins, 110 + 200)

        var q = PlayerProfile()
        var boss = run(tiny, boss: true)
        let bossWin = q.play(.reveal(c(0, 0)), in: &boss)
        XCTAssertEqual(bossWin.drops.count, 3)
        XCTAssertEqual(q.ledger.coins, 110 + 1000)
        XCTAssertEqual(q.bossesDefeated, 1)
    }

    func testBossSitesComeEveryTenthClear() {
        XCTAssertFalse(BossCatalog.isBossSite(clears: 0))
        XCTAssertTrue(BossCatalog.isBossSite(clears: 9))
        XCTAssertFalse(BossCatalog.isBossSite(clears: 10))
        XCTAssertTrue(BossCatalog.isBossSite(clears: 19))

        var p = PlayerProfile()
        p.zoneClears[ZoneID.sunnyQuarry.rawValue] = 9
        let spec = p.nextSiteSpec(in: .sunnyQuarry)
        XCTAssertTrue(spec.isBoss)
        XCTAssertEqual(spec.config, BossCatalog.config(for: .sunnyQuarry))
        let started = p.startExpedition(in: .sunnyQuarry, seed: 3)
        XCTAssertTrue(started.isBoss)
        XCTAssertEqual(BossCatalog.health(of: started.board).total, spec.config.safeCellCount)
    }

    func testBossBoardsAreNoGuess() {
        for zone in ZoneID.allCases {
            let config = BossCatalog.config(for: zone)
            let opening = Coord(row: config.rows / 2, col: config.cols / 2)
            let board = PuzzleSolver.generateBoard(config: config, seed: 21, opening: opening, requireNoGuess: true)
            let fresh = MinesweeperBoard(config: config, seed: 0, mineIndices: Set(board.mineCoords.map { $0.row * config.cols + $0.col }))
            XCTAssertTrue(PuzzleSolver.isSolvableWithoutGuessing(fresh, opening: opening), "\(zone)")
        }
    }

    func testBuyingItems() {
        var p = PlayerProfile()
        XCTAssertEqual(p.buyItem(.radar), .insufficientFunds(cost: 400))
        p.ledger.credit(1000, .coins, id: "grant")
        XCTAssertEqual(p.buyItem(.radar), .purchased(newLevel: 3, cost: 400))
        XCTAssertEqual(p.ledger.coins, 600)
    }

    func testInventoryAndBestsSurviveSave() throws {
        var p = PlayerProfile()
        p.inventory.add(.xray, 5)
        p.rushBest = 321
        p.endlessBestDepth = 77
        let data = try JSONEncoder().encode(p)
        let back = try JSONDecoder().decode(PlayerProfile.self, from: data)
        XCTAssertEqual(back.inventory[.xray], 7)
        XCTAssertEqual(back.rushBest, 321)
        XCTAssertEqual(back.endlessBestDepth, 77)
        let old = try JSONDecoder().decode(PlayerProfile.self, from: Data("{}".utf8))
        XCTAssertEqual(old.inventory, .starter)
    }
}

final class ArcadeModeTests: XCTestCase {
    private func firstSafeHidden(_ b: MinesweeperBoard) -> Coord? {
        b.allCoords.first { !b[$0].isMine && b[$0].state == .hidden }
    }

    // MARK: Rush

    func testRushClockMinePenaltyAndNewBoard() {
        var rush = RushSession(id: "r", seed: 5)
        XCTAssertEqual(rush.board.status, .playing)
        rush.tick(5)
        XCTAssertEqual(rush.timeLeft, 55)
        let mine = rush.board.mineCoords.first { rush.board[$0].state == .hidden }!
        let boom = rush.play(.reveal(mine), now: 1)
        XCTAssertEqual(boom.timeDelta, -10)
        XCTAssertTrue(boom.newBoard)
        XCTAssertEqual(rush.timeLeft, 45)
        XCTAssertEqual(rush.board.status, .playing, "a fresh board was dealt")
    }

    func testRushClearAddsTimeAndScore() {
        var rush = RushSession(id: "r", seed: 6)
        var t = 0.0
        var cleared = false
        while !cleared, let cell = firstSafeHidden(rush.board) {
            t += 0.5
            let outcome = rush.play(.reveal(cell), now: t)
            cleared = outcome.newBoard
            if cleared { XCTAssertEqual(outcome.timeDelta, 8) }
        }
        XCTAssertTrue(cleared)
        XCTAssertEqual(rush.boardsCleared, 1)
        XCTAssertEqual(rush.timeLeft, 68)
        XCTAssertGreaterThan(rush.score, RushSession.clearPoints)
        XCTAssertEqual(rush.coinReward, rush.score * 4)
    }

    func testRushEndsWhenTimeRunsOut() {
        var rush = RushSession(id: "r", seed: 7)
        rush.tick(61)
        XCTAssertTrue(rush.isOver)
        let cell = firstSafeHidden(rush.board)!
        XCTAssertEqual(rush.play(.reveal(cell), now: 0), ArcadeOutcome())
    }

    // MARK: Dark Mine

    func testDarkMineLightsOnlyRecentDigs() {
        var dark = DarkMineSession(id: "d", seed: 8)
        let opening = Coord(row: 6, col: 4)
        XCTAssertTrue(dark.litCells.contains(opening))
        for corner in [Coord(row: 0, col: 0), Coord(row: 0, col: 8), Coord(row: 11, col: 0), Coord(row: 11, col: 8)] {
            dark.play(.flag(corner))
        }
        XCTAssertEqual(dark.recentDigs.count, 3)
        XCTAssertTrue(dark.litCells.contains(Coord(row: 10, col: 7)))
        XCTAssertFalse(dark.litCells.contains(opening))
        XCTAssertFalse(dark.litCells.contains(Coord(row: 1, col: 1)), "the oldest dig went dark")
    }

    // MARK: Endless

    private func assertNumbersFinal(_ b: MinesweeperBoard, file: StaticString = #filePath, line: UInt = #line) {
        for p in b.allCoords where b[p].state == .revealed && !b[p].isMine {
            let actual = b.neighbors(of: p).filter { b[$0].isMine }.count
            XCTAssertEqual(b[p].adjacentMines, actual, "\(p)", file: file, line: line)
        }
    }

    func testEndlessStartsSealedWithRoomBelow() {
        let e = EndlessSession(id: "e", seed: 9)
        XCTAssertGreaterThanOrEqual(e.board.rows, 36)
        XCTAssertEqual(e.board.floodLimitRow, e.board.rows - EndlessSession.chunkRows)
        XCTAssertEqual(e.livesLeft, 3)
        XCTAssertGreaterThan(e.board.revealedSafeCount, 0)
    }

    func testEndlessGrowsAndEveryShownNumberIsFinal() {
        var e = EndlessSession(id: "e", seed: 10)
        var t = 0.0
        for _ in 0..<150 {
            guard let cell = e.board.allCoords.first(where: { !e.board[$0].isMine && e.board[$0].state == .hidden }) else { break }
            t += 0.2
            e.play(.reveal(cell), now: t)
            assertNumbersFinal(e.board)
            XCTAssertTrue(e.board.allCoords.filter { e.board[$0].state == .revealed }.allSatisfy { $0.row < e.board.floodLimitRow! })
        }
        XCTAssertGreaterThan(e.depth, 12)
        XCTAssertGreaterThan(e.board.rows, 36)
        XCTAssertGreaterThanOrEqual(e.board.rows - e.deepestRow, 2 * EndlessSession.chunkRows)
        XCTAssertEqual(e.coinReward, e.depth * 15)
    }

    func testEndlessDensityRisesAndCaps() {
        XCTAssertEqual(EndlessSession.density(chunk: 0), 12)
        XCTAssertEqual(EndlessSession.density(chunk: 5), 17)
        XCTAssertEqual(EndlessSession.density(chunk: 40), 24)
    }

    func testEndlessThreeLives() {
        var e = EndlessSession(id: "e", seed: 11)
        for expected in [2, 1, 0] {
            let mine = e.board.mineCoords.first { e.board[$0].state == .hidden }!
            let outcome = e.play(.reveal(mine), now: 0)
            XCTAssertTrue(outcome.lostLife)
            XCTAssertEqual(e.livesLeft, expected)
        }
        XCTAssertTrue(e.isOver)
    }

    func testEndlessItems() {
        var e = EndlessSession(id: "e", seed: 12)
        let mine = e.board.mineCoords.first { e.board[$0].state == .hidden && $0.row < 20 }!
        let radar = e.play(.item(.radar, mine), now: 0)
        XCTAssertTrue(radar.radarMines.contains(mine))
        let blast = e.play(.item(.dynamite, mine), now: 0)
        XCTAssertTrue(blast.result.defused.contains(mine))
        XCTAssertEqual(e.livesLeft, 3)
    }
}
