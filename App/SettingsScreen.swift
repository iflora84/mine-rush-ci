import SwiftUI

struct SettingsScreen: View {
    @ObservedObject private var feedback = FeedbackService.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Sound") {
                    Toggle("Sound effects", isOn: $feedback.soundOn)
                    Toggle("Music", isOn: $feedback.musicOn)
                }
                Section {
                    Toggle("Haptics", isOn: $feedback.hapticsOn)
                    Toggle("Reduce motion", isOn: $feedback.reduceMotionSetting)
                } header: {
                    Text("Feel")
                } footer: {
                    Text("Reduce Motion in iOS Settings is always respected too.")
                }
                Section("How to play") {
                    Label("Tap a tile to dig.", systemImage: "hand.tap")
                    Label("Press and hold to place or remove a flag.", systemImage: "hand.point.up.left")
                    Label("Tap a number whose flags are all placed to clear around it.", systemImage: "number")
                    Label("Pinch to zoom and drag to move around big sites.", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .font(.subheadline)
                Section("About") {
                    LabeledContent("Version", value: version)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }
}
