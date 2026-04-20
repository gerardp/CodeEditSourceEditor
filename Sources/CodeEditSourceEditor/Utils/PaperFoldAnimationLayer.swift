//
//  PaperFoldAnimationLayer.swift
//  CodeEditTextView
//
//  Created by Abe Malla on 4/11/26.
//

import AppKit
import QuartzCore

/// A reusable Core Animation layer that performs a physically-accurate "paper fold" animation.
///
/// ## Geometry
///
/// The fold simulates a real sheet of paper bending in half. The two halves keep their full
/// length at every stage of the animation — only the crease changes position:
///
/// The layer uses CA's default bottom-up Y internally, so `y = foldHeight` corresponds visually to
/// the **line above** the fold region and `y = 0` to the **line below**.
///
/// - The **bottom half** is anchored at its top edge and pinned at `y = foldHeight` — the boundary
///   above the fold region (the line just above the fold, which stays put). It rotates around that
///   edge, sending its crease end backward into `-z`.
/// - The **top half** is anchored at its bottom edge. Its position slides *upward* along Y as the
///   fold closes: `y = foldHeight − projected = foldHeight · (1 − cos θ)`. It rotates around that
///   edge, also sending its crease end backward into `-z`.
/// - Because both halves are the same length and rotate by the same angle symmetrically, the two
///   crease ends always meet. At `θ = 0` the paper is flat and the outer edges are `foldHeight`
///   apart; at `θ = π/2` the paper is fully folded and both outer edges meet at `y = foldHeight`
///   — the line above — while the line below rides the view-zone shrink upward to meet them.
///
/// A gentle perspective (`m34 = -1/1200`) makes the receding crease read as depth. The
/// perspective vanishing point is re-centered each frame at the visible midpoint
/// (`projected/2`) so the crease always appears exactly centered between the two halves,
/// regardless of fold angle.
///
/// ## Shading
///
/// A dark overlay on each half ramps up proportional to `sin(θ)`, matching the lighting cue in
/// Xcode's native fold: the rotated surface receives less light, so it reads darker.
///
/// ## Clip
///
/// A shape-layer mask clips the layer to the paper's projected height (`foldHeight · cos(θ)`).
/// This keeps the halves from spilling outside the shrinking footprint.
///
/// ## Driving the animation
///
/// Unlike a conventional `CAAnimation`-based layer, this one is driven directly by a caller via
/// ``setFoldAngle(_:)``. Drive it from a `CADisplayLink` in lockstep with any other animations
/// (e.g. text-view line-height transitions) so the pieces stay visually synchronized.
///
/// ## Usage
///
/// ```swift
/// let layer = PaperFoldAnimationLayer(snapshot: image, foldRect: rect, backingScale: 2)
/// parent.addSublayer(layer)
/// // Each display-link tick:
/// layer.setFoldAngle(currentTheta)
/// // When done:
/// layer.cleanup()
/// ```
public final class PaperFoldAnimationLayer: CALayer {

    // MARK: - Sublayers

    /// Upper half of the paper. Pinned at its top edge (the boundary with the line above the
    /// fold). Rotates around that top edge so its crease-end recedes into `-z`.
    private let topHalf = CATransformLayer()
    /// Lower half of the paper. Pinned at its bottom edge (the boundary with the line below
    /// the fold). Rotates around that bottom edge.
    private let bottomHalf = CATransformLayer()

    /// Image-backed layers showing the top/bottom halves of the snapshot.
    private let topContent = CALayer()
    private let bottomContent = CALayer()

    /// Dark shade overlays. Their opacity is driven by `sin(θ)` so rotated surfaces darken
    /// predictably — the lighting cue that makes the depth change readable.
    private let topShade = CALayer()
    private let bottomShade = CALayer()

    /// Shape-layer mask that tracks the paper's projected 2D height — clips the layer down as
    /// the fold closes so the halves don't spill beyond their logical footprint.
    private let clipMask = CAShapeLayer()

