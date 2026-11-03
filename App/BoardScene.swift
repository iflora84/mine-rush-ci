import MineRushCore
import SpriteKit
import UIKit

/// Everything the board needs to draw. Equality drives SwiftUI's `onChange`.
struct BoardSnapshot: Equatable {
    var board: MinesweeperBoard
    var treasures: Set<Coord> = []
    var scanned: Coord?
    var dimSatisfied = false

    static func == (a: BoardSnapshot, b: BoardSnapshot) -> Bool {
        a.board.seed == b.board.seed
            && a.board.config == b.board.config
            && a.board.status == b.board.status
            && a.board.cells == b.board.cells
            && a.treasures == b.treasures
            && a.scanned == b.scanned
            && a.dimSatisfied == b.dimSatisfied
    }
}

private extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }

    static let turquoise = UIColor(hex: 0x20B9AD)
    static let turquoiseDark = UIColor(hex: 0x148A81)
    static let turquoiseLight = UIColor(hex: 0x6FDCD2)
    static let cream = UIColor(hex: 0xFFF6E8)
    static let creamDark = UIColor(hex: 0xE9D9BC)
    static let navy = UIColor(hex: 0x24354A)
    static let gold = UIColor(hex: 0xFFC247)
    static let coral = UIColor(hex: 0xFF735A)

    static func number(_ n: Int) -> UIColor {
        switch n {
        case 1: return UIColor(red: 0.13, green: 0.42, blue: 0.85, alpha: 1)
        case 2: return UIColor(red: 0.16, green: 0.55, blue: 0.27, alpha: 1)
        case 3: return UIColor(red: 0.86, green: 0.25, blue: 0.20, alpha: 1)
        case 4: return UIColor(red: 0.38, green: 0.20, blue: 0.68, alpha: 1)
        case 5: return UIColor(red: 0.62, green: 0.32, blue: 0.10, alpha: 1)
        case 6: return UIColor(red: 0.05, green: 0.52, blue: 0.56, alpha: 1)
        case 7: return .navy
        default: return .gray
        }
    }
}

/// Tile faces drawn once per scene: a raised turquoise block and recessed cream cells.
private struct TileTextures {
    let hidden: SKTexture
    let pressed: SKTexture
    let revealed: SKTexture
    let treasure: SKTexture
    let triggered: SKTexture
    let scanRing: SKTexture
    let spark: SKTexture
    let flag = SKTexture(imageNamed: "icon_flag")
    let bomb = SKTexture(imageNamed: "icon_bomb")
    let explosion = SKTexture(imageNamed: "icon_explosion")
    let helmet = SKTexture(imageNamed: "icon_helmet")
    let chest = SKTexture(imageNamed: "icon_chest")
    let coin = SKTexture(imageNamed: "icon_coin")

