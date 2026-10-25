import AppKit
import CoreAudio
import EventKit

// System frameworks only. This process owns popups, never another bar.
struct Audio {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func scalar<T>(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress, _ initial: T) -> T? {
        var address = address
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
        }
        return status == noErr ? value : nil
    }

    static func set<T>(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress, _ value: T) throws {
        var address = address
        var value = value
        let status = withUnsafePointer(to: &value) {
            AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<T>.size), $0)
        }
        if status != noErr { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    static func writable(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        var writable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(id, &address, &writable) == noErr && writable.boolValue
    }

    static var current: AudioObjectID {
        scalar(system, address(kAudioHardwarePropertyDefaultOutputDevice), AudioObjectID(0)) ?? 0
    }

    static func devices() -> [(id: AudioObjectID, name: String)] {
        var property = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &property, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &property, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var streams = address(kAudioDevicePropertyStreams, kAudioDevicePropertyScopeOutput)
            var bytes: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &bytes) == noErr, bytes > 0,
                  scalar(id, address(kAudioDevicePropertyDeviceIsAlive), UInt32(0)) == 1 else { return nil }
            var name: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var nameProperty = address(kAudioObjectPropertyName)
            guard AudioObjectGetPropertyData(id, &nameProperty, 0, nil, &nameSize, &name) == noErr,
                  let name else { return nil }
            return (id, name.takeRetainedValue() as String)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func channels(_ id: AudioObjectID) -> [AudioObjectPropertyElement] {
        var property = address(kAudioDevicePropertyStreamConfiguration, kAudioDevicePropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &property, 0, nil, &size) == noErr, size > 0 else { return [] }
        let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { memory.deallocate() }
        guard AudioObjectGetPropertyData(id, &property, 0, nil, &size, memory) == noErr else { return [] }
        let buffers = UnsafeMutableAudioBufferListPointer(memory.assumingMemoryBound(to: AudioBufferList.self))
        let count = buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
        return count > 0 ? (1...count).map { UInt32($0) } : []
    }

    static func controls(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectPropertyAddress] {
        let main = address(selector, kAudioDevicePropertyScopeOutput)
        if writable(id, main) { return [main] }
        return channels(id).map { address(selector, kAudioDevicePropertyScopeOutput, $0) }.filter { writable(id, $0) }
    }

    static func volume(_ id: AudioObjectID) -> Float? {
        let values = controls(id, kAudioDevicePropertyVolumeScalar).compactMap { scalar(id, $0, Float(0)) }
        return values.isEmpty ? nil : values.reduce(0, +) / Float(values.count)
    }

    static func muted(_ id: AudioObjectID) -> Bool {
        let values = controls(id, kAudioDevicePropertyMute).compactMap { scalar(id, $0, UInt32(0)) }
        return !values.isEmpty && values.allSatisfy { $0 != 0 }
    }

    static func setVolume(_ value: Float) throws {
        let id = current
        for property in controls(id, kAudioDevicePropertyVolumeScalar) { try set(id, property, min(1, max(0, value))) }
    }

    static func setMuted(_ value: Bool) throws {
        let id = current
        for property in controls(id, kAudioDevicePropertyMute) { try set(id, property, UInt32(value ? 1 : 0)) }
    }

    static func select(_ id: AudioObjectID) throws {
        try set(system, address(kAudioHardwarePropertyDefaultOutputDevice), id)
    }

    static func snapshot() -> [String: Any] {
        let id = current
        return ["current": id, "volume": volume(id).map { Int(($0 * 100).rounded()) } as Any? ?? NSNull(),
                "muted": muted(id), "devices": devices().map { ["id": $0.id, "name": $0.name] as [String: Any] }]
    }
}

struct Theme {
    let environment = ProcessInfo.processInfo.environment
    func number(_ name: String) -> CGFloat { CGFloat(Double(environment[name]!)!) }
    func color(_ name: String) -> NSColor {
        let value = UInt32(environment[name]!.replacingOccurrences(of: "0x", with: ""), radix: 16)!
        return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                       green: CGFloat((value >> 8) & 255) / 255,
                       blue: CGFloat(value & 255) / 255,
                       alpha: CGFloat(value >> 24) / 255)
    }
    var font: NSFont { NSFont(name: "SF Pro Semibold", size: 13) ?? .systemFont(ofSize: 13, weight: .semibold) }
}

