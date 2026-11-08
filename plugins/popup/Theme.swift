import AppKit

enum ConfigurationError: LocalizedError {
    case missingValue(String)
    case invalidValue(String)

    var errorDescription: String? {
        switch self {
        case .missingValue(let name): "Missing popup environment value: \(name). Launch through plugins/popup.sh."
        case .invalidValue(let name): "Invalid popup environment value: \(name). Check theme.sh and plugins/popup.sh."
        }
    }
}

struct Theme {
    let configDirectory: String
    let sketchybarPath: String
    let barPID: Int32
    private let numbers: [String: CGFloat]
    private let colors: [String: NSColor]

    init() throws(ConfigurationError) {
        let environment = ProcessInfo.processInfo.environment
        func required(_ name: String) throws(ConfigurationError) -> String {
            guard let value = environment[name], !value.isEmpty else { throw ConfigurationError.missingValue(name) }
            return value
        }
        configDirectory = try required("CONFIG_DIR")
        sketchybarPath = try required("SB")
        guard let pid = Int32(try required("POPUP_BAR_PID")), pid > 0 else { throw ConfigurationError.invalidValue("POPUP_BAR_PID") }
        barPID = pid
        var numbers: [String: CGFloat] = [:]
        for name in ["POPUP_RADIUS", "POPUP_WIDTH_VOLUME", "POPUP_WIDTH_CLOCK", "POPUP_WIDTH_NETWORK", "POPUP_WIDTH_BLUETOOTH", "POPUP_WIDTH_TAILSCALE",
                     "POPUP_WIDTH_MEDIA", "POPUP_WIDTH_SYSTEM", "POPUP_WIDTH_FRONT", "POPUP_WIDTH_INFORMATION",
                     "POPUP_GAP", "POPUP_PADDING", "POPUP_ROW", "CALENDAR_TODAY_SIZE", "ISLAND_GAP", "ISLAND_RADIUS", "MERGE_DISTANCE",
                     "PROGRESS_INSET", "SPRING_RESIZE", "SPRING_EMERGE", "SPRING_RETRACT"] {
            guard let value = Double(try required(name)), value.isFinite, value >= 0 else { throw ConfigurationError.invalidValue(name) }
            numbers[name] = CGFloat(value)
        }
        self.numbers = numbers
        var colors: [String: NSColor] = [:]
        for name in ["TEXT", "TEXT2", "TEXT3", "BAR_COLOR", "BAR_EDGE", "WARN", "CRIT"] {
            let raw = try required(name)
            guard raw.hasPrefix("0x"), let value = UInt32(raw.dropFirst(2), radix: 16) else { throw ConfigurationError.invalidValue(name) }
            colors[name] = NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                                  green: CGFloat((value >> 8) & 255) / 255,
                                  blue: CGFloat(value & 255) / 255,
                                  alpha: CGFloat(value >> 24) / 255)
        }
        self.colors = colors
    }

    func number(_ name: String) -> CGFloat {
        guard let value = numbers[name] else { preconditionFailure("Unknown layout key: \(name)") }
        return value
    }

    // Each width is measured from the popup's fixed rows (theme.sh). A new kind must choose one here.
    func width(for kind: PopupKind) -> CGFloat {
        switch kind {
        case .volume: number("POPUP_WIDTH_VOLUME")
        case .clock: number("POPUP_WIDTH_CLOCK")
        case .network: number("POPUP_WIDTH_NETWORK")
        case .bluetooth: number("POPUP_WIDTH_BLUETOOTH")
        case .tailscale: number("POPUP_WIDTH_TAILSCALE")
        case .media: number("POPUP_WIDTH_MEDIA")
        case .system: number("POPUP_WIDTH_SYSTEM")
        case .front: number("POPUP_WIDTH_FRONT")
        case .battery, .workspace, .mode: number("POPUP_WIDTH_INFORMATION")
        }
    }

    func color(_ name: String) -> NSColor {
        guard let value = colors[name] else { preconditionFailure("Unknown color key: \(name)") }
        return value
    }

    var font: NSFont { NSFont(name: "SF Pro Semibold", size: 13) ?? .systemFont(ofSize: 13, weight: .semibold) }
    // The bar's icon font, which measures the media glyph.
    var iconFont: NSFont { NSFont(name: "SF Pro Medium", size: 13) ?? .systemFont(ofSize: 13, weight: .medium) }
}
