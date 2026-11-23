import AppKit
import SwiftUI

/// The track title on a single line. When it does not fit, it scrolls back and forth.
/// The scrolling is a Core Animation animation: the system's render server moves the text,
/// so an open player with a long title costs the app no per-frame work.
final class MarqueeNSView: NSView {
    private static let font = NSFont.systemFont(ofSize: 15, weight: .semibold)
    private static let leadingFade: CGFloat = 8
    private static let trailingFade: CGFloat = 20

    private let textLayer = CATextLayer()
    private let fade = CAGradientLayer()
    private var text = ""
    private var running = false
    private var textSize = CGSize.zero
    private var scrollKey: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        textLayer.anchorPoint = CGPoint(x: 0, y: 0.5)
        textLayer.isWrapped = false
        textLayer.truncationMode = .none
        textLayer.alignmentMode = .left
        textLayer.contentsScale = 2
        layer?.addSublayer(textLayer)
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        layer?.mask = fade
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// True while the title is being scrolled, for tests.
    var isScrolling: Bool { scrollKey != nil }

    func apply(text newText: String, running newRunning: Bool) {
        guard newText != text || newRunning != running else { return }
        if newText != text {
            text = newText
            let attributed = NSAttributedString(string: newText, attributes: [
                .font: Self.font,
                .foregroundColor: NSColor.white,
            ])
            let measured = attributed.size()
            textSize = CGSize(width: ceil(measured.width), height: ceil(measured.height))
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            textLayer.string = attributed
            CATransaction.commit()
        }
        running = newRunning
        update()
    }

    override func layout() {
        super.layout()
        update()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Animations do not survive leaving the window; start over when the view comes back.
        scrollKey = nil
        textLayer.removeAnimation(forKey: "scroll")
        matchScreenScale()
        update()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        matchScreenScale()
    }

    private func matchScreenScale() {
        guard let scale = window?.backingScaleFactor, scale != textLayer.contentsScale else { return }
        textLayer.contentsScale = scale
    }

    private func update() {
        let width = bounds.width
        guard width > 0 else { return }
        let overflow = textSize.width - width
        let overflows = overflow > 4
        let shouldScroll = overflows && running && window != nil

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        textLayer.bounds = CGRect(origin: .zero, size: textSize)
        textLayer.position = CGPoint(x: 0, y: bounds.midY)
        fade.frame = bounds
        // Soft edges: on the right when the text is cut off, on both sides while it scrolls.
        let opaque = NSColor.black.cgColor
        let clear = NSColor.clear.cgColor
        let leading = min(0.4, Self.leadingFade / width)
        let trailing = max(0.6, 1 - Self.trailingFade / width)
        fade.colors = [shouldScroll ? clear : opaque, opaque, opaque, overflows ? clear : opaque]
        fade.locations = [0, NSNumber(value: Double(leading)), NSNumber(value: Double(trailing)), 1]
        CATransaction.commit()

        let key = shouldScroll ? text + "|" + String(Int(overflow)) : nil
        guard key != scrollKey else { return }
        scrollKey = key
        textLayer.removeAnimation(forKey: "scroll")
        guard shouldScroll else { return }

        // Rest at the start, travel to the end, rest there, then come back the same way.
        let distance = overflow + 16
        let animation = CAKeyframeAnimation(keyPath: "position.x")
        animation.values = [0, 0, -distance, -distance]
        animation.keyTimes = [0, 0.12, 0.88, 1]
        let linear = CAMediaTimingFunction(name: .linear)
        animation.timingFunctions = [linear, CAMediaTimingFunction(name: .easeInEaseOut), linear]
        animation.duration = max(5, Double(distance) / 18)
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        animation.beginTime = textLayer.convertTime(CACurrentMediaTime(), from: nil) + 1.2
        animation.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        textLayer.add(animation, forKey: "scroll")
    }
}

struct MarqueeTitle: NSViewRepresentable {
    var text: String
    var running: Bool

    func makeNSView(context: Context) -> MarqueeNSView {
        MarqueeNSView(frame: .zero)
    }

