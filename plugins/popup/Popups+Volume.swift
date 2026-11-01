import AppKit
import CoreAudio

extension Popups {
    // Each notch moves the volume 2 percentage points. Notifications arrive one at a time on the main
    // actor, so each notch starts from the volume the previous one wrote.
    func scrollVolume(_ notches: Int) {
        do { try Audio.change(by: 2 * notches) }
        catch { logger.error("Changing the volume failed: \(error.localizedDescription, privacy: .public)") }
    }

    func buildVolume(devices: [(id: AudioObjectID, name: String)]? = nil, current: AudioObjectID? = nil) {
        let devices = devices ?? Audio.devices()
        let current = current ?? Audio.current
        let pad = theme.number("POPUP_PADDING")
        let width = theme.width(for: .volume)
        let row = theme.number("POPUP_ROW")
        let view = surface(width: width, height: pad * 2 + row * CGFloat(3 + devices.count))
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
            button.title = "\(device.id == current ? "✓" : "  ")  \(device.name)"
            button.font = theme.font
            button.alignment = .left
            button.bezelStyle = .inline
            button.isBordered = false
            button.contentTintColor = theme.color(device.id == current ? "TEXT" : "TEXT2")
            button.lineBreakMode = .byTruncatingTail
            button.toolTip = device.name
            button.setAccessibilityLabel(device.name)
            button.setAccessibilityValue(device.id == current ? 1 : 0)
            button.target = self
            button.action = #selector(changeDevice(_:))
            view.addSubview(button)
        }
        deviceSignature = signature(devices, current: current)
        updateVolume(current)
    }

    func signature(_ devices: [(id: AudioObjectID, name: String)], current: AudioObjectID) -> String {
        "\(current):" + devices.map { "\($0.id):\($0.name)" }.joined(separator: "|")
    }

    func refreshVolume() {
        guard item == .volume else { return }
        let id = Audio.current
        let devices = Audio.devices()
        if signature(devices, current: id) != deviceSignature { buildVolume(devices: devices, current: id); return }
        updateVolume(id)
    }

    func updateVolume(_ id: AudioObjectID) {
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
        updateVolume(Audio.current)
    }

    @objc func changeVolume(_ sender: NSSlider) { perform { try Audio.setVolume(Float(sender.doubleValue / 100)) } }

    @objc func changeMute(_ sender: NSButton) { perform { try Audio.setMuted(sender.state == .on) } }

    @objc func changeDevice(_ sender: OutputButton) { perform { try Audio.select(sender.device) }; refreshVolume() }
}
