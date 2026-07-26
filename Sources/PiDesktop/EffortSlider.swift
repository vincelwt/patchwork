import SwiftUI

/// A calm-to-intense replacement for the native `Slider` behind the composer's effort control.
/// AppKit's `Slider` cannot be given a custom track or knob on macOS, so making `/mode` "look
/// cooler" needs its own drawing: a capsule track that fills with `PiTheme.effortRamp` up to the
/// current step, and a knob that grows and gains a stronger glow at `ultra`.
///
/// This view is self-contained and currently unused by `ComposerView.swift` (a file this change
/// does not own) — see the working notes for the one-line swap that adopts it in `ModeSlider`.
/// Interaction mirrors the control it replaces: press or drag anywhere along the track to snap
/// to the nearest step, with the same rounding rule `ModeSlider` already used.
struct PiEffortTrack: View {
    let mode: PiMode?
    let onSelect: (PiMode) -> Void

    @State private var dragIndex: Double?

    private static var steps: Int { PiMode.allCases.count }

    private var index: Double {
        dragIndex ?? Double(PiMode.allCases.firstIndex(of: mode ?? .smart) ?? 0)
    }
    private var clampedIndex: Int { min(Self.steps - 1, max(0, Int(index.rounded()))) }
    private var isUltra: Bool { mode == .ultra }
    private var knobDiameter: CGFloat { isUltra ? PiTheme.effortUltraKnobDiameter : PiTheme.effortKnobDiameter }
    private var knobTint: Color { mode?.piTint ?? Color.secondary.opacity(0.4) }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let step = Self.steps > 1 ? width / CGFloat(Self.steps - 1) : width
            let knobX = min(width, max(0, step * CGFloat(index)))

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.piInset)
                    .frame(height: PiTheme.effortTrackHeight)

                // Solid at the leftmost stop, a genuine gradient once there is more than one
                // stop behind the knob — `ultra` widens into its own red-hot accent.
                Capsule()
                    .fill(fillStyle)
                    .frame(width: knobX, height: PiTheme.effortTrackHeight)

                Circle()
                    .fill(knobTint)
                    .overlay(Circle().stroke(Color.piWindow, lineWidth: 1.5))
                    .shadow(color: knobTint.opacity(isUltra ? 0.75 : 0.3), radius: isUltra ? 5.5 : 2.5)
                    .frame(width: knobDiameter, height: knobDiameter)
                    .position(x: knobX, y: PiTheme.effortTrackHeight / 2)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard step > 0 else { return }
                        let raw = Double(value.location.x / step)
                        let clamped = min(Double(Self.steps - 1), max(0, raw))
                        dragIndex = clamped
                        let candidate = PiMode.allCases[min(Self.steps - 1, max(0, Int(clamped.rounded())))]
                        if candidate != mode { onSelect(candidate) }
                    }
                    .onEnded { _ in dragIndex = nil }
            )
            .animation(.easeOut(duration: 0.15), value: clampedIndex)
        }
        .frame(width: PiTheme.effortTrackWidth, height: PiTheme.effortUltraKnobDiameter)
    }

    private var fillStyle: LinearGradient {
        let stops = isUltra
            ? PiTheme.effortRamp + [PiTheme.effortUltraAccent]
            : Array(PiTheme.effortRamp[0...clampedIndex])
        return LinearGradient(colors: stops, startPoint: .leading, endPoint: .trailing)
    }
}
