import Foundation
import XCTest
@testable import MineRushCore

final class EconomyTests: XCTestCase {
    private func c(_ row: Int, _ col: Int) -> Coord { Coord(row: row, col: col) }

    private func richProfile(_ coins: Int = 10_000_000) -> PlayerProfile {
        var p = PlayerProfile()
        p.ledger.credit(coins, .coins, id: "test-grant")
        return p
    }

    // MARK: Ledger

    func testLedgerIgnoresDuplicateIDs() {
        var ledger = CurrencyLedger()
        XCTAssertTrue(ledger.credit(100, .coins, id: "a"))
        XCTAssertFalse(ledger.credit(100, .coins, id: "a"))
        XCTAssertEqual(ledger.coins, 100)
        XCTAssertTrue(ledger.spend(40, .coins, id: "b"))
        XCTAssertFalse(ledger.spend(40, .coins, id: "b"))
        XCTAssertEqual(ledger.coins, 60)
        XCTAssertEqual(ledger.coinsEarned, 100)
        XCTAssertEqual(ledger.coinsSpent, 40)
    }

    func testLedgerKeepsCurrenciesSeparateAndRefusesOverspend() {
        var ledger = CurrencyLedger()
        ledger.credit(50, .gems, id: "g")
        XCTAssertFalse(ledger.spend(1, .coins, id: "x"))
        XCTAssertEqual(ledger.gems, 50)
        XCTAssertEqual(ledger.coins, 0)
        XCTAssertFalse(ledger.credit(-5, .coins, id: "neg"))
    }

    func testLedgerSaturatesInsteadOfOverflowing() {
        var ledger = CurrencyLedger()
        ledger.credit(.max - 10, .coins, id: "a")
        ledger.credit(1000, .coins, id: "b")
        XCTAssertEqual(ledger.coins, .max)
        XCTAssertEqual(Int.max.applyingPercent(500), Int.max / 100)
    }

    func testLedgerIdempotencySurvivesRoundTrip() throws {
        var ledger = CurrencyLedger()
        ledger.credit(10, .coins, id: "once")
        var restored = try JSONDecoder().decode(CurrencyLedger.self, from: JSONEncoder().encode(ledger))
        XCTAssertFalse(restored.credit(10, .coins, id: "once"))
        XCTAssertEqual(restored.coins, 10)
    }

    // MARK: Upgrades

    func testAllTwelveUpgradesExistWithRisingCosts() {
        XCTAssertEqual(UpgradeCatalog.all.count, 12)
        XCTAssertEqual(Set(UpgradeCatalog.all.map(\.id)).count, 12)
        for def in UpgradeCatalog.all {
            XCTAssertGreaterThan(def.cost(atLevel: 1), def.cost(atLevel: 0), def.name)
            XCTAssertGreaterThan(def.maxLevel, 0)
            XCTAssertFalse(def.effectDescription(atLevel: 1).isEmpty)
        }
    }

    func testPurchaseSpendsCoinsAndStopsAtMax() {
        var p = richProfile()
        let def = UpgradeCatalog.definition(.mineScanner)
        for level in 1...def.maxLevel {
            XCTAssertEqual(p.buyUpgrade(.mineScanner), .purchased(newLevel: level, cost: def.cost(atLevel: level - 1)))
        }
        XCTAssertEqual(p.buyUpgrade(.mineScanner), .maxed)
        XCTAssertEqual(p.upgrades[.mineScanner], 3)
    }

    func testPurchaseWithoutFundsChangesNothing() {
        var p = PlayerProfile()
        XCTAssertEqual(p.buyUpgrade(.betterPickaxe), .insufficientFunds(cost: 150))
        XCTAssertEqual(p.upgrades[.betterPickaxe], 0)
    }

    func testExtraSuppliesNeedsScanner() {
        var p = richProfile()
        XCTAssertEqual(p.buyUpgrade(.extraSupplies), .locked(reason: "Requires Mine Scanner"))
        _ = p.buyUpgrade(.mineScanner)
        XCTAssertEqual(p.buyUpgrade(.extraSupplies), .purchased(newLevel: 1, cost: 2000))
        XCTAssertEqual(p.rewards(in: .sunnyQuarry).scannerCharges, 2)
    }

    // MARK: Rewards