    func updateNSView(_ view: MarqueeNSView, context: Context) {
        view.apply(text: text, running: running)
    }
}

/// The artist line; a short status note (for example "added to Liked Songs") slides over it.
struct ArtistLine: View {
    let artist: String
    let note: PlayerNote?
    @State private var lastNote: PlayerNote?

    var body: some View {
        let shown = note ?? lastNote
        ZStack(alignment: .leading) {
            Text(artist)
                .foregroundStyle(Color.islandDim)
                .opacity(note == nil ? 1 : 0)
                .offset(y: note == nil ? 0 : -6)
            Text(shown?.text ?? "")
                .minimumScaleFactor(0.8)
                .foregroundStyle(shown?.tone == .positive ? Color.liked : Color.islandDim)
                .opacity(note == nil ? 0 : 1)
                .offset(y: note == nil ? 6 : 0)
        }
        .font(.system(size: 13))
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeOut(duration: 0.25), value: note)
        .onChange(of: note) { _, newNote in
            if let newNote { lastNote = newNote }
        }
        .onAppear { lastNote = note }
    }
}

/// Title and artist of the open player. On a track change they slide out towards the direction
/// of the switch and the new ones slide in from the other side.
struct TrackTitles: View {
    let title: String
    let artist: String
    let note: PlayerNote?
    let transition: TrackTransition
    let animated: Bool
    let running: Bool

    @State private var shownTitle: String
    @State private var shownArtist: String
    @State private var offset: CGFloat = 0
    @State private var opacity = 1.0
    @State private var generation = 0

    init(title: String, artist: String, note: PlayerNote?, transition: TrackTransition, animated: Bool, running: Bool) {
        self.title = title
        self.artist = artist
        self.note = note
        self.transition = transition
        self.animated = animated
        self.running = running
        _shownTitle = State(initialValue: title)
        _shownArtist = State(initialValue: artist)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            MarqueeTitle(text: shownTitle, running: running && opacity == 1)
                .frame(height: 20)
            ArtistLine(artist: shownArtist, note: note)
                .frame(height: 18)
        }
        .offset(x: offset)
        .opacity(opacity)
        .onChange(of: transition) { _, newTransition in
            swap(direction: CGFloat(newTransition.direction))
        }
        .onChange(of: title) { _, _ in adoptIfIdle() }
        .onChange(of: artist) { _, _ in adoptIfIdle() }
    }

    private func adoptIfIdle() {
        guard opacity == 1, offset == 0 else { return }
        shownTitle = title
        shownArtist = artist
    }

    private func swap(direction: CGFloat) {
        generation += 1
        let current = generation
        guard animated else {
            shownTitle = title
            shownArtist = artist
            offset = 0
            opacity = 1
            return
        }
        withAnimation(.easeIn(duration: 0.14)) {
            offset = -direction * 16
            opacity = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard current == generation else { return }
            shownTitle = title
            shownArtist = artist
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) { offset = direction * 16 }
            // Start the slide-in on the next screen update, after the jump to the other side was drawn.
            DispatchQueue.main.async {
                guard current == generation else { return }
                withAnimation(.timingCurve(0.2, 1.2, 0.35, 1, duration: 0.38)) {
                    offset = 0
                    opacity = 1
                }
            }
        }
    }
}

/// Title and artist shown for a couple of seconds when a new track starts.
struct PeekText: View {
    let title: String
    let artist: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.white)
                .frame(height: 19)
            Text(artist)
                .font(.system(size: 12))
                .foregroundStyle(Color.islandDim)
                .frame(height: 17)
        }
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Elapsed or remaining time. Its value is animatable, so the digits roll while the slider glides.
struct TimeLabel: View, Animatable {
    var seconds: Double
    let duration: Double
    let remaining: Bool
    let highlighted: Bool

    var animatableData: Double {
        get { seconds }
        set { seconds = newValue }
    }

    var body: some View {
        Text(remaining ? "-" + formatTime(duration - seconds.rounded(.down)) : formatTime(seconds))
            .font(.system(size: 11, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(highlighted ? Color.white : Color.islandDim)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .contentTransition(.identity)
    }
}
