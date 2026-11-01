import AppKit

extension Popups {
    func refreshSystem() {
        // A rebuild under a pressed button would drop its click. The next sample catches up.
        guard NSEvent.pressedMouseButtons == 0 else { return }
        if let top = processes.sample(count: 3) { topProcesses = top }
        buildSystem()
    }

    func buildSystem() {
        systemShown = bar.system
        let sample = bar.system
        let pad = theme.number("POPUP_PADDING")
        let width = theme.width(for: .system)
        let row = theme.number("POPUP_ROW")
        let clusters = sample?.clusters ?? []
        // Three process rows always, so the panel keeps its height between refreshes.
        let rows = CGFloat(15 + clusters.count + 3)
        let meterHeight: CGFloat = 8, legendHeight: CGFloat = 24
        let view = surface(width: width, height: pad * 2 + row * rows + meterHeight * 2 + legendHeight)
        var y = pad
        func next() -> CGFloat { defer { y += row }; return y }
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: theme.font.pointSize, weight: .semibold)
        func line(_ title: String, _ value: String, valueColor: String = "TEXT2") {
            let rowY = next()
            let detail = label(value, x: 0, y: rowY, width: width, color: valueColor, in: view)
            detail.font = valueFont
            detail.sizeToFit()
            detail.setFrameOrigin(NSPoint(x: width - pad - detail.frame.width, y: rowY))
            label(title, x: pad, y: rowY, width: detail.frame.minX - pad - theme.number("POPUP_GAP"), in: view)
        }
        func heading(_ text: String) { label(text, x: pad, y: next(), width: width - pad * 2, color: "TEXT3", in: view) }
        // Thin bars under the row above, in TEXT at falling opacity, or tinted under strain.
        func meter(_ parts: [(fraction: Double, alpha: CGFloat)], strain: Strain) {
            let track = NSView(frame: NSRect(x: pad, y: y - row + 26, width: width - pad * 2, height: 6))
            track.wantsLayer = true
            track.layer?.backgroundColor = theme.color("BAR_EDGE").cgColor
            track.layer?.cornerRadius = 3
            track.layer?.masksToBounds = true
            let color = switch strain {
            case .normal: theme.color("TEXT")
            case .warn: theme.color("WARN")
            case .crit: theme.color("CRIT")
            }
            var x: CGFloat = 0
            for part in parts {
                let segment = CALayer()
                let length = (track.frame.width * CGFloat(min(1, max(0, part.fraction)))).rounded()
                segment.frame = CGRect(x: x, y: 0, width: min(length, track.frame.width - x), height: 6)
                segment.backgroundColor = color.withAlphaComponent(part.alpha).cgColor
                track.layer?.addSublayer(segment)
                x += segment.frame.width
            }
            view.addSubview(track)
            y += meterHeight
        }
        func percent(_ fraction: Double) -> String { "\(Int((fraction * 100).rounded()))%" }
        func gigabytes(_ bytes: UInt64, unit: Double) -> String {
            let value = Double(bytes) / unit
            return value.rounded() == value || value >= 100 ? "\(Int(value.rounded()))" : String(format: "%.1f", value)
        }
        let gib = Double(1 << 30)
        func speed(_ bytes: Double) -> String {
            bytes < 1_000_000 ? "\(Int((bytes / 1000).rounded())) KB/s" : String(format: "%.1f MB/s", bytes / 1_000_000)
        }

        let titleY = next()
        label("System", x: pad, y: titleY, width: width - pad * 2, in: view)
        if let boot = SystemRead.bootTime() {
            let minutes = max(0, Int(Date().timeIntervalSince(boot) / 60))
            let text = minutes >= 1440 ? "Up \(minutes / 1440) d \(minutes % 1440 / 60) h"
                : minutes >= 60 ? "Up \(minutes / 60) h \(minutes % 60) min" : "Up \(minutes) min"
            let uptime = label(text, x: pad, y: titleY, width: width - pad * 2, color: "TEXT3", in: view)
            uptime.alignment = .right
        }

        heading("CPU")
        line("Load", sample.map { percent($0.cpu.total) } ?? "")
        if let sample { meter([(sample.cpu.user, 0.92), (sample.cpu.system, 0.45)], strain: sample.cpuStrain) }
        for cluster in clusters { line(cluster.title, percent(cluster.load)) }

