import CoreMotion
import SwiftUI

/// Rule-of-thirds grid plus a horizon level.
/// Tilt is the single most common giveaway of a propped-phone shot.
struct GridOverlay: View {
    @StateObject private var level = LevelReader()

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Path { path in
                    for i in 1..<3 {
                        let x = geo.size.width * CGFloat(i) / 3
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: geo.size.height))

                        let y = geo.size.height * CGFloat(i) / 3
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: geo.size.width, y: y))
                    }
                }
                .stroke(.white.opacity(0.25), lineWidth: 0.5)

                // Horizon indicator: goes yellow when you're within a degree
                // of level, which is close enough that nobody will notice.
                let isLevel = abs(level.rollDegrees) < 1.0
                Rectangle()
                    .fill(isLevel ? Color.yellow : Color.white.opacity(0.5))
                    .frame(width: geo.size.width * 0.42, height: isLevel ? 2 : 1)
                    .rotationEffect(.degrees(-level.rollDegrees))
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                    .animation(.linear(duration: 0.08), value: level.rollDegrees)
            }
        }
        .allowsHitTesting(false)
    }
}

@MainActor
final class LevelReader: ObservableObject {
    @Published var rollDegrees: Double = 0

    private let motion = CMMotionManager()

    init() {
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 30.0
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let gravity = data?.gravity else { return }
            // Roll around the screen's vertical axis, in degrees.
            let radians = atan2(gravity.x, -gravity.y)
            self?.rollDegrees = radians * 180 / .pi
        }
    }

    deinit {
        motion.stopDeviceMotionUpdates()
    }
}
