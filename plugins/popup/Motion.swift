import AppKit
import os

// A critically damped spring. A new target keeps the current value and velocity,
// so an island that changes its mind mid-flight neither jumps nor stalls.
struct Spring {
    var value: CGFloat
    var velocity: CGFloat = 0
    var target: CGFloat

    init(_ value: CGFloat) { self.value = value; target = value }

    mutating func step(_ seconds: CGFloat, response: CGFloat) {
        guard response > 0 else { settle(); return }
        let omega = 2 * .pi / response
        let offset = value - target
        let rate = velocity + omega * offset
        let decay = exp(-omega * seconds)
        value = target + (offset + rate * seconds) * decay
        velocity = (rate - omega * (offset + rate * seconds)) * decay
    }

    mutating func settle() { value = target; velocity = 0 }

    var settled: Bool { abs(value - target) < 0.25 && abs(velocity) < 2 }
}

// Moves the glass. Each island drop has one Spring per horizontal edge: y and height do not move. The popup drop
// has one per edge. Popups owns the one Motion. It owns the display link, which runs only while a spring is
// unsettled and is invalidated once every spring has settled, on a screen change, and at shutdown.
// It also owns the popup window's opacity, which follows the popup drop's geometry.
final class Motion: NSObject {
    private struct Drop {
        var minX: Spring
        var maxX: Spring
        var minY: CGFloat
        var height: CGFloat
        var response: CGFloat
        var interval: OSSignpostIntervalState?

        var settled: Bool { minX.settled && maxX.settled }
        var frame: NSRect { NSRect(x: minX.value, y: minY, width: maxX.value - minX.value, height: height) }
    }

    // The popup drop. It grows out of a pill, slides to the next popup, and is drawn back into its pill.
    private struct Popup {
        enum Phase { case open, retracting }
        var minX: Spring, maxX: Spring, minY: Spring, maxY: Spring
        var phase = Phase.open
        var response: CGFloat
        // The largest edge distance at the start of the current move. Progress is 1 - remaining / total.
        var total: CGFloat = 0
        // The content's opacity. It follows the geometry: up while the drop opens, down while it retracts.
        var alpha: CGFloat = 0
        var interval: OSSignpostIntervalState?
        var done: (() -> Void)?

        init(at frame: NSRect, response: CGFloat) {
            minX = Spring(frame.minX); maxX = Spring(frame.maxX); minY = Spring(frame.minY); maxY = Spring(frame.maxY)
            self.response = response
        }

        var settled: Bool { minX.settled && maxX.settled && minY.settled && maxY.settled }
        var frame: NSRect { NSRect(x: minX.value, y: minY.value, width: max(0, maxX.value - minX.value), height: max(0, maxY.value - minY.value)) }
        var target: NSRect { NSRect(x: minX.target, y: minY.target, width: maxX.target - minX.target, height: maxY.target - minY.target) }
        var remaining: CGFloat {
            max(abs(minX.value - minX.target), abs(maxX.value - maxX.target), abs(minY.value - minY.target), abs(maxY.value - maxY.target))
        }
        var progress: CGFloat { total > 0 ? min(1, max(0, 1 - remaining / total)) : 1 }

        mutating func aim(at frame: NSRect) {
            minX.target = frame.minX; maxX.target = frame.maxX; minY.target = frame.minY; maxY.target = frame.maxY
        }

        mutating func step(_ seconds: CGFloat) {
            minX.step(seconds, response: response); maxX.step(seconds, response: response)
            minY.step(seconds, response: response); maxY.step(seconds, response: response)
        }

        mutating func settle() { minX.settle(); maxX.settle(); minY.settle(); maxY.settle() }
    }

    // Under Reduce Motion the content fades over COLOR_ANIM's tanh 10, which is 10 frames at 60 Hz.
    private static let fadeDuration: TimeInterval = 10.0 / 60

    private let glass: GlassLayer
    private let content: NSWindow
    private var drops: [Island: Drop] = [:]
    private var popup: Popup?
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?
    // The task that waits for an animated fade to end and then runs its follow-up. Any other opacity change
    // cancels it, and so does `stop`.
    private var fadeTask: Task<Void, Never>?
    private var fading = false