    func testRewardFormulasRespondToUpgradesAndZones() {
        var levels = UpgradeLevels()
        let base = RewardCalculator(upgrades: levels, zoneMultiplierPercent: 100)
        XCTAssertEqual(base.tiles(10), 100)
        XCTAssertEqual(base.completion(streak: 1), 200)
        XCTAssertEqual(base.correctFlags(4), 100)
        XCTAssertEqual(base.treasure(), 150)

        levels[.betterPickaxe] = 5   // +50%
        levels[.luckyGloves] = 2     // +30%
        levels[.treasureMagnet] = 1  // +20%
        let upgraded = RewardCalculator(upgrades: levels, zoneMultiplierPercent: 250)
        XCTAssertEqual(upgraded.tiles(10), 375)
        XCTAssertEqual(upgraded.completion(streak: 1), 650)
        XCTAssertEqual(upgraded.treasure(), 450)
    }

    func testStreakBonusGrowsAndCaps() {
        var levels = UpgradeLevels()
        let calc = RewardCalculator(upgrades: levels, zoneMultiplierPercent: 100)
        XCTAssertEqual(calc.completion(streak: 3), 240) // 2 steps x 10%
        XCTAssertEqual(calc.completion(streak: 50), calc.completion(streak: 11))
        levels[.comboCharm] = 10 // +30% per step
        XCTAssertEqual(RewardCalculator(upgrades: levels, zoneMultiplierPercent: 100).completion(streak: 3), 360)
    }

    // MARK: Expedition runs

    private func smallRun(treasures: Int = 0) -> ExpeditionRun {
        // Row 0 is the opening area; the mine sits in the far corner.
        //   . . . .
        //   . . . .
        //   . . . M
        let board = MinesweeperBoard(rows: 3, cols: 4, mines: [c(2, 3)])
        return ExpeditionRun(id: "t", zone: .sunnyQuarry, board: board, scannerCharges: 1, helmetCharges: 1, treasureCount: treasures)
    }

    func testTilesPayOnceAndWinSettlesOnce() {
        var p = PlayerProfile()
        var run = smallRun()
        let first = p.play(.reveal(c(1, 2)), in: &run)
        XCTAssertEqual(first.tileCoins, 10)
        let again = p.play(.reveal(c(1, 2)), in: &run)
        XCTAssertEqual(again.tileCoins, 0)

        p.play(.flag(c(2, 3)), in: &run)
        p.play(.flag(c(2, 3)), in: &run)
        p.play(.flag(c(2, 3)), in: &run)
        XCTAssertEqual(p.ledger.coins, 10, "flag toggling pays nothing")

        let win = p.play(.reveal(c(0, 0)), in: &run)
        XCTAssertTrue(win.result.didWin)
        XCTAssertEqual(win.tileCoins, 100)
        // 10 + 100 tiles, 200 clear, 25 for the verified flag.
        XCTAssertEqual(p.ledger.coins, 335)
        XCTAssertNil(run.settleWin(streak: 1, rewards: p.rewards(in: .sunnyQuarry)))
        XCTAssertEqual(p.expeditionWins, 1)
        XCTAssertEqual(p.clears(in: .sunnyQuarry), 1)
    }

    func testHelmetAbsorbsOneMineThenLossResetsStreak() {
        var p = PlayerProfile()
        p.expeditionStreak = 4
        var run = smallRun()
        let saved = p.play(.reveal(c(2, 3)), in: &run)
        XCTAssertEqual(saved.result.shieldedMine, c(2, 3))
        XCTAssertEqual(run.board.status, .playing)
        XCTAssertEqual(run.helmetCharges, 0)
        XCTAssertTrue(run.board[c(2, 3)].isDefused)
        var copy = run.board
        XCTAssertNil(copy.toggleFlag(c(2, 3)), "defused mines stay flagged")
        XCTAssertEqual(p.expeditionStreak, 4)

        let board = MinesweeperBoard(rows: 3, cols: 4, mines: [c(2, 3)])
        var noHelmet = ExpeditionRun(id: "u", zone: .sunnyQuarry, board: board, scannerCharges: 0, helmetCharges: 0, treasureCount: 0)
        let boom = p.play(.reveal(c(2, 3)), in: &noHelmet)
        XCTAssertNotNil(boom.result.hitMine)
        XCTAssertEqual(p.expeditionStreak, 0)
        XCTAssertEqual(p.bestExpeditionStreak, 0, "streak only counts wins earned in play")
    }

