import AudioToolbox
import UIKit

/// Audio + haptic cues, so you can shoot with your back to the phone.
/// A 260pt countdown is useless if you're turned three-quarters away.
enum SoundCue {

    private static let impact = UIImpactFeedbackGenerator(style: .medium)

    /// A short tick for each of the final countdown seconds.
    static func tick() {
        AudioServicesPlaySystemSound(1103)   // "Tink"
        impact.impactOccurred()
    }

    /// A brighter tone on zero, so you know the burst has started.
    static func go() {
        AudioServicesPlaySystemSound(1113)   // "Begin recording"
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// One per captured frame — lets you count shots without looking.
    static func shutter() {
        AudioServicesPlaySystemSound(1108)   // Shutter
    }

    /// Marks the end of an interval round, your cue to change pose.
    static func roundComplete() {
        AudioServicesPlaySystemSound(1114)   // "End recording"
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    static func prepare() {
        impact.prepare()
    }
}
