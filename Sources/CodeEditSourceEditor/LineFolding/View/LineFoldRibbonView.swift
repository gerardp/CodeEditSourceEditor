//
//  LineFoldRibbonView.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 5/6/25.
//

import Foundation
import AppKit
import CodeEditTextView

// swiftlint:disable type_body_length file_length

/// Displays the code folding ribbon in the ``GutterView``.
///
/// This view draws its contents manually. This was chosen over managing views on a per-fold basis, which would come
/// with needing to manage view reuse and positioning. Drawing allows this view to draw only what macOS requests, and
/// ends up being extremely efficient. This does mean that animations have to be done manually with a timer.
/// Re: the `hoveredFold` property.
class LineFoldRibbonView: NSView {
    struct HoverAnimationDetails: Equatable {
        var fold: FoldRange?
        var foldMask: CGPath?
        var timer: Timer?
        var progress: CGFloat = 0.0

        static let empty = HoverAnimationDetails()

        public static func == (_ lhs: HoverAnimationDetails, _ rhs: HoverAnimationDetails) -> Bool {
            lhs.fold == rhs.fold && lhs.foldMask == rhs.foldMask && lhs.progress == rhs.progress
        }
    }

    static let width: CGFloat = 7.0

    var model: LineFoldModel?

    @Invalidating(.display)
    var hoveringFold: HoverAnimationDetails = .empty

    @Invalidating(.display)
    var backgroundColor: NSColor = NSColor.controlBackgroundColor

    @Invalidating(.display)
    var markerColor = NSColor(
        light: NSColor(deviceWhite: 0.0, alpha: 0.1),
        dark: NSColor(deviceWhite: 1.0, alpha: 0.2)
    ).cgColor

    @Invalidating(.display)
    var markerBorderColor = NSColor(
        light: NSColor(deviceWhite: 1.0, alpha: 0.4),
        dark: NSColor(deviceWhite: 0.0, alpha: 0.4)
    ).cgColor

    @Invalidating(.display)
    var hoverFillColor = NSColor(
        light: NSColor(deviceWhite: 1.0, alpha: 1.0),
        dark: NSColor(deviceWhite: 0.17, alpha: 1.0)
    ).cgColor

    @Invalidating(.display)
    var hoverBorderColor = NSColor(
        light: NSColor(deviceWhite: 0.8, alpha: 1.0),
        dark: NSColor(deviceWhite: 0.4, alpha: 1.0)
    ).cgColor

    @Invalidating(.display)
    var foldedIndicatorColor = NSColor(
        light: NSColor(deviceWhite: 0.0, alpha: 0.3),
        dark: NSColor(deviceWhite: 1.0, alpha: 0.6)
    ).cgColor

    @Invalidating(.display)
    var foldedIndicatorChevronColor = NSColor(
        light: NSColor(deviceWhite: 1.0, alpha: 1.0),
        dark: NSColor(deviceWhite: 0.0, alpha: 1.0)
    ).cgColor

    override public var isFlipped: Bool {
        true
    }

    init(controller: TextViewController) {
        super.init(frame: .zero)
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        clipsToBounds = false
        self.model = LineFoldModel(
            controller: controller,
            foldView: self
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // CGColor values resolved from dynamic NSColors are static snapshots. Re-resolve them
        // so the ribbon picks up the correct light/dark variant after an appearance switch.
        markerColor = NSColor(
            light: NSColor(deviceWhite: 0.0, alpha: 0.1),
            dark: NSColor(deviceWhite: 1.0, alpha: 0.2)
        ).cgColor
        markerBorderColor = NSColor(
            light: NSColor(deviceWhite: 1.0, alpha: 0.4),
            dark: NSColor(deviceWhite: 0.0, alpha: 0.4)
        ).cgColor
        hoverFillColor = NSColor(
            light: NSColor(deviceWhite: 1.0, alpha: 1.0),
            dark: NSColor(deviceWhite: 0.17, alpha: 1.0)
        ).cgColor
        hoverBorderColor = NSColor(
            light: NSColor(deviceWhite: 0.8, alpha: 1.0),
            dark: NSColor(deviceWhite: 0.4, alpha: 1.0)
        ).cgColor
        foldedIndicatorColor = NSColor(
            light: NSColor(deviceWhite: 0.0, alpha: 0.3),
            dark: NSColor(deviceWhite: 1.0, alpha: 0.6)
        ).cgColor
        foldedIndicatorChevronColor = NSColor(
            light: NSColor(deviceWhite: 1.0, alpha: 1.0),
            dark: NSColor(deviceWhite: 0.0, alpha: 1.0)
        ).cgColor
    }

    override public func resetCursorRects() {
        // Don't use an iBeam in this view
        addCursorRect(bounds, cursor: .arrow)
    }

    // MARK: - Hover

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeInKeyWindow, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        self.mouseMoved(with: event)
    }