    func testScannerRevealsProvablySafeTileAndUsesCharge() {
        var p = PlayerProfile()
        var run = smallRun()
        // Two overlapping "1"s: the subset rule proves the top row safe.
        p.play(.reveal(c(1, 2)), in: &run)
        p.play(.reveal(c(2, 2)), in: &run)
        let scan = p.play(.scan, in: &run)
        XCTAssertNotNil(scan.scanned)
        XCTAssertFalse(run.board[scan.scanned!].isMine)
        XCTAssertEqual(run.scannerCharges, 0)
        XCTAssertNil(p.play(.scan, in: &run).scanned, "no charges left")
    }

    func testScansPayNothing() {
        var p = PlayerProfile()
        var run = smallRun()
        p.play(.reveal(c(1, 2)), in: &run)
        p.play(.reveal(c(2, 2)), in: &run)
        let coins = p.ledger.coins
        let revealed = run.board.revealedSafeCount
        let scan = p.play(.scan, in: &run)
        XCTAssertEqual(scan.tileCoins, 0)
        XCTAssertGreaterThan(run.board.revealedSafeCount, revealed)
        // Here the scan's flood happens to finish the site: only the clear bonus is paid.
        XCTAssertEqual(p.ledger.coins, coins + (scan.result.didWin ? 200 : 0))
    }

    func testAbandoningUnfinishedSiteBreaksStreakAndRunIsSaved() throws {
        var p = PlayerProfile()
        p.expeditionStreak = 5
        p.startExpedition(in: .sunnyQuarry, seed: 1)
        XCTAssertEqual(p.expeditionStreak, 5, "nothing to abandon yet")
        XCTAssertNotNil(p.playExpedition(.flag(Coord(row: 0, col: 0))))

        let repo = SaveRepository(directory: tempDir())
        try repo.save(p, now: 1)
        let restored = repo.load().profile
        XCTAssertEqual(restored.activeRun?.board.cells, p.activeRun?.board.cells)
        XCTAssertEqual(restored.activeRun?.id, p.activeRun?.id)

        p.startExpedition(in: .sunnyQuarry, seed: 2)
        XCTAssertEqual(p.expeditionStreak, 0)
    }