    // `content` is the popup's window, which holds the popup's views on a clear background.
    init(glass: GlassLayer, content: NSWindow) {
        self.glass = glass
        self.content = content
        super.init()
    }

    var popupShowing: Bool { popup != nil }

    private var idle: Bool { drops.values.allSatisfy(\.settled) && popup?.settled != false }

    // Points each island's edges at a new frame. An island seen for the first time, and every island while
    // Reduce Motion is on, settles at once. Otherwise the springs keep their value and velocity.
    func retarget(_ frames: [Island: NSRect], response: CGFloat) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if reduceMotion { for island in Array(drops.keys) where drops[island]?.settled == false { settle(island) } }
        for (island, frame) in frames {
            guard var drop = drops[island] else {
                var drop = Drop(minX: Spring(frame.minX), maxX: Spring(frame.maxX), minY: frame.minY, height: frame.height, response: response)
                drop.minX.settle()
                drops[island] = drop
                glass.place([island: frame])
                logPlacement(island, frame)
                continue
            }
            guard abs(drop.minX.target - frame.minX) > 0.01 || abs(drop.maxX.target - frame.maxX) > 0.01
                    || drop.minY != frame.minY || drop.height != frame.height else { continue }
            let from = drop.frame
            drop.minY = frame.minY
            drop.height = frame.height
            drop.response = response
            drop.minX.target = frame.minX
            drop.maxX.target = frame.maxX
            motionLogger.debug("event=spring_retarget island=\(island.rawValue, privacy: .public) t=\(CACurrentMediaTime(), privacy: .public) from=\(Double(from.minX), privacy: .public),\(Double(from.maxX), privacy: .public) to=\(Double(frame.minX), privacy: .public),\(Double(frame.maxX), privacy: .public) response=\(Double(response), privacy: .public) reduce_motion=\(reduceMotion, privacy: .public)")
            drops[island] = drop
            if reduceMotion || drop.settled {
                settle(island)
            } else if drop.interval == nil {
                drops[island]?.interval = motionSignposter.beginInterval("spring", id: motionSignposter.makeSignpostID(),
                    "island=\(island.rawValue, privacy: .public) from_min=\(Double(from.minX), privacy: .public) from_max=\(Double(from.maxX), privacy: .public) to_min=\(Double(frame.minX), privacy: .public) to_max=\(Double(frame.maxX), privacy: .public) response=\(Double(response), privacy: .public)")
            }
        }
        updateLink()
    }

    // The popup opens out of its pill: the drop starts as the pill's rect and springs to the popup's frame.
    func emerge(from pill: NSRect, to frame: NSRect, response: CGFloat) {
        popup = Popup(at: pill, response: response)
        glass.extend(to: frame)
        placePopup(pill, settled: false)
        setAlpha(0)
        aim(at: frame, phase: .open, newContent: true, response: response)
    }

    // Another popup opens while one shows or retracts: the same springs retarget and keep their speed. A new
    // popup's content starts at zero opacity. The same popup changing size keeps what it has shown.
    func slide(to frame: NSRect, newContent: Bool, response: CGFloat) {
        guard popup != nil else { return }
        glass.extend(to: frame)
        aim(at: frame, phase: .open, newContent: newContent, response: response)
    }

    // The drop is drawn back into its pill, then hidden, then `then` runs. A slide or an emerge before that
    // retargets the drop and drops `then`. Under Reduce Motion the drop stays and the content fades.
    func retract(into pill: NSRect, response: CGFloat, then: @escaping () -> Void) {
        guard var current = popup, current.phase == .open else { return }
        current.done = then
        popup = current
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            popup?.phase = .retracting
            fade(to: 0) { [weak self] in self?.finishRetract() }
        } else {
            aim(at: pill, phase: .retracting, newContent: false, response: response)
        }
    }

    // Ends every motion and forgets the drops, so the next placement settles at once. Also the shutdown path.
    func stop() {
        stopLink()
        for island in Array(drops.keys) { endInterval(island) }
        drops.removeAll()
        if let interval = popup?.interval { motionSignposter.endInterval("spring", interval, "island=popup stopped") }
        popup = nil
        setAlpha(1)
        glass.hidePopup()
    }

    private func updateLink() {
        if idle { stopLink() } else { startLink() }
    }

    // Points the popup drop's four edges at a frame. It settles at once under Reduce Motion, and the content
    // fades in place when the content is new.
    private func aim(at frame: NSRect, phase: Popup.Phase, newContent: Bool, response: CGFloat) {
        guard var popup else { return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let from = popup.frame
        let target = popup.target
        let moved = abs(target.minX - frame.minX) > 0.01 || abs(target.maxX - frame.maxX) > 0.01
            || abs(target.minY - frame.minY) > 0.01 || abs(target.maxY - frame.maxY) > 0.01
        let phaseChanged = popup.phase != phase
        guard moved || phaseChanged || newContent else { return }
        popup.phase = phase
        popup.done = phase == .open ? nil : popup.done
        popup.response = response
        popup.aim(at: frame)
        popup.total = newContent || phaseChanged ? popup.remaining : max(popup.total, popup.remaining)
        if newContent { popup.alpha = 0 }
        if moved {
            motionLogger.debug("event=spring_retarget island=popup t=\(CACurrentMediaTime(), privacy: .public) from=\(Double(from.minX), privacy: .public),\(Double(from.minY), privacy: .public),\(Double(from.maxX), privacy: .public),\(Double(from.maxY), privacy: .public) to=\(Double(frame.minX), privacy: .public),\(Double(frame.minY), privacy: .public),\(Double(frame.maxX), privacy: .public),\(Double(frame.maxY), privacy: .public) response=\(Double(response), privacy: .public) reduce_motion=\(reduceMotion, privacy: .public)")
        }
        if reduceMotion {
            popup.settle()
            popup.alpha = 1
            self.popup = popup
            endPopupInterval()
            placePopup(popup.frame, settled: true)
            if newContent {
                setAlpha(0)
                fade(to: 1)
            }
        } else if popup.settled {
            self.popup = popup
            settlePopup()
        } else {
            if popup.interval == nil {
                popup.interval = motionSignposter.beginInterval("spring", id: motionSignposter.makeSignpostID(),
                    "island=popup from_min=\(Double(from.minX), privacy: .public) from_max=\(Double(from.maxX), privacy: .public) to_min=\(Double(frame.minX), privacy: .public) to_max=\(Double(frame.maxX), privacy: .public) response=\(Double(response), privacy: .public)")
            }
            self.popup = popup
            updateAlpha()
        }
        updateLink()
    }

    // Opacity follows the geometry, so an interrupted move never leaves the content out of step with the glass.
    // The drop opening raises it from half the way, and never lowers it. The drop retracting lowers it until half
    // the way back, and never raises it.
    private func updateAlpha() {
        guard var popup else { return }
        switch popup.phase {
        case .open: popup.alpha = max(popup.alpha, min(1, max(0, (popup.progress - 0.5) * 2)))
        case .retracting: popup.alpha = min(popup.alpha, min(1, max(0, (0.5 - popup.progress) * 2)))
        }
        self.popup = popup
        setAlpha(popup.alpha)
    }

    // Sets the content's opacity now, replacing any fade in flight.
    private func setAlpha(_ alpha: CGFloat) {
        fadeTask?.cancel()
        fadeTask = nil
        if fading {
            fading = false
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                content.animator().alphaValue = alpha
            }
        } else if content.alphaValue != alpha {
            content.alphaValue = alpha
        }
    }

    // Fades the content's opacity over COLOR_ANIM's duration. `then` runs at the end unless something else set
    // the opacity first.
    private func fade(to alpha: CGFloat, then: (() -> Void)? = nil) {
        fadeTask?.cancel()
        fadeTask = nil
        fading = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeDuration
            content.animator().alphaValue = alpha
        }
        fadeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.fadeDuration))
            guard !Task.isCancelled, let self else { return }
            self.fadeTask = nil
            self.fading = false
            then?()
        }
    }

    private func settlePopup() {
        guard var popup else { return }
        popup.settle()
        self.popup = popup
        endPopupInterval()
        if popup.phase == .retracting {
            finishRetract()
        } else {
            self.popup?.alpha = 1
            placePopup(popup.frame, settled: true)
            setAlpha(1)
        }
    }

    private func finishRetract() {
        guard let popup, popup.phase == .retracting else { return }
        let done = popup.done
        self.popup = nil
        glass.hidePopup()
        done?()
    }

    private func endPopupInterval() {
        guard let interval = popup?.interval else { return }
        popup?.interval = nil
        motionSignposter.endInterval("spring", interval, "island=popup settled")
    }

    private func startLink() {
        guard link == nil else { return }
        lastTimestamp = nil
        let link = glass.makeDisplayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
    }

    // The link is added to RunLoop.main, so AppKit calls this on the main thread, which is the main actor.
    @objc private func step(_ link: CADisplayLink) {
        let sinceLast = lastTimestamp.map { link.timestamp - $0 } ?? link.targetTimestamp - link.timestamp
        let seconds = CGFloat(min(1 / 30, max(0, sinceLast)))
        lastTimestamp = link.timestamp
        var frames: [Island: NSRect] = [:]
        for island in Array(drops.keys) {
            guard var drop = drops[island], !drop.settled else { continue }
            drop.minX.step(seconds, response: drop.response)
            drop.maxX.step(seconds, response: drop.response)
            drops[island] = drop
            if drop.settled { settle(island) } else { frames[island] = drop.frame }
        }
        glass.place(frames)
        if var moving = popup, !moving.settled {
            moving.step(seconds)
            popup = moving
            if moving.settled {
                settlePopup()
            } else {
                placePopup(moving.frame, settled: false)
                updateAlpha()
            }
        }
        if idle { stopLink() }
    }

    // Places the popup drop and carries the content with it: the content's top centre rides at the drop's top centre,
    // and while the drop moves the content is masked to the drop's shape, so no text shows outside the glass.
    // Settled open, the drop is the panel's frame and the mask goes.
    private func placePopup(_ frame: NSRect, settled: Bool) {
        glass.placePopup(frame)
        let size = content.frame.size
        let origin = NSPoint(x: (frame.midX - size.width / 2).rounded(), y: (frame.maxY - size.height).rounded())
        if content.frame.origin != origin { content.setFrameOrigin(origin) }
        guard let view = content.contentView else { return }
        if settled && popup?.phase != .retracting {
            view.layer?.mask = nil
            return
        }
        view.wantsLayer = true
        let mask = (view.layer?.mask as? CAShapeLayer) ?? CAShapeLayer()
        let inWindow = NSRect(x: frame.minX - origin.x, y: frame.minY - origin.y, width: frame.width, height: frame.height)
        let radius = min(glass.popupRadius, frame.width / 2, frame.height / 2)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.frame = view.bounds
        mask.path = CGPath(roundedRect: view.convert(inWindow, from: nil), cornerWidth: radius, cornerHeight: radius, transform: nil)
        if view.layer?.mask !== mask { view.layer?.mask = mask }
        CATransaction.commit()
    }

    // Snaps an island to its target and ends its interval.
    private func settle(_ island: Island) {
        guard var drop = drops[island] else { return }
        drop.minX.settle()
        drop.maxX.settle()
        drops[island] = drop
        endInterval(island)
        glass.place([island: drop.frame])
        logPlacement(island, drop.frame)
    }

    private func endInterval(_ island: Island) {
        guard let interval = drops[island]?.interval else { return }
        drops[island]?.interval = nil
        motionSignposter.endInterval("spring", interval, "island=\(island.rawValue, privacy: .public) settled")
    }

    private func logPlacement(_ island: Island, _ bracket: NSRect) {
        let placed = glass.frame(of: island).map(NSStringFromRect) ?? "hidden"
        interactionLogger.debug("event=glass_place island=\(island.rawValue, privacy: .public) drop=\(placed, privacy: .public) bracket=\(NSStringFromRect(bracket), privacy: .public)")
    }
}