    // MARK: - Public

    /// Height of the fold region at angle 0 (paper fully flat).
    public let foldHeight: CGFloat

    /// Backing scale for pixel-accurate rendering on Retina. Propagated to every image-backed
    /// sublayer so snapshots render at native resolution.
    public var backingScale: CGFloat {
        didSet { applyBackingScale() }
    }

    /// Maximum opacity of the dark shade overlay on the bottom half at full fold (0…1).
    public var maxBottomShadeOpacity: Float = 0.16

    /// Maximum opacity of the dark shade overlay on the top half at full fold (0…1).
    public var maxTopShadeOpacity: Float = 0.12

    // MARK: - Init

    /// Creates a paper-fold layer.
    ///
    /// - Parameters:
    ///   - snapshot: A full-width bitmap of the fold region. The top half of the image maps to
    ///     the top half of the fold, the bottom half to the bottom half.
    ///   - foldRect: The rect (in the parent layer's coordinate space) where the fold sits at
    ///     angle 0. Assumes a flipped (top-down Y) coord system — the same one an AppKit
    ///     flipped NSView would use.
    ///   - backingScale: The screen scale. Pass `window.backingScaleFactor` for correct Retina
    ///     rendering.
    public init(
        snapshot: CGImage,
        foldRect: NSRect,
        backingScale: CGFloat = NSScreen.main?.backingScaleFactor ?? 2.0
    ) {
        self.foldHeight = foldRect.height
        self.backingScale = backingScale
        super.init()

        self.frame = foldRect
        self.isGeometryFlipped = true
        self.masksToBounds = false
        self.contentsScale = backingScale
        self.actions = Self.allDisabledActions

        applyPerspective()
        buildHalves(snapshot: snapshot)
        buildShading()
        buildMask()
        setFoldAngle(0)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override init(layer: Any) {
        if let other = layer as? PaperFoldAnimationLayer {
            self.foldHeight = other.foldHeight
            self.backingScale = other.backingScale
        } else {
            self.foldHeight = 0
            self.backingScale = 2.0
        }
        super.init(layer: layer)
    }

    // MARK: - Setup

    private func applyPerspective() {
        // Small m34 gives a subtle perspective — the crease reads as receding without visibly
        // distorting the text. 1/1200 matches Xcode's gentle foreshortening.
        var perspective = CATransform3DIdentity
        perspective.m34 = -1.0 / 1200.0
        self.sublayerTransform = perspective
    }

    private func buildHalves(snapshot: CGImage) {
        let halfHeight = foldHeight / 2.0
        let width = bounds.width
        let halfSize = CGSize(width: width, height: halfHeight)
        let centerX = width / 2.0

        // --- Top half: anchored at its TOP edge (outer edge of the fold).
        // In flipped geometry, anchor y=0 is at the top edge.
        // Position places the anchor at (centerX, 0) in the container — the top of the fold region.
        topHalf.anchorPoint = CGPoint(x: 0.5, y: 0.0)
        topHalf.position = CGPoint(x: centerX, y: 0)
        topHalf.bounds = CGRect(origin: .zero, size: halfSize)
        topHalf.isDoubleSided = false
        topHalf.actions = Self.allDisabledActions

        // `contentsRect` samples the image in its native (bottom-left origin) unit space — geometry
        // flipping on the layer doesn't affect sampling. So the TOP half of a CGImage (top rows of
        // pixels) corresponds to Y=0.5…1.0 in contentsRect, which is what the top-of-paper displays.
        configureContent(
            layer: topContent,
            snapshot: snapshot,
            bounds: halfSize,
            contentsRect: CGRect(x: 0, y: 0.5, width: 1, height: 0.5)
        )
        topHalf.addSublayer(topContent)

        // --- Bottom half: anchored at its BOTTOM edge (outer edge of the fold).
        // anchor y=1.0 in flipped geometry = bottom edge.
        // position.y is driven by setFoldAngle so the anchor tracks `foldHeight · cos(θ)`.
        bottomHalf.anchorPoint = CGPoint(x: 0.5, y: 1.0)
        bottomHalf.position = CGPoint(x: centerX, y: foldHeight)
        bottomHalf.bounds = CGRect(origin: .zero, size: halfSize)
        bottomHalf.isDoubleSided = false
        bottomHalf.actions = Self.allDisabledActions

        // Bottom half of the snapshot (bottom rows of pixels = Y=0…0.5 in contentsRect unit space).
        configureContent(
            layer: bottomContent,
            snapshot: snapshot,
            bounds: halfSize,
            contentsRect: CGRect(x: 0, y: 0, width: 1, height: 0.5)
        )
        bottomHalf.addSublayer(bottomContent)

        addSublayer(topHalf)
        addSublayer(bottomHalf)
    }

    private func configureContent(
        layer: CALayer,
        snapshot: CGImage,
        bounds: CGSize,
        contentsRect: CGRect
    ) {
        layer.frame = CGRect(origin: .zero, size: bounds)
        layer.contents = snapshot
        layer.contentsRect = contentsRect
        layer.contentsGravity = .resize
        // Without matching contentsScale, a 2× CGImage renders at 1× density on Retina →
        // visibly blurry. Always match the backing scale.
        layer.contentsScale = backingScale
        layer.isGeometryFlipped = true
        layer.masksToBounds = true
        layer.actions = Self.allDisabledActions
    }

    private func buildShading() {
        for shade in [topShade, bottomShade] {
            shade.backgroundColor = NSColor.black.cgColor
            shade.opacity = 0
            shade.contentsScale = backingScale
            shade.actions = Self.allDisabledActions
        }
        topShade.frame = topContent.frame
        bottomShade.frame = bottomContent.frame
        topHalf.addSublayer(topShade)
        bottomHalf.addSublayer(bottomShade)
    }

    private func buildMask() {
        clipMask.frame = bounds
        clipMask.path = CGPath(rect: bounds, transform: nil)
        clipMask.actions = Self.allDisabledActions
        self.mask = clipMask
    }

    private func applyBackingScale() {
        self.contentsScale = backingScale
        topContent.contentsScale = backingScale
        bottomContent.contentsScale = backingScale
        topShade.contentsScale = backingScale
        bottomShade.contentsScale = backingScale
    }

    // MARK: - Driving the fold

    /// Drives the fold to the given angle. Call on every display-link tick.
    /// - Parameter theta: 0 = flat (fully open), `π/2` = fully folded (closed).
    public func setFoldAngle(_ theta: CGFloat) {
        let cosT = cos(theta)
        let sinT = sin(theta)
        let projected = foldHeight * cosT

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // Re-center the perspective vanishing point at the visible midpoint each frame.
        //
        // Core Animation applies `sublayerTransform` relative to the layer's bounds center
        // (foldHeight/2), which is fixed. As the visible area shrinks to `projected`, the
        // static center diverges from the visible midpoint, causing asymmetric foreshortening
        // that shifts the crease away from center. The combined transform
        //   T(0, δ) · P · T(0, -δ)   where δ = (foldHeight - projected) / 2
        // re-centers the projection at (width/2, foldHeight - projected/2) — the midpoint of the
        // visible paper, which sits at the TOP of the layer's bounds (since the bottom half is
        // pinned at `y = foldHeight` and the top half slides up toward it).
        var persp = CATransform3DIdentity
        persp.m34 = -1.0 / 1200.0
        let delta = (foldHeight - projected) / 2.0
        persp.m32 = persp.m34 * delta
        self.sublayerTransform = persp

        // Top half rotates around its anchor (its bottom edge). Negative θ sends its top edge
        // (the crease end) into -z — "fold back, away from the viewer." Its position slides
        // *upward* along Y as the fold closes — the bottom of the fold region closes toward
        // the stationary top.
        topHalf.transform = CATransform3DMakeRotation(-theta, 1, 0, 0)
        topHalf.position = CGPoint(x: bounds.width / 2, y: foldHeight - projected)

        // Bottom half rotates around its anchor (its top edge, pinned at `y = foldHeight` —
        // the line above the fold). Positive θ sends its bottom edge (the crease end) into -z
        // — symmetric with the top half.
        bottomHalf.transform = CATransform3DMakeRotation(theta, 1, 0, 0)

        // The two halves are lit differently as they fold:
        // - Bottom half folds underneath and faces progressively away from the viewer → darkens
        //   heavily using sin(θ), peaking at full fold.
        // - Top half stays facing the viewer and only picks up a slight crease shadow, scaled
        //   by sin²(θ) so it remains subtle until near-fully-folded.
        topShade.opacity = maxTopShadeOpacity * Float(sinT * sinT)
        bottomShade.opacity = maxBottomShadeOpacity * Float(sinT)

        // Clip down to the paper's projected 2D height. The visible paper hugs the TOP of the
        // layer's bounds (both halves converge at `y = foldHeight`, the line above), so the
        // mask rect starts at `y = foldHeight - projected` and grows upward.
        let clipHeight = max(0, projected)
        clipMask.path = CGPath(
            rect: CGRect(x: 0, y: foldHeight - clipHeight, width: bounds.width, height: clipHeight),
            transform: nil
        )

        CATransaction.commit()
    }

    /// Removes the layer from its parent. Safe to call even if it was never added.
    public func cleanup() {
        removeFromSuperlayer()
    }

    // MARK: - Snapshot helpers

    /// Captures a bitmap of `rect` from `view`. Suitable for feeding into
    /// ``init(snapshot:foldRect:backingScale:)``.
    public static func captureSnapshot(of rect: NSRect, in view: NSView) -> CGImage? {
        guard rect.width > 0 && rect.height > 0 else { return nil }
        guard let bitmapRep = view.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        view.cacheDisplay(in: rect, to: bitmapRep)
        return bitmapRep.cgImage
    }

    /// Stitches two images horizontally (left | right) into a single bitmap. Useful for
    /// combining a gutter snapshot and a text-view snapshot into a single image covering the
    /// full editor width.
    public static func compositeSnapshot(
        left: CGImage,
        leftWidth: CGFloat,
        right: CGImage,
        totalSize: CGSize,
        scale: CGFloat = NSScreen.main?.backingScaleFactor ?? 2.0
    ) -> CGImage? {
        let pixelWidth = Int((totalSize.width * scale).rounded())
        let pixelHeight = Int((totalSize.height * scale).rounded())
        let leftPixelWidth = Int((leftWidth * scale).rounded())

        guard pixelWidth > 0, pixelHeight > 0 else { return nil }

        // BGRA (little-endian premultiplied first) is the GPU-native format. Avoids a CoreGraphics
        // conversion pass on the layer.
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue

        guard let ctx = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ) else { return nil }

        let leftRect = CGRect(x: 0, y: 0, width: leftPixelWidth, height: pixelHeight)
        let rightRect = CGRect(
            x: leftPixelWidth,
            y: 0,
            width: pixelWidth - leftPixelWidth,
            height: pixelHeight
        )
        ctx.interpolationQuality = .none
        ctx.draw(left, in: leftRect)
        ctx.draw(right, in: rightRect)
        return ctx.makeImage()
    }

    // MARK: - Helpers

    /// Disables implicit animations on every property we mutate per-frame. Without this,
    /// CoreAnimation would try to cross-fade each change, fighting our display-link updates.
    private static let allDisabledActions: [String: CAAction] = [
        "transform": NSNull(),
        "position": NSNull(),
        "bounds": NSNull(),
        "opacity": NSNull(),
        "contents": NSNull(),
        "path": NSNull(),
        "backgroundColor": NSNull(),
        "hidden": NSNull()
    ]
}