    // MARK: - Mouse Events

    override func mouseDown(with event: NSEvent) {
        let clickPoint = convert(event.locationInWindow, from: nil)
        guard let controller = model?.controller,
              let textView = controller.textView,
              let layoutManager = textView.layoutManager,
              event.type == .leftMouseDown,
              let lineNumber = layoutManager.textLineForPosition(clickPoint.y)?.index,
              let fold = model?.getCachedFoldAt(lineNumber: lineNumber) else {
            super.mouseDown(with: event)
            return
        }

        // If a collapse/expand is currently animating for this fold, jump it to its final state
        // before deciding which direction this click goes. This is what prevents a rapid second
        // click from stacking another overlay on top of the first — it forces the toggle to be
        // based on settled (post-finalization) state, not the transient mid-animation state.
        finalizeActiveAnimation(for: fold)

        // Re-fetch line position — finalizing an animation mutates line heights, view zones, and
        // attachments, so yPos/range may have shifted.
        guard let firstLineInFold = layoutManager.textLineForOffset(fold.range.lowerBound) else {
            super.mouseDown(with: event)
            return
        }

        let isCurrentlyCollapsed = findAttachmentFor(fold: fold, firstLineRange: firstLineInFold.range) != nil

        if isCurrentlyCollapsed {
            expandFold(fold: fold, firstLineInFold: firstLineInFold, event: event)
        } else {
            collapseFold(fold: fold, firstLineInFold: firstLineInFold, event: event)
        }
    }

    /// Duration of the paper-fold animation, in seconds. Every piece — paper fold, view-zone height, below-fold
    /// slide, and ribbon refresh — is driven by this single duration so they always finish together.
    private static let foldAnimationDuration: CFTimeInterval = 0.5

    // MARK: - Collapse