        heading("Memory")
        let memory = sample?.memory
        line("Used", memory.map { "\(gigabytes($0.used, unit: gib)) of \(gigabytes($0.total, unit: gib)) GB" } ?? "")
        if let sample, sample.memory.total > 0 {
            let total = Double(sample.memory.total)
            meter([(Double(sample.memory.app) / total, 0.92), (Double(sample.memory.wired) / total, 0.6),
                 (Double(sample.memory.compressed) / total, 0.35)], strain: sample.pressure.strain)
            let entries = [("App", sample.memory.app, 0.92), ("Wired", sample.memory.wired, 0.6),
                           ("Compressed", sample.memory.compressed, 0.35)] as [(String, UInt64, CGFloat)]
            let texts = entries.map { name, bytes, _ in
                label("\(name) \(String(format: "%.1f", Double(bytes) / gib))", x: 0, y: y, width: width, color: "TEXT2", in: view)
            }
            // Each entry is an 8 pt swatch, 4 pt, then its text. Wide values close the 10 pt gaps down to
            // 6 pt, then shrink the text, so the legend never passes the right padding.
            let swatches = CGFloat(entries.count) * 12, gaps = CGFloat(entries.count - 1)
            var font = NSFont(name: "SF Pro Semibold", size: 11) ?? .systemFont(ofSize: 11, weight: .semibold)
            func measure() -> CGFloat {
                for text in texts { text.font = font; text.sizeToFit() }
                return texts.reduce(0) { $0 + $1.frame.width }
            }
            var textWidth = measure()
            let gap = min(10, max(6, (width - pad * 2 - swatches - textWidth) / gaps))
            while textWidth > width - pad * 2 - swatches - gap * gaps && font.pointSize > 6 {
                font = font.withSize(font.pointSize - 0.5)
                textWidth = measure()
            }
            var x = pad
            for (entry, text) in zip(entries, texts) {
                let swatch = NSView(frame: NSRect(x: x, y: y + 3, width: 8, height: 8))
                swatch.wantsLayer = true
                swatch.layer?.cornerRadius = 2
                swatch.layer?.backgroundColor = theme.color("TEXT").withAlphaComponent(entry.2).cgColor
                view.addSubview(swatch)
                text.setFrameOrigin(NSPoint(x: x + 12, y: y + 7 - text.frame.height / 2))
                x = text.frame.maxX + gap
            }
            y += legendHeight
        }
        line("Pressure", sample?.pressure.title ?? "")
        line("Swap", sample?.swap.map { "\(gigabytes($0.used, unit: gib)) of \(gigabytes($0.total, unit: gib)) GB" } ?? "")

        heading("Storage and network")
        let volume = (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeNameKey]))?.volumeName ?? "Startup disk"
        line(volume, sample?.disk.map { "\(gigabytes($0.total - $0.used, unit: 1e9)) GB free" } ?? "")
        // U+2193 and U+2191 were checked against /Library/Fonts/SF-Pro.ttf (glyphs 31651 and 31629).
        if let network = sample?.network {
            line(network.interface, "↓ \(speed(network.received))  ↑ \(speed(network.sent))")
        } else {
            line("Network", "Not connected", valueColor: "TEXT3")
        }

        heading("Graphics and heat")
        line("GPU", SystemRead.gpu().map { "\($0)%" } ?? "Unavailable")
        let thermal = switch sample?.thermal {
        case .nominal: "Nominal"
        case .fair: "Fair"
        case .serious: "Serious"
        case .critical: "Critical"
        case nil: ""
        @unknown default: "Unknown"
        }
        line("Thermal state", thermal)

        heading("Top processes")
        for index in 0..<3 {
            if index < topProcesses.count { line(topProcesses[index].name, "\(topProcesses[index].percent)%") } else { y += row }
        }

        let monitor = NSButton(title: "Activity Monitor…", target: self, action: #selector(openActivityMonitor))
        monitor.frame = NSRect(x: pad, y: next(), width: width - pad * 2, height: row)
        monitor.bezelStyle = .inline
        monitor.font = theme.font
        view.addSubview(monitor)
    }

    @objc func openActivityMonitor() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ActivityMonitor") else {
            logger.error("Activity Monitor is not installed.")
            return
        }
        NSWorkspace.shared.open(url)
        close()
    }
}
