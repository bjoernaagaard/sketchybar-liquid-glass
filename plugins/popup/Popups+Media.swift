import AppKit

extension Popups {
    func readMedia() async {
        do {
            let snapshot = try await Media.read(artwork: true)
            guard !Task.isCancelled else { return }
            media = snapshot
            mediaError = nil
        } catch {
            guard !Task.isCancelled else { return }
            media = nil
            mediaError = error as? MediaError ?? .commandFailed(error.localizedDescription)
        }
    }

    func refreshMedia() {
        guard item == .media, refreshTask == nil, mediaActionTasks.isEmpty else { return }
        refreshTask = Task { [weak self] in
            guard let self else { return }
            let previous = self.media?.contentSignature
            let previousError = self.mediaError?.localizedDescription
            await self.readMedia()
            guard !Task.isCancelled, self.item == .media, self.isOpen else { return }
            self.refreshTask = nil
            if previous != self.media?.contentSignature || previousError != self.mediaError?.localizedDescription {
                self.buildMedia()
            } else { self.updateMediaTiming() }
        }
    }

    func buildMedia() {
        mediaSeeking = false
        mediaSlider = nil
        mediaElapsed = nil
        mediaDuration = nil
        let pad = theme.number("POPUP_PADDING")
        let width = theme.width(for: .media)
        let row = theme.number("POPUP_ROW")
        let artworkSize: CGFloat = 48
        let contentY = pad + row
        let timingHeight = media?.timing == nil ? 0 : row
        let view = surface(width: width, height: pad * 2 + row * 2 + artworkSize + 16 + timingHeight)
        label("Now Playing", x: pad, y: pad, width: width - pad * 2 - 100, in: view)
        let application = label(media?.applicationName ?? "", x: width - pad - 100, y: pad, width: 100, color: "TEXT3", in: view)
        application.alignment = .right

        let artwork = NSImageView(frame: NSRect(x: pad, y: contentY, width: artworkSize, height: artworkSize))
        artwork.wantsLayer = true
        artwork.layer?.cornerRadius = 6
        artwork.layer?.masksToBounds = true
        artwork.imageScaling = .scaleProportionallyUpOrDown
        if let data = media?.artworkData, let image = NSImage(data: data) {
            artwork.image = image
        } else {
            artwork.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "No artwork")
            artwork.contentTintColor = theme.color("TEXT2")
        }
        artwork.setAccessibilityLabel("Album artwork")
        view.addSubview(artwork)

        let textX = pad + artworkSize + 12
        let textWidth = width - textX - pad
        let title = media?.title.isEmpty == false ? media?.title ?? "" : "Not playing"
        let detail = mediaError?.localizedDescription ?? (media?.artist.isEmpty == false ? media?.artist ?? "" : "No active media")
        label(title, x: textX, y: contentY + 2, width: textWidth, in: view)
        label(detail, x: textX, y: contentY + 26, width: textWidth, color: "TEXT2", in: view)