    /// Collapses the fold with a paper-fold animation.
    ///
    /// The fold is committed immediately (so the real text view can authoritatively hold the collapsed state),
    /// then a view zone of matching height is inserted so the below-fold content visually stays in place. The
    /// zone shrinks over `foldAnimationDuration` seconds in lockstep with the paper-fold overlay's angle. When
    /// the zone hits zero the real text view is already correctly laid out — the below-fold content finishes
    /// the animation at its final position, so there is no "snap" when the overlay is removed.
    ///
    /// We do not snapshot or slide the below-fold content. The real text view does the sliding itself.
    private func collapseFold(
        fold: FoldRange,
        firstLineInFold: TextLineStorage<TextLine>.TextLinePosition,
        event: NSEvent
    ) {
        guard let controller = model?.controller,
              let textView = controller.textView,
              let scrollView = controller.scrollView,
              let layoutManager = textView.layoutManager,
              let gutterView = controller.gutterView else { return }

        // If a previous collapse/expand for this fold is still animating, finalize it so its
        // overlay/zone/attachment state settles before we start a new one. Prevents overlays
        // stacking on rapid clicks.
        finalizeActiveAnimation(for: fold)

        guard let metrics = computeFoldMetrics(
            fold: fold, firstLineInFold: firstLineInFold, layoutManager: layoutManager
        ), metrics.foldHeight > 0 else {
            performCollapse(fold: fold, event: event)
            return
        }

        // Snapshot the fold region at its current (expanded) state so the paper fold can render over it.
        // The snapshot is clipped to the visible viewport
        guard let snapshotResult = captureFoldSnapshot(
            docY: metrics.foldRegionMinY, height: metrics.foldHeight, controller: controller
        ) else {
            performCollapse(fold: fold, event: event)
            return
        }

        // Commit the collapse now. Real line storage heights go to zero for the fold lines, the placeholder
        // attachment is installed, and the ribbon flips to its collapsed indicator.
        performCollapse(fold: fold, event: event)

        // A view zone of matching height restores the visual spacing. Without it, the below-fold content
        // would jump up to its collapsed position immediately; with it, the below content sits in place and
        // rides the zone height down to 0 over the animation.
        let zoneID = layoutManager.viewZones.addZone(
            ViewZone(afterLineNumber: firstLineInFold.index, heightInPoints: metrics.foldHeight)
        )

        // Force layout so the zone is reflected in line positions before we mount the overlay.
        textView.needsLayout = true
        textView.layoutSubtreeIfNeeded()

        // The paper-fold layer covers only the visible portion of the fold. The view zone handles the
        // full fold height so below-fold content slides correctly even when the fold extends off-screen.
        guard let mount = mountOverlay(
            scrollView: scrollView,
            snapshot: snapshotResult.snapshot,
            foldDocY: snapshotResult.capturedDocY,
            foldHeight: snapshotResult.capturedHeight,
            totalWidth: snapshotResult.totalWidth
        ) else {
            layoutManager.viewZones.removeZone(id: zoneID)
            return
        }

        let foldKey = NSRange(fold.range)
        let driver = runFoldAnimation(
            direction: .collapse,
            foldHeight: metrics.foldHeight,
            zoneID: zoneID,
            mount: mount,
            layoutManager: layoutManager,
            textView: textView,
            gutterView: gutterView,
            onComplete: { [weak self, weak gutterView] in
                layoutManager.viewZones.removeZone(id: zoneID)
                mount.foldLayer.cleanup()
                mount.overlay.removeFromSuperview()
                gutterView?.needsDisplay = true
                self?.activeAnimations.removeValue(forKey: foldKey)
                self?.mouseMoved(with: event)
            }
        )
        activeAnimations[foldKey] = driver
    }

    // MARK: - Expand

