import Combine
import MineRushCore
import SwiftUI

enum FXKind: Equatable {
    case combo(tier: Int, count: Int)
    case blast(Coord)
    case radar(center: Coord, mines: [Coord])
    case xray(row: Int)
    case magnet
    case bigOpen(Int)
    case bossIntro(BossDefinitionRef)
    case bossDefeated(String)
    case drops([PowerUp])
    /// Rush: seconds gained or lost.
    case timeBonus(Double)
    /// Endless: lives left after a hit.
    case lifeLost(Int)
    case newBest
}

/// `BossDefinition` lives in the core package and isn't Equatable; this is the slice the effects need.
struct BossDefinitionRef: Equatable {
    let zone: ZoneID
    let name: String
    let title: String

    init(_ boss: BossDefinition) {
        zone = boss.zone
        name = boss.name
        title = boss.title
    }
}

struct FXEvent: Identifiable, Equatable {
    let id = UUID()
    let kind: FXKind

    init(_ kind: FXKind) {
        self.kind = kind
    }
}

/// Full-screen effects drawn over the whole Play screen: combo banners, flashes,
/// shockwaves, the boss entrance, confetti and item drops. Board-level effects
/// (explosions on tiles, laser, radar markers) live in BoardScene.
struct FXOverlay: View {
    let events: PassthroughSubject<FXEvent, Never>
    var magnetSecondsLeft = 0
    @ObservedObject private var feedback = FeedbackService.shared

    @State private var banner: Banner?
    @State private var flash: Color?
    @State private var rings: [Ring] = []
    @State private var confetti: ConfettiBurst?
    @State private var boss: BossDefinitionRef?
    @State private var toast: [PowerUp] = []

