import AppKit

extension Popups {
    // One worker owns both workspace and media writes. A newer event invalidates every in-flight read;
    // a write already sent to SketchyBar finishes before the worker starts the next snapshot.
    func updateWorkspace(retry: Int) {
        workspaceRetry = retry
        workspaceDirty = true
        requestLayout()
    }

    func requestLayout() {
        layoutRevision += 1
        layoutDirty = true
        guard workspaceTask == nil else { return }
        workspaceTask = Task { [weak self] in
            while !Task.isCancelled, let self, self.layoutDirty {
                self.layoutDirty = false
                let revision = self.layoutRevision
                let needsWorkspace = self.workspaceDirty
                self.workspaceDirty = false
                var snapshot: WorkspaceSnapshot?
                do {
                    if needsWorkspace {
                        let script = URL(fileURLWithPath: self.theme.configDirectory + "/plugins/spaces.sh")
                        let result = try await ProcessCapture().run(URL(fileURLWithPath: "/bin/bash"),
                                                                    [script.path, "--snapshot", String(self.workspaceRetry)])
                        if result.status == 75 { self.workspaceDirty = true; self.layoutDirty = true; continue }
                        guard result.status == 0, let decoded = try? JSONDecoder().decode(WorkspaceSnapshot.self, from: result.output) else {
                            logger.error("Workspace snapshot failed with status \(result.status, privacy: .public)")
                            continue
                        }
                        snapshot = decoded
                    }
                    guard let layout = await self.mediaLayout(workspace: snapshot) else {
                        if needsWorkspace { self.workspaceDirty = true }
                        logger.error("Could not measure the workspace and media layout.")
                        continue
                    }
                    guard !Task.isCancelled, revision == self.layoutRevision else {
                        if needsWorkspace { self.workspaceDirty = true }
                        continue
                    }
                    let display = self.mediaDisplay ?? .unavailable
                    let gap = Double(self.theme.number("ISLAND_GAP"))
                    let visibility = MediaVisibility(layout: layout, gap: gap)
                    let visibilityChanged = visibility != (layout.controlsVisible ? .visible : .hidden)
                    let fit = MediaFit(text: display.text, layout: layout, gap: gap, font: self.theme.font)
                    let islandWidth = visibility == .visible ? max(0, layout.islandWidth(gap: gap)) : 0
                    let inset = Double(self.theme.number("PROGRESS_INSET"))
                    let progress: Int
                    if case .track = display, let timing = self.streamedMedia?.timing {
                        progress = max(0, Int((max(0, islandWidth - 2 * inset) * timing.elapsed / timing.duration).rounded(.down)))
                    } else { progress = 0 }
                    let radius = min(progress / 2, max(0, Int(self.theme.number("ISLAND_RADIUS") - self.theme.number("PROGRESS_INSET"))))
                    var arguments = (snapshot?.add ?? []) + (snapshot?.now ?? [])
                    let mediaContent = Double(fit.width) >= layout.reserved ? "on" : "off"
                    let drawing = visibility == .visible ? "on" : "off"
                    arguments += ["--set", "island.media.end", "icon.drawing=off", "icon=\(layout.footprint.stored)"]
                    for item in ["island.media.start", "media", "media.prev", "media.toggle", "media.next", "volume"] {
                        arguments += ["--set", item, "drawing=\(drawing)"]
                    }
                    arguments += ["--set", "media", "width=\(visibility == .visible ? fit.width : 0)", "label=\(fit.label)",
                                  "icon.drawing=\(mediaContent)", "label.drawing=\(mediaContent)"]
                    if let volume = layout.volumeUpdate {
                        arguments += ["--set", "volume", "icon=\(volume.icon)", "label=\(volume.label)"]
                    }
                    if progress > 0 {
                        arguments += ["--set", "media.progress", "drawing=on", "label.width=\(progress)",
                                      "padding_right=-\(Int(gap + inset) + progress)", "background.corner_radius=\(radius)"]
                    } else { arguments += ["--set", "media.progress", "drawing=off"] }
                    arguments += snapshot?.animation ?? []
                    if self.mediaStyle != display.style {
                        let environment = ProcessInfo.processInfo.environment
                        guard let text = environment["TEXT"], let text2 = environment["TEXT2"], let text3 = environment["TEXT3"] else {
                            logger.error("Media colors are missing from the helper environment.")
                            continue
                        }
                        let note: String, toggle: String, toggleColor: String, skip: String
                        switch display.style {
                        case .unavailable: note = text3; toggle = "\u{100284}"; toggleColor = text3; skip = text3
                        case .playing: note = text2; toggle = "\u{100286}"; toggleColor = text; skip = text2
                        case .paused: note = text3; toggle = "\u{100284}"; toggleColor = text2; skip = text2
                        }
                        arguments += snapshot?.colorAnimation ?? self.colorAnimation
                        arguments += ["--set", "media", "icon=\u{10046A}", "icon.color=\(note)",
                                      "--set", "media.toggle", "icon=\(toggle)", "icon.color=\(toggleColor)",
                                      "--set", "media.prev", "icon=\u{10028A}", "icon.color=\(skip)",
                                      "--set", "media.next", "icon=\u{10028C}", "icon.color=\(skip)"]
                    }
                    var frames: [Island: NSRect] = [.left: layout.leftFrame]
                    if visibility == .visible { frames[.media] = layout.mediaFrame }
                    let moved = snapshot != nil || frames != self.layoutFrames || visibilityChanged || visibility != self.mediaVisibility
                    let result = try await ProcessCapture().run(URL(fileURLWithPath: self.theme.sketchybarPath), arguments)
                    guard result.status == 0 else {
                        if needsWorkspace { self.workspaceDirty = true }
                        self.refreshIslands()
                        logger.error("Coordinated bar update failed with status \(result.status, privacy: .public)")
                        continue
                    }
                    if moved {
                        self.islandsTask?.cancel()
                        self.mediaVisibility = visibility
                        if visibility == .hidden { self.motion.hide(.media) }
                        self.motion.retarget(frames, response: self.theme.number("SPRING_RESIZE"), immediately: [.left, .media])
                    }
                    self.mediaStyle = display.style
                    self.layoutFrames = frames
                    if let snapshot { self.colorAnimation = snapshot.colorAnimation }
                    guard revision == self.layoutRevision else { continue }
                    self.bar.publish(display.state(fit))
                    if moved { self.geometryChanged(refitMedia: false) }
                    if (visibilityChanged && visibility == .visible) || layout.volumeUpdate != nil { self.requestLayout() }
                } catch is CancellationError {
                    return
                } catch {
                    if needsWorkspace { self.workspaceDirty = true }
                    self.refreshIslands()
                    logger.error("Coordinated bar update failed: \(error.localizedDescription, privacy: .private)")
                }
            }
            self?.workspaceTask = nil
        }
    }

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