    /// Expands the fold with a paper-fold animation.
    ///
    /// The placeholder attachment is kept in place for the duration of the animation — this is what holds the
    /// real fold lines at zero height. A view zone grows from 0 to `foldHeight` over the animation, and the
    /// below-fold content rides that zone down to its final (expanded) position. When the animation finishes,
    /// the attachment is removed (fold line heights restored to natural) and the zone removed simultaneously —
    /// the two changes net to zero vertical shift, so there is no visible snap.
    ///
    /// Before the animation begins we do a brief dance: remove the attachment, force layout to measure the
    /// natural heights, capture the snapshot at the expanded positions, then re-install the attachment. This
    /// all happens synchronously within the mouseDown handler, so the screen never paints an intermediate state.
    private func expandFold(
        fold: FoldRange,
        firstLineInFold: TextLineStorage<TextLine>.TextLinePosition,
        event: NSEvent
    ) {
        guard let controller = model?.controller,
              let textView = controller.textView,
              let scrollView = controller.scrollView,
              let layoutManager = textView.layoutManager,
              let gutterView = controller.gutterView else {
            return
        }

        // If a previous collapse/expand for this fold is still animating, finalize it so its
        // overlay/zone/attachment state settles before we start a new one. Must happen BEFORE we
        // look for the attachment, because the in-flight animation may still be holding it.
        finalizeActiveAnimation(for: fold)

        guard let attachment = findAttachmentFor(fold: fold, firstLineRange: firstLineInFold.range) else {
            return
        }

        let attachmentOffset = attachment.range.location

        // Flip the ribbon's indicator to "expanded" immediately so it matches the state the user just clicked to.
        model?.foldCache.toggleCollapse(forFold: fold)
        gutterView.needsDisplay = true

        // Temporarily uncommit so the layout system fills in natural heights — we need them both for measuring
        // foldHeight and for rendering an expanded-state snapshot.
        layoutManager.attachments.remove(atOffset: attachmentOffset)
        textView.needsLayout = true
        textView.layoutSubtreeIfNeeded()

        // Re-fetch the first line — its height hasn't changed, but there's no harm in refreshing the position.
        guard let updatedFirstLine = layoutManager.textLineForOffset(fold.range.lowerBound),
              let metrics = computeFoldMetrics(
                fold: fold, firstLineInFold: updatedFirstLine, layoutManager: layoutManager
              ), metrics.foldHeight > 0 else {
            // Nothing to animate — just leave the attachment off and let layout finish.
            gutterView.needsDisplay = true
            mouseMoved(with: event)
            return
        }

        // The snapshot is clipped to the visible viewport — off-screen lines aren't captured.
        guard let snapshotResult = captureFoldSnapshot(
            docY: metrics.foldRegionMinY, height: metrics.foldHeight, controller: controller
        ) else {
            // Snapshot failed — leave the attachment off, which means the fold is now expanded without animation.
            gutterView.needsDisplay = true
            mouseMoved(with: event)
            return
        }

        // Re-install the placeholder so fold line heights snap back to zero. This is the state the animation
        // starts from: fold region visually collapsed, below-fold content at `foldRegionMinY`.
        let charWidth = controller.font.charWidth
        let placeholder = LineFoldPlaceholder(delegate: model, fold: fold, charWidth: charWidth)
        layoutManager.attachments.add(placeholder, for: NSRange(fold.range))

        // A view zone grows from 0 to foldHeight over the animation, pushing the below-fold content down.
        let zoneID = layoutManager.viewZones.addZone(
            ViewZone(afterLineNumber: updatedFirstLine.index, heightInPoints: 0)
        )

        textView.needsLayout = true
        textView.layoutSubtreeIfNeeded()

        // The paper-fold layer covers only the visible portion of the fold. The view zone handles the
        // full fold height so below-fold content slides correctly even when the fold extends off-screen.
        guard let mount = mountOverlay(
            scrollView: scrollView,
            snapshot: snapshotResult.snapshot,
            foldDocY: snapshotResult.capturedDocY,
            foldHeight: snapshotResult.capturedHeight,
            totalWidth: snapshotResult.totalWidth
        ) else {
            // Couldn't mount the overlay — finish expansion synchronously by removing the attachment we just added.
            layoutManager.viewZones.removeZone(id: zoneID)
            layoutManager.attachments.remove(atOffset: fold.range.lowerBound)
            textView.needsLayout = true
            textView.layoutSubtreeIfNeeded()
            mouseMoved(with: event)
            return
        }

        let foldKey = NSRange(fold.range)
        let driver = runFoldAnimation(
            direction: .expand,
            foldHeight: metrics.foldHeight,
            zoneID: zoneID,
            mount: mount,
            layoutManager: layoutManager,
            textView: textView,
            gutterView: gutterView,
            onComplete: { [weak self, weak gutterView] in
                // Remove attachment (fold lines restore to natural) and zone (removes the pushed-down space)
                // in the same turn. Net vertical shift: zero — nothing snaps.
                layoutManager.attachments.remove(atOffset: fold.range.lowerBound)
                layoutManager.viewZones.removeZone(id: zoneID)
                textView.needsLayout = true
                textView.layoutSubtreeIfNeeded()
                mount.foldLayer.cleanup()
                mount.overlay.removeFromSuperview()
                gutterView?.needsDisplay = true
                self?.activeAnimations.removeValue(forKey: foldKey)
                self?.mouseMoved(with: event)
            }
        )
        activeAnimations[foldKey] = driver
    }

    // MARK: - Animation Driver

    /// Direction of a fold animation, used to select the heightScale curve.
    private enum FoldAnimationDirection {
        case collapse  // 1 → 0
        case expand    // 0 → 1
    }

    /// Self-contained per-frame animation clock. Drives a closure each tick with the current
    /// normalized height scale (1 = fully open, 0 = fully closed), so every caller can share the
    /// same curve, duration, and lifecycle.
    ///
    /// Uses a repeating Timer on `.common` mode so scrolling and event tracking don't pause the
    /// animation — at this package's deployment target (macOS 13) `CADisplayLink` isn't yet
    /// available.
    private final class FoldAnimationDriver {
        private let duration: CFTimeInterval
        private let direction: FoldAnimationDirection
        private let onTick: (CGFloat) -> Void
        private let onComplete: () -> Void
        private let startTime: CFTimeInterval
        private var timer: Timer?
        private var isFinished = false

