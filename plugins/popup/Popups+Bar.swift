import AppKit

extension Popups {
    func startMediaStream() {
        guard mediaStream == nil else { return }
        mediaStream = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let executable = try Media.executable()
                    _ = try await ProcessCapture().run(executable, ["stream", "--no-diff", "--debounce=100"]) { line in
                        guard let event = try? JSONDecoder().decode(MediaStreamEvent.self, from: line) else { return }
                        self?.streamed(event.payload)
                    }
                } catch is CancellationError {
                    return
                } catch MediaError.missingCLI {
                    logger.error("The media stream needs media-control on PATH.")
                    self?.showMedia(.unavailable)
                    return
                } catch {
                    logger.error("The media stream failed: \(error.localizedDescription, privacy: .private)")
                    self?.showMedia(.unavailable)
                }
                // The stream ends when media-control or its system service restarts.
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func streamed(_ snapshot: MediaSnapshot?) {
        streamedMedia = snapshot
        showMedia(MediaDisplay(snapshot))
    }

    func showMedia(_ display: MediaDisplay) {
        mediaDisplay = display
        fitMedia()
        syncMediaProgress()
    }

    // The plate fills the island, less the inset on each side, in proportion to the elapsed time. The stream
    // reports pauses, seeks, and track changes, which push at once. While a timed track plays, a loop pushes
    // every 2 s. `publish` skips a width the bar already has.
    func pushMediaProgress() {
        guard case .track? = mediaDisplay, let timing = streamedMedia?.timing, let island = mediaIslandWidth else {
            bar.publish(.mediaProgress(0))
            return
        }
        let track = island - 2 * Double(theme.number("PROGRESS_INSET"))
        bar.publish(.mediaProgress(max(0, Int((track * timing.elapsed / timing.duration).rounded(.down)))))
    }

