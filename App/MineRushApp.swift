import MineRushCore
import SwiftUI

@main
struct MineRushApp: App {
    // Built once here: App.init runs a single time, unlike a View's init.
    @StateObject private var store: PlayerStore
    @StateObject private var game: GameViewModel

    init() {
        let store = PlayerStore()
        _store = StateObject(wrappedValue: store)
        _game = StateObject(wrappedValue: GameViewModel(store: store))
    }

    var body: some Scene {
        WindowGroup {
            RootView(store: store, game: game)
        }
    }
}

enum Palette {
    static let turquoise = Color(red: 0x20 / 255, green: 0xB9 / 255, blue: 0xAD / 255)
    static let coral = Color(red: 1, green: 0x73 / 255, blue: 0x5A / 255)
    static let gold = Color(red: 1, green: 0xC2 / 255, blue: 0x47 / 255)
    static let cream = Color(red: 1, green: 0xF6 / 255, blue: 0xE8 / 255)
    static let navy = Color(red: 0x24 / 255, green: 0x35 / 255, blue: 0x4A / 255)
    static let grass = Color(red: 0x71 / 255, green: 0xBF / 255, blue: 0x63 / 255)

    /// Distinct hues plus the digit itself, so color is never the only cue.
    static func number(_ n: Int) -> Color {
        switch n {
        case 1: return Color(red: 0.13, green: 0.42, blue: 0.85)
        case 2: return Color(red: 0.16, green: 0.55, blue: 0.27)
        case 3: return Color(red: 0.86, green: 0.25, blue: 0.20)
        case 4: return Color(red: 0.38, green: 0.20, blue: 0.68)
        case 5: return Color(red: 0.62, green: 0.32, blue: 0.10)
        case 6: return Color(red: 0.05, green: 0.52, blue: 0.56)
        case 7: return navy
        default: return Color.gray
        }
    }

    static func zone(_ id: ZoneID) -> Color {
        switch id {
        case .sunnyQuarry: return grass
        case .crystalCaves: return turquoise
        case .volcanoVault: return coral
        }
    }
}

struct RootView: View {
    @ObservedObject var store: PlayerStore
    @ObservedObject var game: GameViewModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            GameScreen(game: game, store: store)
                .tabItem { Label("Play", systemImage: "hammer.fill") }
            UpgradesScreen(store: store)
                .tabItem { Label("Upgrades", systemImage: "arrow.up.circle.fill") }
            WorkersScreen(store: store)
                .tabItem { Label("Workers", systemImage: "person.3.fill") }
        }
        .tint(Palette.navy)
        // Here rather than on a tab: tab views re-run .task on every tab switch.
        .task { game.start() }
        .sheet(isPresented: Binding(
            get: { store.profile.pendingOffline != nil },
            set: { if !$0 { store.claimOfflineReward() } }
        )) {
            if let reward = store.profile.pendingOffline {
                WelcomeBackView(
                    reward: reward,
                    crew: WorkerID.allCases.filter { store.profile.workers[$0] > 0 }
                ) { store.claimOfflineReward() }
                    .presentationDetents([.medium])
                    .interactiveDismissDisabled()
            }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active {
                store.becameActive()
            } else {
                game.pause()
                store.resignedActive()
            }
        }
    }
}

struct GameScreen: View {
    @ObservedObject var game: GameViewModel
    @ObservedObject var store: PlayerStore
    @State private var showZones = false
    @State private var confirmNewSite = false

