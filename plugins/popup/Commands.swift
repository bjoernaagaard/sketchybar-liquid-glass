import AppKit

enum PopupKind: String {
    case volume, clock, network, bluetooth, tailscale, media, system, front, battery, workspace, mode
}

enum PopupSource: Equatable {
    case volume, clock, network, bluetooth, tailscale, media, system, cpu, memory, front, frontIcon, battery, mode
    case workspace(String, String)

    init?(rawValue: String) {
        switch rawValue {
        case "volume": self = .volume
        case "clock": self = .clock
        case "network": self = .network
        case "bluetooth": self = .bluetooth
        case "tailscale": self = .tailscale
        case "media": self = .media
        case "system": self = .system
        case "system.cpu": self = .cpu
        case "system.memory": self = .memory
        case "front": self = .front
        case "front.icon": self = .frontIcon
        case "battery": self = .battery
        case "mode": self = .mode
        default:
            let parts = rawValue.split(separator: ".", omittingEmptySubsequences: false)
            guard (parts.count == 2 || parts.count == 3), parts[0] == "ws",
                  !parts[1].isEmpty, parts[1].utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }),
                  parts.count == 2 || (parts[2].first == "a" && parts[2].dropFirst().allSatisfy(\.isNumber) && parts[2].count > 1) else { return nil }
            self = .workspace(String(parts[1]), rawValue)
        }
    }

    var rawValue: String {
        switch self {
        case .volume: "volume"
        case .clock: "clock"
        case .network: "network"
        case .bluetooth: "bluetooth"
        case .tailscale: "tailscale"
        case .media: "media"
        case .system: "system"
        case .cpu: "system.cpu"
        case .memory: "system.memory"
        case .front: "front"
        case .frontIcon: "front.icon"
        case .battery: "battery"
        case .mode: "mode"
        case .workspace(_, let item): item
        }
    }

    var kind: PopupKind {
        switch self {
        case .volume: .volume
        case .clock: .clock
        case .network: .network
        case .bluetooth: .bluetooth
        case .tailscale: .tailscale
        case .media: .media
        case .system, .cpu, .memory: .system
        case .front, .frontIcon: .front
        case .battery: .battery
        case .mode: .mode
        case .workspace: .workspace
        }
    }

    var identity: String {
        if case .workspace(let id, _) = self { return "workspace.\(id)" }
        return kind.rawValue
    }
}

struct PopupTarget {
    let id: UUID
    let source: PopupSource
    var kind: PopupKind { source.kind }
}

enum PopupLifecycle {
    case closed, opening(PopupTarget), open(PopupTarget), dismissed(String, NSRect?)

    var target: PopupTarget? {
        switch self {
        case .opening(let target), .open(let target): target
        case .closed, .dismissed: nil
        }
    }
}

// Commands for the running helper. Strings exist only at the shell and notification boundary.
enum PopupCommand {
    case toggle(PopupSource), hover(PopupSource), hoverEnd(PopupSource), geometry, start, stop, volumeScroll(notches: Int)
    case media(MediaAction)
    case workspaceUpdate(retry: Int)

    init?(_ raw: String, argument: String? = nil) {
        switch raw {
        case "volume-scroll":
            // status.sh passes SketchyBar's SCROLL_DELTA.
            guard let argument, let delta = Double(argument), delta.isFinite else { return nil }
            self = .volumeScroll(notches: Int(min(50, max(-50, delta)).rounded()))
        case "hover", "hover-end":
            guard let argument, let source = PopupSource(rawValue: argument) else { return nil }
            self = raw == "hover" ? .hover(source) : .hoverEnd(source)
        case "geometry": self = .geometry
        case "workspace-update":
            guard let argument, let retry = Int(argument), (0...30).contains(retry) else { return nil }
            self = .workspaceUpdate(retry: retry)
        case "start": self = .start
        case "stop": self = .stop
        default:
            if let action = MediaAction(command: raw) { self = .media(action); return }
            guard let popup = PopupSource(rawValue: raw) else { return nil }
            self = .toggle(popup)
        }
    }

    var rawValue: String {
        switch self {
        case .toggle(let popup): popup.rawValue
        case .hover: "hover"
        case .hoverEnd: "hover-end"
        case .geometry: "geometry"
        case .workspaceUpdate: "workspace-update"
        case .start: "start"
        case .stop: "stop"
        case .volumeScroll: "volume-scroll"
        case .media(let action): action.command
        }
    }

    var userInfo: [String: String] {
        switch self {
        case .volumeScroll(let notches): ["item": rawValue, "argument": String(notches)]
        case .workspaceUpdate(let retry): ["item": rawValue, "argument": String(retry)]
        case .hover(let source), .hoverEnd(let source): ["item": rawValue, "argument": source.rawValue]
        case .toggle, .geometry, .start, .stop, .media: ["item": rawValue]
        }
    }

    init?(userInfo: [AnyHashable: Any]?) {
        guard let raw = userInfo?["item"] as? String else { return nil }
        self.init(raw, argument: userInfo?["argument"] as? String)
    }

    func post() {
        DistributedNotificationCenter.default().postNotificationName(Popups.notification, object: nil, userInfo: userInfo, deliverImmediately: true)
    }
}
