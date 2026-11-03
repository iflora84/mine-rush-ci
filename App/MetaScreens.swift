import MineRushCore
import SwiftUI
import UIKit

struct CurrencyBar: View {
    let profile: PlayerProfile

    var body: some View {
        HStack(spacing: 14) {
            ArtLabel(text: profile.ledger.coins.compact, image: Art.coin, size: 26)
                .foregroundStyle(Palette.navy)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(profile.ledger.coins) coins")
            ArtLabel(text: profile.ledger.gems.compact, image: Art.gem, size: 24)
                .foregroundStyle(Palette.navy)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(profile.ledger.gems) gems")
            Spacer()
            if profile.teamRateMilli > 0 {
                Text("+\(rateText(profile.teamRateMilli))/s")
                    .font(.subheadline.bold())
                    .foregroundStyle(Palette.grass)
            }
        }
        .font(.title3.bold())
        .monospacedDigit()
    }
}

/// Milli-coins per second as "2", "12.5", "1.2K".
func rateText(_ milli: Int) -> String {
    if milli >= 1_000_000 { return (milli / 1000).compact }
    let value = Double(milli) / 1000
    return value == value.rounded() ? "\(Int(value))" : String(format: "%.1f", value)
}

private func purchaseMessage(_ outcome: PurchaseOutcome) -> String? {
    switch outcome {
    case .purchased: return nil
    case .maxed: return "Already at max level."
    case .locked(let reason): return reason
    case .insufficientFunds(let cost): return "Need \(cost.compact) coins."
    }
}

// MARK: - Upgrades

struct UpgradesScreen: View {
    @ObservedObject var store: PlayerStore
    @State private var notice: String?
    @State private var bumped: UpgradeID?

    var body: some View {
        NavigationStack {
            List {
                ForEach(UpgradeCategory.allCases, id: \.self) { category in
                    Section(category.title) {
                        ForEach(UpgradeCatalog.all.filter { $0.category == category }, id: \.id) { def in
                            row(def)
                        }
                    }
                }
            }
            .safeAreaInset(edge: .top) {
                CurrencyBar(profile: store.profile)
                    .padding(.horizontal, 20).padding(.vertical, 8)
                    .background(.bar)
            }
            .navigationTitle("Upgrades")
            .alert(notice ?? "", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
                Button("OK", role: .cancel) {}
            }
        }
    }

    private func row(_ def: UpgradeDefinition) -> some View {
        let levels = store.profile.upgrades
        let level = levels[def.id]
        let cost = UpgradeService.nextCost(def.id, levels: levels)
        let lock = UpgradeService.lockReason(def.id, levels: levels)
        let affordable = cost.map { store.profile.ledger.coins >= $0 } ?? false

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Art.upgrade(def.id).resizable().scaledToFit().frame(width: 34, height: 34)
                Text(def.name).font(.headline)
                Spacer()
                Text("Lv \(level)/\(def.maxLevel)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(def.summary).font(.subheadline).foregroundStyle(.secondary)
            HStack {
                Text(def.effectDescription(atLevel: level))
                if level < def.maxLevel {
                    Image(systemName: "arrow.right").font(.caption)
                    Text(def.effectDescription(atLevel: level + 1)).foregroundStyle(Palette.grass)
                }
                Spacer()
                if let cost {
                    Button {
                        let outcome = store.buyUpgrade(def.id)
                        notice = purchaseMessage(outcome)
                        if notice == nil {
                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                            bumped = def.id
                        }
                    } label: {
                        ArtLabel(text: cost.compact, image: Art.coin, size: 18)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(affordable && lock == nil ? Palette.gold : .gray)
                    .foregroundStyle(Palette.navy)
                } else {
                    Text("MAX").font(.subheadline.bold()).foregroundStyle(Palette.grass)
                }
            }
            .font(.subheadline.bold())
            if let lock {
                Label(lock, systemImage: "lock.fill").font(.caption).foregroundStyle(Palette.coral)
            }
            if def.category == .puzzleTools, let run = store.profile.activeRun, !run.board.status.isOver {
                Text("Applies from your next site.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .scaleEffect(bumped == def.id ? 1.03 : 1)
        .animation(.spring(duration: 0.25, bounce: 0.6), value: bumped)
        .onChange(of: bumped) { _, value in
            guard value == def.id else { return }
            Task {
                try? await Task.sleep(for: .milliseconds(250))
                if bumped == def.id { bumped = nil }
            }
        }
    }
}

// MARK: - Workers

struct WorkersScreen: View {
    @ObservedObject var store: PlayerStore
    @State private var notice: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Team income", value: "\(rateText(store.profile.teamRateMilli)) coins/s")
                    LabeledContent("Offline storage", value: "\(store.profile.offlineCapHours) hours")
                } footer: {
                    Text("Your team keeps mining while you're away, up to the storage limit.")
                }

                Section("Crew") {
                    ForEach(WorkerCatalog.all, id: \.id) { def in
                        row(def)
                    }
                }
            }
            .safeAreaInset(edge: .top) {
                CurrencyBar(profile: store.profile)
                    .padding(.horizontal, 20).padding(.vertical, 8)
                    .background(.bar)
            }
            .navigationTitle("Workers")
            .alert(notice ?? "", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
                Button("OK", role: .cancel) {}
            }
        }
    }

