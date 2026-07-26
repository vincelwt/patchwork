import SwiftUI

/// A calm-to-intense replacement for the native `Slider` behind the composer's effort control.
/// AppKit's `Slider` cannot be given a custom track or knob on macOS, so `/mode` gets its own
/// drawing: a capsule track that fills with `PiTheme.effortRamp` up to the current step, and a
/// knob that grows modestly at `ultra`. Used by `ModeSlider` in `ComposerView.swift`.
///
/// Interaction: press or drag anywhere along the track jumps to the nearest step;
/// `ModeSlider` layers keyboard/VoiceOver adjustment on top via `accessibilityAdjustableAction`.
struct PiEffortTrack: View {
    let mode: PiMode?
    let onSelect: (PiMode) -> Void

    /// Tracks the pointer while a press/drag is active; nil the rest of the time.
    @State private var dragIndex: Double?
    /// Set on release and held until the reported `mode` actually changes (or a bounded wait
    /// gives up). `onSelect` round-trips through an RPC command, so without this the knob would
    /// snap back to the pre-drag stop the instant the mouse lifts and only jump forward again
    /// once the round trip resolves — that snap-then-jump is what made dragging feel broken.
    @State private var pendingIndex: Int?
    @State private var reconcileTask: Task<Void, Never>?

    private static var steps: Int { PiMode.allCases.count }
    /// The larger (`ultra`) radius is used as the inset at both ends regardless of the current
    /// stop, so the track's usable range — and the mapping from a click's x position back to a
    /// step — never shifts depending on which mode happens to be selected.
    private static var knobInset: CGFloat { PiTheme.effortUltraKnobDiameter / 2 }
    /// `/mode` never calls a provider (see `AppStore.runExtensionCommand`), so a real response
    /// is always fast; this is only a backstop against a rejected or lost command leaving the
    /// knob showing a guess forever.
    private static let reconcileTimeoutNanoseconds: UInt64 = 4_000_000_000

    private var currentModeIndex: Int { PiMode.allCases.firstIndex(of: mode ?? .smart) ?? 0 }
    private var index: Double {
        PiEffortTrackGeometry.displayedIndex(dragIndex: dragIndex, pendingIndex: pendingIndex, reportedIndex: currentModeIndex)
    }
    private var clampedIndex: Int { min(Self.steps - 1, max(0, Int(index.rounded()))) }
    private var isUltra: Bool { mode == .ultra }
    private var knobDiameter: CGFloat { isUltra ? PiTheme.effortUltraKnobDiameter : PiTheme.effortKnobDiameter }
    private var knobTint: Color { mode?.piTint ?? Color.secondary.opacity(0.4) }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let knobX = PiEffortTrackGeometry.knobCenterX(index: index, steps: Self.steps, width: width, inset: Self.knobInset)

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
                    // Restrained: a bare hint of depth normally, a genuine but still tasteful
                    // glow at `ultra` — the previous radius/opacity read as a lens flare.
                    .shadow(color: knobTint.opacity(isUltra ? 0.4 : 0.12), radius: isUltra ? 3 : 1)
                    .frame(width: knobDiameter, height: knobDiameter)
                    // Centred on the space this `GeometryReader` actually reports, not on
                    // `effortTrackHeight / 2` — that measured against the track's own thickness
                    // instead of the taller frame the knob is positioned within, so it sat near
                    // the top instead of on the track's centre line.
                    .position(x: knobX, y: proxy.size.height / 2)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let raw = PiEffortTrackGeometry.index(forX: value.location.x, steps: Self.steps, width: width, inset: Self.knobInset)
                        dragIndex = raw
                        let candidate = PiMode.allCases[min(Self.steps - 1, max(0, Int(raw.rounded())))]
                        if candidate != mode { onSelect(candidate) }
                    }
                    .onEnded { value in
                        let raw = PiEffortTrackGeometry.index(forX: value.location.x, steps: Self.steps, width: width, inset: Self.knobInset)
                        dragIndex = nil
                        pendingIndex = min(Self.steps - 1, max(0, Int(raw.rounded())))
                        armReconciliation()
                    }
            )
            .animation(.easeOut(duration: 0.15), value: clampedIndex)
        }
        .frame(width: PiTheme.effortTrackWidth, height: PiTheme.effortUltraKnobDiameter)
        .onChange(of: mode) { _, _ in
            // The authoritative value came back — accepted or not, it wins over any guess held
            // since the drag ended.
            reconcileTask?.cancel()
            pendingIndex = nil
        }
    }

    private func armReconciliation() {
        reconcileTask?.cancel()
        reconcileTask = Task {
            try? await Task.sleep(nanoseconds: Self.reconcileTimeoutNanoseconds)
            guard !Task.isCancelled else { return }
            pendingIndex = nil
        }
    }

    private var fillStyle: LinearGradient {
        let stops = isUltra
            ? PiTheme.effortRamp + [PiTheme.effortUltraAccent]
            : Array(PiTheme.effortRamp[0...clampedIndex])
        return LinearGradient(colors: stops, startPoint: .leading, endPoint: .trailing)
    }
}

/// Pure position math for `PiEffortTrack`, kept separate from the view so the exact geometry bug
/// — the knob's centre reaching `width` at the last stop, and being measured against the wrong
/// height — can be pinned down with a plain unit test instead of a rendered snapshot.
enum PiEffortTrackGeometry {
    /// The knob's centre for a continuous `index` in `0...(steps - 1)`. The travel range is
    /// inset by `inset` (a radius) at both ends so the knob's edge never crosses the frame
    /// boundary — previously the centre reached `width` exactly at the last stop, hanging half
    /// the knob off the end and over whatever sits next to the control (the send button).
    static func knobCenterX(index: Double, steps: Int, width: CGFloat, inset: CGFloat) -> CGFloat {
        guard steps > 1 else { return width / 2 }
        let usable = max(0, width - inset * 2)
        let step = usable / CGFloat(steps - 1)
        let clamped = min(Double(steps - 1), max(0, index))
        return inset + step * CGFloat(clamped)
    }

    /// The inverse of `knobCenterX`: which continuous step index a pointer's x offset (in the
    /// track's own coordinate space) resolves to, clamped to the track's stops. Shared by
    /// press/drag-to-jump so the hit test always agrees with where the knob is actually drawn.
    static func index(forX x: CGFloat, steps: Int, width: CGFloat, inset: CGFloat) -> Double {
        guard steps > 1 else { return 0 }
        let usable = width - inset * 2
        guard usable > 0 else { return 0 }
        let raw = Double((x - inset) / usable) * Double(steps - 1)
        return min(Double(steps - 1), max(0, raw))
    }

    /// What the knob should actually show: an in-progress drag wins outright, then an
    /// unconfirmed release, and only then the mode the runtime has actually reported. This
    /// ordering is what keeps the knob from snapping backwards while `/mode` is in flight.
    static func displayedIndex(dragIndex: Double?, pendingIndex: Int?, reportedIndex: Int) -> Double {
        dragIndex ?? pendingIndex.map(Double.init) ?? Double(reportedIndex)
    }
}
