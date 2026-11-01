import AppKit

extension Popups {
    func readTailscale() async {
        tailscaleRead = Date()
        do {
            let state = try await Tailscale.read()
            guard !Task.isCancelled else { return }
            tailscale = .success(state)
            bar.publish(.tailscale(TailscaleKind(state.status)))
        } catch {
            guard !Task.isCancelled else { return }
            tailscale = .failure(error as? TailscaleError ?? .commandFailed(error.localizedDescription))
        }
    }

    func refreshTailscale() {
        guard item == .tailscale, refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            guard let self else { return }
            let previous = self.tailscale
            await self.readTailscale()
            guard !Task.isCancelled, self.item == .tailscale, self.isOpen else { return }
            self.refreshTask = nil
            if self.tailscaleLogin, case .success(let state) = self.tailscale, let url = URL(string: state.status.authURL),
               url.scheme == "https" {
                self.tailscaleLogin = false
                NSWorkspace.shared.open(url)
                self.close()
                return
            }
            if !self.sameTailscale(previous, self.tailscale) { self.buildTailscale() }
        }
    }

    func sameTailscale(_ a: Result<Tailscale, TailscaleError>?, _ b: Result<Tailscale, TailscaleError>?) -> Bool {
        switch (a, b) {
        case (.success(let a), .success(let b)): a == b
        case (.failure(let a), .failure(let b)): a.localizedDescription == b.localizedDescription
        default: false
        }
    }

    func buildTailscale() {
        let pad = theme.number("POPUP_PADDING")
        let width = theme.width(for: .tailscale)
        let row = theme.number("POPUP_ROW")
        let state = try? tailscale?.get()
        let backend = state?.status.backend
        let running = backend == .running
        let loggedIn = backend == .running || backend == .stopped || backend == .starting
        let peers = running ? state?.status.peers ?? [] : []
        let exitNodes = peers.filter { $0.exitNodeOption || $0.exitNode }
        let busy = tailscaleCommand != nil
        var rows: CGFloat = 2
        if running { rows += 2 + 1 + CGFloat(peers.count) + 1 + CGFloat(1 + exitNodes.count) + 2 }
        if loggedIn { rows += 4 }
        // A daemon error wraps onto a second line. Otherwise the admin link closes the popup.
        rows += 1
        let view = surface(width: width, height: pad * 2 + row * rows)
        var y = pad
        func next() -> CGFloat { defer { y += row }; return y }

        let titleY = next()
        label("Tailscale", x: pad, y: titleY, width: width - pad * 2 - 60, in: view)
        let subtitle: String
        switch tailscale {
        case .failure(let error): subtitle = error.localizedDescription
        case .success(let state):
            switch state.status.backend {
            case .running: subtitle = state.status.tailnet?.name ?? "Connected"
            case .starting, .noState: subtitle = "Connecting…"
            case .stopped: subtitle = "Disconnected"
            case .needsLogin: subtitle = "Logged out"
            case .needsMachineAuth: subtitle = "Waiting for admin approval"
            }
        case nil: subtitle = ""
        }
        let detail = NSTextField(wrappingLabelWithString: subtitle)
        detail.font = theme.font
        detail.textColor = theme.color("TEXT2")
        detail.maximumNumberOfLines = state == nil ? 3 : 1
        detail.lineBreakMode = .byTruncatingTail
        detail.frame = NSRect(x: pad, y: next(), width: width - pad * 2, height: 22)
        detail.toolTip = subtitle
        view.addSubview(detail)
        if loggedIn {
            let toggle = NSSwitch()
            toggle.controlSize = .small
            toggle.sizeToFit()
            toggle.setFrameOrigin(NSPoint(x: width - pad - toggle.frame.width, y: titleY + (22 - toggle.frame.height) / 2))
            toggle.state = backend == .stopped ? .off : .on
            toggle.isEnabled = !busy
            toggle.target = self
            toggle.action = #selector(changeTailscaleRunning(_:))
            toggle.setAccessibilityLabel("Connected")
            view.addSubview(toggle)
        } else if backend == .needsLogin {
            let login = NSButton(title: "Log In…", target: self, action: #selector(logInTailscale))
            login.bezelStyle = .inline
            login.font = theme.font
            login.isEnabled = !busy
            login.sizeToFit()
            login.setFrameOrigin(NSPoint(x: width - pad - login.frame.width, y: titleY + (22 - login.frame.height) / 2))
            view.addSubview(login)
        } else if state == nil {
            detail.frame.size.height = row * 2
            y += row
        }

        func heading(_ text: String) { label(text, x: pad, y: next(), width: width - pad * 2, color: "TEXT3", in: view) }
        // Rows read like the Network popup: a check gutter, a name, and a trailing detail.
        // A transparent button covers the whole row so the labels stay plain text.
        func choice(_ title: String, detail: String, checked: Bool = false, dimmed: Bool, value: String?,
                    enabled: Bool, help: String, _ action: Selector) {
            let rowY = next()
            // U+2713 was checked against /Library/Fonts/SF-Pro.ttf (glyph 31267).
            label(checked ? "✓" : "", x: pad, y: rowY, width: 18, in: view)
            let trailing = label(detail, x: 0, y: rowY, width: width, color: dimmed ? "TEXT3" : "TEXT2", in: view)
            trailing.sizeToFit()
            trailing.setFrameOrigin(NSPoint(x: width - pad - trailing.frame.width, y: rowY))
            label(title, x: pad + 22, y: rowY, width: trailing.frame.minX - pad - 22 - theme.number("POPUP_GAP"),
                  color: dimmed ? "TEXT3" : "TEXT", in: view)
            let button = ValueButton(frame: NSRect(x: pad, y: rowY - 5, width: width - pad * 2, height: row))
            button.title = ""
            button.value = value ?? ""
            button.isTransparent = true
            button.isEnabled = enabled && value != nil
            button.toolTip = help
            button.setAccessibilityLabel(help)
            button.setAccessibilityValue(checked ? 1 : 0)
            button.target = self
            button.action = action
            view.addSubview(button)
        }
        func device(_ node: TailscaleNode) {
            let help = [node.dnsName.trimmingCharacters(in: CharacterSet(charactersIn: ".")), node.os, node.online ? "" : "Offline",
                        node.address.map { "Click to copy \($0)" } ?? ""].filter { !$0.isEmpty }.joined(separator: "\n")
            choice(node.name, detail: node.address ?? "", dimmed: !node.online, value: node.address, enabled: true,
                   help: help, #selector(copyTailscaleAddress(_:)))
        }
        func check(_ title: String, _ on: Bool, enabled: Bool = true, _ action: Selector) {
            let box = NSButton(checkboxWithTitle: title, target: self, action: action)
            // A checkbox centers its title in 24 pt. Raise it to the label baseline.
            box.frame = NSRect(x: pad, y: next() - 3, width: width - pad * 2, height: 24)
            box.font = theme.font
            box.contentTintColor = theme.color("TEXT")
            box.state = on ? .on : .off
            box.isEnabled = enabled && !busy
            view.addSubview(box)
        }

        if running, let state, let this = state.status.device {
            heading("This Device")
            device(this)
            heading("Network Devices")
            peers.forEach(device)
            heading("Exit Node")
            let current = exitNodes.first { $0.exitNode }
            choice("None", detail: "", checked: current == nil, dimmed: false, value: "", enabled: !busy,
                   help: "Stop using an exit node", #selector(changeTailscaleExitNode(_:)))
            for node in exitNodes {
                choice(node.name, detail: node.online ? "" : "Offline", checked: node.exitNode, dimmed: !node.online,
                       value: node.address, enabled: !busy, help: "Use \(node.name) as the exit node", #selector(changeTailscaleExitNode(_:)))
            }
            check("Allow Local Network Access", state.prefs.allowLANAccess, enabled: current != nil, #selector(changeTailscaleLAN(_:)))
            check("Run as Exit Node", state.prefs.advertisesExitNode, #selector(changeTailscaleAdvertise(_:)))
        }
        if loggedIn, let state {
            heading("Settings")
            check("Use Tailscale DNS", state.prefs.acceptDNS, #selector(changeTailscaleDNS(_:)))
            check("Use Tailscale Subnets", state.prefs.acceptRoutes, #selector(changeTailscaleRoutes(_:)))
            check("Allow Incoming Connections", !state.prefs.shieldsUp, #selector(changeTailscaleIncoming(_:)))
        }
        if state != nil {
            let admin = NSButton(title: "Admin Console…", target: self, action: #selector(openTailscaleAdmin))
            admin.frame = NSRect(x: pad, y: next(), width: width - pad * 2, height: row)
            admin.bezelStyle = .inline
            admin.font = theme.font
            view.addSubview(admin)
        }
    }

    func runTailscale(_ arguments: [String]) {
        guard tailscaleCommand == nil else { return }
        tailscaleCommand = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await ProcessCapture().run(Tailscale.executable(), arguments)
                guard !Task.isCancelled else { return }
                self.bar.pollTailscale()
                self.tailscaleCommand = nil
                guard self.item == .tailscale, self.isOpen else { return }
                if result.status != 0 && result.status != SIGTERM {
                    self.tailscaleLogin = false
                    let message = Tailscale.message(result.errors)
                    NSAlert(error: TailscaleError.commandFailed(message.isEmpty ? "tailscale exited with status \(result.status)." : message))
                        .beginSheetModal(for: self.panel, completionHandler: nil)
                }
                self.refreshTask?.cancel()
                self.refreshTask = nil
                self.refreshTailscale()
                self.buildTailscale()
            } catch {
                guard !Task.isCancelled else { return }
                self.tailscaleCommand = nil
                if self.item == .tailscale && self.isOpen { NSAlert(error: error).beginSheetModal(for: self.panel, completionHandler: nil); self.buildTailscale() }
            }
        }
        if item == .tailscale && isOpen { buildTailscale() }
    }

    @objc func changeTailscaleRunning(_ sender: NSSwitch) { runTailscale([sender.state == .on ? "up" : "down"]) }

    @objc func changeTailscaleExitNode(_ sender: ValueButton) { runTailscale(["set", "--exit-node=\(sender.value)"]) }

    @objc func changeTailscaleLAN(_ sender: NSButton) { runTailscale(["set", "--exit-node-allow-lan-access=\(sender.state == .on)"]) }

    @objc func changeTailscaleAdvertise(_ sender: NSButton) { runTailscale(["set", "--advertise-exit-node=\(sender.state == .on)"]) }

    @objc func changeTailscaleDNS(_ sender: NSButton) { runTailscale(["set", "--accept-dns=\(sender.state == .on)"]) }

    @objc func changeTailscaleRoutes(_ sender: NSButton) { runTailscale(["set", "--accept-routes=\(sender.state == .on)"]) }

    @objc func changeTailscaleIncoming(_ sender: NSButton) { runTailscale(["set", "--shields-up=\(sender.state == .off)"]) }

    @objc func logInTailscale() {
        if case .success(let state) = tailscale, let url = URL(string: state.status.authURL), url.scheme == "https" {
            NSWorkspace.shared.open(url)
            close()
            return
        }
        // `tailscale login` waits for the browser. The refresh opens its URL once status has it.
        tailscaleLogin = true
        tailscaleRead = .distantPast
        runTailscale(["login"])
    }

    @objc func copyTailscaleAddress(_ sender: ValueButton) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sender.value, forType: .string)
        close()
    }

    @objc func openTailscaleAdmin() { openSettings("https://login.tailscale.com/admin/machines") }
}