        let controlsY = contentY + artworkSize + 12 + timingHeight
        if media?.timing != nil {
            let timeWidth: CGFloat = 56
            let progressY = contentY + artworkSize + 8
            mediaElapsed = label("", x: pad, y: progressY, width: timeWidth, color: "TEXT2", in: view)
            mediaDuration = label("", x: width - pad - timeWidth, y: progressY, width: timeWidth, color: "TEXT2", in: view)
            mediaDuration?.alignment = .right
            let timeFont = NSFont.monospacedDigitSystemFont(ofSize: theme.font.pointSize, weight: .semibold)
            mediaElapsed?.font = timeFont
            mediaDuration?.font = timeFont
            let slider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: self, action: #selector(seekMedia(_:)))
            slider.frame = NSRect(x: pad + timeWidth + 4, y: progressY,
                                  width: width - pad * 2 - timeWidth * 2 - 8, height: 24)
            slider.isContinuous = true
            slider.trackFillColor = theme.color("TEXT")
            slider.setAccessibilityLabel("Playback position")
            slider.toolTip = "Drag to seek"
            view.addSubview(slider)
            mediaSlider = slider
            updateMediaTiming()
        }
        let buttonWidth: CGFloat = 64
        let spacing: CGFloat = 8
        let controlsWidth = buttonWidth * 3 + spacing * 2
        let startX = (width - controlsWidth) / 2
        func control(_ symbol: String, _ help: String, x: CGFloat, action: Selector) {
            let button = NSButton(frame: NSRect(x: x, y: controlsY, width: buttonWidth, height: row))
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)
            button.imagePosition = .imageOnly
            button.bezelStyle = .inline
            button.contentTintColor = theme.color("TEXT")
            button.isEnabled = media != nil
            button.toolTip = help
            button.setAccessibilityLabel(help)
            button.target = self
            button.action = action
            view.addSubview(button)
        }
        control("backward.fill", "Previous", x: startX, action: #selector(previousMedia))
        control(media?.playing == true ? "pause.fill" : "play.fill", media?.playing == true ? "Pause" : "Play or pause",
                x: startX + buttonWidth + spacing, action: #selector(playPauseMedia))
        control("forward.fill", "Next", x: startX + (buttonWidth + spacing) * 2, action: #selector(nextMedia))
    }

    func updateMediaTiming() {
        guard let timing = media?.timing else { return }
        var elapsed = timing.elapsed
        if let pending = pendingMediaSeek {
            let age = Date().timeIntervalSince(pending.requestedAt)
            let expected = min(timing.duration, pending.position + (media?.playing == true ? age : 0))
            if pending.trackSignature != media?.trackSignature || age >= 3 {
                pendingMediaSeek = nil
            } else if abs(timing.elapsed - expected) <= 2 {
                pendingMediaSeek = nil
            } else {
                elapsed = expected
            }
        }
        mediaSlider?.maxValue = timing.duration
        mediaDuration?.stringValue = MediaTiming.format(timing.duration)
        guard !mediaSeeking else { return }
        mediaSlider?.doubleValue = elapsed
        mediaElapsed?.stringValue = MediaTiming.format(elapsed)
        mediaSlider?.setAccessibilityValue("\(MediaTiming.format(elapsed)) of \(MediaTiming.format(timing.duration))")
    }

    func seekMedia(to seconds: Double) {
        refreshTask?.cancel()
        refreshTask = nil
        let signature = media?.trackSignature ?? []
        pendingMediaSeek = PendingMediaSeek(position: seconds, trackSignature: signature)
        updateMediaTiming()
        let previous = mediaActionTask
        let id = UUID()
        let task = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            defer {
                self.mediaActionTasks[id] = nil
                if self.mediaActionTasks.isEmpty && self.item == .media && self.isOpen { self.refreshMedia() }
            }
            guard !Task.isCancelled else { return }
            do {
                let current = try await Media.read()
                guard !Task.isCancelled, current?.trackSignature == signature else { return }
                try await Media.seek(to: seconds)
            } catch {
                guard !Task.isCancelled, self.item == .media, self.isOpen else { return }
                self.pendingMediaSeek = nil
                NSAlert(error: error).beginSheetModal(for: self.panel, completionHandler: nil)
            }
        }
        mediaActionTask = task
        mediaActionTasks[id] = task
    }

    func performMedia(_ action: MediaAction) {
        pendingMediaSeek = nil
        refreshTask?.cancel()
        refreshTask = nil
        let previous = mediaActionTask
        let id = UUID()
        let task = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            defer {
                self.mediaActionTasks[id] = nil
                if self.mediaActionTasks.isEmpty && self.item == .media && self.isOpen { self.refreshMedia() }
            }
            guard !Task.isCancelled else { return }
            do {
                try await Media.perform(action)
            } catch {
                // The bar controls run with the popup closed, so the log is the only record then.
                logger.error("Media \(action.argument, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                guard !Task.isCancelled, self.item == .media, self.isOpen else { return }
                NSAlert(error: error).beginSheetModal(for: self.panel, completionHandler: nil)
            }
        }
        mediaActionTask = task
        mediaActionTasks[id] = task
    }

    @objc func previousMedia() { performMedia(.previous) }

    @objc func playPauseMedia() { performMedia(.playPause) }

    @objc func nextMedia() { performMedia(.next) }

    @objc func seekMedia(_ sender: NSSlider) {
        guard media?.timing != nil else { return }
        let eventType = NSApp.currentEvent?.type
        if eventType == .leftMouseDown {
            mediaSeeking = true
            pendingMediaSeek = nil
        }
        let seconds = min(sender.maxValue, max(0, sender.doubleValue))
        mediaElapsed?.stringValue = MediaTiming.format(seconds)
        mediaSlider?.setAccessibilityValue("\(MediaTiming.format(seconds)) of \(MediaTiming.format(sender.maxValue))")
        let dragging = eventType == .leftMouseDown || eventType == .leftMouseDragged
        guard !dragging else { return }
        mediaSeeking = false
        seekMedia(to: seconds)
    }
}
