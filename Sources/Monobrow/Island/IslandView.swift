import SwiftUI

/// The whole island window: a fixed, transparent canvas with the island hanging from its top edge.
struct IslandRootView: View {
    @ObservedObject var model: PlayerModel
    @ObservedObject var island: IslandState
    @ObservedObject var prefs: Preferences
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The mode currently drawn. It follows the target mode with a spring.
    @State private var mode = IslandMode.hidden
    /// The full player exists only while the island is open and for a moment after it closes.
    @State private var fullMounted = false
    @State private var unmount = OneShot()

    var body: some View {
        let metrics = island.metrics
        let target = model.mode(hovering: island.isHovering || island.pinned)
        ZStack(alignment: .top) {
            if DevFlags.backdrop {
                ScreenshotBackdrop(barHeight: metrics.barHeight)
            } else {
                Color.clear
            }
            if !metrics.hasNotch {
                // Without a notch a hidden island leaves nothing to point at. This strip is
                // invisible but still receives the pointer, so hovering the top edge opens the player.
                Rectangle()
                    .fill(Color.white.opacity(0.004))
                    .frame(width: IslandMetrics.hotZone.width, height: IslandMetrics.hotZone.height)
            }
            islandBody(metrics)
        }
        .frame(width: metrics.windowSize.width, height: metrics.windowSize.height, alignment: .top)
        .environment(\.colorScheme, .dark)
        .onAppear { setMode(target, animated: false) }
        .onChange(of: target) { _, newTarget in setMode(newTarget, animated: true) }
    }

    private func setMode(_ newMode: IslandMode, animated: Bool) {
        let old = mode
        guard newMode != old else { return }
        if newMode == .expanded {
            unmount.cancel()
            fullMounted = true
        } else if old == .expanded {
            unmount.schedule(after: 0.45) { fullMounted = false }
        }
        if animated, !reduceMotion {
            withAnimation(newMode.rawValue < old.rawValue ? Motion.shrink : Motion.grow) { mode = newMode }
        } else {
            mode = newMode
        }
        island.displayedModeChanged()
    }

    private func islandBody(_ metrics: IslandMetrics) -> some View {
        let size = metrics.size(mode)
        let ear = metrics.ear(mode)
        let radius = metrics.bottomRadius(mode)
        let open = mode == .expanded
        let shadowOpacity = open ? 0.5 : (mode == .peek ? 0.42 : 0)
        return ZStack(alignment: .topLeading) {
            NotchShape(bottomRadius: radius, ear: ear)
                .fill(Color.black)
                .shadow(color: .black.opacity(shadowOpacity), radius: open ? 22 : 14, x: 0, y: open ? 14 : 8)
            IslandContent(
                model: model, island: island, prefs: prefs, metrics: metrics,
                mode: mode, size: size, fullMounted: fullMounted, reduceMotion: reduceMotion
            )
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: radius, bottomTrailingRadius: radius))
            .offset(x: ear)
        }
        .frame(width: size.width + ear * 2, height: size.height, alignment: .topLeading)
        // On a screen without a notch the hidden island must not leave a black line at the top edge.
        .opacity(metrics.hasNotch || mode != .hidden ? 1 : 0)
    }
}

/// A stand-in for the desktop and the menu bar, so screenshots show the island in context.
private struct ScreenshotBackdrop: View {
    let barHeight: CGFloat

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(
                colors: [
                    Color(red: 0.62, green: 0.71, blue: 0.85),
                    Color(red: 0.80, green: 0.76, blue: 0.87),
                    Color(red: 0.95, green: 0.81, blue: 0.71),
                ],
                startPoint: .top, endPoint: .bottom
            )
            Rectangle()
                .fill(Color.white.opacity(0.3))
                .frame(height: barHeight)
        }
    }
}

/// Everything inside the island. The cover and the equalizer are always the same two views;
/// they travel between their collapsed and open positions as the island changes size.
private struct IslandContent: View {
    @ObservedObject var model: PlayerModel
    let island: IslandState
    @ObservedObject var prefs: Preferences
    let metrics: IslandMetrics
    let mode: IslandMode
    let size: CGSize
    let fullMounted: Bool
    let reduceMotion: Bool

    var body: some View {
        let art = metrics.artFrame(mode)
        let equalizer = metrics.equalizerFrame(mode, shapeWidth: size.width)
        let hidden = mode == .hidden
        let peeking = mode == .peek
        ZStack(alignment: .topLeading) {
            if fullMounted {
                ExpandedContent(model: model, island: island, metrics: metrics, visible: mode == .expanded, reduceMotion: reduceMotion)
                    .offset(x: (size.width - IslandMetrics.expandedWidth) / 2)
            }

            PeekText(title: model.track?.title ?? "", artist: model.track?.artist ?? "")
                .opacity(peeking ? 1 : 0)
                .blur(radius: peeking || reduceMotion ? 0 : 4)
                .animation(peeking ? .easeOut(duration: 0.3).delay(0.1) : .easeOut(duration: 0.12), value: peeking)
                .frame(width: IslandMetrics.peekWidth - 70 - 56, height: 40, alignment: .leading)
                .offset(x: 70 + (size.width - IslandMetrics.peekWidth) / 2, y: metrics.topInset + 10)
                .allowsHitTesting(false)

            CoverView(
                image: model.artwork,
                key: model.artworkKey,
                direction: model.transition.direction,
                cornerRadius: metrics.artRadius(mode),
                dimmed: !model.isPlaying && model.track != nil,
                love: model.loveBurst,
                animated: !reduceMotion && !hidden
            )
            .frame(width: art.width, height: art.height)
            .scaleEffect(hidden ? 0.6 : 1)
            .opacity(hidden ? 0 : 1)
            .onTapGesture(count: 2) {
                if mode == .expanded { model.toggleLike(fromCover: true) }
            }
            .offset(x: art.minX, y: art.minY)

            EqualizerView(
                playing: model.isPlaying,
                animated: prefs.animatedEqualizer && !reduceMotion && !model.lowPower,
                visible: !hidden,
                amplitude: 0.3 + 0.7 * CGFloat(model.volume) / 100,
                color: model.accent
            )
            .frame(width: equalizer.width, height: equalizer.height)
            .scaleEffect(hidden ? 0.6 : 1)
            .opacity(hidden ? 0 : 1)
            .offset(x: equalizer.minX, y: equalizer.minY)
            .allowsHitTesting(false)
        }
    }
}

