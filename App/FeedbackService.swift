import AVFoundation
import UIKit

/// Sound effects, music, haptics and the motion preference, all behind the
/// player's settings. Uses the ambient audio session so the silent switch
/// and other apps' audio are respected.
@MainActor
final class FeedbackService: ObservableObject {
    static let shared = FeedbackService()

    enum Sound: String, CaseIterable {
        case dig, flag, unflag, coin, scan, shield, boom, win
    }

    enum Haptic {
        case light, medium, success, error
    }

    @Published var soundOn: Bool { didSet { defaults.set(soundOn, forKey: Keys.sound) } }
    @Published var musicOn: Bool {
        didSet {
            defaults.set(musicOn, forKey: Keys.music)
            if musicOn { startMusic() } else { pauseMusic() }
        }
    }
    @Published var hapticsOn: Bool { didSet { defaults.set(hapticsOn, forKey: Keys.haptics) } }
    /// In-game switch; the iOS Reduce Motion setting is always honoured as well.
    @Published var reduceMotionSetting: Bool { didSet { defaults.set(reduceMotionSetting, forKey: Keys.reduceMotion) } }

    var reduceMotion: Bool {
        reduceMotionSetting || UIAccessibility.isReduceMotionEnabled
    }

    private enum Keys {
        static let sound = "settings.sound"
        static let music = "settings.music"
        static let haptics = "settings.haptics"
        static let reduceMotion = "settings.reduceMotion"
    }

    private let defaults = UserDefaults.standard
    /// A few players per effect so quick repeats overlap instead of cutting off.
    private var pools: [Sound: [AVAudioPlayer]] = [:]
    private var music: AVAudioPlayer?
    private let light = UIImpactFeedbackGenerator(style: .light)
    private let medium = UIImpactFeedbackGenerator(style: .medium)
    private let notifier = UINotificationFeedbackGenerator()

    private init() {
        // A local, because self isn't fully initialized until the flags below are set.
        let stored = UserDefaults.standard
        stored.register(defaults: [Keys.sound: true, Keys.music: true, Keys.haptics: true, Keys.reduceMotion: false])
        soundOn = stored.bool(forKey: Keys.sound)
        musicOn = stored.bool(forKey: Keys.music)
        hapticsOn = stored.bool(forKey: Keys.haptics)
        reduceMotionSetting = stored.bool(forKey: Keys.reduceMotion)
        try? AVAudioSession.sharedInstance().setCategory(.ambient)
        for sound in Sound.allCases {
            guard let url = Bundle.main.url(forResource: sound.rawValue, withExtension: "wav") else { continue }
            pools[sound] = (0..<3).compactMap { _ in
                let player = try? AVAudioPlayer(contentsOf: url)
                player?.prepareToPlay()
                return player
            }
        }
    }

    func play(_ sound: Sound, volume: Float = 1) {
        guard soundOn, let pool = pools[sound] else { return }
        let player = pool.first { !$0.isPlaying } ?? pool[0]
        player.volume = volume
        player.currentTime = 0
        player.play()
    }

    func haptic(_ kind: Haptic) {
        guard hapticsOn else { return }
        switch kind {
        case .light: light.impactOccurred(intensity: 0.6)
        case .medium: medium.impactOccurred()
        case .success: notifier.notificationOccurred(.success)
        case .error: notifier.notificationOccurred(.error)
        }
    }

    func startMusic() {
        guard musicOn else { return }
        if music == nil, let url = Bundle.main.url(forResource: "music", withExtension: "wav") {
            music = try? AVAudioPlayer(contentsOf: url)
            music?.numberOfLoops = -1
            music?.volume = 0.35
        }
        try? AVAudioSession.sharedInstance().setActive(true)
        music?.play()
    }

    func pauseMusic() {
        music?.pause()
    }
}
