import AppKit
import CoreAudio
import EventKit

final class Popups: NSObject, NSApplicationDelegate {
    static let notification = Notification.Name("com.bjoernaagaard.sketchybar.popup")

    let theme: Theme

    let panel = PopupPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)

    var lifecycle: PopupLifecycle = .closed

    var item: PopupKind? { lifecycle.target?.kind }

    var candidateTask: Task<Void, Never>?

    var candidate: PopupTarget?

    var candidateProbes: [String: Task<Void, Never>] = [:]

    var probeSources: [String: PopupSource] = [:]

    var pendingClick: NSPoint?

    var geometryGeneration = 0

    var geometryTask: Task<Void, Never>?

    var refreshTask: Task<Void, Never>?

    var mediaActionTask: Task<Void, Never>?

    var mediaActionTasks: [UUID: Task<Void, Never>] = [:]

    var suppressionPoints: [NSPoint] = []

    var openingHasAnchor = false

    var pointerManagesPopup = true

    var anchor = NSRect.zero

    var monitors: [Any] = []

    var timer: Timer?

    var slider: NSSlider?

    var percentage: NSTextField?

    var mute: NSButton?

    var deviceSignature = ""

    var networkState: NetworkState?

    let bluetooth = Bluetooth()
    var bluetoothSignature = ""
    var bluetoothErrors: [String: String] = [:]
    var bluetoothPendingOutput: BluetoothOutputRequest?
    var bluetoothOutputListener: Audio.Listener?
    var bluetoothOutputWatches: [(id: AudioObjectID, address: AudioObjectPropertyAddress)] = []
    var bluetoothScroll: NSScrollView?

    var front: FrontSnapshot?

    var information: [String] = []

    var media: MediaSnapshot?

    var mediaError: MediaError?

    var mediaSlider: NSSlider?

    var mediaElapsed: NSTextField?

    var mediaDuration: NSTextField?

    var mediaSeeking = false

    var pendingMediaSeek: PendingMediaSeek?

    var initialCommand = PopupCommand.toggle(.volume)

    var notchTask: Task<Void, Never>?

    var lock: Int32 = -1
    lazy var eventStore = EKEventStore()
    var calendarAccessTask: Task<Void, Never>?

    var events: [CalendarEvent] = []

    var calendarBusy = false

    var calendarDirty = true

    var calendarMinute = -1

    var calendarError: (any Error)?

    var tailscale: Result<Tailscale, TailscaleError>?

    var tailscaleRead = Date.distantPast
    // One CLI write at a time. Its process is owned here and ended at shutdown.
    var tailscaleCommand: Task<Void, Never>?

    var tailscaleLogin = false

    let bar: BarFeed
    // The islands' and the popup's glass, the springs that move it, and the one task that reads the brackets to
    // retarget the islands. A new read replaces a pending one. The panel holds the popup's content and input only;
    // its glass is a drop in GlassLayer that moves with Motion.
    let glass: GlassLayer

    let motion: Motion

    var islandsTask: Task<Void, Never>?
    // The popup whose content the panel shows now. A rebuild of the same popup keeps its content visible.
    var contentTarget: UUID?
    // SketchyBar's arrangement index of the main display. It changes only with the displays, so it is read
    // once and forgotten when they change.
    var displayIndex: Int?
    // One media-control stream feeds the bar item and the media popup.
    var mediaStream: Task<Void, Never>?

    var streamedMedia: MediaSnapshot?
    // What the bar item shows, and the one task that fits it. A new fit replaces a pending one.
    var mediaDisplay: MediaDisplay?

    var mediaFitTask: Task<Void, Never>?
    var workspaceTask: Task<Void, Never>?
    var workspaceDirty = false
    var workspaceRetry = 0
    var layoutDirty = false
    var layoutRevision = 0
    var mediaStyle: MediaStyle?
    var mediaVisibility: MediaVisibility = .visible
    var volumeStageMismatch: (VolumeStatus, String)?
    var colorAnimation: [String] = []
    var layoutFrames: [Island: NSRect] = [:]
    // The loop moves the progress plate while a track plays.
    var mediaProgressLoop: Task<Void, Never>?
    // The system popup shows the bar's latest sample and adds GPU and top processes while open.
    var systemShown: SystemSample?

    var processes = ProcessSampler()

    var topProcesses: [ProcessLoad] = []

    init(theme: Theme) {
        self.theme = theme
        bar = BarFeed(sketchybar: URL(fileURLWithPath: theme.sketchybarPath))
        glass = GlassLayer(theme: theme)
        motion = Motion(glass: glass, content: panel)
        super.init()
        bar.volumeChanged = { [weak self] in self?.requestLayout() }
    }

    var isOpen: Bool {
        if case .open = lifecycle { return true }
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        glass.show()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.acceptsMouseMovedEvents = true
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged], handler: { [weak self] _ in
            self?.pointerMoved()
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged], handler: { [weak self] event in
            self?.pointerMoved()
            return event
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] _ in
            guard let self, self.isOpen || self.candidate != nil else { return }
            self.outsideClick(at: NSEvent.mouseLocation)
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] event in
            guard let self, self.lifecycle.target != nil || self.candidate != nil else { return event }
            let point = NSEvent.mouseLocation
            if !(self.isOpen && self.panel.frame.contains(point)) { self.outsideClick(at: point) }
            return event
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            if event.keyCode == 53, let self, self.lifecycle.target != nil || self.candidate != nil {
                interactionLogger.debug("event=dismiss_reason reason=escape")
                self.close()
            }
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            if event.keyCode == 53, let self, self.lifecycle.target != nil || self.candidate != nil {
                interactionLogger.debug("event=dismiss_reason reason=escape")
                self.close()
                return nil
            }
            return event
        }) { monitors.append(monitor) }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(close), name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(woke), name: NSWorkspace.didWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(close), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(calendarChanged), name: .EKEventStoreChanged, object: nil)
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            // This timer is installed only on RunLoop.main. Assert that SDK boundary.
            MainActor.assumeIsolated {
                guard let self else { return }
                if kill(self.theme.barPID, 0) != 0 { NSApp.terminate(nil) }
                if self.workspaceDirty && self.workspaceTask == nil { self.requestLayout() }
                guard self.isOpen else { return }
                switch self.item {
                case .volume: self.refreshVolume()
                case .network: self.refreshNetwork()
                case .bluetooth: self.refreshBluetooth()
                case .tailscale: if Date().timeIntervalSince(self.tailscaleRead) >= 2 { self.refreshTailscale() }
                case .media: self.refreshMedia()
                case .clock:
                    if self.calendarMinute != Int(Date().timeIntervalSince1970 / 60) || self.calendarDirty { self.loadCalendar() }
                case .system: if self.bar.system != self.systemShown { self.refreshSystem() }
                case .front: self.refreshFront()
                case .battery, .workspace, .mode: self.refreshInformation()
                case nil: break
                }
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        bar.start()
        refreshIslands()
        startMediaStream()
        // The bar can send its first update before distributed notifications are observed.
        updateWorkspace(retry: 0)
        switch initialCommand {
        case .toggle(let source): show(source, requiresPointer: source.kind != .bluetooth)
        case .hover(let source): show(source)
        case .volumeScroll(let notches): scrollVolume(notches)
        case .media(let action): performMedia(action)
        case .workspaceUpdate(let retry): updateWorkspace(retry: retry)
        case .geometry, .start, .hoverEnd, .stop: break
        }
    }

    @objc func woke() {
        bar.pushAll()
        fitMedia(after: .milliseconds(50))
        refreshIslands(after: .milliseconds(350))
    }

    @objc func screensChanged() {
        close()
        glass.moveToBarScreen()
        // The glass jumps to the new display instead of springing across it. That drops a retract in flight, so
        // the panel goes now.
        motion.stop()
        panel.orderOut(nil)
        displayIndex = nil
        // notch.sh sets the notch width for the new display, which moves the media island.
        fitMedia(after: .milliseconds(50))
        refreshIslands(after: .milliseconds(350), remeasureDisplay: true)
        notchTask?.cancel()
        notchTask = Task { [weak self] in await self?.trigger("notch_change") }
    }

    func applicationWillTerminate(_ notification: Notification) {
        clearBluetoothOutputRequest()
        bluetooth.shutdown()
        calendarAccessTask?.cancel()
        calendarAccessTask = nil
        candidateTask?.cancel()
        candidateTask = nil
        candidate = nil
        close()
        for task in mediaActionTasks.values { task.cancel() }
        mediaActionTasks.removeAll()
        tailscaleCommand?.cancel()
        tailscaleCommand = nil
        notchTask?.cancel()
        notchTask = nil
        mediaFitTask?.cancel()
        mediaFitTask = nil
        workspaceTask?.cancel()
        workspaceTask = nil
        islandsTask?.cancel()
        islandsTask = nil
        motion.stop()
        glass.close()
        mediaProgressLoop?.cancel()
        mediaProgressLoop = nil
        mediaStream?.cancel()
        mediaStream = nil
        bar.stop()
        ProcessCapture.terminateRunningChildren()
        timer?.invalidate()
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
    }

    @objc func receive(_ notification: Notification) {
        guard let command = PopupCommand(userInfo: notification.userInfo) else { return }
        switch command {
        case .hover(let source):
            interactionLogger.debug("event=received action=hover kind=\(source.kind.rawValue, privacy: .public)")
        case .toggle(let source):
            interactionLogger.debug("event=received action=toggle kind=\(source.kind.rawValue, privacy: .public)")
        case .hoverEnd(let source):
            interactionLogger.debug("event=received action=hover-end kind=\(source.kind.rawValue, privacy: .public)")
        default: break
        }
        switch command {
        case .stop: NSApp.terminate(nil)
        case .volumeScroll(let notches): scrollVolume(notches)
        case .geometry: geometryChanged()
        case .workspaceUpdate(let retry): updateWorkspace(retry: retry)
        case .hover(let source): show(source)
        case .hoverEnd(let source):
            if lifecycle.target?.source.identity == source.identity { pointerMoved() }
            else if case .dismissed(let identity, _) = lifecycle, identity == source.identity { pointerMoved() }
        case .start:
            bar.pushAll()
            fitMedia()
            refreshIslands()
        case .toggle(let source): show(source, requiresPointer: source.kind != .bluetooth)
        case .media(let action): performMedia(action)
        }
    }

    func outsideClick(at point: NSPoint) {
        if openingHasAnchor && anchor.contains(point) { return }
        if candidate != nil {
            interactionLogger.debug("event=pending_click candidate=\(self.candidate?.id.uuidString ?? "none", privacy: .public)")
            pendingClick = point
        } else {
            interactionLogger.debug("event=dismiss_reason reason=outside_click kind=\(self.item?.rawValue ?? "none", privacy: .public)")
            close()
        }
    }

    func geometryChanged(refitMedia: Bool = true) {
        refreshIslands()
        if refitMedia { fitMedia() }
        geometryGeneration += 1
        geometryTask?.cancel()
        geometryTask = nil
        guard let target = lifecycle.target, openingHasAnchor else { return }
        let generation = geometryGeneration
        let source: PopupSource
        switch target.source {
        case .front, .frontIcon: source = .front
        case .system, .cpu, .memory: source = .system
        case .workspace(let id, _): source = .workspace(id, "ws.\(id)")
        default: source = target.source
        }
        geometryTask = Task { [weak self] in
            guard let self else { return }
            let rect = await self.queryAnchor(source)
            guard !Task.isCancelled, self.geometryGeneration == generation,
                  self.lifecycle.target?.id == target.id else { return }
            self.geometryTask = nil
            guard let rect else { return }
            self.anchor = rect
            if self.isOpen {
                let screen = NSScreen.screens.first { $0.frame.intersects(rect) } ?? NSScreen.screens[0]
                let inset = self.theme.number("POPUP_GAP")
                let frame = self.panel.frame
                let x = max(screen.frame.minX + inset, min(rect.midX - frame.width / 2, screen.frame.maxX - inset - frame.width))
                self.panel.setFrameOrigin(NSPoint(x: x, y: rect.minY - inset - frame.height))
                self.motion.slide(to: self.panel.frame, newContent: false, response: self.theme.number("SPRING_EMERGE"))
            }
            self.pointerMoved()
        }
    }

    func pointerMoved() {
        let point = NSEvent.mouseLocation
        if case .dismissed(_, let bounds) = lifecycle {
            if let bounds {
                if !bounds.contains(point) { lifecycle = .closed }
            } else {
                suppressionPoints.append(point)
                if suppressionPoints.count > 4 {
                    suppressionPoints = [suppressionPoints.min(by: { $0.x < $1.x }), suppressionPoints.max(by: { $0.x < $1.x }),
                                         suppressionPoints.min(by: { $0.y < $1.y }), suppressionPoints.max(by: { $0.y < $1.y })].compactMap { $0 }
                }
            }
            return
        }
        guard lifecycle.target != nil, openingHasAnchor, geometryTask == nil else { return }
        if !pointerManagesPopup {
            guard anchor.contains(point) || (isOpen && panel.frame.contains(point)) else { return }
            pointerManagesPopup = true
        }
        if anchor.contains(point) { return }
        if isOpen {
            let popup = panel.frame
            if popup.contains(point) { return }
            let left = max(anchor.minX, popup.minX)
            let right = min(anchor.maxX, popup.maxX)
            if right > left {
                let corridor = NSRect(x: left, y: popup.maxY, width: right - left, height: max(0, anchor.minY - popup.maxY))
                if corridor.contains(point) { return }
            }
        }
        interactionLogger.debug("event=dismiss_reason reason=pointer_exit kind=\(self.item?.rawValue ?? "none", privacy: .public)")
        dismiss(suppress: false)
    }

    func show(_ source: PopupSource, requiresPointer: Bool = true) {
        if lifecycle.target?.source.identity == source.identity {
            interactionLogger.debug("event=show_ignored reason=already_active kind=\(source.kind.rawValue, privacy: .public)")
            return
        }
        if candidate?.source.identity == source.identity {
            interactionLogger.debug("event=show_ignored reason=already_candidate kind=\(source.kind.rawValue, privacy: .public)")
            return
        }
        if case .dismissed(let identity, let bounds) = lifecycle, identity == source.identity {
            guard let bounds else {
                interactionLogger.debug("event=show_ignored reason=suppressed_pending kind=\(source.kind.rawValue, privacy: .public)")
                return
            }
            if bounds.contains(NSEvent.mouseLocation) {
                interactionLogger.debug("event=show_ignored reason=suppressed_inside kind=\(source.kind.rawValue, privacy: .public)")
                return
            }
        }
        if candidate != nil {
            guard candidateProbes[source.identity] == nil else { return }
            probeSources[source.identity] = source
            interactionLogger.debug("event=probe_start kind=\(source.kind.rawValue, privacy: .public) candidate=\(self.candidate?.id.uuidString ?? "none", privacy: .public)")
            candidateProbes[source.identity] = Task { [weak self] in
                guard let self else { return }
                var rect: NSRect?
                repeat {
                    let generation = self.geometryGeneration
                    rect = await self.queryAnchor(source)
                    guard !Task.isCancelled else {
                        interactionLogger.debug("event=probe_cancelled kind=\(source.kind.rawValue, privacy: .public) generation=\(generation)")
                        return
                    }
                    interactionLogger.debug("event=probe_anchor kind=\(source.kind.rawValue, privacy: .public) generation=\(generation) current_generation=\(self.geometryGeneration) found=\(rect != nil) contains=\(rect?.contains(NSEvent.mouseLocation) == true)")
                    if generation == self.geometryGeneration { break }
                } while true
                self.candidateProbes[source.identity] = nil
                self.probeSources[source.identity] = nil
                guard let rect, rect.contains(NSEvent.mouseLocation) else {
                    interactionLogger.debug("event=probe_rejected kind=\(source.kind.rawValue, privacy: .public) reason=anchor_or_pointer")
                    return
                }
                interactionLogger.debug("event=probe_accepted kind=\(source.kind.rawValue, privacy: .public) replaced_candidate=\(self.candidate?.id.uuidString ?? "none", privacy: .public)")
                self.candidateTask?.cancel()
                self.candidateTask = nil
                self.candidate = nil
                self.pendingClick = nil
                self.show(source)
            }
            return
        }
        if case .dismissed(_, nil) = lifecycle { lifecycle = .closed; suppressionPoints.removeAll() }
        let target = PopupTarget(id: UUID(), source: source)
        candidate = target
        interactionLogger.debug("event=candidate_start kind=\(source.kind.rawValue, privacy: .public) id=\(target.id.uuidString, privacy: .public) generation=\(self.geometryGeneration)")
        let next = source.kind
        candidateTask = Task { [weak self] in
            guard let self else { return }
            var rect: NSRect?
            repeat {
                let generation = self.geometryGeneration
                rect = await self.queryAnchor(source)
                guard !Task.isCancelled, self.candidate?.id == target.id else {
                    interactionLogger.debug("event=candidate_cancelled kind=\(next.rawValue, privacy: .public) id=\(target.id.uuidString, privacy: .public) cancelled=\(Task.isCancelled) current=\(self.candidate?.id == target.id)")
                    return
                }
                interactionLogger.debug("event=candidate_anchor kind=\(next.rawValue, privacy: .public) id=\(target.id.uuidString, privacy: .public) generation=\(generation) current_generation=\(self.geometryGeneration) found=\(rect != nil) contains=\(rect?.contains(NSEvent.mouseLocation) == true)")
                if generation == self.geometryGeneration { break }
            } while true
            if let point = self.pendingClick {
                self.pendingClick = nil
                if rect?.contains(point) != true { self.close() }
            }
            self.candidate = nil
            self.candidateTask = nil
            if case .dismissed(let identity, nil) = self.lifecycle, identity == source.identity {
                interactionLogger.debug("event=candidate_rejected kind=\(next.rawValue, privacy: .public) id=\(target.id.uuidString, privacy: .public) reason=suppressed")
                let exited = rect.map { bounds in self.suppressionPoints.contains { !bounds.contains($0) } } ?? true
                self.suppressionPoints.removeAll()
                if let rect, !exited, rect.contains(NSEvent.mouseLocation) {
                    self.lifecycle = .dismissed(identity, rect)
                } else {
                    self.lifecycle = .closed
                    if let rect, exited, rect.contains(NSEvent.mouseLocation) { self.show(source) }
                }
                return
            }
            guard let rect, !requiresPointer || rect.contains(NSEvent.mouseLocation) else {
                interactionLogger.debug("event=candidate_rejected kind=\(next.rawValue, privacy: .public) id=\(target.id.uuidString, privacy: .public) reason=anchor_or_pointer")
                if let source = self.probeSources.values.first {
                    self.candidateProbes[source.identity]?.cancel()
                    self.candidateProbes[source.identity] = nil
                    self.probeSources[source.identity] = nil
                    self.show(source)
                }
                return
            }
            interactionLogger.debug("event=candidate_accepted kind=\(next.rawValue, privacy: .public) id=\(target.id.uuidString, privacy: .public)")
            // The panel and its drop stay: the new popup slides the same drop, or turns a retract around.
            self.dismiss(suppress: false, replacing: true)
            self.lifecycle = .opening(target)
            self.panel.ignoresMouseEvents = false
            self.anchor = rect
            self.openingHasAnchor = true
            self.pointerManagesPopup = requiresPointer || rect.contains(NSEvent.mouseLocation)
            switch next {
            case .volume: self.buildVolume()
            case .bluetooth: self.buildBluetooth()
            case .network:
                self.networkState = readNetworkState(context: "opening")
                self.buildNetwork()
            case .tailscale:
                self.tailscale = nil
                self.buildTailscale()
            case .media:
                self.media = self.streamedMedia
                self.mediaError = nil
                self.buildMedia()
            case .clock:
                self.events = []
                self.calendarError = nil
                self.buildCalendar()
            case .system:
                if self.bar.system == nil { self.bar.sampleSystem() }
                self.processes = ProcessSampler()
                self.topProcesses = self.processes.sample(count: 3) ?? []
                self.buildSystem()
            case .front:
                self.front = nil
                self.buildFront()
            case .battery, .workspace, .mode:
                self.information = ["Loading"]
                self.buildInformation()
            }
            guard !Task.isCancelled, self.lifecycle.target?.id == target.id else {
                interactionLogger.debug("event=panel_cancelled kind=\(next.rawValue, privacy: .public) id=\(target.id.uuidString, privacy: .public)")
                return
            }
            self.lifecycle = .open(target)
            self.panel.makeKeyAndOrderFront(nil)
            interactionLogger.debug("event=panel_ordered kind=\(next.rawValue, privacy: .public) id=\(target.id.uuidString, privacy: .public) panel=popup")
            if next == .volume { self.panel.makeFirstResponder(self.slider) }
            if next == .clock { self.loadCalendar() }
            if next == .tailscale { self.refreshTailscale() }
            if next == .media { self.refreshMedia() }
            if next == .front { self.refreshFront() }
            if next == .battery || next == .workspace || next == .mode { self.refreshInformation() }
            if requiresPointer { self.pointerMoved() }
        }
    }

    @objc func close() { dismiss(suppress: true) }

    // `replacing` is for a popup that opens in the place of this one: its drop slides on instead of retracting.
    func dismiss(suppress: Bool, replacing: Bool = false) {
        if lifecycle.target?.kind == .bluetooth {
            bluetoothScroll = nil
        }
        let target = suppress ? (candidate ?? lifecycle.target) : lifecycle.target
        if let target {
            interactionLogger.debug("event=dismiss kind=\(target.kind.rawValue, privacy: .public) id=\(target.id.uuidString, privacy: .public) reason=\(suppress ? "close" : "replacement_or_pointer_exit", privacy: .public) candidate=\(self.candidate?.id.uuidString ?? "none", privacy: .public)")
        }
        let bounds: NSRect? = candidate != nil && suppress ? nil : (openingHasAnchor ? anchor : nil)
        openingHasAnchor = false
        geometryTask?.cancel()
        geometryTask = nil
        for task in candidateProbes.values { task.cancel() }
        candidateProbes.removeAll()
        probeSources.removeAll()
        pendingClick = nil
        refreshTask?.cancel()
        refreshTask = nil
        if suppress, let target {
            suppressionPoints = bounds == nil ? [NSEvent.mouseLocation] : []
            lifecycle = .dismissed(target.source.identity, bounds)
        } else {
            suppressionPoints.removeAll()
            lifecycle = .closed
        }
        mediaSeeking = false
        pendingMediaSeek = nil
        if !replacing { retractPopup() }
    }

    // The drop is drawn back into its pill while the content fades with it, then the panel goes. Until then the
    // panel takes no clicks.
    func retractPopup() {
        panel.ignoresMouseEvents = true
        guard motion.popupShowing else { panel.orderOut(nil); return }
        motion.retract(into: pill(containing: anchor), response: theme.number("SPRING_RETRACT")) { [weak self] in
            self?.panel.orderOut(nil)
        }
    }

    // Where a popup grows out of and is drawn back into: the anchor's span of the island drop that holds it, at the
    // drop's height, so the popup leaves from its item and not from the whole island. A rect outside every island
    // stands for itself.
    func pill(containing rect: NSRect) -> NSRect {
        guard let island = Island.allCases.lazy.compactMap({ self.glass.frame(of: $0) })
            .first(where: { $0.insetBy(dx: -1, dy: -1).contains(rect) }) else { return rect }
        return NSRect(x: rect.minX, y: island.minY, width: rect.width, height: island.height)
    }

    // The panel holds the popup's views on a clear background. Its glass is the popup drop in GlassLayer, which
    // follows the panel's frame: it grows out of the anchor's pill, or slides on from the popup that showed.
    func surface(width: CGFloat, height: CGFloat) -> NSView {
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.screens[0]
        let inset = theme.number("POPUP_GAP")
        let x = max(screen.frame.minX + inset, min(anchor.midX - width / 2, screen.frame.maxX - inset - width))
        let visibleHeight = min(height, anchor.minY - screen.visibleFrame.minY - inset * 2)
        panel.setFrame(NSRect(x: x, y: anchor.minY - inset - visibleHeight, width: width, height: visibleHeight), display: false)
        let view = FlippedView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        if height > visibleHeight {
            let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: visibleHeight))
            let scroll = NSScrollView(frame: container.bounds.insetBy(dx: 1, dy: theme.number("POPUP_RADIUS")))
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = true
            scroll.documentView = view
            container.addSubview(scroll)
            panel.contentView = container
        } else {
            panel.contentView = view
        }
        panel.title = item?.rawValue ?? ""
        if let id = lifecycle.target?.id {
            let response = theme.number("SPRING_EMERGE")
            let newContent = contentTarget != id
            contentTarget = id
            if motion.popupShowing {
                motion.slide(to: panel.frame, newContent: newContent, response: response)
            } else {
                motion.emerge(from: pill(containing: anchor), to: panel.frame, response: response)
            }
        }
        return view
    }

    @discardableResult func label(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat, color: String = "TEXT", in view: NSView) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.frame = NSRect(x: x, y: y, width: width, height: 22)
        field.font = theme.font
        field.textColor = theme.color(color)
        field.lineBreakMode = .byTruncatingTail
        field.toolTip = text
        view.addSubview(field)
        return field
    }

    func openSettings(_ address: String) {
        // Callers pass fixed URL literals. A parse failure is a programmer mistake.
        guard let url = URL(string: address) else { preconditionFailure("Invalid settings URL: \(address)") }
        NSWorkspace.shared.open(url)
        close()
    }
}
