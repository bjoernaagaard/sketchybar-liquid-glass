import AppKit
import EventKit

struct CalendarEvent {
    let title: String
    let start: Date
    let allDay: Bool
    let calendar: String
    let color: NSColor
}

extension Popups {
    @objc nonisolated func calendarChanged() {
        // EventKit can post from another thread. Only the UI update crosses actors.
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.calendarDirty = true
            if self.isOpen && self.item == .clock { self.loadCalendar() }
        }
    }

    @objc func requestCalendarAccess() {
        guard !calendarBusy, EKEventStore.authorizationStatus(for: .event) == .notDetermined else { return }
        calendarBusy = true
        buildCalendar()
        // A permission request belongs to the app, not the currently open popup.
        calendarAccessTask = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.eventStore.requestFullAccessToEvents()
                guard !Task.isCancelled else { return }
                self.calendarError = nil
            } catch {
                guard !Task.isCancelled else { return }
                self.calendarError = error
            }
            self.calendarBusy = false
            self.calendarAccessTask = nil
            // The user may have switched or closed popups while permission was pending.
            self.calendarDirty = true
            if self.item == .clock && self.isOpen { self.loadCalendar() }
        }
    }

    func loadCalendar() {
        guard !calendarBusy else { return }
        let authorization = EKEventStore.authorizationStatus(for: .event)
        calendarMinute = Int(Date().timeIntervalSince1970 / 60)
        calendarDirty = false
        guard authorization == .fullAccess else {
            events = []
            calendarError = calendarError ?? NSError(domain: EKErrorDomain, code: EKError.Code.eventStoreNotAuthorized.rawValue)
            if item == .clock { buildCalendar() }
            return
        }
        calendarBusy = true
        calendarError = nil
        // Keep the store and its events on the main actor; do not share EKEventStore
        // with a dispatch queue. The UI consumes value snapshots, never EKEvent objects.
        let now = Date()
        let calendar = Calendar.autoupdatingCurrent
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        let predicate = eventStore.predicateForEvents(withStart: now, end: tomorrow, calendars: nil)
        // EventKit expands recurring occurrences. Include ongoing and all-day events,
        // but never cancelled, declined, or already-finished occurrences.
        events = eventStore.events(matching: predicate)
            .filter { event in
                event.endDate > now && event.startDate < tomorrow && event.status != .canceled &&
                !(event.attendees ?? []).contains { $0.isCurrentUser && $0.participantStatus == .declined }
            }
            .sorted { $0.startDate == $1.startDate ? ($0.title ?? "") < ($1.title ?? "") : $0.startDate < $1.startDate }
            .map { CalendarEvent(title: $0.title ?? "", start: $0.startDate, allDay: $0.isAllDay,
                                 calendar: $0.calendar.title, color: NSColor(cgColor: $0.calendar.cgColor) ?? .white) }
        calendarBusy = false
        if item == .clock { buildCalendar() }
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
        let width = theme.width(for: .clock)
        let column = (width - pad * 2) / 7
        let eventsY = pad + row * CGFloat(weeks + 2) + theme.number("POPUP_GAP")
        let errorHeight: CGFloat = calendarError == nil ? 0 : row * 3
        let view = surface(width: width, height: eventsY + row + CGFloat(events.count) * row + errorHeight + pad)
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
            let canRequest = EKEventStore.authorizationStatus(for: .event) == .notDetermined
            let button = NSButton(title: canRequest ? "Allow calendar access" : "Calendar", target: self,
                                  action: canRequest ? #selector(requestCalendarAccess) : #selector(openCalendarPrivacy))
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

    @objc func openCalendarPrivacy() { openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") }
}