final class PopupPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
}

final class Surface: NSView {
    let theme: Theme
    init(frame: NSRect, theme: Theme) { self.theme = theme; super.init(frame: frame) }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard enclosingScrollView == nil else { return }
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                               xRadius: theme.number("POPUP_RADIUS"), yRadius: theme.number("POPUP_RADIUS"))
        theme.color("BAR_COLOR").setFill(); path.fill()
        theme.color("BAR_EDGE").setStroke(); path.lineWidth = 1; path.stroke()
    }
}

final class OutputButton: NSButton {
    var device: AudioObjectID = 0
}

struct CalendarEvent {
    let title: String
    let start: Date
    let allDay: Bool
    let calendar: String
    let color: NSColor
}

final class Popups: NSObject, NSApplicationDelegate {
    static let notification = Notification.Name("com.bjoernaagaard.sketchybar.popup")
    let theme = Theme()
    let panel = PopupPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    var item = ""
    var anchor = NSRect.zero
    var monitors: [Any] = []
    var timer: Timer?
    var slider: NSSlider?
    var percentage: NSTextField?
    var mute: NSButton?
    var deviceSignature = ""
    var initialItem = "volume"
    var lock: Int32 = -1
    lazy var eventStore = EKEventStore()
    let calendarQueue = DispatchQueue(label: "sketchybar.calendar")
    var events: [CalendarEvent] = []
    var calendarBusy = false
    var calendarDirty = true
    var calendarMinute = -1
    var calendarError: Error?

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua)
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] _ in
            guard let self, self.panel.isVisible else { return }
            // The source item must reach its click script so a second click toggles closed.
            if !self.anchor.contains(NSEvent.mouseLocation) { self.close() }
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            if event.keyCode == 53 { self?.close(); return nil }
            return event
        }) { monitors.append(monitor) }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(close), name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(close), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(close), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(calendarChanged), name: .EKEventStoreChanged, object: nil)
        timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            if let pid = Int32(self.theme.environment["POPUP_BAR_PID"] ?? ""), kill(pid, 0) != 0 { NSApp.terminate(nil) }
            if self.panel.isVisible {
                if self.item == "volume" { self.refreshVolume() }
                else if self.calendarMinute != Int(Date().timeIntervalSince1970 / 60) || self.calendarDirty { self.loadCalendar() }
            }
        }
        RunLoop.main.add(timer!, forMode: .common)
        toggle(initialItem)
    }

    @objc func receive(_ notification: Notification) {
        guard let item = notification.userInfo?["item"] as? String else { return }
        if item == "stop" { NSApp.terminate(nil) }
        else { toggle(item) }
    }

    func queryAnchor(_ item: String) -> NSRect? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: theme.environment["SB"]!)
        process.arguments = ["--query", item]
        process.standardOutput = pipe
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rects = object["bounding_rects"] as? [String: [String: Any]],
              let rect = rects.sorted(by: { $0.key < $1.key }).first?.value,
              let origin = rect["origin"] as? [Double], let size = rect["size"] as? [Double],
              origin.count == 2, size.count == 2,
              let screen = NSScreen.screens.first else { return nil }
        // SketchyBar uses top-left display coordinates; AppKit uses bottom-left.
        return NSRect(x: origin[0], y: screen.frame.maxY - origin[1] - size[1], width: size[0], height: size[1])
    }

    func toggle(_ next: String) {
        guard next == "volume" || next == "clock" else { return }
        if item == next && panel.isVisible { close(); return }
        guard let rect = queryAnchor(next) else { close(); return }
        item = next
        anchor = rect
        if next == "volume" {
            buildVolume()
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(slider)
        } else {
            events = []
            calendarError = nil
            buildCalendar()
            panel.makeKeyAndOrderFront(nil)
            loadCalendar(requestAccess: true)
        }
    }

    @objc func close() { panel.orderOut(nil) }

    func surface(height: CGFloat) -> Surface {
        let width = theme.number("POPUP_WIDTH")
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.screens[0]
        let inset = theme.number("POPUP_GAP")
        let x = max(screen.frame.minX + inset, min(anchor.midX - width / 2, screen.frame.maxX - inset - width))
        let visibleHeight = min(height, anchor.minY - screen.visibleFrame.minY - inset * 2)
        panel.setFrame(NSRect(x: x, y: anchor.minY - inset - visibleHeight, width: width, height: visibleHeight), display: false)
        let view = Surface(frame: NSRect(x: 0, y: 0, width: width, height: height), theme: theme)
        if height > visibleHeight {
            let background = Surface(frame: NSRect(x: 0, y: 0, width: width, height: visibleHeight), theme: theme)
            let scroll = NSScrollView(frame: background.bounds.insetBy(dx: 1, dy: theme.number("POPUP_RADIUS")))
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = true
            scroll.documentView = view
            background.addSubview(scroll)
            panel.contentView = background
        } else {
            panel.contentView = view
        }
        panel.title = item
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

    func buildVolume() {
        let devices = Audio.devices()
        let pad = theme.number("POPUP_PADDING")
        let width = theme.number("POPUP_WIDTH")
        let row = theme.number("POPUP_ROW")
        let view = surface(height: pad * 2 + row * CGFloat(3 + devices.count))
        label("Volume", x: pad, y: pad, width: width - pad * 2 - 50, in: view)
        percentage = label("", x: width - pad - 50, y: pad, width: 50, color: "TEXT2", in: view)
        percentage?.alignment = .right
        let slider = NSSlider(value: 0, minValue: 0, maxValue: 100, target: self, action: #selector(changeVolume(_:)))
        slider.frame = NSRect(x: pad, y: pad + row, width: width - pad * 2, height: 24)
        slider.isContinuous = true
        slider.trackFillColor = theme.color("TEXT")
        slider.setAccessibilityLabel("Volume")
        view.addSubview(slider)
        self.slider = slider
        let mute = NSButton(checkboxWithTitle: "Mute", target: self, action: #selector(changeMute(_:)))
        mute.frame = NSRect(x: pad, y: pad + row * 2, width: width - pad * 2, height: 24)
        mute.font = theme.font
        mute.contentTintColor = theme.color("TEXT")
        view.addSubview(mute)
        self.mute = mute
        for (index, device) in devices.enumerated() {
            let button = OutputButton(frame: NSRect(x: pad, y: pad + row * CGFloat(3 + index), width: width - pad * 2, height: row))
            button.device = device.id
            // U+2713 was checked against /Library/Fonts/SF-Pro.ttf (glyph 31267).
            button.title = "\(device.id == Audio.current ? "✓" : "  ")  \(device.name)"
            button.font = theme.font
            button.alignment = .left
            button.bezelStyle = .inline
            button.isBordered = false
            button.contentTintColor = theme.color(device.id == Audio.current ? "TEXT" : "TEXT2")
            button.lineBreakMode = .byTruncatingTail
            button.toolTip = device.name
            button.setAccessibilityLabel(device.name)
            button.setAccessibilityValue(device.id == Audio.current ? 1 : 0)
            button.target = self
            button.action = #selector(changeDevice(_:))
            view.addSubview(button)
        }
        deviceSignature = signature(devices)
        refreshVolume()
    }

    func signature(_ devices: [(id: AudioObjectID, name: String)]) -> String {
        "\(Audio.current):" + devices.map { "\($0.id):\($0.name)" }.joined(separator: "|")
    }

    func refreshVolume() {
        guard item == "volume" else { return }
        if signature(Audio.devices()) != deviceSignature { buildVolume(); return }
        let id = Audio.current
        let value = Audio.volume(id)
        slider?.isEnabled = value != nil
        if let value { slider?.doubleValue = Double(value * 100) }
        percentage?.stringValue = value.map { "\(Int(($0 * 100).rounded()))%" } ?? ""
        mute?.isEnabled = !Audio.controls(id, kAudioDevicePropertyMute).isEmpty
        mute?.state = Audio.muted(id) ? .on : .off
    }

    func perform(_ action: () throws -> Void) {
        do { try action() }
        catch { NSAlert(error: error).beginSheetModal(for: panel) }
        refreshVolume()
    }

    @objc func calendarChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.calendarDirty = true
            if self.panel.isVisible && self.item == "clock" { self.loadCalendar() }
        }
    }

    func loadCalendar(requestAccess: Bool = false) {
        guard !calendarBusy else { return }
        let authorization = EKEventStore.authorizationStatus(for: .event)
        if authorization == .notDetermined && requestAccess {
            calendarBusy = true
            buildCalendar()
            eventStore.requestFullAccessToEvents { [weak self] _, error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.calendarBusy = false
                    self.calendarError = error
                    self.loadCalendar()
                }
            }
            return
        }
        calendarMinute = Int(Date().timeIntervalSince1970 / 60)
        calendarDirty = false
        guard authorization == .fullAccess else {
            events = []
            calendarError = calendarError ?? NSError(domain: EKErrorDomain, code: EKError.Code.eventStoreNotAuthorized.rawValue)
            if item == "clock" { buildCalendar() }
            return
        }
        calendarBusy = true
        calendarError = nil
        let store = eventStore
        calendarQueue.async { [weak self] in
            guard let self else { return }
            let now = Date()
            let calendar = Calendar.autoupdatingCurrent
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
            let predicate = store.predicateForEvents(withStart: now, end: tomorrow, calendars: nil)
            // EventKit expands recurring occurrences. Include ongoing and all-day events,
            // but never cancelled, declined, or already-finished occurrences.
            let events = store.events(matching: predicate)
                .filter { event in
                    event.endDate > now && event.startDate < tomorrow && event.status != .canceled &&
                    !(event.attendees ?? []).contains { $0.isCurrentUser && $0.participantStatus == .declined }
                }
                .sorted { $0.startDate == $1.startDate ? ($0.title ?? "") < ($1.title ?? "") : $0.startDate < $1.startDate }
                .map { CalendarEvent(title: $0.title ?? "", start: $0.startDate, allDay: $0.isAllDay,
                                     calendar: $0.calendar.title, color: NSColor(cgColor: $0.calendar.cgColor) ?? .white) }
            DispatchQueue.main.async {
                self.events = events
                self.calendarBusy = false
                if self.item == "clock" { self.buildCalendar() }
            }
        }
    }

    func buildCalendar() {
        let now = Date()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        calendar.firstWeekday = 2
        let first = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!
        let days = calendar.range(of: .day, in: .month, for: now)!
        let offset = (calendar.component(.weekday, from: first) + 5) % 7
        let weeks = (offset + days.count + 6) / 7
        let pad = theme.number("POPUP_PADDING")
        let row = theme.number("POPUP_ROW")
        let width = theme.number("POPUP_WIDTH")
        let column = (width - pad * 2) / 7
        let eventsY = pad + row * CGFloat(weeks + 2) + theme.number("POPUP_GAP")
        let errorHeight: CGFloat = calendarError == nil ? 0 : row * 3
        let view = surface(height: eventsY + row + CGFloat(events.count) * row + errorHeight + pad)
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.calendar = calendar
        formatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        label(formatter.string(from: now), x: pad, y: pad, width: width - pad * 2, in: view)
        let weekdays = formatter.veryShortStandaloneWeekdaySymbols!
        for col in 0..<7 {
            let field = label(weekdays[(col + 1) % 7], x: pad + column * CGFloat(col), y: pad + row,
                              width: column, color: col >= 5 ? "TEXT3" : "TEXT2", in: view)
            field.alignment = .center
            field.toolTip = formatter.standaloneWeekdaySymbols[(col + 1) % 7]
            field.setAccessibilityLabel(field.toolTip)
        }
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        for day in days {
            let index = offset + day - 1
            let col = index % 7
            let x = pad + column * CGFloat(col)
            let y = pad + row * CGFloat(2 + index / 7)
            let today = day == calendar.component(.day, from: now)
            if today {
                let diameter = theme.number("CALENDAR_TODAY_SIZE")
                let circleX = ((x + (column - diameter) / 2) * panel.backingScaleFactor).rounded() / panel.backingScaleFactor
                let circle = NSView(frame: NSRect(x: circleX, y: y, width: diameter, height: diameter))
                circle.wantsLayer = true
                circle.layer?.cornerRadius = diameter / 2
                circle.layer?.backgroundColor = NSColor.white.cgColor
                view.addSubview(circle)
            }
            let field = label(String(day), x: x, y: y + 2, width: column, color: col >= 5 ? "TEXT3" : "TEXT", in: view)
            field.alignment = .center
            if today { field.textColor = theme.color("BAR_COLOR").withAlphaComponent(1) }
            let date = calendar.date(byAdding: .day, value: day - 1, to: first)!
            field.toolTip = formatter.string(from: date)
            field.setAccessibilityLabel(field.toolTip)
        }
        label("Today", x: pad, y: eventsY, width: width - pad * 2 - 40, in: view)
        let count = label(calendarError != nil ? "" : (calendarBusy ? "..." : String(events.count)), x: width - pad - 40, y: eventsY, width: 40, color: "TEXT2", in: view)
        count.alignment = .right
        if let error = calendarError {
            let message = NSTextField(wrappingLabelWithString: error.localizedDescription)
            message.font = theme.font
            message.textColor = theme.color("TEXT2")
            message.frame = NSRect(x: pad, y: eventsY + row, width: width - pad * 2, height: row * 2)
            view.addSubview(message)
            let button = NSButton(title: "Calendar", target: self, action: #selector(openCalendarPrivacy))
            button.frame = NSRect(x: pad, y: eventsY + row * 3, width: width - pad * 2, height: row)
            button.bezelStyle = .inline
            button.font = theme.font
            view.addSubview(button)
        }
        formatter.dateStyle = .none
        formatter.dateFormat = "HH:mm"
        for (index, event) in events.enumerated() {
            let y = eventsY + row * CGFloat(index + 1)
            let color = NSView(frame: NSRect(x: pad, y: y + 1, width: 3, height: 22))
            color.wantsLayer = true
            color.layer?.cornerRadius = 1.5
            color.layer?.backgroundColor = event.color.cgColor
            color.toolTip = event.calendar
            view.addSubview(color)
            let time = formatter.string(from: event.start)
            label(time, x: pad + 10, y: y + 2, width: 46, color: "TEXT2", in: view)
            let title = label(event.title, x: pad + 64, y: y + 2, width: width - pad * 2 - 64, in: view)
            title.toolTip = "\(event.calendar)\n\(event.title)\n\(DateFormatter.localizedString(from: event.start, dateStyle: .medium, timeStyle: event.allDay ? .none : .short))"
            title.setAccessibilityLabel(title.toolTip)
        }
    }

    @objc func openCalendarPrivacy() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
        close()
    }

    @objc func changeVolume(_ sender: NSSlider) { perform { try Audio.setVolume(Float(sender.doubleValue / 100)) } }
    @objc func changeMute(_ sender: NSButton) { perform { try Audio.setMuted(sender.state == .on) } }
    @objc func changeDevice(_ sender: OutputButton) { perform { try Audio.select(sender.device) } }
}

let arguments = CommandLine.arguments
if arguments.count > 1 && arguments[1] == "audio" {
    let data = try JSONSerialization.data(withJSONObject: Audio.snapshot(), options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
} else if arguments.count > 1 && arguments[1] == "stop" {
    DistributedNotificationCenter.default().postNotificationName(Popups.notification, object: nil, userInfo: ["item": "stop"], deliverImmediately: true)
} else {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = Popups()
    delegate.initialItem = arguments.count > 1 ? arguments[1] : "volume"
    DistributedNotificationCenter.default().addObserver(delegate, selector: #selector(Popups.receive(_:)), name: Popups.notification, object: nil)
    // Lock the existing source inode, not a scratch file. The kernel releases it on exit.
    delegate.lock = open(ProcessInfo.processInfo.environment["CONFIG_DIR"]! + "/plugins/popup.swift", O_RDONLY)
    guard delegate.lock >= 0 else { exit(1) }
    if flock(delegate.lock, LOCK_EX | LOCK_NB) != 0 {
        DistributedNotificationCenter.default().postNotificationName(Popups.notification, object: nil, userInfo: ["item": delegate.initialItem], deliverImmediately: true)
        exit(0)
    }
    app.delegate = delegate
    app.run()
}
