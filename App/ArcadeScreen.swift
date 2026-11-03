import MineRushCore
import SwiftUI

/// The Arcade tab: pick Rush, Dark Mine or Endless Depth, play, see the result.
struct ArcadeScreen: View {
    @ObservedObject var arcade: ArcadeViewModel

    var body: some View {
        if let kind = arcade.kind {
            session(kind)
        } else {
            chooser
        }
    }

    // MARK: Chooser

    private var chooser: some View {
        ScrollView {
            VStack(spacing: 14) {
                ForEach(ArcadeKind.allCases) { kind in
                    Button {
                        arcade.start(kind)
                    } label: {
                        HStack(spacing: 14) {
                            kind.icon.resizable().scaledToFit().frame(width: 64, height: 64)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(kind.title).font(.title3.bold())
                                Text(kind.tagline).font(.subheadline).multilineTextAlignment(.leading)
                                Text(arcade.best(for: kind)).font(.caption.bold()).foregroundStyle(Palette.coral)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "play.circle.fill").font(.largeTitle).foregroundStyle(Palette.turquoise)
                        }
                        .foregroundStyle(Palette.navy)
                        .padding()
                        .background(RoundedRectangle(cornerRadius: 18).fill(.white.opacity(0.85)))
                        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Palette.navy.opacity(0.12), lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                }
                Text("Arcade coins go to your Expedition bank. Power-ups can be used in Endless Depth.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.vertical, 8)
        }
    }

    // MARK: Session

    private func session(_ kind: ArcadeKind) -> some View {
        VStack(spacing: 10) {
            hud(kind)
            ZStack {
                if let snapshot = arcade.snapshot, !arcade.isStarting {
                    BoardView(host: arcade, snapshot: snapshot)
                } else {
                    ProgressView("Getting ready…").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if let result = arcade.result {
                    resultCard(result, kind: kind)
                }
            }
            .frame(maxHeight: .infinity)
            if kind == .endless { itemBar }
            controls(kind)
        }
    }

    @ViewBuilder
    private func hud(_ kind: ArcadeKind) -> some View {
        HStack(spacing: 12) {
            Button {
                arcade.leave()
            } label: {
                Image(systemName: "chevron.left").font(.headline.bold())
            }
            .accessibilityLabel(kind == .endless ? "End dive and leave" : "Leave")
            Text(kind.title).font(.headline.bold())
            if arcade.comboCount >= 2 {
                Text("COMBO x\(arcade.comboCount)")
                    .font(.caption.weight(.black))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(arcade.comboCount >= 10 ? Palette.coral : Palette.gold))
            }
            Spacer()
            switch kind {
            case .rush:
                if let rush = arcade.rush {
                    Text("\(rush.score)").font(.title3.weight(.black).monospacedDigit())
                }
            case .dark:
                if let dark = arcade.dark {
                    ArtLabel(text: "\(dark.board.minesRemaining)", image: Art.flag, size: 22)
                }
            case .endless:
                if let endless = arcade.endless {
                    Text("\(endless.depth)m").font(.title3.weight(.black).monospacedDigit())
                    HStack(spacing: 2) {
                        ForEach(0..<EndlessSession.lives, id: \.self) { i in
                            Image(systemName: i < endless.livesLeft ? "heart.fill" : "heart")
                                .foregroundStyle(Palette.coral)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(endless.livesLeft) lives")
                }
            }
        }
        .foregroundStyle(Palette.navy)
        if kind == .rush, let rush = arcade.rush {
            RushClock(timeLeft: rush.timeLeft)
        }
    }

    private var itemBar: some View {
        VStack(spacing: 4) {
            if let armed = arcade.armedItem {
                Text("Tap a tile to use \(armed.name)")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(Palette.coral))
            }
            HStack(spacing: 8) {
                ForEach(PowerUp.allCases.filter { $0 != .magnet }, id: \.self) { item in
                    let count = arcade.inventory[item]
                    Button {
                        arcade.useItem(item)
                    } label: {
                        ArtLabel(text: "\(count)", image: Art.powerUp(item), size: 34)
                            .font(.caption.bold().monospacedDigit())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(arcade.armedItem == item ? Palette.coral.opacity(0.35) : Color.white.opacity(0.75))
                            )
                            .opacity(count > 0 ? 1 : 0.45)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.navy)
                    .accessibilityLabel("\(item.name), \(count) left")
                }
            }
        }
    }

    private func controls(_ kind: ArcadeKind) -> some View {
        HStack(spacing: 10) {
            Button {
                arcade.flagMode.toggle()
            } label: {
                ArtLabel(text: arcade.flagMode ? "Flagging" : "Flag", image: Art.flag)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(arcade.flagMode ? Palette.coral : Palette.navy.opacity(0.6))

            Button {
                arcade.togglePause()
            } label: {
                Image(systemName: arcade.isPaused ? "play.fill" : "pause.fill")
            }
            .buttonStyle(.bordered)
            .disabled(!arcade.isRunning)
            .accessibilityLabel(arcade.isPaused ? "Resume" : "Pause")

            if kind == .endless {
                Button("Cash out") { arcade.cashOut() }
                    .buttonStyle(.bordered)
                    .disabled(!arcade.isRunning)
            }
        }
        .font(.headline)
        .tint(Palette.navy)
    }

    private func resultCard(_ result: ArcadeResult, kind: ArcadeKind) -> some View {
        VStack(spacing: 12) {
            Text(result.title).font(.system(size: 34, weight: .black, design: .rounded))
            if result.isBest {
                Text("NEW BEST!").font(.headline.weight(.black)).foregroundStyle(Palette.coral)
            }
            Text(result.detail).font(.headline).multilineTextAlignment(.center)
            if result.coins > 0 {
                ArtLabel(text: "+\(result.coins.compact)", image: Art.coin, size: 34)
                    .font(.title.weight(.black))
            }
            HStack(spacing: 12) {
                Button("Play again") { arcade.start(kind) }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.grass)
                Button("Modes") { arcade.leave() }
                    .buttonStyle(.bordered)
            }
            .font(.headline)
            .controlSize(.large)
        }
        .foregroundStyle(Palette.navy)
        .padding(24)
        .background(RoundedRectangle(cornerRadius: 24).fill(Palette.cream).shadow(radius: 16))
        .padding(24)
        .transition(.scale.combined(with: .opacity))
    }
}

extension ArcadeKind {
    var icon: Image {
        switch self {
        case .rush: return Art.explosion
        case .dark: return Art.helmet
        case .endless: return Art.pickaxe
        }
    }
}

/// Rush countdown bar: turquoise, gold under 20s, coral and pulsing under 10s.
private struct RushClock: View {
    let timeLeft: Double

    var body: some View {
        let fraction = min(timeLeft / RushSession.duration, 1)
        let color = timeLeft < 10 ? Palette.coral : timeLeft < 20 ? Palette.gold : Palette.turquoise
        HStack(spacing: 8) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.navy.opacity(0.15))
                    Capsule().fill(color).frame(width: geo.size.width * fraction)
                }
            }
            .frame(height: 14)
            Text(String(format: "%.1fs", timeLeft))
                .font(.headline.weight(.black).monospacedDigit())
                .foregroundStyle(color)
                .frame(width: 64, alignment: .trailing)
        }
        .scaleEffect(timeLeft < 10 && Int(timeLeft * 2) % 2 == 0 ? 1.03 : 1)
        .animation(.easeInOut(duration: 0.2), value: Int(timeLeft * 2))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Int(timeLeft)) seconds left")
    }
}