    func syncMediaProgress() {
        pushMediaProgress()
        mediaProgressLoop?.cancel()
        mediaProgressLoop = nil
        guard case .track(_, _, true)? = mediaDisplay, streamedMedia?.timing != nil else { return }
        mediaProgressLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self else { return }
                self.pushMediaProgress()
            }
        }
    }

    // Measures the gap between the left island and the media island, then pushes the width and title that
    // fill it. `publish` skips a state the bar already has, so a refit that changes nothing ends here and
    // the geometry call that status.sh makes after the push does not loop.
    func fitMedia(after delay: Duration = .zero) {
        mediaFitTask?.cancel()
        mediaFitTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let layout = await self?.mediaLayout(), !Task.isCancelled, let self,
                  let display = self.mediaDisplay else { return }
            let gap = Double(self.theme.number("ISLAND_GAP"))
            let fit = MediaFit(text: display.text, layout: layout, gap: gap, font: self.theme.font)
            self.mediaIslandWidth = layout.islandWidth(gap: gap)
            self.bar.publish(display.state(fit))
            self.pushMediaProgress()
        }
    }

    // Reads the three brackets at once and points the glass springs at their bounds. A bracket that cannot be
    // read keeps its glass where it is. After a display change, the delay gives SketchyBar time to arrange
    // the displays before the index is read again.
    func refreshIslands(after delay: Duration = .zero, remeasureDisplay: Bool = false) {
        islandsTask?.cancel()
        islandsTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self else { return }
            if remeasureDisplay { self.displayIndex = nil }
            guard let frames = await self.queryIslands(), !Task.isCancelled else { return }
            self.motion.retarget(frames, response: self.theme.number("SPRING_RESIZE"))
        }
    }

    // One CLI process reads the three brackets. Its output holds one JSON object per bracket.
    func queryIslands() async -> [Island: NSRect]? {
        guard let screen = NSScreen.screens.first, let index = await barDisplayIndex(),
              let result = try? await ProcessCapture().run(URL(fileURLWithPath: theme.sketchybarPath),
                                                           Island.allCases.flatMap { ["--query", $0.rawValue] }),
              !Task.isCancelled, result.status == 0 else { return nil }
        var frames: [Island: NSRect] = [:]
        for query in ItemQuery.decodeAll(result.output) {
            if let island = Island(rawValue: query.name), let frame = query.frame(display: index, on: screen) { frames[island] = frame }
        }
        return frames.isEmpty ? nil : frames
    }

    func queryItem(_ name: String) async -> ItemQuery? {
        guard let result = try? await ProcessCapture().run(URL(fileURLWithPath: theme.sketchybarPath), ["--query", name]),
              !Task.isCancelled, result.status == 0 else { return nil }
        return try? JSONDecoder().decode(ItemQuery.self, from: result.output)
    }

    func mediaLayout() async -> MediaLayout? {
        guard let index = await barDisplayIndex(),
              let left = await queryItem("half.left"), let prev = await queryItem("media.prev"),
              let start = await queryItem("island.media.start"), let end = await queryItem("island.media.end"),
              let media = await queryItem("media"), !Task.isCancelled,
              let leftBounds = left.bounds(display: index), let prevBounds = prev.bounds(display: index),
              let startBounds = start.bounds(display: index), let endBounds = end.bounds(display: index),
              let icon = media.icon, let label = media.label else { return nil }
        // q items fill leftward from the notch: notch.gap, island.media.end, volume, media.next, media.toggle,
        // media.prev, then media. So media.prev's left edge is where media must end, whatever media's width is
        // now. Measure only items nearer the notch than media.
        let glyph = (icon.value as NSString).size(withAttributes: [.font: theme.iconFont]).width.rounded(.up)
        return MediaLayout(leftEdge: leftBounds.minX + leftBounds.width, rightEdge: prevBounds.minX,
                           islandEnd: endBounds.minX + endBounds.width, startWidth: startBounds.width,
                           reserved: icon.paddingLeft + Double(glyph) + icon.paddingRight + label.paddingLeft + label.paddingRight)
    }

    // SketchyBar's arrangement index of the main display, which names the key in `bounding_rects`.
    // Only the first call after launch or a display change starts a process.
    func barDisplayIndex() async -> Int? {
        if let displayIndex { return displayIndex }
        let index = await readDisplayIndex()
        if let index, !Task.isCancelled { displayIndex = index }
        return index
    }

    func readDisplayIndex() async -> Int? {
        guard let displays = try? await ProcessCapture().run(URL(fileURLWithPath: theme.sketchybarPath), ["--query", "displays"]),
              !Task.isCancelled, displays.status == 0,
              let objects = try? JSONSerialization.jsonObject(with: displays.output) as? [[String: Any]],
              let display = objects.first(where: { ($0["DirectDisplayID"] as? NSNumber)?.uint32Value == CGMainDisplayID() }) else { return nil }
        return display["arrangement-id"] as? Int
    }

    func queryAnchor(_ source: PopupSource) async -> NSRect? {
        let executable = URL(fileURLWithPath: theme.sketchybarPath)
        guard let index = await barDisplayIndex(), let screen = NSScreen.screens.first else { return nil }
        let names: [String]
        switch source {
        case .system, .cpu, .memory: names = ["system.cpu", "system.memory"]
        case .front, .frontIcon: names = ["front", "front.icon"]
        case .workspace(let id, _):
            guard let bar = try? await ProcessCapture().run(executable, ["--query", "bar"]),
                  !Task.isCancelled, bar.status == 0,
                  let object = try? JSONSerialization.jsonObject(with: bar.output) as? [String: Any],
                  let items = object["items"] as? [String] else { return nil }
            let base = "ws.\(id)"
            names = items.filter { $0 == base || ($0.hasPrefix(base + ".a") && $0.dropFirst((base + ".a").count).allSatisfy(\.isNumber)) }
            guard names.contains(base) else { return nil }
        default: names = [source.rawValue]
        }
        var union: NSRect?
        var sourceVisible = source == .system
        for name in names {
            guard let result = try? await ProcessCapture().run(executable, ["--query", name]),
                  !Task.isCancelled, result.status == 0,
                  let object = try? JSONSerialization.jsonObject(with: result.output) as? [String: Any],
                  let geometry = object["geometry"] as? [String: Any], let drawing = geometry["drawing"] as? String else { return nil }
            if drawing != "on" {
                if name == source.rawValue || source.kind == .system || name == "front" || (source.kind == .workspace && name == names.first) { return nil }
                continue
            }
            guard let rects = object["bounding_rects"] as? [String: [String: Any]],
                  let rect = rects["display-\(index)"],
                  let origin = rect["origin"] as? [Double], let size = rect["size"] as? [Double],
                  origin.count == 2, size.count == 2, size[0] > 0, size[1] > 0 else { return nil }
            if name == source.rawValue { sourceVisible = true }
            let measured = NSRect(x: origin[0], y: screen.frame.maxY - origin[1] - size[1], width: size[0], height: size[1])
            guard measured.intersects(screen.frame) else { return nil }
            union = union.map { $0.union(measured) } ?? measured
        }
        return sourceVisible ? union : nil
    }

    func trigger(_ event: String) async {
        _ = try? await ProcessCapture().run(URL(fileURLWithPath: theme.sketchybarPath), ["--trigger", event])
    }
}
