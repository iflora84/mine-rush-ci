import Foundation
import XCTest
@testable import MineRushCore

final class BoardEngineTests: XCTestCase {
    private func c(_ row: Int, _ col: Int) -> Coord { Coord(row: row, col: col) }

    // MARK: Generation

    func testSeededRNGIsDeterministic() {
        var a = SplitMix64(seed: 42)
        var b = SplitMix64(seed: 42)
        for _ in 0..<100 { XCTAssertEqual(a.next(), b.next()) }
        var other = SplitMix64(seed: 43)
        XCTAssertNotEqual(SplitMix64(seed: 42).nextCopy(), other.next())
    }

    func testSameSeedAndFirstClickGiveSameLayout() {
        let first = MineGenerator.layout(config: .expert, seed: 7, firstClick: c(5, 5))
        let second = MineGenerator.layout(config: .expert, seed: 7, firstClick: c(5, 5))
        XCTAssertEqual(first, second)
        XCTAssertNotEqual(first, MineGenerator.layout(config: .expert, seed: 8, firstClick: c(5, 5)))
    }

    func testLayoutHasExactMineCountAndSafeZone() {
        for seed in UInt64(0)..<200 {
            let click = c(Int(seed % 9), Int((seed / 9) % 9))
            let mines = MineGenerator.layout(config: .beginner, seed: seed, firstClick: click)
            XCTAssertEqual(mines.count, 10)
            for dr in -1...1 {
                for dc in -1...1 {
                    let r = click.row + dr, col = click.col + dc
                    guard r >= 0, r < 9, col >= 0, col < 9 else { continue }
                    XCTAssertFalse(mines.contains(r * 9 + col), "seed \(seed) put a mine next to the first click")
                }
            }
        }
    }

    func testAcceptHookRetriesUntilAccepted() {
        var calls = 0
        _ = MineGenerator.layout(config: .beginner, seed: 1, firstClick: c(4, 4), maxAttempts: 5) { _ in
            calls += 1
            return calls == 3
        }
        XCTAssertEqual(calls, 3)
    }

    func testConfigClampsMineCount() {
        XCTAssertEqual(BoardConfig(rows: 4, cols: 4, mines: 100).mines, 7)
        XCTAssertEqual(BoardConfig(rows: 9, cols: 9, mines: 0).mines, 1)
    }

    // MARK: First click

    func testFirstRevealIsAlwaysSafeAndOpensArea() {
        for seed in UInt64(0)..<100 {
            var board = MinesweeperBoard(config: .expert, seed: seed)
            XCTAssertEqual(board.status, .ready)
            let result = board.reveal(c(15, 8))
            XCTAssertNil(result.hitMine)
            XCTAssertEqual(board[c(15, 8)].adjacentMines, 0, "first click should land on an empty cell")
            XCTAssertGreaterThanOrEqual(result.revealed.count, 9)
            XCTAssertEqual(board.mineCoords.count, 99)
        }
    }

    func testRevealingFlaggedCellBeforeFirstDigPlacesNoMines() {
        var board = MinesweeperBoard(config: .beginner, seed: 3)
        board.toggleFlag(c(0, 0))
        XCTAssertEqual(board.reveal(c(0, 0)), .empty)
        XCTAssertEqual(board.status, .ready)
        XCTAssertTrue(board.mineCoords.isEmpty)
    }

    func testMinesNeverMoveAfterFirstClick() {
        var board = MinesweeperBoard(config: .intermediate, seed: 99)
        board.reveal(c(0, 0))
        let mines = board.mineCoords
        for coord in board.allCoords where !board[coord].isMine {
            board.reveal(coord)
        }
        XCTAssertEqual(board.mineCoords, mines)
    }

    // MARK: Numbers and flood fill

    // Layout used below (M = mine):
    //   row 0: M . . .
    //   row 1: . . . .
    //   row 2: . . . M
    private func smallBoard() -> MinesweeperBoard {
        MinesweeperBoard(rows: 3, cols: 4, mines: [c(0, 0), c(2, 3)])
    }

    func testAdjacentCounts() {
        let board = smallBoard()
        XCTAssertEqual(board[c(0, 1)].adjacentMines, 1)
        XCTAssertEqual(board[c(1, 1)].adjacentMines, 1)
        XCTAssertEqual(board[c(1, 2)].adjacentMines, 1)
        XCTAssertEqual(board[c(0, 3)].adjacentMines, 0)
        XCTAssertEqual(board[c(2, 0)].adjacentMines, 0)
        XCTAssertEqual(board.config.mines, 2)
        XCTAssertEqual(board.status, .playing)
    }

