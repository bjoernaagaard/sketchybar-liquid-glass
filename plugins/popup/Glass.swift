import AppKit

// The three pills of the bar. Each raw value is the SketchyBar bracket that holds the pill's items.
enum Island: String, CaseIterable {
    case left = "half.left", media = "island.media", right = "half.right"
}

// The glass behind the islands: one borderless window on the bar's display, one level below SketchyBar's
// item windows, which sit at kCGFloatingWindowLevel because sketchybarrc sets topmost=window. The window
// ignores the mouse, so SketchyBar keeps every click and hover. Each island drop follows its bracket's bounds.
// A fourth drop is the open popup's glass. It lives in the same container, so it can join its pill. The window
// covers the bar strip, and also the popup while one shows.
final class GlassLayer {
    // The bar strip: y_offset 8, height 30, and the 8 pt margin below, as sketchybarrc sets them.
    private static let stripHeight: CGFloat = 46
    private let window = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let container = NSGlassEffectContainerView()
    private let drops: [Island: NSGlassEffectView]
    private let popupDrop = NSGlassEffectView()
    private let mergeDistance: CGFloat
    // The union of the frames the popup drop has been aimed at since it appeared, in screen coordinates.
    // The window reaches it, plus the merge distance, until the drop is hidden.
    private var popupReach: NSRect?

    init(theme: Theme) {
        let canvas = NSView()
        mergeDistance = theme.number("MERGE_DISTANCE")
        container.spacing = mergeDistance
        container.contentView = canvas
        var drops: [Island: NSGlassEffectView] = [:]
        for island in Island.allCases {
            let drop = NSGlassEffectView()
            drop.style = .regular
            drop.cornerRadius = theme.number("ISLAND_RADIUS")
            drop.tintColor = theme.color("BAR_COLOR")
            drop.isHidden = true
            canvas.addSubview(drop)
            drops[island] = drop
        }
        self.drops = drops
        // The popup's glass is the style it has always had: untinted, with the popup's corners.
        popupDrop.style = .regular
        popupDrop.cornerRadius = theme.number("POPUP_RADIUS")
        popupDrop.isHidden = true
        canvas.addSubview(popupDrop)
        window.contentView = container
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.floatingWindow)) - 1)
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        moveToBarScreen()
    }

    // SketchyBar's display=main is the first screen AppKit lists (see Notch.main). A new screen forgets the reach.
    func moveToBarScreen() {
        popupReach = nil
        reframe()
    }

    // The strip on the bar's display, plus every place a popup has reached on it. Resizing this window costs the
    // glass a slow frame, so it grows when a popup goes somewhere new and never shrinks between popups. The drops
    // are positioned relative to the window, so a new window frame re-places each visible drop on screen.
    private func reframe() {
        guard let screen = NSScreen.screens.first else { return }
        var frame = NSRect(x: screen.frame.minX, y: screen.frame.maxY - Self.stripHeight,
                           width: screen.frame.width, height: Self.stripHeight)
        if let popupReach { frame = frame.union(popupReach.insetBy(dx: -mergeDistance, dy: -mergeDistance)) }
        guard frame != window.frame else { return }
        let visible = (Array(drops.values) + [popupDrop]).filter { !$0.isHidden }
        let onScreen = visible.map { window.convertToScreen($0.convert($0.bounds, to: nil)) }
        window.setFrame(frame, display: false)
        for (drop, rect) in zip(visible, onScreen) { drop.frame = rect.offsetBy(dx: -frame.minX, dy: -frame.minY) }
    }

    func show() { window.orderFrontRegardless() }

    // Grows the window to reach a frame the popup drop is about to move to.
    func extend(to frame: NSRect) {
        popupReach = popupReach.map { $0.union(frame) } ?? frame
        reframe()
    }

    var popupRadius: CGFloat { popupDrop.cornerRadius }

    func placePopup(_ frame: NSRect) {
        popupDrop.frame = frame.offsetBy(dx: -window.frame.minX, dy: -window.frame.minY)
        popupDrop.isHidden = false
    }

    // Hides the popup drop. The window keeps its reach, so the next popup opens without a resize.
    func hidePopup() { popupDrop.isHidden = true }

    // Frames are in AppKit screen coordinates. An island without a frame keeps its last one.
    func place(_ frames: [Island: NSRect]) {
        for (island, frame) in frames {
            guard let drop = drops[island] else { continue }
            drop.frame = frame.offsetBy(dx: -window.frame.minX, dy: -window.frame.minY)
            drop.isHidden = false
        }
    }

    // Where an island's drop is on screen now.
    func frame(of island: Island) -> NSRect? {
        guard let drop = drops[island], !drop.isHidden else { return nil }
        return window.convertToScreen(drop.convert(drop.bounds, to: nil))
    }

    // Where the popup drop is on screen now.
    var popupFrame: NSRect? {
        popupDrop.isHidden ? nil : window.convertToScreen(popupDrop.convert(popupDrop.bounds, to: nil))
    }

    // A link on the glass view ticks with the display the glass is on. The caller owns it and invalidates it.
    func makeDisplayLink(target: Any, selector: Selector) -> CADisplayLink {
        container.displayLink(target: target, selector: selector)
    }

    func close() { window.close() }
}