        init(
            duration: CFTimeInterval,
            direction: FoldAnimationDirection,
            onTick: @escaping (CGFloat) -> Void,
            onComplete: @escaping () -> Void
        ) {
            self.duration = duration
            self.direction = direction
            self.onTick = onTick
            self.onComplete = onComplete
            self.startTime = CACurrentMediaTime()
        }

        func start() {
            // Fire a zero-time tick so the initial state is applied before the next paint — the screen
            // never shows an un-animated frame.
            tick()
            guard !isFinished else { return }
            // Strong self capture: the timer retains the driver until `tick()` invalidates it on completion.
            // Without this the driver would deallocate as soon as `runFoldAnimation` returns (nothing else
            // holds it), the timer's `[weak self]` would be nil on first fire, and the animation would
            // never tick — leaving the view zone at full height and the paper overlay flat.
            let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [self] _ in
                self.tick()
            }
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        }

        private func tick() {
            guard !isFinished else { return }
            let elapsed = CACurrentMediaTime() - startTime
            let progress = min(max(elapsed / duration, 0), 1)
            let eased = Self.easeInOutCubic(progress)
            let heightScale: CGFloat = (direction == .collapse) ? (1 - eased) : eased
            onTick(heightScale)
            if progress >= 1 {
                isFinished = true
                timer?.invalidate()
                timer = nil
                onComplete()
            }
        }

        /// Cancels the timer and jumps straight to the final state via `onComplete`. Used when the
        /// user re-clicks the same fold mid-animation — we finalize the current animation (so the
        /// overlay/zone/attachment are cleaned up) before the caller starts the new one.
        func finishImmediately() {
            guard !isFinished else { return }
            isFinished = true
            timer?.invalidate()
            timer = nil
            onComplete()
        }