    func testFloodRevealStopsAtNumbersAndSkipsFlags() {
        var board = MinesweeperBoard(rows: 5, cols: 5, mines: [c(4, 4)])
        board.toggleFlag(c(0, 4))
        let result = board.reveal(c(0, 0))
        XCTAssertEqual(board[c(0, 4)].state, .flagged)
        XCTAssertEqual(result.revealed.count, 23)
        XCTAssertEqual(Set(result.revealed).count, result.revealed.count, "no cell reported twice")
        XCTAssertFalse(result.didWin)

        board.toggleFlag(c(0, 4))
        let last = board.reveal(c(0, 4))
        XCTAssertEqual(last.revealed, [c(0, 4)])
        XCTAssertTrue(last.didWin)
        XCTAssertEqual(board.status, .won)
    }

    func testFloodFillHandlesHugeEmptyBoard() {
        var board = MinesweeperBoard(rows: 200, cols: 200, mines: [c(199, 199)])
        let result = board.reveal(c(0, 0))
        XCTAssertEqual(result.revealed.count, 200 * 200 - 1)
        XCTAssertEqual(board.status, .won)
    }

    func testRevealingSameCellTwiceReportsNothing() {
        var board = smallBoard()
        XCTAssertEqual(board.reveal(c(1, 1)).revealed, [c(1, 1)])
        XCTAssertEqual(board.reveal(c(1, 1)), .empty)
        XCTAssertEqual(board.revealedSafeCount, 1)
    }

    // MARK: Flags

    func testFlagToggleAndCounter() {
        var board = smallBoard()
        XCTAssertEqual(board.toggleFlag(c(0, 0)), .placed)
        XCTAssertEqual(board.minesRemaining, 1)
        XCTAssertEqual(board.reveal(c(0, 0)), .empty, "flagged cells can't be revealed")
        XCTAssertEqual(board.toggleFlag(c(0, 0)), .removed)
        XCTAssertEqual(board.minesRemaining, 2)

        board.reveal(c(1, 1))
        XCTAssertNil(board.toggleFlag(c(1, 1)), "revealed cells can't be flagged")
    }

    // MARK: Chord

    func testChordRevealsNeighborsWhenFlagsMatch() {
        var board = smallBoard()
        board.reveal(c(1, 1))
        XCTAssertEqual(board.chord(c(1, 1)), .empty, "no flags yet, chord does nothing")
        board.toggleFlag(c(0, 0))
        let result = board.chord(c(1, 1))
        XCTAssertNil(result.hitMine)
        XCTAssertTrue(result.revealed.contains(c(0, 1)))
        XCTAssertTrue(result.revealed.contains(c(2, 0)))
        XCTAssertEqual(board[c(0, 0)].state, .flagged)
    }

    func testChordWithWrongFlagLoses() {
        var board = smallBoard()
        board.reveal(c(1, 1))
        board.toggleFlag(c(0, 1))
        let result = board.chord(c(1, 1))
        XCTAssertEqual(result.hitMine, c(0, 0))
        XCTAssertEqual(board.status, .lost(triggered: c(0, 0)))
        XCTAssertEqual(board.wrongFlags, [c(0, 1)])
    }

    // MARK: Win / loss

    func testHittingMineLosesAndFreezesBoard() {
        var board = smallBoard()
        let result = board.reveal(c(2, 3))
        XCTAssertEqual(result.hitMine, c(2, 3))
        XCTAssertEqual(board.status, .lost(triggered: c(2, 3)))
        XCTAssertEqual(board.reveal(c(0, 3)), .empty)
        XCTAssertNil(board.toggleFlag(c(0, 3)))
    }

    func testWinRequiresAllSafeCellsNotFlags() {
        var board = smallBoard()
        board.toggleFlag(c(0, 0))
        board.toggleFlag(c(2, 3))
        XCTAssertEqual(board.status, .playing)
        var won = false
        for coord in board.allCoords where !board[coord].isMine {
            won = board.reveal(coord).didWin || won
        }
        XCTAssertTrue(won)
        XCTAssertEqual(board.status, .won)
    }

    func testBoardRoundTripsThroughCodable() throws {
        var board = MinesweeperBoard(config: .beginner, seed: 5)
        board.reveal(c(4, 4))
        board.toggleFlag(board.mineCoords[0])
        let data = try JSONEncoder().encode(board)
        let restored = try JSONDecoder().decode(MinesweeperBoard.self, from: data)
        XCTAssertEqual(restored.cells, board.cells)
        XCTAssertEqual(restored.status, board.status)
        XCTAssertEqual(restored.flagCount, 1)
    }

    // MARK: Clock

    func testClockPausesAndResumes() {
        var clock = GameClock()
        clock.start(at: 100)
        XCTAssertEqual(clock.elapsed(at: 110), 10)
        clock.pause(at: 110)
        XCTAssertEqual(clock.elapsed(at: 500), 10)
        clock.start(at: 500)
        XCTAssertEqual(clock.elapsed(at: 505), 15)
        XCTAssertEqual(clock.elapsed(at: 400), 10, "clock never runs backwards")
    }
}

private extension SplitMix64 {
    func nextCopy() -> UInt64 {
        var copy = self
        return copy.next()
    }
}