    init(size s: CGFloat) {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: s, height: s))
        let inset: CGFloat = s * 0.04
        let radius = s * 0.2

        func raised(face: UIColor, edge: UIColor, highlight: UIColor, lift: CGFloat) -> SKTexture {
            SKTexture(image: renderer.image { _ in
                let outer = CGRect(x: 0, y: 0, width: s, height: s).insetBy(dx: inset, dy: inset)
                UIColor.navy.withAlphaComponent(0.85).setFill()
                UIBezierPath(roundedRect: outer, cornerRadius: radius).fill()
                let body = outer.insetBy(dx: s * 0.035, dy: s * 0.035)
                edge.setFill()
                UIBezierPath(roundedRect: body, cornerRadius: radius * 0.85).fill()
                var top = body
                top.size.height -= lift
                face.setFill()
                UIBezierPath(roundedRect: top, cornerRadius: radius * 0.85).fill()
                let shine = CGRect(x: top.minX + s * 0.12, y: top.minY + s * 0.08, width: top.width * 0.45, height: s * 0.09)
                highlight.withAlphaComponent(0.7).setFill()
                UIBezierPath(roundedRect: shine, cornerRadius: s * 0.045).fill()
            })
        }

        func recessed(fill: UIColor) -> SKTexture {
            SKTexture(image: renderer.image { _ in
                let outer = CGRect(x: 0, y: 0, width: s, height: s).insetBy(dx: inset, dy: inset)
                UIColor.creamDark.setFill()
                UIBezierPath(roundedRect: outer, cornerRadius: radius * 0.7).fill()
                var inner = outer.insetBy(dx: s * 0.03, dy: s * 0.03)
                inner.origin.y += s * 0.04
                inner.size.height -= s * 0.04
                fill.setFill()
                UIBezierPath(roundedRect: inner, cornerRadius: radius * 0.6).fill()
            })
        }

        hidden = raised(face: .turquoise, edge: .turquoiseDark, highlight: .turquoiseLight, lift: s * 0.1)
        pressed = raised(face: .turquoiseDark, edge: .turquoiseDark, highlight: .turquoise, lift: s * 0.03)
        revealed = recessed(fill: .cream)
        treasure = recessed(fill: UIColor(hex: 0xFFE3A0))
        triggered = recessed(fill: .coral)
        scanRing = SKTexture(image: renderer.image { _ in
            let ring = UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: s, height: s).insetBy(dx: s * 0.06, dy: s * 0.06),
                                    cornerRadius: radius)
            ring.lineWidth = s * 0.08
            UIColor.gold.setStroke()
            ring.stroke()
        })
        spark = SKTexture(image: UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).image { _ in
            UIColor.white.setFill()
            UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: 16, height: 16)).fill()
        })
    }
}

private final class TileNode: SKSpriteNode {
    let icon = SKSpriteNode()
    let label = SKLabelNode(fontNamed: "ArialRoundedMTBold")
    let ring = SKSpriteNode()

    init(side: CGFloat) {
        super.init(texture: nil, color: .clear, size: CGSize(width: side, height: side))
        icon.size = CGSize(width: side * 0.74, height: side * 0.74)
        icon.zPosition = 2
        label.fontSize = side * 0.58
        label.verticalAlignmentMode = .center
        label.horizontalAlignmentMode = .center
        label.zPosition = 2
        ring.size = size
        ring.zPosition = 3
        addChild(icon)
        addChild(label)
        addChild(ring)
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) is not used")
    }
}

/// The Minesweeper board in SpriteKit: pinch to zoom, drag to pan, tap to dig,
/// press and hold to flag. It diffs each new snapshot against the last one and
/// animates only what changed.
final class BoardScene: SKScene {
    var onTap: ((Coord) -> Void)?
    var onLongPress: ((Coord) -> Void)?
    var longPressDuration: TimeInterval = 0.3

    private let side: CGFloat = 64
    private let boardNode = SKNode()
    private let effects = SKNode()
    private let cam = SKCameraNode()
    private lazy var textures = TileTextures(size: side)
    private var tiles: [TileNode] = []
    private var rows = 0
    private var cols = 0
    private var snapshot: BoardSnapshot?
    private var lastTouched: Coord?

    private var minScale: CGFloat = 1
    private var maxScale: CGFloat = 1
    private var pinchStartScale: CGFloat = 1