        private static func easeInOutCubic(_ t: CFTimeInterval) -> CGFloat {
            return t < 0.5
                ? CGFloat(4 * t * t * t)
                : CGFloat(1 - pow(-2 * t + 2, 3) / 2)
        }
    }

    /// Spins up a `FoldAnimationDriver` that updates the view zone, paper-fold angle, and text layout
    /// each tick. Ensures the projected paper-fold height (`foldHeight · cos(θ)`) tracks the zone
    /// height exactly, so the two visual elements always align.
    ///
    /// Returns the driver so the caller can register it in `activeAnimations` and cancel it if the
    /// user clicks the same fold again while it's in flight.
    // swiftlint:disable:next function_parameter_count
    @discardableResult
    private func runFoldAnimation(
        direction: FoldAnimationDirection,
        foldHeight: CGFloat,
        zoneID: UUID,
        mount: MountedFold,
        layoutManager: TextLayoutManager,
        textView: TextView,
        gutterView: GutterView,
        onComplete: @escaping () -> Void
    ) -> FoldAnimationDriver {
        // The driver is retained by the RunLoop via its timer until it completes.
        let driver = FoldAnimationDriver(
            duration: Self.foldAnimationDuration,
            direction: direction,
            onTick: { [weak textView, weak gutterView] heightScale in
                let clampedScale = min(max(heightScale, 0), 1)
                // θ = acos(heightScale) keeps the paper's projected height `foldHeight·cos(θ)` exactly
                // equal to the view-zone height. The real below-fold content (pushed down by the zone)
                // always meets the bottom edge of the visible paper fold.
                let theta = acos(clampedScale)
                mount.foldLayer.setFoldAngle(theta)
                layoutManager.viewZones.updateZoneHeight(id: zoneID, newHeight: foldHeight * clampedScale)
                textView?.needsLayout = true
                textView?.layoutSubtreeIfNeeded()
                // The gutter reads view zone whitespace offsets in its draw routine, so forcing a redraw
                // here makes its line numbers slide in lockstep with the text as the zone shrinks/grows.
                gutterView?.needsDisplay = true
                gutterView?.displayIfNeeded()
            },
            onComplete: onComplete
        )
        driver.start()
        return driver
    }

    // MARK: - In-Flight Animation Tracking

    /// Tracks animations currently in flight, keyed by fold range. Used so a rapid second click on
    /// the same fold cancels (finalizes) the first animation rather than stacking a second overlay
    /// on top of the first.
    private var activeAnimations: [NSRange: FoldAnimationDriver] = [:]

    /// If a fold has an animation in flight, run its completion immediately. The completion cleans
    /// up the overlay/zone/attachment so the state is settled before the caller starts a new
    /// animation.
    private func finalizeActiveAnimation(for fold: FoldRange) {
        let key = NSRange(fold.range)
        guard let driver = activeAnimations[key] else { return }
        driver.finishImmediately()
        // onComplete (registered in the collapse/expand paths) clears the entry via
        // `activeAnimations.removeValue`, so we don't need to clear it here.
    }

    // MARK: - Fold Animation Helpers

    /// Cache of measurements needed to drive the animation. Computing these requires walking the fold
    /// range once, so we bundle them into a struct rather than recomputing.
    private struct FoldAnimationMetrics {
        /// First document Y the paper-fold occupies (the bottom edge of the line just above the fold).
        let foldRegionMinY: CGFloat
        /// Height of the paper fold at full extension (equals the sum of the natural heights of every
        /// line whose height goes to zero when collapsed).
        let foldHeight: CGFloat
    }

    /// Snapshot data for a fold animation capture.
    private struct FoldSnapshot {
        let snapshot: CGImage
        let totalWidth: CGFloat
        let capturedDocY: CGFloat
        let capturedHeight: CGFloat
    }

    /// Measures everything we need to know about the fold region in one pass. Must be called with the
    /// fold lines at their natural (expanded) heights — the caller must force layout first for expand.
    private func computeFoldMetrics(
        fold: FoldRange,
        firstLineInFold: TextLineStorage<TextLine>.TextLinePosition,
        layoutManager: TextLayoutManager
    ) -> FoldAnimationMetrics? {
        // The first line in `fold.range` always stays at full height — it displays the placeholder inline.
        // The fold region visually starts just below this line's bottom edge, which gives us a coordinate
        // system where `foldHeight == sum of the heights of every line that gets zeroed`.
        let foldRegionMinY = firstLineInFold.yPos + firstLineInFold.height

        var totalHeight: CGFloat = 0
        var lastLine: TextLineStorage<TextLine>.TextLinePosition = firstLineInFold
        var iter = layoutManager.lineStorage.linesInRange(NSRange(fold.range)).makeIterator()
        // First line is the first-line-in-fold; drop it.
        _ = iter.next()
        while let line = iter.next() {
            totalHeight += line.height
            lastLine = line
        }

        // Matches `TextAttachmentManager.add`'s trailing-line case: when the fold range ends exactly on a
        // line boundary (and isn't at document end), the line *after* the range also gets zeroed, so it's
        // part of the animated region.
        let rangeMax = fold.range.upperBound
        if rangeMax != layoutManager.lineStorage.length,
           lastLine.range.max == rangeMax,
           let trailingLine = layoutManager.lineStorage.getLine(atOffset: rangeMax),
           trailingLine.height != 0 {
            totalHeight += trailingLine.height
        }

        guard totalHeight > 0 else { return nil }
        return FoldAnimationMetrics(foldRegionMinY: foldRegionMinY, foldHeight: totalHeight)
    }

    /// Mounted pieces of a fold animation: the scroll-view-relative overlay and the single paper
    /// fold layer hosted inside it.
    private struct MountedFold {
        let overlay: FoldAnimationOverlay
        let foldLayer: PaperFoldAnimationLayer
    }

    /// Builds and mounts a `FoldAnimationOverlay` with a paper-fold layer positioned over the
    /// text-view area only. The gutter's line numbers are drawn live (with view-zone whitespace
    /// offsets) and animate in lockstep with the text, so they do not need to be snapshotted.
    /// Returns nil if mounting fails.
    private func mountOverlay(
        scrollView: NSScrollView,
        snapshot: CGImage,
        foldDocY: CGFloat,
        foldHeight: CGFloat,
        totalWidth: CGFloat
    ) -> MountedFold? {
        let overlay = FoldAnimationOverlay(scrollView: scrollView)
        // Normal subview (not floating): a floating overlay gets repositioned by the scroll view
        // on each scroll event, which offsets the fold away from the captured region. The gutter
        // is a floating subview and draws on top of this overlay — but the fold layer is
        // positioned past the gutter's trailing edge, so the two never overlap.
        scrollView.addSubview(overlay, positioned: .above, relativeTo: nil)
        guard let overlayLayer = overlay.layer else {
            overlay.removeFromSuperview()
            return nil
        }

        let scale = overlay.window?.backingScaleFactor ?? 2.0
        let overlayFoldY = overlay.documentYToOverlayY(foldDocY)

        // Fold layer spans the text width, starting past the gutter so it doesn't clash with
        // the live line numbers.
        let foldRect = NSRect(
            x: 0.0, y: overlayFoldY, width: totalWidth, height: foldHeight
        )
        let foldLayer = PaperFoldAnimationLayer(
            snapshot: snapshot, foldRect: foldRect, backingScale: scale
        )
        overlayLayer.addSublayer(foldLayer)

        return MountedFold(overlay: overlay, foldLayer: foldLayer)
    }

    /// Transparent overlay view sitting above the text view (but below the floating gutter) during
    /// a fold animation. Hosts the paper-fold layer.
    ///
    /// Lives in scroll-view coordinates (not document coordinates). When the user scrolls
    /// mid-animation, we translate the hosted layer via `sublayerTransform` so the fold stays
    /// aligned with the folding region.
    private final class FoldAnimationOverlay: NSView {
        private weak var scrollView: NSScrollView?
        private var scrollObserver: NSObjectProtocol?
        /// The scroll origin Y captured when layers were positioned. Deltas from this are applied as
        /// a translation on `sublayerTransform` so the fold stays attached to its document Y.
        private let initialScrollOriginY: CGFloat

        override var isFlipped: Bool { true }
        override var wantsDefaultClipping: Bool { false }

        init(scrollView: NSScrollView) {
            self.scrollView = scrollView
            self.initialScrollOriginY = scrollView.contentView.bounds.origin.y
            super.init(frame: scrollView.bounds)
            wantsLayer = true
            layer?.masksToBounds = false
            autoresizingMask = [.width, .height]

            // If the user scrolls mid-animation, shift the overlay layer so fold + sliding content
            // stay anchored to the text they represent. Using `queue: nil` ensures the handler
            // runs synchronously during the clip view's bounds change — `queue: .main` would
            // enqueue the block for the next run-loop iteration, causing a visible one-frame lag.
            scrollObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: nil
            ) { [weak self] _ in
                self?.syncScrollOffset()
            }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        deinit {
            if let scrollObserver {
                NotificationCenter.default.removeObserver(scrollObserver)
            }
        }

        /// Converts a document Y coordinate into this overlay's (scroll-view-relative) coords. Uses
        /// the scroll origin captured at init so the conversion stays consistent with the coordinate
        /// space the animation was anchored in — even if the user scrolls while the animation is in
        /// flight, positions remain correct relative to the fold.
        func documentYToOverlayY(_ docY: CGFloat) -> CGFloat {
            return docY - initialScrollOriginY
        }

        private func syncScrollOffset() {
            guard let layer, let scrollView else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let delta = initialScrollOriginY - scrollView.contentView.bounds.origin.y
            layer.sublayerTransform = CATransform3DMakeTranslation(0, delta, 0)
            CATransaction.commit()
        }
    }

    /// Captures the text-area portion of the fold region as a single bitmap. The gutter is not
    /// captured because its line numbers animate live via view-zone whitespace offsets.
    ///
    /// The capture region is clipped to the scroll view's visible rect. Content outside the
    /// viewport isn't rendered into bitmaps reliably and can be enormous for large folds.
    ///
    /// Returns a `FoldSnapshot` struct containing the snapshot, the total width, and the clipped document-Y / height so callers
    /// can position the paper-fold layer over the captured region rather than the full fold.
    private func captureFoldSnapshot(
        docY: CGFloat,
        height: CGFloat,
        controller: TextViewController
    ) -> FoldSnapshot? {
        guard let textView = controller.textView,
              let gutterView = controller.gutterView,
              let scrollView = controller.scrollView else { return nil }

        // Clip the capture region to what's actually visible in the viewport.
        let visibleRect = scrollView.contentView.bounds
        let clippedMinY = max(docY, visibleRect.minY)
        let clippedMaxY = min(docY + height, visibleRect.maxY)
        let clippedHeight = clippedMaxY - clippedMinY

        let gutterWidth = gutterView.bounds.width
        let scrollWidth = scrollView.bounds.width
        let textWidth = scrollWidth - gutterWidth
        let textX = textView.visibleRect.origin.x + gutterWidth

        guard textWidth > 0, clippedHeight > 0 else { return nil }

        let gutterRect = NSRect(x: 0, y: clippedMinY, width: gutterWidth, height: clippedHeight)
        let textRect = NSRect(x: textX, y: clippedMinY, width: textWidth, height: clippedHeight)

        guard let gutterSnap = PaperFoldAnimationLayer.captureSnapshot(of: gutterRect, in: gutterView),
              let textSnap = PaperFoldAnimationLayer.captureSnapshot(of: textRect, in: textView) else {
            return nil
        }

        let totalSize = CGSize(width: scrollWidth, height: clippedHeight)
        guard let composite = PaperFoldAnimationLayer.compositeSnapshot(
            left: gutterSnap,
            leftWidth: gutterWidth,
            right: textSnap,
            totalSize: totalSize
        ) else { return nil }

        return FoldSnapshot(
            snapshot: composite,
            totalWidth: scrollWidth,
            capturedDocY: clippedMinY,
            capturedHeight: clippedHeight
        )
    }

    /// Performs the actual collapse state change (adding attachment, toggling, re-layout).
    private func performCollapse(fold: FoldRange, event: NSEvent) {
        guard let controller = model?.controller,
              let textView = controller.textView,
              let layoutManager = textView.layoutManager else { return }

        let charWidth = controller.font.charWidth
        let placeholder = LineFoldPlaceholder(delegate: model, fold: fold, charWidth: charWidth)
        layoutManager.attachments.add(placeholder, for: NSRange(fold.range))

        model?.foldCache.toggleCollapse(forFold: fold)
        textView.needsLayout = true
        controller.gutterView.needsDisplay = true
        mouseMoved(with: event)
    }

    private func findAttachmentFor(fold: FoldRange, firstLineRange: NSRange) -> AnyTextAttachment? {
        model?.controller?.textView?.layoutManager.attachments
            .getAttachmentsStartingIn(NSRange(fold.range))
            .filter({
                $0.attachment is LineFoldPlaceholder && firstLineRange.contains($0.range.location)
            }).first
    }

    override func mouseMoved(with event: NSEvent) {
        defer {
            super.mouseMoved(with: event)
        }

        let pointInView = convert(event.locationInWindow, from: nil)
        guard let lineNumber = model?.controller?.textView.layoutManager.textLineForPosition(pointInView.y)?.index,
              let fold = model?.getCachedFoldAt(lineNumber: lineNumber),
              !fold.isCollapsed else {
            clearHoveredFold()
            return
        }

        guard fold.range != hoveringFold.fold?.range else {
            return
        }

        setHoveredFold(fold: fold)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        clearHoveredFold()
    }

    /// Clears the current hovered fold. Does not animate.
    func clearHoveredFold() {
        hoveringFold = .empty
        model?.clearEmphasis()
    }

    /// Set the current hovered fold. This method determines when an animation is required and will facilitate it.
    /// - Parameter fold: The fold to set as the current hovered fold.
    func setHoveredFold(fold: FoldRange) {
        defer {
            model?.emphasizeBracketsForFold(fold)
        }

        hoveringFold.timer?.invalidate()
        // We only animate the first hovered fold. If the user moves the mouse vertically into other folds we just
        // show it immediately.
        if hoveringFold.fold == nil {
            let duration: TimeInterval = 0.2
            let startTime = CACurrentMediaTime()

            hoveringFold = HoverAnimationDetails(
                fold: fold,
                timer: Timer.scheduledTimer(withTimeInterval: 1/60, repeats: true) { [weak self] timer in
                    guard let self = self else { return }
                    let now = CACurrentMediaTime()
                    let time = CGFloat((now - startTime) / duration)
                    self.hoveringFold.progress = min(1.0, time)
                    if self.hoveringFold.progress >= 1.0 {
                        timer.invalidate()
                    }
                }
            )
            return
        }

        // Don't animate these
        hoveringFold = HoverAnimationDetails(fold: fold, progress: 1.0)
    }
}