    var body: some View {
        VStack(spacing: 10) {
            CurrencyBar(profile: store.profile)
            Picker("Mode", selection: $game.mode) {
                ForEach(PlayMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            modeHeader
            statusRow

            ZStack {
                if let board = game.board, !game.isGenerating {
                    BoardView(game: game, board: board)
                } else {
                    ProgressView("Surveying the site…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxHeight: .infinity)
            .overlay(alignment: .top) { feedback }

            controls
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Palette.cream.ignoresSafeArea())
        .sheet(isPresented: $showZones) {
            ZoneMapView(store: store) { zone in
                showZones = false
                if zone != store.profile.activeRun?.zone || store.profile.activeRun?.board.status.isOver != false {
                    game.startSite(in: zone)
                }
            }
        }
        .alert("Leave this site?", isPresented: $confirmNewSite) {
            Button("New site", role: .destructive) { game.restart() }
            Button("Keep digging", role: .cancel) {}
        } message: {
            Text("Unfinished sites end your win streak. Coins you've earned are kept.")
        }
    }

    // MARK: Header

    @ViewBuilder
    private var modeHeader: some View {
        switch game.mode {
        case .expedition:
            let zone = ZoneCatalog.definition(game.run?.zone ?? store.selectedZone)
            Button {
                showZones = true
            } label: {
                HStack {
                    Circle().fill(Palette.zone(zone.id)).frame(width: 12, height: 12)
                    Text(zone.name).font(.headline)
                    Text("x\(Double(zone.rewardMultiplierPercent) / 100, specifier: "%g") coins")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    Text("Streak \(store.profile.expeditionStreak)")
                        .font(.subheadline.bold()).foregroundStyle(Palette.coral)
                    Image(systemName: "map.fill")
                }
                .foregroundStyle(Palette.navy)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.7)))
            }
        case .classic:
            Picker("Difficulty", selection: $game.difficulty) {
                ForEach(Difficulty.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
        case .daily:
            HStack {
                Text("Daily \(game.todayKey)").font(.headline)
                Spacer()
                Text(game.dailyDoneToday ? "Done today ✓" : "Streak \(store.profile.daily.streak)")
                    .font(.subheadline.bold())
                    .foregroundStyle(game.dailyDoneToday ? Palette.grass : Palette.coral)
            }
            .foregroundStyle(Palette.navy)
        }
    }

    private var statusRow: some View {
        HStack {
            Label("\(game.board?.minesRemaining ?? 0)", systemImage: "flag.fill")
                .foregroundStyle(Palette.coral)
            Spacer()
            Text(statusText)
                .font(.headline)
                .foregroundStyle(Palette.navy)
            Spacer()
            Label(String(format: "%d:%02d", game.elapsedSeconds / 60, game.elapsedSeconds % 60), systemImage: "timer")
                .foregroundStyle(Palette.navy)
                .monospacedDigit()
        }
        .font(.title3.bold())
    }

    private var statusText: String {
        guard let status = game.board?.status else { return "Surveying…" }
        switch status {
        case .ready: return "Tap to dig"
        case .playing: return game.isPaused ? "Paused" : "Digging…"
        case .won: return "Site cleared!"
        case .lost: return "Boom!"
        }
    }

    @ViewBuilder
    private var feedback: some View {
        VStack(spacing: 6) {
            if let pop = game.pop {
                Text(pop.text)
                    .font(.headline.bold())
                    .foregroundStyle(Palette.navy)
                    .padding(.horizontal, 12).padding(.vertical, 4)
                    .background(Capsule().fill(Palette.gold))
                    .id(pop.id)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let message = game.message {
                Text(message)
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(Palette.navy.opacity(0.9)))
                    .onTapGesture { game.clearMessage() }
            }
        }
        .padding(.top, 6)
        .animation(.spring(duration: 0.3), value: game.pop)
        .animation(.spring(duration: 0.3), value: game.message)
        .allowsHitTesting(game.message != nil)
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 10) {
            Button {
                game.flagMode.toggle()
            } label: {
                Label(game.flagMode ? "Flagging" : "Flag", systemImage: "flag")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(game.flagMode ? Palette.coral : Palette.navy.opacity(0.6))

            if let run = game.run, run.scannerCharges > 0 || store.profile.upgrades[.mineScanner] > 0 {
                Button {
                    game.scan()
                } label: {
                    Label("\(run.scannerCharges)", systemImage: "dot.radiowaves.left.and.right")
                }
                .buttonStyle(.bordered)
                .disabled(run.scannerCharges == 0 || run.board.status != .playing)
                .accessibilityLabel("Mine scanner, \(run.scannerCharges) left")
            }

            if let run = game.run, run.helmetCharges > 0 {
                Label("\(run.helmetCharges)", systemImage: "shield.fill")
                    .foregroundStyle(Palette.turquoise)
                    .accessibilityLabel("Safety helmet, \(run.helmetCharges) left")
            }

            Button {
                game.togglePause()
            } label: {
                Image(systemName: game.isPaused ? "play.fill" : "pause.fill")
            }
            .buttonStyle(.bordered)
            .disabled(game.board?.status != .playing)
            .accessibilityLabel(game.isPaused ? "Resume" : "Pause")

            Button {
                if game.mode == .expedition, game.isRunInProgress {
                    confirmNewSite = true
                } else {
                    game.restart()
                }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(game.isGenerating)
            .accessibilityLabel(game.mode == .expedition ? "New site" : "Restart")
        }
        .font(.headline)
        .tint(Palette.navy)
    }
}

struct BoardView: View {
    @ObservedObject var game: GameViewModel
    let board: MinesweeperBoard

    var body: some View {
        GeometryReader { geo in
            let size = min(44, floor(geo.size.width / CGFloat(board.cols)))
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    ForEach(0..<board.rows, id: \.self) { row in
                        HStack(spacing: 0) {
                            ForEach(0..<board.cols, id: \.self) { col in
                                let coord = Coord(row: row, col: col)
                                TileView(
                                    cell: board[coord],
                                    coord: coord,
                                    status: board.status,
                                    size: size,
                                    isTreasure: game.isTreasure(coord),
                                    isScanned: game.scannedCell == coord,
                                    isSatisfied: game.smartFlagsLevel > 0 && isSatisfied(coord)
                                )
                                .onTapGesture { game.tap(coord) }
                                .onLongPressGesture(minimumDuration: game.longPressDuration) { game.longPress(coord) }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .overlay {
                if game.isPaused {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Palette.navy.opacity(0.92))
                        .overlay(Text("Paused").font(.largeTitle.bold()).foregroundStyle(.white))
                        .onTapGesture { game.togglePause() }
                }
            }
        }
    }

    /// A revealed number whose flags already match it (Smart Flags dims these).
    private func isSatisfied(_ c: Coord) -> Bool {
        let cell = board[c]
        guard cell.state == .revealed, cell.adjacentMines > 0 else { return false }
        return board.neighbors(of: c).filter { board[$0].state == .flagged }.count == cell.adjacentMines
    }
}

struct TileView: View {
    let cell: Cell
    let coord: Coord
    let status: GameStatus
    let size: CGFloat
    var isTreasure = false
    var isScanned = false
    var isSatisfied = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.18)
                .fill(background)
            if isHiddenLook {
                RoundedRectangle(cornerRadius: size * 0.18)
                    .strokeBorder(Color.white.opacity(0.35), lineWidth: 2)
                    .padding(1)
            }
            if isScanned {
                RoundedRectangle(cornerRadius: size * 0.18)
                    .strokeBorder(Palette.gold, lineWidth: 3)
            }
            content
        }
        .frame(width: size - 2, height: size - 2)
        .frame(width: size, height: size)
        .contentShape(Rectangle())
        .accessibilityElement()
        .accessibilityLabel(accessibilityText)
    }

    private var isHiddenLook: Bool {
        cell.state != .revealed && !(status.isOver && cell.isMine && !cell.isDefused)
    }

    private var background: Color {
        if case .lost(let triggered) = status, triggered == coord { return Palette.coral }
        if isTreasure { return Palette.gold.opacity(0.55) }
        return isHiddenLook ? Palette.turquoise : Palette.cream.opacity(0.6)
    }

    @ViewBuilder
    private var content: some View {
        let font = Font.system(size: size * 0.55, weight: .black, design: .rounded)
        if cell.isDefused {
            Image(systemName: "shield.lefthalf.filled").font(font).foregroundStyle(Palette.navy)
        } else if cell.state == .flagged {
            if status.isOver && !cell.isMine {
                Image(systemName: "xmark").font(font).foregroundStyle(Palette.coral)
            } else {
                Image(systemName: "flag.fill").font(font.weight(.bold)).foregroundStyle(Palette.coral)
            }
        } else if cell.isMine && (cell.state == .revealed || status.isOver) {
            Text("💣").font(.system(size: size * 0.6))
        } else if cell.state == .revealed && cell.adjacentMines > 0 {
            Text("\(cell.adjacentMines)")
                .font(font)
                .foregroundStyle(Palette.number(cell.adjacentMines))
                .opacity(isSatisfied ? 0.35 : 1)
        } else if isTreasure {
            Text("💎").font(.system(size: size * 0.5))
        }
    }

    private var accessibilityText: String {
        let position = "Row \(coord.row + 1), column \(coord.col + 1)"
        if cell.isDefused { return "\(position), defused mine" }
        switch cell.state {
        case .flagged: return "\(position), flagged"
        case .hidden: return "\(position), hidden"
        case .revealed:
            if cell.isMine { return "\(position), mine" }
            let treasure = isTreasure ? ", treasure" : ""
            return cell.adjacentMines == 0 ? "\(position), empty\(treasure)" : "\(position), \(cell.adjacentMines)\(treasure)"
        }
    }
}