    private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
    private lazy var pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))

    private var touchStart: CGPoint?
    private var touchCoord: Coord?
    private var pressWork: DispatchWorkItem?
    private var longPressFired = false

    private var feedback: FeedbackService { .shared }

    /// The size is a placeholder; `.resizeFill` follows the view.
    override init(size: CGSize) {
        super.init(size: size)
        scaleMode = .resizeFill
        backgroundColor = .clear
        anchorPoint = CGPoint(x: 0.5, y: 0.5)
        effects.zPosition = 10
        addChild(boardNode)
        addChild(effects)
        addChild(cam)
        camera = cam
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func didMove(to view: SKView) {
        view.isMultipleTouchEnabled = true
        pan.maximumNumberOfTouches = 2
        view.addGestureRecognizer(pan)
        view.addGestureRecognizer(pinch)
        fitCamera()
    }

    override func willMove(from view: SKView) {
        view.removeGestureRecognizer(pan)
        view.removeGestureRecognizer(pinch)
    }

    override func didChangeSize(_ oldSize: CGSize) {
        super.didChangeSize(oldSize)
        fitCamera()
    }

    // MARK: Snapshot

    func apply(_ new: BoardSnapshot) {
        let board = new.board
        let resized = board.rows != rows || board.cols != cols
        if resized { build(rows: board.rows, cols: board.cols) }
        let isNewBoard = resized
            || snapshot?.board.seed != board.seed
            || (snapshot?.board.status.isOver == true && !board.status.isOver)
        let old = isNewBoard ? nil : snapshot
        snapshot = new
        if isNewBoard {
            effects.removeAllChildren()
            boardNode.removeAllActions()
            boardNode.position = .zero
            fitCamera()
        }

        let motion = !feedback.reduceMotion
        var revealedCount = 0
        var flagsPlaced = 0
        var flagsRemoved = 0
        var newlyDefused: Coord?

        for coord in board.allCoords {
            let i = coord.row * cols + coord.col
            let tile = tiles[i]
            let cell = board[coord]
            render(tile, cell: cell, coord: coord, snapshot: new)

            guard let before = old?.board[coord] else {
                if isNewBoard && motion {
                    tile.setScale(0)
                    tile.run(.sequence([
                        .wait(forDuration: Double(coord.row) * 0.012 + Double(coord.col) * 0.008),
                        .scale(to: 1, duration: 0.18),
                    ]))
                } else {
                    tile.setScale(1)
                }
                continue
            }
            if before.state != .revealed, cell.state == .revealed, !cell.isMine {
                revealedCount += 1
                if motion { pop(tile, delay: rippleDelay(to: coord)) }
            }
            if before.state != .flagged, cell.state == .flagged {
                if cell.isDefused { newlyDefused = coord } else { flagsPlaced += 1 }
                if motion { dropIn(tile.icon) }
            }
            if before.state == .flagged, cell.state == .hidden { flagsRemoved += 1 }
        }

        guard let old else { return }

        if let defused = newlyDefused {
            feedback.play(.shield)
            feedback.haptic(.medium)
            if motion { pulse(at: defused) }
        }
        if new.scanned != nil, new.scanned != old.scanned {
            feedback.play(.scan)
        }

        switch (old.board.status, board.status) {
        case (_, .lost(let triggered)) where !old.board.status.isOver:
            explode(at: triggered, board: board, motion: motion)
        case (_, .won) where !old.board.status.isOver:
            celebrate(motion: motion)
        default:
            if revealedCount > 0 {
                feedback.play(.dig, volume: min(1, 0.55 + Float(revealedCount) * 0.03))
                feedback.haptic(.light)
                if motion, revealedCount > 6, let origin = lastTouched { dust(at: origin) }
            }
            if flagsPlaced > 0 {
                feedback.play(.flag)
                feedback.haptic(.medium)
            } else if flagsRemoved > 0 {
                feedback.play(.unflag)
            }
        }
    }

    private func build(rows: Int, cols: Int) {
        self.rows = rows
        self.cols = cols
        boardNode.removeAllChildren()
        tiles = (0..<(rows * cols)).map { i in
            let tile = TileNode(side: side)
            tile.position = position(of: Coord(row: i / cols, col: i % cols))
            boardNode.addChild(tile)
            return tile
        }
    }

    private func render(_ tile: TileNode, cell: Cell, coord: Coord, snapshot: BoardSnapshot) {
        let status = snapshot.board.status
        let showsMine = cell.isMine && !cell.isDefused && (cell.state == .revealed || status.isOver)
        var triggered = false
        if case .lost(let at) = status, at == coord { triggered = true }

        if triggered {
            tile.texture = textures.triggered
        } else if cell.state == .revealed || showsMine {
            tile.texture = snapshot.treasures.contains(coord) ? textures.treasure : textures.revealed
        } else {
            tile.texture = textures.hidden
        }

        tile.label.text = nil
        tile.icon.texture = nil
        tile.icon.alpha = 1
        if cell.isDefused {
            tile.icon.texture = textures.helmet
        } else if cell.state == .flagged {
            tile.icon.texture = textures.flag
            // A wrong flag fades once the game is over.
            if status.isOver && !cell.isMine { tile.icon.alpha = 0.4 }
        } else if showsMine {
            tile.icon.texture = triggered ? textures.explosion : textures.bomb
        } else if cell.state == .revealed, cell.adjacentMines > 0 {
            tile.label.text = "\(cell.adjacentMines)"
            tile.label.fontColor = .number(cell.adjacentMines)
            tile.label.alpha = snapshot.dimSatisfied && isSatisfied(coord, in: snapshot.board) ? 0.35 : 1
        } else if cell.state == .revealed, snapshot.treasures.contains(coord) {
            tile.icon.texture = textures.chest
        }
        tile.ring.texture = snapshot.scanned == coord ? textures.scanRing : nil
        tile.ring.isHidden = snapshot.scanned != coord

        tile.isAccessibilityElement = true
        tile.accessibilityLabel = accessibilityText(cell, coord: coord, treasure: snapshot.treasures.contains(coord))
    }

    private func isSatisfied(_ c: Coord, in board: MinesweeperBoard) -> Bool {
        let cell = board[c]
        guard cell.state == .revealed, cell.adjacentMines > 0 else { return false }
        return board.neighbors(of: c).filter { board[$0].state == .flagged }.count == cell.adjacentMines
    }

    private func accessibilityText(_ cell: Cell, coord: Coord, treasure: Bool) -> String {
        let position = "Row \(coord.row + 1), column \(coord.col + 1)"
        if cell.isDefused { return "\(position), defused mine" }
        switch cell.state {
        case .flagged: return "\(position), flagged"
        case .hidden: return "\(position), hidden"
        case .revealed:
            if cell.isMine { return "\(position), mine" }
            let extra = treasure ? ", treasure" : ""
            return cell.adjacentMines == 0 ? "\(position), empty\(extra)" : "\(position), \(cell.adjacentMines)\(extra)"
        }
    }

    // MARK: Effects

    private func rippleDelay(to c: Coord) -> TimeInterval {
        guard let o = lastTouched else { return 0 }
        let d = hypot(Double(c.row - o.row), Double(c.col - o.col))
        return min(d * 0.025, 0.45)
    }

    private func pop(_ tile: TileNode, delay: TimeInterval) {
        tile.removeAllActions()
        tile.setScale(0.7)
        let grow = SKAction.scale(to: 1.08, duration: 0.09)
        grow.timingMode = .easeOut
        let settle = SKAction.scale(to: 1, duration: 0.07)
        tile.run(.sequence([.wait(forDuration: delay), grow, settle]))
    }

    private func dropIn(_ node: SKNode) {
        node.removeAllActions()
        node.position = CGPoint(x: 0, y: side * 0.35)
        node.setScale(1.25)
        let fall = SKAction.group([.move(to: .zero, duration: 0.12), .scale(to: 1, duration: 0.12)])
        fall.timingMode = .easeIn
        node.run(.sequence([fall, .scaleY(to: 0.85, duration: 0.05), .scaleY(to: 1, duration: 0.08)]))
    }

    private func pulse(at c: Coord) {
        let tile = tiles[c.row * cols + c.col]
        tile.icon.run(.sequence([.scale(to: 1.4, duration: 0.12), .scale(to: 1, duration: 0.18)]))
        burst(at: tile.position, colors: [.turquoise, .gold], count: 14, speed: 160)
    }

    private func dust(at c: Coord) {
        burst(at: position(of: c), colors: [.cream, .gold, .creamDark], count: 18, speed: 120)
    }

    private func burst(at point: CGPoint, colors: [UIColor], count: Int, speed: CGFloat) {
        let emitter = SKEmitterNode()
        emitter.particleTexture = textures.spark
        emitter.particleBirthRate = CGFloat(count) * 40
        emitter.numParticlesToEmit = count
        emitter.particleLifetime = 0.6
        emitter.particleLifetimeRange = 0.3
        emitter.particleSpeed = speed
        emitter.particleSpeedRange = speed * 0.5
        emitter.emissionAngleRange = .pi * 2
        emitter.particleScale = 0.6
        emitter.particleScaleRange = 0.3
        emitter.particleScaleSpeed = -0.8
        emitter.particleAlphaSpeed = -1.4
        emitter.particleColorBlendFactor = 1
        emitter.particleColorSequence = SKKeyframeSequence(
            keyframeValues: colors,
            times: colors.indices.map { NSNumber(value: Double($0) / Double(max(colors.count - 1, 1))) }
        )
        emitter.position = point
        effects.addChild(emitter)
        emitter.run(.sequence([.wait(forDuration: 1.2), .removeFromParent()]))
    }

    private func explode(at c: Coord, board: MinesweeperBoard, motion: Bool) {
        feedback.play(.boom)
        feedback.haptic(.error)
        guard motion else { return }
        let tile = tiles[c.row * cols + c.col]
        tile.icon.setScale(0.3)
        tile.icon.run(.sequence([.scale(to: 1.5, duration: 0.15), .scale(to: 1.1, duration: 0.2)]))
        burst(at: tile.position, colors: [.gold, .coral, .navy], count: 60, speed: 320)
        let shake = SKAction.sequence((0..<8).map { i in
            SKAction.moveBy(x: i.isMultiple(of: 2) ? 9 : -9, y: i.isMultiple(of: 3) ? 6 : -6, duration: 0.035)
        } + [.move(to: .zero, duration: 0.05)])
        boardNode.run(shake)

        // The rest of the mines appear one by one, nearest first.
        let others = board.mineCoords.filter { $0 != c && !board[$0].isDefused && board[$0].state != .flagged }
            .sorted { hypot(Double($0.row - c.row), Double($0.col - c.col)) < hypot(Double($1.row - c.row), Double($1.col - c.col)) }
        for (n, mine) in others.enumerated() {
            let icon = tiles[mine.row * cols + mine.col].icon
            icon.alpha = 0
            icon.run(.sequence([.wait(forDuration: 0.35 + Double(n) * 0.04), .fadeIn(withDuration: 0.1)]))
        }
    }

    private func celebrate(motion: Bool) {
        feedback.play(.win)
        feedback.haptic(.success)
        run(.sequence([.wait(forDuration: 0.35), .run { [weak self] in self?.feedback.play(.coin) }]))
        guard motion, let view else { return }
        let origin = convertPoint(fromView: CGPoint(x: view.bounds.midX, y: view.bounds.maxY))
        for i in 0..<24 {
            let coin = SKSpriteNode(texture: textures.coin)
            let scale = cam.xScale
            coin.size = CGSize(width: 34 * scale, height: 34 * scale)
            coin.position = origin
            coin.zPosition = 20
            effects.addChild(coin)
            let dx = CGFloat.random(in: -180...180) * scale
            let dy = CGFloat.random(in: 280...520) * scale
            let rise = SKAction.moveBy(x: dx, y: dy, duration: 0.7)
            rise.timingMode = .easeOut
            let fall = SKAction.moveBy(x: dx * 0.3, y: -dy * 0.6, duration: 0.6)
            fall.timingMode = .easeIn
            coin.run(.sequence([
                .wait(forDuration: Double(i) * 0.025),
                .group([.sequence([rise, fall]), .rotate(byAngle: .pi * 4, duration: 1.3),
                        .sequence([.wait(forDuration: 0.9), .fadeOut(withDuration: 0.4)])]),
                .removeFromParent(),
            ]))
        }
    }

    // MARK: Camera

    private var boardSize: CGSize {
        CGSize(width: CGFloat(cols) * side, height: CGFloat(rows) * side)
    }

    private func position(of c: Coord) -> CGPoint {
        CGPoint(x: (CGFloat(c.col) - CGFloat(cols - 1) / 2) * side,
                y: (CGFloat(rows - 1) / 2 - CGFloat(c.row)) * side)
    }

    private func coord(at p: CGPoint) -> Coord? {
        let col = Int(floor((p.x + boardSize.width / 2) / side))
        let row = Int(floor((boardSize.height / 2 - p.y) / side))
        guard row >= 0, row < rows, col >= 0, col < cols else { return nil }
        return Coord(row: row, col: col)
    }

    /// Fits the board's width to the view; tall boards start at the top and pan.
    private func fitCamera() {
        guard rows > 0, size.width > 10, size.height > 10 else { return }
        let fitWidth = boardSize.width / (size.width - 8)
        let fitAll = max(fitWidth, boardSize.height / (size.height - 8))
        let start = boardSize.height / fitWidth <= size.height - 8 ? fitAll : fitWidth
        // Zooming in stops when tiles reach 56pt on screen.
        minScale = min(side / 56, start)
        maxScale = max(fitAll, start)
        cam.setScale(start)
        cam.position = CGPoint(x: 0, y: CGFloat.greatestFiniteMagnitude)
        clampCamera()
    }

    private func clampCamera() {
        let visible = CGSize(width: size.width * cam.xScale, height: size.height * cam.yScale)
        let spareX = max(0, (boardSize.width - visible.width) / 2 + side * 0.25)
        let spareY = max(0, (boardSize.height - visible.height) / 2 + side * 0.25)
        let x = boardSize.width <= visible.width ? 0 : min(max(cam.position.x, -spareX), spareX)
        let y = boardSize.height <= visible.height ? 0 : min(max(cam.position.y, -spareY), spareY)
        cam.position = CGPoint(x: x, y: y)
    }

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        guard let view else { return }
        let t = g.translation(in: view)
        cam.position = CGPoint(x: cam.position.x - t.x * cam.xScale, y: cam.position.y + t.y * cam.yScale)
        g.setTranslation(.zero, in: view)
        clampCamera()
    }

    @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
        guard let view else { return }
        if g.state == .began { pinchStartScale = cam.xScale }
        let focus = g.location(in: view)
        let before = convertPoint(fromView: focus)
        cam.setScale(min(max(pinchStartScale / g.scale, minScale), maxScale))
        let after = convertPoint(fromView: focus)
        cam.position = CGPoint(x: cam.position.x + before.x - after.x, y: cam.position.y + before.y - after.y)
        clampCamera()
    }

    // MARK: Touches (tap vs. hold; any drag hands over to the pan gesture)

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let view, let touch = touches.first, touchStart == nil, (event?.allTouches?.count ?? 1) == 1 else {
            cancelPress()
            return
        }
        touchStart = touch.location(in: view)
        touchCoord = coord(at: touch.location(in: boardNode))
        longPressFired = false
        if let c = touchCoord, snapshot?.board[c].state == .hidden {
            tiles[c.row * cols + c.col].texture = textures.pressed
        }
        let work = DispatchWorkItem { [weak self] in self?.firePress() }
        pressWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + longPressDuration, execute: work)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let view, let start = touchStart, let touch = touches.first else { return }
        let p = touch.location(in: view)
        if hypot(p.x - start.x, p.y - start.y) > 10 { cancelPress() }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard touchStart != nil else { return }
        pressWork?.cancel()
        let coord = touchCoord
        let fired = longPressFired
        resetTouch()
        if !fired, let coord {
            lastTouched = coord
            onTap?(coord)
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        cancelPress()
    }

    private func firePress() {
        guard let coord = touchCoord, touchStart != nil else { return }
        longPressFired = true
        lastTouched = coord
        restoreTouchedTile()
        onLongPress?(coord)
    }

    private func cancelPress() {
        pressWork?.cancel()
        resetTouch()
    }

    private func resetTouch() {
        restoreTouchedTile()
        pressWork = nil
        touchStart = nil
        touchCoord = nil
    }

    private func restoreTouchedTile() {
        guard let c = touchCoord, let snapshot else { return }
        render(tiles[c.row * cols + c.col], cell: snapshot.board[c], coord: c, snapshot: snapshot)
    }
}
