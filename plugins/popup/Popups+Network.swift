import AppKit

extension Popups {
    func refreshNetwork() {
        let state = readNetworkState(context: "refresh")
        if state != networkState {
            networkState = state
            buildNetwork()
        }
    }

    func buildNetwork() {
        let connections = networkState?.connections ?? []
        let pad = theme.number("POPUP_PADDING")
        let width = theme.width(for: .network)
        let row = theme.number("POPUP_ROW")
        let view = surface(width: width, height: pad * 2 + row * CGFloat(3 + connections.count * 2))
        label("Network", x: pad, y: pad, width: width - pad * 2, in: view)
        for (index, connection) in connections.enumerated() {
            let y = pad + row * CGFloat(1 + index * 2)
            label(connection.primary ? "✓" : "", x: pad, y: y, width: 18, in: view)
            label(connection.name, x: pad + 22, y: y, width: width - pad * 2 - 22,
                  color: connection.active ? "TEXT" : "TEXT3", in: view)
            let device = label(connection.interface, x: 0, y: y + 24, width: width, color: "TEXT3", in: view)
            device.sizeToFit()
            device.setFrameOrigin(NSPoint(x: width - pad - device.frame.width, y: y + 24))
            let details = connection.addresses.first ?? "Not connected"
            let addressWidth = device.frame.minX - pad - 22 - theme.number("POPUP_GAP")
            let address = label(details, x: pad + 22, y: y + 24, width: addressWidth, color: "TEXT2", in: view)
            address.toolTip = connection.addresses.isEmpty ? details : connection.addresses.joined(separator: "\n")
            address.setAccessibilityValue(address.toolTip)
        }
        let wifi = NSButton(title: "Wi-Fi Settings…", target: self, action: #selector(openWiFiSettings))
        wifi.frame = NSRect(x: pad, y: pad + row * CGFloat(1 + connections.count * 2), width: width - pad * 2, height: row)
        wifi.bezelStyle = .inline
        wifi.font = theme.font
        view.addSubview(wifi)
        let network = NSButton(title: "Network Settings…", target: self, action: #selector(openNetworkSettings))
        network.frame = NSRect(x: pad, y: pad + row * CGFloat(2 + connections.count * 2), width: width - pad * 2, height: row)
        network.bezelStyle = .inline
        network.font = theme.font
        view.addSubview(network)
    }

    @objc func openWiFiSettings() { openSettings("x-apple.systempreferences:com.apple.wifi-settings-extension") }

    @objc func openNetworkSettings() { openSettings("x-apple.systempreferences:com.apple.Network-Settings.extension") }
}