    private struct Banner: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let subtitle: String?
        let colors: [Color]
        let size: CGFloat
    }

    private struct Ring: Identifiable, Equatable {
        let id = UUID()
        let color: Color
        let delay: Double
    }

    var body: some View {
        ZStack {
            if magnetSecondsLeft > 0 {
                MagnetGlow(secondsLeft: magnetSecondsLeft, animated: !feedback.reduceMotion)
            }
            if let flash {
                flash.ignoresSafeArea().transition(.opacity)
            }
            ForEach(rings) { ring in
                ShockRing(color: ring.color, delay: ring.delay)
            }
            if let confetti {
                ConfettiView(burst: confetti).ignoresSafeArea()
            }
            if let banner {
                BannerView(banner: banner).id(banner.id)
                    .transition(.scale(scale: 0.3).combined(with: .opacity))
            }
            if !toast.isEmpty {
                VStack {
                    Spacer()
                    DropToast(items: toast).padding(.bottom, 150)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let boss {
                BossIntro(boss: boss) { withAnimation { self.boss = nil } }
                    .transition(.opacity)
            }
        }
        .allowsHitTesting(boss != nil)
        .onReceive(events) { handle($0) }
    }

    private var motion: Bool { !feedback.reduceMotion }

    private func handle(_ event: FXEvent) {
        switch event.kind {
        case .combo(let tier, let count):
            let palettes: [[Color]] = [[Palette.gold], [Palette.gold, Palette.coral], [Palette.coral, .pink, Palette.gold],
                                       [.purple, Palette.coral, Palette.gold, Palette.turquoise]]
            let words = ["", "COMBO!", "SUPER COMBO!", "INSANE!!"]
            show(Banner(title: words[min(tier, 3)], subtitle: "x\(count)  ·  +\(ComboTracker.tierBonusPercent[min(tier, 3)])% coins",
                        colors: palettes[min(tier, 3)], size: 44 + CGFloat(tier) * 8), for: 1.1)
            flashScreen(palettes[min(tier, 3)][0].opacity(0.22 + Double(tier) * 0.06))
            addRings(color: palettes[min(tier, 3)].last ?? Palette.gold, count: tier)
            if tier >= 3 { burstConfetti() }
        case .blast:
            flashScreen(Color.white.opacity(0.55))
            addRings(color: Palette.coral, count: 2)
            show(Banner(title: "KABOOM!", subtitle: nil, colors: [Palette.coral, Palette.gold], size: 52), for: 0.8)
        case .radar(_, let mines):
            addRings(color: Palette.turquoise, count: 3)
            show(Banner(title: "RADAR PULSE", subtitle: "\(mines.count) mine\(mines.count == 1 ? "" : "s") nearby, remember them!",
                        colors: [Palette.turquoise], size: 34), for: 1.4)
        case .xray:
            flashScreen(Palette.turquoise.opacity(0.25))
            show(Banner(title: "X-RAY!", subtitle: "Row scanned", colors: [Palette.turquoise, .white], size: 40), for: 0.9)
        case .magnet:
            show(Banner(title: "COIN MAGNET", subtitle: "Double coins for 30s", colors: [Palette.gold, Palette.coral], size: 38), for: 1.2)
            flashScreen(Palette.gold.opacity(0.3))
        case .bigOpen(let count):
            addRings(color: Palette.gold, count: 1)
            show(Banner(title: "MEGA DIG!", subtitle: "\(count) tiles", colors: [Palette.gold, Palette.grass], size: 40), for: 0.9)
        case .bossIntro(let ref):
            withAnimation(.easeOut(duration: 0.3)) { boss = ref }
        case .bossDefeated(let name):
            flashScreen(Palette.gold.opacity(0.5))
            addRings(color: Palette.gold, count: 3)
            burstConfetti()
            show(Banner(title: "BOSS DEFEATED!", subtitle: "\(name) is down. x\(BossCatalog.rewardMultiplier) reward!",
                        colors: [Palette.gold, Palette.coral, .purple], size: 46), for: 2.2)
        case .drops(let items):
            withAnimation(.spring(duration: 0.4)) { toast = items }
            later(2.4) { withAnimation { toast = [] } }
        case .timeBonus(let seconds):
            let gained = seconds > 0
            show(Banner(title: gained ? "+\(Int(seconds))s" : "\(Int(seconds))s", subtitle: gained ? "Board cleared!" : "Boom! New board",
                        colors: gained ? [Palette.grass, Palette.gold] : [Palette.coral, .red], size: 56), for: 0.8)
            flashScreen((gained ? Palette.grass : Palette.coral).opacity(0.3))
            if gained { addRings(color: Palette.grass, count: 1) }
        case .lifeLost(let left):
            flashScreen(Palette.coral.opacity(0.45))
            show(Banner(title: "OUCH!", subtitle: "\(left) \(left == 1 ? "life" : "lives") left",
                        colors: [Palette.coral, .red], size: 48), for: 1.0)
        case .newBest:
            burstConfetti()
            addRings(color: Palette.gold, count: 2)
            show(Banner(title: "NEW BEST!", subtitle: nil, colors: [Palette.gold, .purple, Palette.coral], size: 50), for: 1.6)
        }
    }

    private func show(_ next: Banner, for seconds: Double) {
        withAnimation(.spring(duration: 0.35, bounce: 0.5)) { banner = next }
        later(seconds) {
            if banner?.id == next.id { withAnimation(.easeIn(duration: 0.25)) { banner = nil } }
        }
    }

    private func flashScreen(_ color: Color) {
        guard motion else { return }
        flash = color
        withAnimation(.easeOut(duration: 0.45)) { flash = nil }
    }

    private func addRings(color: Color, count: Int) {
        guard motion, count > 0 else { return }
        let new = (0..<count).map { Ring(color: color, delay: Double($0) * 0.15) }
        rings += new
        later(1.4) { rings.removeAll { ring in new.contains(ring) } }
    }

    private func burstConfetti() {
        guard motion else { return }
        let burst = ConfettiBurst()
        confetti = burst
        later(2.6) { if confetti?.id == burst.id { confetti = nil } }
    }

    private func later(_ seconds: Double, _ work: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            work()
        }
    }

    // MARK: Pieces

    private struct BannerView: View {
        let banner: Banner
        @State private var wobble = false

        var body: some View {
            VStack(spacing: 4) {
                Text(banner.title)
                    .font(.system(size: banner.size, weight: .black, design: .rounded))
                    .foregroundStyle(LinearGradient(colors: banner.colors.count > 1 ? banner.colors : banner.colors + [.white],
                                                    startPoint: .topLeading, endPoint: .bottomTrailing))
                    .shadow(color: Palette.navy, radius: 0, x: 3, y: 3)
                    .shadow(color: .black.opacity(0.35), radius: 8)
                if let subtitle = banner.subtitle {
                    Text(subtitle)
                        .font(.headline.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(Capsule().fill(Palette.navy.opacity(0.85)))
                }
            }
            .rotationEffect(.degrees(wobble ? -4 : 4))
            .onAppear {
                withAnimation(.easeInOut(duration: 0.12).repeatCount(5, autoreverses: true)) { wobble = true }
            }
            .multilineTextAlignment(.center)
            .padding()
        }
    }

    private struct ShockRing: View {
        let color: Color
        let delay: Double
        @State private var expanded = false

        var body: some View {
            Circle()
                .strokeBorder(color, lineWidth: expanded ? 2 : 18)
                .scaleEffect(expanded ? 2.6 : 0.05)
                .opacity(expanded ? 0 : 0.9)
                .frame(width: 320, height: 320)
                .onAppear {
                    withAnimation(.easeOut(duration: 0.9).delay(delay)) { expanded = true }
                }
        }
    }

    private struct MagnetGlow: View {
        let secondsLeft: Int
        let animated: Bool
        @State private var pulse = false

        var body: some View {
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 36)
                    .strokeBorder(
                        LinearGradient(colors: [Palette.gold, Palette.coral, Palette.gold], startPoint: .top, endPoint: .bottom),
                        lineWidth: pulse ? 14 : 7
                    )
                    .blur(radius: 6)
                    .opacity(pulse ? 0.95 : 0.55)
                    .ignoresSafeArea()
                ArtLabel(text: "x2  \(secondsLeft)s", image: Art.magnet, size: 22)
                    .font(.headline.bold().monospacedDigit())
                    .foregroundStyle(Palette.navy)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Capsule().fill(Palette.gold))
                    .padding(.top, 4)
            }
            .onAppear {
                guard animated else { return }
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { pulse = true }
            }
        }
    }

    private struct DropToast: View {
        let items: [PowerUp]

        var body: some View {
            HStack(spacing: 10) {
                Text("Found:").font(.headline.bold())
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Art.powerUp(item).resizable().scaledToFit().frame(width: 38, height: 38)
                }
            }
            .foregroundStyle(Palette.navy)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(Capsule().fill(Palette.cream).shadow(radius: 8))
            .overlay(Capsule().strokeBorder(Palette.gold, lineWidth: 3))
        }
    }

    private struct BossIntro: View {
        let boss: BossDefinitionRef
        let onDismiss: () -> Void
        @State private var entered = false

        var body: some View {
            ZStack {
                LinearGradient(colors: [.black.opacity(0.85), Palette.zone(boss.zone).opacity(0.6), .black.opacity(0.85)],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
                VStack(spacing: 10) {
                    Text("BOSS SITE")
                        .font(.system(size: 22, weight: .heavy, design: .rounded))
                        .tracking(6)
                        .foregroundStyle(Palette.coral)
                    Art.boss(boss.zone)
                        .resizable().scaledToFit()
                        .frame(maxHeight: 300)
                        .scaleEffect(entered ? 1 : 0.4)
                        .offset(y: entered ? 0 : 200)
                        .shadow(color: Palette.coral.opacity(0.7), radius: 30)
                    Text(boss.name)
                        .font(.system(size: 44, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                        .shadow(color: Palette.navy, radius: 0, x: 3, y: 3)
                    Text(boss.title).font(.title3.bold()).foregroundStyle(Palette.gold)
                    Text("Dig every safe tile to drain its health.\nx\(BossCatalog.rewardMultiplier) reward and \(BossCatalog.itemDrops) power-ups!")
                        .font(.subheadline.bold())
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.9))
                    Text("Tap to fight").font(.footnote).foregroundStyle(.white.opacity(0.6)).padding(.top, 8)
                }
                .padding()
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onDismiss)
            .onAppear {
                withAnimation(.spring(duration: 0.6, bounce: 0.45)) { entered = true }
                FeedbackService.shared.play(.boom, volume: 0.6)
                FeedbackService.shared.haptic(.error)
            }
        }
    }
}

