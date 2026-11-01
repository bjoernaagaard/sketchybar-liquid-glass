import AppKit
import SystemConfiguration

enum NetworkKind: String {
    case ethernet, wifi, network, none
}

struct NetworkConnection: Equatable {
    let name: String
    let interface: String
    let kind: NetworkKind
    let addresses: [String]
    let active: Bool
    let primary: Bool
}

struct NetworkState: Equatable {
    let connections: [NetworkConnection]
    let kind: NetworkKind

    // The patterns cover every key `read` uses, plus service setup for enabling and disabling.
    static let watchedKeys = ["State:/Network/Global/IPv[46]", "State:/Network/Service/.*/IPv[46]",
                              "State:/Network/Interface/.*/Link", "Setup:/Network/Service/.*"]

    // Calls `owner.networkChanged()` from a source on the main run loop. The owner invalidates
    // the source before it goes away, so the unretained pointer never outlives it.
    static func watch(_ owner: BarFeed) -> (store: SCDynamicStore, source: CFRunLoopSource)? {
        var context = SCDynamicStoreContext(version: 0, info: Unmanaged.passUnretained(owner).toOpaque(),
                                            retain: nil, release: nil, copyDescription: nil)
        guard let store = SCDynamicStoreCreate(nil, "SketchyBar" as CFString, { _, _, info in
            guard let info else { return }
            // The run loop source is added only to the main run loop.
            MainActor.assumeIsolated { Unmanaged<BarFeed>.fromOpaque(info).takeUnretainedValue().networkChanged() }
        }, &context),
              SCDynamicStoreSetNotificationKeys(store, nil, watchedKeys as CFArray),
              let source = SCDynamicStoreCreateRunLoopSource(nil, store, 0) else { return nil }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        return (store, source)
    }

    static func read() -> NetworkState? {
        guard let preferences = SCPreferencesCreate(nil, "SketchyBar" as CFString, nil),
              let currentSet = SCNetworkSetCopyCurrent(preferences),
              let services = SCNetworkSetCopyServices(currentSet) as? [SCNetworkService],
              let store = SCDynamicStoreCreate(nil, "SketchyBar" as CFString, nil, nil),
              let state = SCDynamicStoreCopyMultiple(store, nil, [
                "State:/Network/Global/IPv[46]",
                "State:/Network/Service/.*/IPv[46]",
                "State:/Network/Interface/.*/Link"
              ] as CFArray) as? [String: [String: Any]] else { return nil }
        let primary = state["State:/Network/Global/IPv4"]?["PrimaryService"] as? String
            ?? state["State:/Network/Global/IPv6"]?["PrimaryService"] as? String
        let configuration = SCPreferencesGetValue(preferences, "NetworkServices" as CFString) as? [String: [String: Any]] ?? [:]
        let wiredTypes = [kSCNetworkInterfaceTypeEthernet, kSCNetworkInterfaceTypeBond, kSCNetworkInterfaceTypeVLAN] as [String]
        let connections: [NetworkConnection] = services.compactMap { service in
            guard let interface = SCNetworkServiceGetInterface(service),
                  let type = SCNetworkInterfaceGetInterfaceType(interface) as String?,
                  let device = SCNetworkInterfaceGetBSDName(interface) as String?,
                  let id = SCNetworkServiceGetServiceID(service) as String? else { return nil }
            // Match macOS settings: internal USB interfaces can have hidden services.
            let metadata = configuration[id]?["Interface"] as? [String: Any]
            guard metadata?["HiddenConfiguration"] as? Bool != true,
                  wiredTypes.contains(type) || metadata?["Hardware"] as? String == "Ethernet"
                    || type == kSCNetworkInterfaceTypeIEEE80211 as String else { return nil }
            let addresses = ["IPv4", "IPv6"].flatMap { family in
                state["State:/Network/Service/\(id)/\(family)"]?["Addresses"] as? [String] ?? []
            }.filter { !$0.hasPrefix("169.254.") && !$0.lowercased().hasPrefix("fe80:") && $0 != "0.0.0.0" && $0 != "::" }
            let link = state["State:/Network/Interface/\(device)/Link"]?["Active"] as? Bool ?? true
            let active = SCNetworkServiceGetEnabled(service) && link && !addresses.isEmpty
            return NetworkConnection(name: SCNetworkServiceGetName(service) as String? ?? device,
                                     interface: device, kind: type == kSCNetworkInterfaceTypeIEEE80211 as String ? .wifi : .ethernet,
                                     addresses: active ? addresses : [], active: active, primary: active && id == primary)
        }.sorted {
            if $0.primary != $1.primary { return $0.primary }
            if $0.active != $1.active { return $0.active }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        // A route can belong to a VPN. Do not mislabel that route as Wi-Fi.
        let kind = connections.first(where: { $0.primary })?.kind
            ?? (connections.contains(where: { $0.active }) ? NetworkKind.network : .none)
        return NetworkState(connections: connections, kind: kind)
    }
}

func readNetworkState(context: String) -> NetworkState? {
    let start = ProcessInfo.processInfo.systemUptime
    let state = NetworkState.read()
    let milliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1_000
    interactionLogger.debug("event=network_read context=\(context, privacy: .public) elapsed_ms=\(milliseconds) success=\(state != nil)")
    return state
}
