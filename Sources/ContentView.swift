import AVFoundation
import SwiftUI

struct ContentView: View {
    @StateObject private var camera = CameraModel()

    @State private var countdownSeconds = 10
    @State private var burstCount = 10
    @State private var intervalRounds = 1

    @State private var ticksRemaining: Int?
    @State private var roundsRemaining = 0
    @State private var showGrid = true
    @State private var focusIndicator: CGPoint?
    @State private var timer: Timer?

    private let countdownOptions = [3, 10, 20]
    private let burstOptions = [1, 5, 10, 20]
    private let roundOptions = [1, 5, 10]

    /// Seconds between interval rounds — enough time to change pose or move.
    private let roundGap: TimeInterval = 6

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            CameraPreview(session: camera.session) { devicePoint, layerPoint in
                camera.focusAndExpose(at: devicePoint)
                focusIndicator = layerPoint
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    if focusIndicator == layerPoint { focusIndicator = nil }
                }
            }
            .ignoresSafeArea()

            if showGrid {
                GridOverlay().ignoresSafeArea()
            }

            if let point = focusIndicator {
                FocusReticle()
                    .position(x: point.x, y: point.y)
                    .transition(.opacity)
            }

            // The countdown is deliberately enormous. The entire point is that
            // you can read it from seven feet away without squinting, which is
            // exactly where you should be standing.
            if let ticks = ticksRemaining {
                Text("\(ticks)")
                    .font(.system(size: 260, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.6), radius: 24)
                    .transition(.scale.combined(with: .opacity))
                    .id(ticks)
                    .allowsHitTesting(false)
            }

            VStack {
                topBar
                Spacer()
                controls
            }
            .padding()
        }
        .onAppear {
            camera.start()
            SoundCue.prepare()
        }
        .onDisappear { cancelSequence() }
        .animation(.snappy, value: ticksRemaining)
        .animation(.snappy, value: focusIndicator)
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 8) {
            chip("\(camera.maxPhotoMegapixels) MP", system: "camera.aperture")

            Button {
                camera.toggleLock()
            } label: {
                chip(camera.isLocked ? "AE/AF Locked" : "Auto",
                     system: camera.isLocked ? "lock.fill" : "lock.open",
                     tint: camera.isLocked ? .yellow : .white)
            }

            Button { showGrid.toggle() } label: {
                chip("Grid", system: "square.grid.3x3", tint: showGrid ? .yellow : .white)
            }

            Spacer()

            if roundsRemaining > 0 {
                chip("\(roundsRemaining) left", system: "repeat", tint: .yellow)
            }
        }
        .foregroundStyle(.white)
        .overlay(alignment: .bottomLeading) {
            if let error = camera.lastError {
                Text(error)
                    .font(.caption2)
                    .lineLimit(2)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.red.opacity(0.85), in: Capsule())
                    .offset(y: 34)
            }
        }
    }

    private func chip(_ text: String, system: String, tint: Color = .white) -> some View {
        Label(text, systemImage: system)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: 14) {
            lensPicker
            modePicker

            if camera.mode == .photo {
                HStack(spacing: 18) {
                    optionChip(title: "Timer", value: "\(countdownSeconds)s",
                               options: countdownOptions.map { ("\($0)s", $0) },
                               selection: $countdownSeconds)
                    optionChip(title: "Frames", value: "\(burstCount)",
                               options: burstOptions.map { ("\($0)", $0) },
                               selection: $burstCount)
                    optionChip(title: "Rounds", value: "\(intervalRounds)",
                               options: roundOptions.map { ("\($0)", $0) },
                               selection: $intervalRounds)
                }
            }

            shutterButton
            hint
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private var lensPicker: some View {
        Picker("Lens", selection: Binding(
            get: { camera.lens },
            set: { camera.switchLens(to: $0) }
        )) {
            ForEach(LensChoice.allCases) { lens in
                Text(lens.rawValue).tag(lens)
            }
        }
        .pickerStyle(.segmented)
    }

    private var modePicker: some View {
        Picker("Mode", selection: Binding(
            get: { camera.mode },
            set: { camera.switchMode(to: $0) }
        )) {
            Text("Photo").tag(CaptureMode.photo)
            Text("4K Video").tag(CaptureMode.video)
        }
        .pickerStyle(.segmented)
    }

    private func optionChip(title: String,
                            value: String,
                            options: [(String, Int)],
                            selection: Binding<Int>) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Menu(value) {
                ForEach(options, id: \.1) { option in
                    Button(option.0) { selection.wrappedValue = option.1 }
                }
            }
            .font(.headline)
        }
    }

    private var shutterButton: some View {
        Button {
            if isSequenceRunning {
                cancelSequence()
            } else if camera.mode == .photo {
                startSequence()
            } else {
                camera.toggleRecording()
            }
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(.white, lineWidth: 4)
                    .frame(width: 76, height: 76)
                RoundedRectangle(cornerRadius: stopShape ? 6 : 30, style: .continuous)
                    .fill(stopShape ? .red : .white)
                    .frame(width: stopShape ? 28 : 60, height: stopShape ? 28 : 60)
            }
        }
        .animation(.snappy, value: stopShape)
    }

    private var stopShape: Bool {
        camera.isRecording || isSequenceRunning
    }

    private var isSequenceRunning: Bool {
        ticksRemaining != nil || roundsRemaining > 0
    }

    private var hint: some View {
        Text(camera.lens.isFront
             ? "Prop the phone \(camera.lens.suggestedDistance) away — distance kills the distortion, not the lens. Tap to focus where you'll stand, then lock."
             : "Rear \(camera.lens.rawValue) — stand \(camera.lens.suggestedDistance) back. Tap your spot to focus, then lock before you walk in.")
            .font(.caption2)
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
    }

    // MARK: - Countdown & interval sequence

    private func startSequence() {
        roundsRemaining = intervalRounds
        beginCountdown()
    }

    private func beginCountdown() {
        timer?.invalidate()
        ticksRemaining = countdownSeconds

        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { t in
            Task { @MainActor in
                guard let current = ticksRemaining else {
                    t.invalidate()
                    return
                }
                if current <= 1 {
                    t.invalidate()
                    ticksRemaining = nil
                    SoundCue.go()
                    camera.captureBurst(count: burstCount)
                    scheduleNextRound()
                } else {
                    ticksRemaining = current - 1
                    // Audible ticks on the last three seconds only — enough
                    // warning without being annoying for a 20s timer.
                    if current - 1 <= 3 { SoundCue.tick() }
                }
            }
        }
    }

    private func scheduleNextRound() {
        roundsRemaining = max(0, roundsRemaining - 1)
        guard roundsRemaining > 0 else { return }

        // Wait out the burst itself, then give time to change pose.
        let burstDuration = Double(burstCount) * 0.35
        DispatchQueue.main.asyncAfter(deadline: .now() + burstDuration + roundGap) {
            guard roundsRemaining > 0 else { return }
            SoundCue.roundComplete()
            beginCountdown()
        }
    }

    private func cancelSequence() {
        timer?.invalidate()
        timer = nil
        ticksRemaining = nil
        roundsRemaining = 0
        camera.cancelBurst()
        if camera.isRecording { camera.toggleRecording() }
    }
}

/// Brief yellow square where you tapped, same idiom as the stock Camera app.
private struct FocusReticle: View {
    @State private var scale: CGFloat = 1.3

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .strokeBorder(.yellow, lineWidth: 1.5)
            .frame(width: 70, height: 70)
            .scaleEffect(scale)
            .onAppear {
                withAnimation(.easeOut(duration: 0.25)) { scale = 1.0 }
            }
    }
}