// MARK: - Confetti

struct ConfettiBurst: Equatable {
    let id = UUID()
    let start = Date()
}

private struct ConfettiView: View {
    let burst: ConfettiBurst

    private struct Piece {
        let x: Double, speed: Double, drift: Double, spin: Double, size: Double, color: Color
    }

    // State, so the pieces aren't re-rolled every time the parent redraws.
    @State private var pieces: [Piece] = (0..<90).map { _ in
        Piece(x: .random(in: 0...1), speed: .random(in: 380...760), drift: .random(in: -80...80),
              spin: .random(in: 2...9), size: .random(in: 7...14),
              color: [Palette.gold, Palette.coral, Palette.turquoise, Palette.grass, .white, .purple].randomElement()!)
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let t = timeline.date.timeIntervalSince(burst.start)
                for p in pieces {
                    let y = -20 + p.speed * t
                    let x = p.x * size.width + p.drift * sin(t * 2 + p.spin)
                    guard y < size.height + 20 else { continue }
                    var piece = context
                    piece.translateBy(x: x, y: y)
                    piece.rotate(by: .radians(t * p.spin))
                    piece.fill(Path(CGRect(x: -p.size / 2, y: -p.size / 4, width: p.size, height: p.size / 2)),
                               with: .color(p.color))
                }
            }
        }
        .allowsHitTesting(false)
    }
}