    // The worker publishes progress together with the media width it was calculated from.
    func pushMediaProgress() { requestLayout() }

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

    func fitMedia(after delay: Duration = .zero) {
        mediaFitTask?.cancel()
        if delay == .zero { requestLayout(); return }
        mediaFitTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.requestLayout()
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
            self.motion.retarget(frames, response: self.theme.number("SPRING_RESIZE"), immediately: [.left, .media])
        }
    }

    // One CLI process reads the three brackets. Its output holds one JSON object per bracket.
    func queryIslands() async -> [Island: NSRect]? {
        guard let screen = NSScreen.screens.first, let index = await barDisplayIndex(),
              let result = try? await ProcessCapture().run(URL(fileURLWithPath: theme.sketchybarPath),
                                                           (Island.allCases.map(\.rawValue) + ["media.prev"]).flatMap { ["--query", $0] }),
              !Task.isCancelled, result.status == 0 else { return nil }
        let queries = ItemQuery.decodeAll(result.output)
        let mediaDrawn = queries.first(where: { $0.name == "media.prev" })?.geometry?.drawing == "on"
        if !mediaDrawn { motion.hide(.media) }
        var frames: [Island: NSRect] = [:]
        for query in queries {
            if let island = Island(rawValue: query.name), (island != .media || (mediaVisibility == .visible && mediaDrawn)),
               let frame = query.frame(display: index, on: screen) { frames[island] = frame }
        }
        return frames.isEmpty ? nil : frames
    }

    func mediaLayout(workspace: WorkspaceSnapshot? = nil) async -> MediaLayout? {
        let names = ["half.left", "media.prev", "media.toggle", "media.next", "island.media.start", "island.media.end", "media", "volume"]
            + (workspace?.items.filter(WorkspaceSnapshot.affectsWidth) ?? [])
        guard let screen = NSScreen.screens.first, let index = await barDisplayIndex(),
              let result = try? await ProcessCapture().run(URL(fileURLWithPath: theme.sketchybarPath),
                                                           names.flatMap { ["--query", $0] }),
              !Task.isCancelled, result.status == 0 else { return nil }
        let items = ItemQuery.decodeAll(result.output)
        guard let left = items.first(where: { $0.name == "half.left" }),
              let prev = items.first(where: { $0.name == "media.prev" }),
              let start = items.first(where: { $0.name == "island.media.start" }),
              let end = items.first(where: { $0.name == "island.media.end" }),
              let media = items.first(where: { $0.name == "media" }),
              let volume = items.first(where: { $0.name == "volume" }),
              let leftBounds = left.bounds(display: index), let leftFrame = left.frame(display: index, on: screen),
              let startWidth = start.geometry?.width, startWidth >= 0,
              let endBounds = end.bounds(display: index),
              let volumeIcon = volume.icon, let volumeLabel = volume.label,
              let icon = media.icon, let label = media.label else { return nil }
        let volumeUpdate: VolumeUpdate?
        if let state = bar.volume, let stagedIcon = end.label.flatMap({ state.stagedIcon($0.value) }) {
            volumeStageMismatch = nil
            volumeUpdate = stagedIcon != volumeIcon.value || state.label != volumeLabel.value
                ? VolumeUpdate(icon: stagedIcon, label: state.label) : nil
        } else {
            volumeUpdate = nil
            if let state = bar.volume {
                let staged = end.label?.value ?? ""
                if volumeStageMismatch?.0 != state || volumeStageMismatch?.1 != staged {
                    volumeStageMismatch = (state, staged)
                    bar.publish(state.barState, force: true)
                }
            }
        }
        // q items fill leftward from the notch: notch.gap, island.media.end, volume, media.next, media.toggle,
        // media.prev, then media. So media.prev's left edge is where media must end, whatever media's width is
        // now. Measure only items nearer the notch than media.
        let glyph = ("\u{10046A}" as NSString).size(withAttributes: [.font: theme.iconFont]).width.rounded(.up)
        let oldEdge = leftBounds.minX + leftBounds.width
        let leftEdge: Double
        if let workspace {
            guard let predicted = workspace.leftEdge(oldEdge, queries: items, display: index, font: theme.font) else { return nil }
            leftEdge = predicted
        } else { leftEdge = oldEdge }
        let islandEnd = endBounds.minX + endBounds.width
        let rightEdge: Double
        let footprint: MediaFootprint
        let controlsVisible = prev.geometry?.drawing == "on"
        if controlsVisible {
            let width: Double
            if let prevBounds = prev.bounds(display: index), prevBounds.minX >= 0, prevBounds.minX <= islandEnd {
                width = islandEnd - prevBounds.minX
            } else {
                let controls = ["media.prev", "media.toggle", "media.next", "volume"]
                let widths = controls.compactMap { name in items.first(where: { $0.name == name })?.bounds(display: index)?.width }
                guard widths.count == controls.count else { return nil }
                width = endBounds.width + widths.reduce(0, +)
            }
            footprint = MediaFootprint(width: width, volumeIcon: volumeIcon.value)
            let targetWidth = volumeUpdate.map { footprint.width(volumeIcon: $0.icon, font: theme.iconFont) } ?? width
            rightEdge = islandEnd - targetWidth
        } else {
            guard let stored = end.icon?.value, let measured = MediaFootprint(stored) else { return nil }
            footprint = measured
            rightEdge = islandEnd - footprint.width(volumeIcon: volumeUpdate?.icon ?? volumeIcon.value, font: theme.iconFont)
        }
        let gap = Double(theme.number("ISLAND_GAP"))
        let targetLeft = NSRect(x: leftFrame.minX, y: leftFrame.minY,
                                width: max(0, leftEdge - leftBounds.minX), height: leftFrame.height)
        let targetMedia = NSRect(x: screen.frame.minX + leftEdge + gap, y: leftFrame.minY,
                                 width: max(0, islandEnd - leftEdge - gap), height: leftFrame.height)
        return MediaLayout(leftEdge: leftEdge, rightEdge: rightEdge,
                           islandEnd: islandEnd, startWidth: startWidth,
                           reserved: icon.paddingLeft + Double(glyph) + icon.paddingRight + label.paddingLeft + label.paddingRight,
                           controlsVisible: controlsVisible, footprint: footprint, volumeUpdate: volumeUpdate,
                           leftFrame: targetLeft, mediaFrame: targetMedia)
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