private extension View {
    /// Rows of the open player appear one after another and vanish together.
    func reveal(_ shown: Bool, delay: Double, blur: Bool, reduceMotion: Bool) -> some View {
        let still = shown || reduceMotion
        return self
            .opacity(shown ? 1 : 0)
            .blur(radius: still || !blur ? 0 : 4)
            .scaleEffect(still ? 1 : 0.98)
            .offset(y: still ? 0 : 8)
            .animation(shown ? .spring(response: 0.45, dampingFraction: 0.8).delay(delay) : .easeOut(duration: 0.1), value: shown)
    }
}

/// The open player: titles, progress and controls.
private struct ExpandedContent: View {
    @ObservedObject var model: PlayerModel
    let island: IslandState
    let metrics: IslandMetrics
    let visible: Bool
    let reduceMotion: Bool
    @State private var shown = false

    var body: some View {
        VStack(spacing: 14) {
            TrackTitles(
                title: model.track?.title ?? "Spotify",
                artist: model.track?.artist ?? "Ничего не играет",
                note: model.note,
                transition: model.transition,
                animated: shown && !reduceMotion,
                running: shown && !reduceMotion
            )
            .padding(.leading, 70)
            .padding(.trailing, 42)
            .frame(height: 56)
            .reveal(shown, delay: 0.06, blur: false, reduceMotion: reduceMotion)

            progressRow
                .frame(height: 16)
                .reveal(shown, delay: 0.11, blur: false, reduceMotion: reduceMotion)

            controlsRow
                .frame(height: 44)
                .reveal(shown, delay: 0.16, blur: false, reduceMotion: reduceMotion)
        }
        .padding(EdgeInsets(top: metrics.topInset + 12, leading: 22, bottom: 16, trailing: 22))
        .frame(width: IslandMetrics.expandedWidth, height: metrics.size(.expanded).height, alignment: .top)
        .allowsHitTesting(visible)
        // The rows are first laid out hidden; this change then animates them in.
        .onAppear { shown = visible }
        .onChange(of: visible) { _, newValue in shown = newValue }
    }

    private var progressRow: some View {
        let duration = model.duration
        let anchor = model.anchor
        let state = GlideSliderState(
            fraction: duration > 0 ? anchor.position / duration : 0,
            stamp: anchor.stamp,
            rate: duration > 0 && anchor.playing ? anchor.rate / duration : 0,
            glideToken: model.seekGlide
        )
        let trackKey = model.track?.id ?? "none"
        return HStack(spacing: 10) {
            TimeLabel(seconds: model.clock, duration: duration, remaining: false, highlighted: model.isScrubbing)
                .id("elapsed-" + trackKey)
                .frame(width: 40, alignment: .leading)
            GlideSlider(
                state: state,
                enabled: duration > 0,
                reduceMotion: reduceMotion,
                onBegan: { fraction in
                    island.lock()
                    model.beginScrub(at: fraction)
                },
                onChanged: { fraction in model.scrub(to: fraction) },
                onEnded: { fraction, wasDrag in
                    model.endScrub(at: fraction, glide: !wasDrag)
                    island.unlock()
                }
            )
            .frame(height: 16)
            TimeLabel(seconds: model.clock, duration: duration, remaining: true, highlighted: model.isScrubbing)
                .id("remaining-" + trackKey)
                .frame(width: 40, alignment: .trailing)
        }
        .animation(reduceMotion ? nil : Motion.glide, value: model.seekGlide)
    }

    private var controlsRow: some View {
        ZStack {
            HStack(spacing: 0) {
                LikeButton(
                    liked: model.likeShown,
                    available: model.likeAvailable,
                    effect: model.likeEffect,
                    accent: Color(nsColor: model.accent)
                ) {
                    model.toggleLike()
                }
                .offset(x: -8)
                Spacer(minLength: 0)
            }

            HStack(spacing: 14) {
                SkipButton(direction: -1) { model.skip(-1) }
                IslandButton(size: 46, help: model.isPlaying ? "Пауза" : "Играть", action: { model.togglePlay() }) { hovering in
                    PlayPauseGlyph(isPlaying: model.isPlaying, size: 28)
                        .scaleEffect(hovering ? 1.07 : 1)
                        .animation(Motion.soft, value: hovering)
                }
                SkipButton(direction: 1) { model.skip(1) }
            }

            HStack(spacing: 4) {
                Spacer(minLength: 0)
                MuteButton(volume: model.volume) { model.toggleMute() }
                GlideSlider(
                    state: GlideSliderState(fraction: Double(model.volume) / 100, glideToken: model.volumeGlide),
                    reduceMotion: reduceMotion,
                    onBegan: { fraction in
                        island.lock()
                        model.beginVolumeScrub(at: fraction)
                    },
                    onChanged: { fraction in model.scrubVolume(to: fraction) },
                    onEnded: { fraction, wasDrag in
                        model.endVolumeScrub(at: fraction, glide: !wasDrag)
                        island.unlock()
                    }
                )
                .frame(width: 72, height: 16)
            }
        }
    }
}