    private func row(_ def: WorkerDefinition) -> some View {
        let profile = store.profile
        let level = profile.workers[def.id]
        let unlocked = WorkerService.isUnlocked(def.id, profile: profile)
        let cost = WorkerService.nextCost(def.id, workers: profile.workers)
        let rate = WorkerService.rateMilli(def.id, workers: profile.workers, upgrades: profile.upgrades)

        return HStack(spacing: 12) {
            WorkerPortrait(worker: def.id, size: 54)
                .saturation(unlocked ? 1 : 0)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(def.name).font(.headline)
                    Text(def.role).font(.caption).foregroundStyle(.secondary)
                }
                if !unlocked {
                    Label(def.unlockText, systemImage: "lock.fill").font(.caption).foregroundStyle(Palette.coral)
                } else if level == 0 {
                    Text(perkText(def.id)).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Lv \(level) · \(rateText(rate)) coins/s").font(.subheadline.monospacedDigit())
                    Text(perkText(def.id)).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                notice = purchaseMessage(store.hireOrUpgrade(def.id))
                if notice == nil { UINotificationFeedbackGenerator().notificationOccurred(.success) }
            } label: {
                VStack(spacing: 2) {
                    Text(level == 0 ? "Hire" : "Train").font(.caption.bold())
                    Text(cost.compact).font(.subheadline.bold().monospacedDigit())
                }
                .frame(minWidth: 56)
            }
            .buttonStyle(.borderedProminent)
            .tint(unlocked && profile.ledger.coins >= cost ? Palette.gold : .gray)
            .foregroundStyle(Palette.navy)
            .disabled(!unlocked)
        }
        .padding(.vertical, 4)
    }

    private func perkText(_ id: WorkerID) -> String {
        switch id {
        case .milo: return "Steady coin production."
        case .pip: return "Finds a treasure chest every 10 minutes."
        case .bolt: return "Each level boosts the whole team by 2%."
        }
    }
}

struct WorkerPortrait: View {
    let worker: WorkerID
    let size: CGFloat

    var body: some View {
        Art.worker(worker)
            .resizable()
            .scaledToFit()
            .padding(size * 0.06)
            .frame(width: size, height: size)
            .background(Circle().fill(Palette.cream))
            .overlay(Circle().strokeBorder(Palette.navy.opacity(0.15), lineWidth: 2))
            .accessibilityHidden(true)
    }
}

// MARK: - Zones

struct ZoneMapView: View {
    @ObservedObject var store: PlayerStore
    let onSelect: (ZoneID) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    ForEach(ZoneCatalog.all.reversed(), id: \.id) { zone in
                        card(zone)
                    }
                    if let run = store.profile.activeRun, !run.board.status.isOver {
                        Text("Switching zones leaves your current site and ends your win streak.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding()
            }
            .background(Palette.cream.ignoresSafeArea())
            .navigationTitle("Mining Map")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func card(_ zone: ZoneDefinition) -> some View {
        let profile = store.profile
        let unlocked = profile.isZoneUnlocked(zone.id)
        let isCurrent = profile.activeRun?.zone == zone.id
        let found = zone.collectibles.filter { (profile.collectibles[$0] ?? 0) > 0 }.count

        return Button {
            onSelect(zone.id)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(zone.name).font(.title3.bold())
                    Spacer()
                    if isCurrent { Text("HERE").font(.caption.bold()).padding(4).background(Capsule().fill(.white)) }
                    if !unlocked { Image(systemName: "lock.fill") }
                }
                Text(zone.tagline).font(.subheadline)
                HStack {
                    Text("x\(Double(zone.rewardMultiplierPercent) / 100, specifier: "%g") coins")
                    Spacer()
                    Text("\(profile.clears(in: zone.id)) cleared")
                    Text("· \(found)/\(zone.collectibles.count) treasures")
                }
                .font(.caption.bold())
                if !unlocked, let req = zone.unlock {
                    let have = min(profile.clears(in: req.zone), req.clears)
                    ProgressView(value: Double(have), total: Double(req.clears)) {
                        Text("Clear \(req.clears) sites in \(ZoneCatalog.definition(req.zone).name): \(have)/\(req.clears)")
                            .font(.caption)
                    }
                    .tint(.white)
                }
            }
            .foregroundStyle(unlocked ? Palette.navy : .white)
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Art.backdrop(zone.id)
                    .resizable()
                    .scaledToFill()
                    .overlay(unlocked ? Color.white.opacity(0.55) : Palette.navy.opacity(0.7))
            )
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Palette.navy, lineWidth: isCurrent ? 3 : 0))
        }
        .buttonStyle(.plain)
        .disabled(!unlocked)
    }
}

// MARK: - Welcome back

struct WelcomeBackView: View {
    let reward: OfflineReward
    let crew: [WorkerID]
    let onCollect: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Welcome back!").font(.largeTitle.bold())
            HStack(spacing: -10) {
                ForEach(crew, id: \.self) { WorkerPortrait(worker: $0, size: 56) }
            }
            Text("Your crew mined for \(durationText(reward.seconds))")
                .font(.headline)
            ArtLabel(text: reward.coins.compact, image: Art.coin, size: 44)
                .font(.system(size: 40, weight: .black, design: .rounded))
                .foregroundStyle(Palette.navy)
            if reward.chests > 0 {
                Text("Pip found \(reward.chests) treasure chest\(reward.chests == 1 ? "" : "s") (included)")
                    .font(.subheadline)
            }
            if reward.wasCapped {
                Text("Storage was full. Upgrade Bigger Storage to hold more.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Button(action: onCollect) {
                Text("Collect").font(.title3.bold()).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Palette.grass)
            .controlSize(.large)
        }
        .padding(24)
        .foregroundStyle(Palette.navy)
    }
}