    func testEmptyProfileFromOlderSaveLoadsDefaults() throws {
        let data = Data(#"{"version":1,"savedAt":0,"profile":{"expeditionWins":7}}"#.utf8)
        let profile = try SaveRepository.decode(data)
        XCTAssertEqual(profile.expeditionWins, 7)
        XCTAssertEqual(profile.ledger.coins, 0)
        XCTAssertNil(profile.activeRun)
        XCTAssertNoThrow(try SaveRepository.decode(Data(#"{"version":1,"savedAt":0,"profile":{}}"#.utf8)))
    }

    func testTreasureTilesPayBonusAndCollectible() {
        var p = PlayerProfile()
        var run = smallRun(treasures: 2)
        XCTAssertEqual(run.treasureCells.count, 2)
        for coord in run.board.allCoords where !run.board[coord].isMine {
            p.play(.reveal(coord), in: &run)
        }
        XCTAssertEqual(run.foundTreasures.count, 2)
        XCTAssertEqual(p.collectibles.values.reduce(0, +), 2)
        XCTAssertEqual(p.ledger.coins, 110 + 300 + 200)
    }

    func testExpeditionBoardsStartOpenedAndPayNothingForOpening() {
        var p = PlayerProfile()
        let run = p.startExpedition(in: .sunnyQuarry, seed: 12)
        XCTAssertEqual(run.board.status, .playing)
        XCTAssertGreaterThan(run.board.revealedSafeCount, 0)
        XCTAssertEqual(p.ledger.coins, 0)
        XCTAssertEqual(run.board.config, ZoneCatalog.definition(.sunnyQuarry).boardConfig(clears: 0))
    }

    // MARK: Zones

    func testZonesUnlockByClearsAndRampDifficulty() {
        var p = PlayerProfile()
        XCTAssertTrue(p.isZoneUnlocked(.sunnyQuarry))
        XCTAssertFalse(p.isZoneUnlocked(.crystalCaves))
        p.zoneClears[ZoneID.sunnyQuarry.rawValue] = 10
        XCTAssertTrue(p.isZoneUnlocked(.crystalCaves))
        XCTAssertFalse(p.isZoneUnlocked(.volcanoVault))
        p.zoneClears[ZoneID.crystalCaves.rawValue] = 15
        XCTAssertTrue(p.isZoneUnlocked(.volcanoVault))

        let sunny = ZoneCatalog.definition(.sunnyQuarry)
        let easy = sunny.boardConfig(clears: 0), hard = sunny.boardConfig(clears: 99)
        XCTAssertEqual(easy, BoardConfig(rows: 9, cols: 9, mines: 9))
        XCTAssertEqual(hard, BoardConfig(rows: 12, cols: 9, mines: 17))
        let multipliers = ZoneCatalog.all.map(\.rewardMultiplierPercent)
        XCTAssertEqual(multipliers, multipliers.sorted())
    }

    // MARK: Workers

    func testWorkersUnlockAndProduce() {
        var p = richProfile()
        XCTAssertEqual(p.hireOrUpgrade(.milo, now: 0), .locked(reason: "Clear 3 Expedition sites"))
        p.expeditionWins = 3
        XCTAssertEqual(p.hireOrUpgrade(.milo, now: 0), .purchased(newLevel: 1, cost: 400))
        XCTAssertEqual(p.teamRateMilli, 2_000)
        XCTAssertEqual(p.hireOrUpgrade(.milo, now: 0), .purchased(newLevel: 2, cost: 472))
        XCTAssertEqual(p.teamRateMilli, 4_000)
        XCTAssertEqual(p.hireOrUpgrade(.pip, now: 0), .locked(reason: "Unlock Crystal Caves"))
    }

    func testWorkerUpgradesMultiplyOutput() {
        var workers = WorkerLevels()
        var levels = UpgradeLevels()
        workers[.milo] = 10
        workers[.bolt] = 5
        XCTAssertEqual(WorkerService.rateMilli(.milo, workers: workers, upgrades: levels), 22_000) // +10% from Bolt
        levels[.minerTraining] = 5   // +40%
        levels[.betterDrill] = 2     // +30% Bolt
        levels[.teamEfficiency] = 2  // +10% team
        XCTAssertEqual(WorkerService.rateMilli(.milo, workers: workers, upgrades: levels), 33_600)
        XCTAssertEqual(WorkerService.rateMilli(.bolt, workers: workers, upgrades: levels), 153_000)
        XCTAssertEqual(WorkerService.teamRateMilli(workers, upgrades: levels), 186_600)
    }

    // MARK: Passive & offline

    private func profileWithMilo() -> PlayerProfile {
        var p = PlayerProfile()
        p.workers[.milo] = 5 // 10 coins/s
        p.lastActiveAt = 1_000
        return p
    }

    func testForegroundIncomeAccruesWithRemainder() {
        var p = profileWithMilo()
        p.workers[.milo] = 1 // 2 coins/s
        p.settleTime(now: 1_000.25)
        p.settleTime(now: 1_000.5)
        XCTAssertEqual(p.ledger.coins, 1)
        p.settleTime(now: 1_030)
        XCTAssertEqual(p.ledger.coins, 60)
        XCTAssertNil(p.pendingOffline)
    }

    func testOfflineRewardIsCappedAndClaimableOnce() {
        var p = profileWithMilo()
        let reward = p.settleTime(now: 1_000 + 10 * 3600)
        XCTAssertEqual(reward?.seconds, 4 * 3600)
        XCTAssertEqual(reward?.coins, 144_000)
        XCTAssertEqual(reward?.wasCapped, true)
        XCTAssertNil(p.settleTime(now: 1_000 + 10 * 3600 + 120), "a pending reward isn't replaced")
        XCTAssertEqual(p.claimOfflineReward(), 144_000)
        XCTAssertEqual(p.claimOfflineReward(), 0)
        XCTAssertGreaterThanOrEqual(p.ledger.coins, 144_000)
    }

    func testBiggerStorageAndPipChests() {
        var p = profileWithMilo()
        p.upgrades[.biggerStorage] = 2
        p.workers[.pip] = 1 // +6 coins/s => 16/s
        let reward = p.settleTime(now: 1_000 + 24 * 3600)!
        XCTAssertEqual(reward.seconds, 6 * 3600)
        XCTAssertEqual(reward.chests, 36)
        XCTAssertEqual(reward.coins, 16 * 6 * 3600 + 36 * 16 * 120)
    }

    func testClockRollbackPaysNothing() {
        var p = profileWithMilo()
        XCTAssertNil(p.settleTime(now: 500))
        XCTAssertEqual(p.ledger.coins, 0)
        XCTAssertEqual(p.lastActiveAt, 1_000, "high-water mark is kept")
        XCTAssertNil(p.settleTime(now: .nan))
        XCTAssertEqual(p.lastActiveAt, 1_000)
    }

    func testClockForwardBackForwardPaysOnlyOnce() {
        var p = profileWithMilo()
        let later = 1_000.0 + 4 * 3600
        XCTAssertNotNil(p.settleTime(now: later))
        let paid = p.claimOfflineReward()
        XCTAssertGreaterThan(paid, 0)
        XCTAssertNil(p.settleTime(now: 1_000)) // wound back
        XCTAssertNil(p.settleTime(now: later)) // wound forward to the same moment
        XCTAssertNil(p.pendingOffline)
        XCTAssertEqual(p.ledger.coins, paid)
    }

    func testDoubledOfflineClaimAndHireSettlesAtOldRate() {
        var p = profileWithMilo()
        p.settleTime(now: 1_000 + 600)
        XCTAssertEqual(p.claimOfflineReward(multiplier: 2), 12_000)

        var q = profileWithMilo()
        q.expeditionWins = 3
        q.ledger.credit(1_000_000, .coins, id: "grant")
        q.settleTime(now: 1_030) // pays 300
        _ = q.hireOrUpgrade(.milo, now: 1_040) // pays 100 at the old rate first
        XCTAssertEqual(q.ledger.coins, 1_000_000 + 400 - WorkerCatalog.definition(.milo).cost(toReachLevel: 6))
    }

    // MARK: Daily & classic

    func testDailyBoardIsDeterministicAndStreakCounts() {
        XCTAssertEqual(DailyChallenge.seed(forDay: "2026-11-02"), DailyChallenge.seed(forDay: "2026-11-02"))
        XCTAssertNotEqual(DailyChallenge.seed(forDay: "2026-11-02"), DailyChallenge.seed(forDay: "2026-11-03"))
        let a = DailyChallenge.board(forDay: "2026-11-02")
        let b = DailyChallenge.board(forDay: "2026-11-02")
        XCTAssertEqual(a.cells, b.cells)
        XCTAssertTrue(PuzzleSolver.isSolvableWithoutGuessing(
            MinesweeperBoard(config: a.config, seed: 0, mineIndices: Set(a.mineCoords.map { $0.row * a.cols + $0.col })),
            opening: DailyChallenge.opening
        ))

        var p = PlayerProfile()
        XCTAssertTrue(p.recordDailyWin(day: "2026-11-02", seconds: 90))
        XCTAssertFalse(p.recordDailyWin(day: "2026-11-02", seconds: 50))
        XCTAssertTrue(p.recordDailyWin(day: "2026-11-03", seconds: 80))
        XCTAssertEqual(p.daily.streak, 2)
        XCTAssertTrue(p.recordDailyWin(day: "2026-11-05", seconds: 80))
        XCTAssertEqual(p.daily.streak, 1)
        XCTAssertEqual(p.daily.bestStreak, 2)
        XCTAssertTrue(DailyChallenge.isConsecutive("2026-12-31", "2027-01-01"))
    }

    func testClassicBestTimes() {
        var p = PlayerProfile()
        XCTAssertTrue(p.recordClassicWin(config: .beginner, seconds: 60))
        XCTAssertFalse(p.recordClassicWin(config: .beginner, seconds: 70))
        XCTAssertTrue(p.recordClassicWin(config: .beginner, seconds: 45))
        XCTAssertEqual(p.classicBest["9x9-10"], 45)
        XCTAssertEqual(p.classicWins, 3)
    }

    // MARK: Save / restore

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("minerush-\(UUID().uuidString)")
    }

    func testSaveAndRestoreRoundTrip() throws {
        let repo = SaveRepository(directory: tempDir())
        var p = richProfile(1234)
        p.upgrades[.betterPickaxe] = 3
        p.workers[.milo] = 2
        p.daily.streak = 4
        try repo.save(p, now: 1)
        let (loaded, source) = repo.load()
        XCTAssertEqual(source, .primary)
        XCTAssertEqual(loaded.ledger.coins, 1234)
        XCTAssertEqual(loaded.upgrades, p.upgrades)
        XCTAssertEqual(loaded.workers, p.workers)
        XCTAssertEqual(loaded.daily, p.daily)
    }

    func testCorruptSaveFallsBackToBackup() throws {
        let repo = SaveRepository(directory: tempDir())
        try repo.save(richProfile(100), now: 1)
        try repo.save(richProfile(200), now: 2)
        try Data("{ not json".utf8).write(to: repo.primaryURL)
        let (loaded, source) = repo.load()
        XCTAssertEqual(source, .backup)
        XCTAssertEqual(loaded.ledger.coins, 100)
    }

    func testFutureSaveVersionIsNotMisread() throws {
        let repo = SaveRepository(directory: tempDir())
        try FileManager.default.createDirectory(at: repo.directory, withIntermediateDirectories: true)
        try Data(#"{"version": 99, "savedAt": 0, "profile": {}}"#.utf8).write(to: repo.primaryURL)
        XCTAssertThrowsError(try SaveRepository.decode(Data(contentsOf: repo.primaryURL))) {
            XCTAssertEqual($0 as? SaveError, .unsupportedVersion(99))
        }
        XCTAssertEqual(repo.load().source, .fresh)
    }
}

final class PuzzleSolverTests: XCTestCase {
    private func c(_ row: Int, _ col: Int) -> Coord { Coord(row: row, col: col) }

    func testDeducesSafeCellsFromSatisfiedNumber() {
        //   M 1 .        After revealing (0,1)=1, (1,0)=1, (1,1)=1 the solver knows
        //   1 1 .        (0,0) is the mine and everything else is safe.
        //   . . .
        var board = MinesweeperBoard(rows: 3, cols: 3, mines: [c(0, 0)])
        board.reveal(c(0, 1))
        board.reveal(c(1, 0))
        board.reveal(c(1, 1))
        let d = PuzzleSolver.deduce(board)
        XCTAssertTrue(d.mines.contains(c(0, 0)))
        XCTAssertTrue(d.safe.contains(c(2, 2)) || board[c(2, 2)].state == .revealed)
        XCTAssertNotNil(PuzzleSolver.hint(for: board))
    }

    func testIgnoresWrongPlayerFlags() {
        var board = MinesweeperBoard(rows: 3, cols: 3, mines: [c(0, 0)])
        board.reveal(c(1, 1))
        board.toggleFlag(c(2, 2)) // wrong flag
        let hint = PuzzleSolver.hint(for: board)
        if let hint { XCTAssertFalse(board[hint].isMine) }
    }

    func testFiftyFiftyIsRejected() {
        // Two cells share a single "1" with no other information: a coin flip.
        //   M .
        //   . .  (2x2 with one mine and the opening on the far side is a guess)
        let board = MinesweeperBoard(rows: 1, cols: 3, mines: [c(0, 0)])
        XCTAssertFalse(PuzzleSolver.isSolvableWithoutGuessing(
            MinesweeperBoard(rows: 2, cols: 2, mines: [c(0, 0)]), opening: c(1, 1)
        ))
        XCTAssertTrue(PuzzleSolver.isSolvableWithoutGuessing(board, opening: c(0, 2)))
    }

    func testGeneratedBoardsAreNoGuessForEveryZone() {
        for zone in ZoneCatalog.all {
            let config = zone.boardConfig(clears: 999)
            let opening = Coord(row: config.rows / 2, col: config.cols / 2)
            for seed in UInt64(1)...5 {
                let board = PuzzleSolver.generateBoard(config: config, seed: seed, opening: opening, requireNoGuess: true)
                let fresh = MinesweeperBoard(config: config, seed: 0, mineIndices: Set(board.mineCoords.map { $0.row * config.cols + $0.col }))
                XCTAssertTrue(PuzzleSolver.isSolvableWithoutGuessing(fresh, opening: opening), "\(zone.name) seed \(seed)")
            }
        }
    }
}
