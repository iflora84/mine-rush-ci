/// Rule-based solver used for scanner hints and for rejecting layouts that
/// would force a guess. It only looks at revealed numbers and defused mines,
/// never at player flags, which may be wrong.
public enum PuzzleSolver {
    public struct Deduction: Equatable {
        public var safe: Set<Coord> = []
        public var mines: Set<Coord> = []
    }

    private struct Constraint {
        var cells: Set<Coord>
        var mines: Int
    }

    /// Cells that are provably safe or provably mines from what's visible.
    public static func deduce(_ board: MinesweeperBoard) -> Deduction {
        var known = Deduction()
        for c in board.allCoords where board[c].isDefused {
            known.mines.insert(c)
        }

        var changed = true
        while changed {
            changed = false
            let constraints = buildConstraints(board, known: known)

            func mark(_ cells: Set<Coord>, asMines: Bool) {
                for c in cells {
                    if asMines {
                        if known.mines.insert(c).inserted { changed = true }
                    } else if known.safe.insert(c).inserted {
                        changed = true
                    }
                }
            }

            for k in constraints {
                if k.mines == 0 { mark(k.cells, asMines: false) }
                if k.mines == k.cells.count { mark(k.cells, asMines: true) }
            }
            if changed { continue }

            // Subset rule: if A's cells sit inside B's, the leftover cells hold B - A mines.
            for a in constraints {
                for b in constraints where a.cells.count < b.cells.count && a.cells.isSubset(of: b.cells) {
                    let rest = b.cells.subtracting(a.cells)
                    let restMines = b.mines - a.mines
                    if restMines == 0 { mark(rest, asMines: false) }
                    if restMines == rest.count { mark(rest, asMines: true) }
                }
            }
            if changed { continue }

            // Global count: once every remaining mine is accounted for, the rest is safe (and vice versa).
            let unknown = board.allCoords.filter {
                board[$0].state != .revealed && !known.mines.contains($0) && !known.safe.contains($0)
            }
            let minesLeft = board.config.mines - known.mines.count
            if !unknown.isEmpty, minesLeft == 0 { mark(Set(unknown), asMines: false) }
            if !unknown.isEmpty, minesLeft == unknown.count { mark(Set(unknown), asMines: true) }
        }
        return known
    }

    /// A hidden, unflagged cell that is provably safe, preferring ones next to revealed numbers.
    public static func hint(for board: MinesweeperBoard) -> Coord? {
        guard board.status == .playing else { return nil }
        let safe = deduce(board).safe.filter { board[$0].state == .hidden }
        return safe.min { a, b in (a.row, a.col) < (b.row, b.col) }
    }

    /// Plays the board out from `opening` using deduction only.
    public static func isSolvableWithoutGuessing(_ board: MinesweeperBoard, opening: Coord) -> Bool {
        var sim = board
        sim.reveal(opening)
        while sim.status == .playing {
            let safe = deduce(sim).safe.filter { sim[$0].state != .revealed }
            if safe.isEmpty { return false }
            for c in safe {
                sim.reveal(c)
            }
        }
        return sim.status == .won
    }

    /// Generates a board with `opening` already revealed. With `requireNoGuess`, retries
    /// derived seeds until the deduction-only solver can finish it (or attempts run out,
    /// in which case the last layout is used so the caller always gets a board).
    public static func generateBoard(
        config: BoardConfig,
        seed: UInt64,
        opening: Coord,
        requireNoGuess: Bool,
        maxAttempts: Int = 300
    ) -> MinesweeperBoard {
        let mines = MineGenerator.layout(
            config: config,
            seed: seed,
            firstClick: opening,
            maxAttempts: requireNoGuess ? maxAttempts : 1
        ) { candidate in
            !requireNoGuess || isSolvableWithoutGuessing(
                MinesweeperBoard(config: config, seed: seed, mineIndices: candidate),
                opening: opening
            )
        }
        var board = MinesweeperBoard(config: config, seed: seed, mineIndices: mines)
        board.reveal(opening)
        return board
    }

    private static func buildConstraints(_ board: MinesweeperBoard, known: Deduction) -> [Constraint] {
        var result: [Constraint] = []
        for c in board.allCoords {
            let cell = board[c]
            guard cell.state == .revealed, !cell.isMine, cell.adjacentMines > 0 else { continue }
            var unknown = Set<Coord>()
            var mines = cell.adjacentMines
            for n in board.neighbors(of: c) where board[n].state != .revealed {
                if known.mines.contains(n) {
                    mines -= 1
                } else if !known.safe.contains(n) {
                    unknown.insert(n)
                }
            }
            if !unknown.isEmpty {
                result.append(Constraint(cells: unknown, mines: mines))
            }
        }
        return result
    }
}
