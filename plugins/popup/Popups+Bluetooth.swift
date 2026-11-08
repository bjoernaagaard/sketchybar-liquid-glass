import AppKit
import CoreAudio
import IOBluetooth

struct BluetoothOutputRequest {
    let deviceID: String
    let uid: String
}

private final class BluetoothButton: NSButton {
    var deviceID = ""
}

extension Popups {
    private var bluetoothLinks: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: "bluetoothOutputLinks") as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "bluetoothOutputLinks") }
    }

    func refreshBluetooth() {
        guard item == .bluetooth else { return }
        let devices = bluetooth.pairedDevices()
        let signature = bluetoothSnapshot(devices)
        if signature != bluetoothSignature { buildBluetooth(devices: devices) }
    }

    func clearBluetoothOutputRequest() {
        if let listener = bluetoothOutputListener {
            for watch in bluetoothOutputWatches { Audio.unlisten(watch.id, watch.address, listener) }
        }
        bluetoothOutputWatches.removeAll()
        bluetoothOutputListener = nil
        bluetoothPendingOutput = nil
    }

    private func requestBluetoothOutput(deviceID: String, uid: String) {
        let listener: Audio.Listener = { [weak self] _, _ in
            // Audio.listen delivers asynchronously on the main queue.
            MainActor.assumeIsolated { self?.updateBluetoothOutputRequest() }
        }
        let address = Audio.address(kAudioHardwarePropertyDevices)
        guard Audio.listen(Audio.system, address, listener) else {
            bluetoothErrors[deviceID] = "Could not select audio output"
            logger.error("Registering the audio device listener failed.")
            return
        }
        bluetoothPendingOutput = BluetoothOutputRequest(deviceID: deviceID, uid: uid)
        bluetoothOutputListener = listener
        bluetoothOutputWatches = [(Audio.system, address)]
    }

    private func updateBluetoothOutputRequest() {
        guard let pending = bluetoothPendingOutput, let listener = bluetoothOutputListener else { return }
        let matchingIDs = Audio.deviceIDs().filter { Audio.uid($0) == pending.uid }
        let watchedIDs = Set(bluetoothOutputWatches.filter { $0.id != Audio.system }.map(\.id))
        if Set(matchingIDs) != watchedIDs {
            for watch in bluetoothOutputWatches where watch.id != Audio.system {
                Audio.unlisten(watch.id, watch.address, listener)
            }
            bluetoothOutputWatches.removeAll { $0.id != Audio.system }
            for id in matchingIDs {
                let addresses = [Audio.address(kAudioDevicePropertyDeviceIsAlive),
                                 Audio.address(kAudioDevicePropertyStreams, kAudioDevicePropertyScopeOutput)]
                for address in addresses {
                    guard Audio.listen(id, address, listener) else {
                        logger.error("Registering an audio availability listener failed.")
                        bluetoothErrors[pending.deviceID] = "Could not select audio output"
                        clearBluetoothOutputRequest()
                        refreshBluetooth()
                        return
                    }
                    bluetoothOutputWatches.append((id, address))
                }
            }
        }
        guard !bluetooth.isConnecting(pending.deviceID),
              bluetooth.pairedDevices().contains(where: { $0.id == pending.deviceID && $0.isConnected }),
              let output = Audio.devices().first(where: { Audio.uid($0.id) == pending.uid }) else {
            refreshBluetooth()
            return
        }
        clearBluetoothOutputRequest()
        do {
            try Audio.select(output.id)
            if Audio.current != output.id { bluetoothErrors[pending.deviceID] = "Could not select audio output" }
        } catch {
            logger.error("Selecting the requested audio output failed: \(error.localizedDescription, privacy: .private)")
            bluetoothErrors[pending.deviceID] = "Could not select audio output"
        }
        refreshBluetooth()
    }

    private func bluetoothSnapshot(_ devices: [BluetoothDevice]) -> String {
        let outputs = Audio.devices().map { "\($0.id):\($0.name):\(Audio.uid($0.id) ?? "")" }.joined(separator: "|")
        return "\(Audio.current):\(outputs):\(bluetoothPendingOutput?.deviceID ?? ""):" + devices.map {
            "\($0.id):\($0.name ?? ""):\($0.isConnected):\($0.advertisesAudio):\(bluetooth.isConnecting($0.id)):\(bluetoothLinks[$0.id] ?? ""):\(bluetoothErrors[$0.id] ?? "")"
        }.joined(separator: "|")
    }

    func buildBluetooth(devices: [BluetoothDevice]? = nil) {
        let devices = devices ?? bluetooth.pairedDevices()
        let outputs = Audio.devices()
        let pad = theme.number("POPUP_PADDING")
        let width = theme.width(for: .bluetooth)
        let row = theme.number("POPUP_ROW")
        let count = max(1, devices.count)
        let cellHeight = row * 2 + 8
        let listHeight = CGFloat(min(4, count)) * cellHeight
        let scrollPosition = bluetoothScroll?.documentVisibleRect.origin ?? .zero
        let view = surface(width: width, height: pad * 2 + row * 4 + listHeight)
        label("Bluetooth & AirDrop", x: pad, y: pad, width: width - pad * 2, in: view)
        label("Paired devices", x: pad, y: pad + row, width: width - pad * 2, color: "TEXT2", in: view)
        let scroll = NSScrollView(frame: NSRect(x: pad, y: pad + row * 2, width: width - pad * 2, height: listHeight))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = devices.count > 4
        scroll.scrollerStyle = .legacy
        scroll.autohidesScrollers = false
        let scrollerWidth = scroll.hasVerticalScroller ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) + 4 : 0
        let list = FlippedView(frame: NSRect(x: 0, y: 0, width: scroll.contentSize.width - scrollerWidth, height: CGFloat(count) * cellHeight))
        scroll.documentView = list
        view.addSubview(scroll)
        bluetoothScroll = scroll
        scroll.contentView.scroll(to: scrollPosition)
        scroll.reflectScrolledClipView(scroll.contentView)
        let listWidth = list.frame.width
        if devices.isEmpty {
            label("No paired devices available. Open Bluetooth Settings.", x: 0, y: 0, width: listWidth, color: "TEXT2", in: list)
        }
        for (index, device) in devices.enumerated() {
            let y = CGFloat(index) * cellHeight
            let name = device.name ?? "Bluetooth device"
            let linked = bluetoothLinks[device.id]
            let canUseAudio = device.advertisesAudio
            let hasAction = !device.isConnected || canUseAudio
            let actionWidth: CGFloat = 110
            let nameField = label(name, x: 0, y: y + 2, width: listWidth - (hasAction ? actionWidth + 4 : 0), in: list)
            nameField.setAccessibilityValue(name)
            let output = outputs.first { Audio.uid($0.id) == linked && linked != nil }
            let state: String
            if bluetooth.isConnecting(device.id) { state = "Connecting…" }
            else if let error = bluetoothErrors[device.id] { state = error }
            else if !device.isConnected { state = "Not connected" }
            else if canUseAudio && output?.id == Audio.current { state = "Audio output" }
            else if canUseAudio && bluetoothPendingOutput?.deviceID == device.id && linked != nil { state = "Connected. Audio unavailable." }
            else { state = "Connected" }
            label(state, x: 0, y: y + row + 2, width: listWidth - (device.isConnected && canUseAudio && linked != nil ? actionWidth + 4 : 0), color: "TEXT2", in: list)
            if device.isConnected && canUseAudio && linked != nil {
                let change = BluetoothButton(frame: NSRect(x: listWidth - actionWidth, y: y + row + 2, width: actionWidth, height: row - 4))
                change.deviceID = device.id
                change.title = "Change output"
                change.font = theme.font
                change.bezelStyle = .inline
                change.target = self
                change.action = #selector(changeBluetoothOutput(_:))
                change.setAccessibilityLabel("Change output for \(name)")
                list.addSubview(change)
            }
            if hasAction {
                let button = BluetoothButton(frame: NSRect(x: listWidth - actionWidth, y: y + 2, width: actionWidth, height: row - 4))
                button.deviceID = device.id
                button.title = !device.isConnected ? (bluetoothErrors[device.id] == nil ? "Connect" : "Retry") : (linked == nil ? "Choose output" : "Use output")
                button.isEnabled = !bluetooth.isConnecting(device.id)
                button.font = theme.font
                button.bezelStyle = .inline
                button.target = self
                button.action = #selector(bluetoothAction(_:))
                button.setAccessibilityLabel("\(button.title) \(name)")
                list.addSubview(button)
            }
        }
        let bottom = pad + row * 2 + listHeight
        let settings = NSButton(title: "Open Bluetooth Settings", target: self, action: #selector(openBluetoothSettings))
        settings.frame = NSRect(x: pad, y: bottom + 2, width: width - pad * 2, height: row - 4)
        settings.font = theme.font
        settings.bezelStyle = .inline
        view.addSubview(settings)
        let airdrop = NSButton(title: "Open AirDrop", target: self, action: #selector(openAirDrop))
        airdrop.frame = NSRect(x: pad, y: bottom + row + 2, width: width - pad * 2, height: row - 4)
        airdrop.font = theme.font
        airdrop.bezelStyle = .inline
        view.addSubview(airdrop)
        bluetoothSignature = bluetoothSnapshot(devices)
    }

    @objc private func bluetoothAction(_ sender: BluetoothButton) {
        let id = sender.deviceID
        guard let device = bluetooth.pairedDevices().first(where: { $0.id == id }) else { refreshBluetooth(); return }
        clearBluetoothOutputRequest()
        bluetoothErrors[id] = nil
        if device.advertisesAudio, let uid = bluetoothLinks[id] {
            requestBluetoothOutput(deviceID: id, uid: uid)
        }
        if device.isConnected {
            if bluetoothLinks[id] == nil && device.advertisesAudio {
                chooseBluetoothOutput(device: device, from: sender)
            }
        } else {
            let result = bluetooth.connect(id) { [weak self] result in
                guard let self else { return }
                if result.status != kIOReturnSuccess && !result.isConnected {
                    self.bluetoothErrors[id] = "Connection failed. Retry or open Bluetooth Settings."
                    if self.bluetoothPendingOutput?.deviceID == id { self.clearBluetoothOutputRequest() }
                }
                self.updateBluetoothOutputRequest()
                self.refreshBluetooth()
            }
            switch result {
            case .started, .alreadyConnecting, .alreadyConnected: break
            case .notPaired, .stopped, .failed:
                if bluetoothPendingOutput?.deviceID == id { clearBluetoothOutputRequest() }
                bluetoothErrors[id] = "Connection failed. Retry or open Bluetooth Settings."
            }
        }
        updateBluetoothOutputRequest()
        refreshBluetooth()
    }

    @objc private func changeBluetoothOutput(_ sender: BluetoothButton) {
        guard let device = bluetooth.pairedDevices().first(where: { $0.id == sender.deviceID && $0.isConnected }) else { return }
        chooseBluetoothOutput(device: device, from: sender)
        refreshBluetooth()
    }

    private func chooseBluetoothOutput(device: BluetoothDevice, from sender: NSButton) {
        let outputs = Audio.devices().compactMap { output -> (String, String)? in
            guard let uid = Audio.uid(output.id) else { return nil }
            return (output.name, uid)
        }
        guard !outputs.isEmpty else {
            bluetoothErrors[device.id] = "No audio output available. Open Bluetooth Settings."
            return
        }
        let menu = NSMenu(title: "Choose audio output")
        for (name, uid) in outputs {
            let title = outputs.filter { $0.0 == name }.count > 1 ? "\(name) (\(uid))" : name
            let choice = NSMenuItem(title: title, action: #selector(linkBluetoothOutput(_:)), keyEquivalent: "")
            choice.target = self
            choice.representedObject = [device.id, uid]
            menu.addItem(choice)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY), in: sender)
    }

    @objc private func linkBluetoothOutput(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2,
              bluetooth.pairedDevices().contains(where: { $0.id == pair[0] && $0.isConnected }),
              let output = Audio.devices().first(where: { Audio.uid($0.id) == pair[1] }) else { return }
        bluetoothLinks[pair[0]] = pair[1]
        clearBluetoothOutputRequest()
        bluetoothErrors[pair[0]] = nil
        do {
            try Audio.select(output.id)
            if Audio.current != output.id { bluetoothErrors[pair[0]] = "Could not select audio output" }
        } catch { bluetoothErrors[pair[0]] = "Could not select audio output" }
        refreshBluetooth()
    }

    @objc private func openBluetoothSettings() { openSettings("x-apple.systempreferences:com.apple.BluetoothSettings") }

    @objc private func openAirDrop() {
        let url = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app/Contents/Applications/AirDrop.app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let description = error?.localizedDescription {
                Task { @MainActor in logger.error("Opening AirDrop failed: \(description, privacy: .private)") }
            }
        }
        close()
    }
}
