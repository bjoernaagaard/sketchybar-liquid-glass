// Before feature work, read ../AGENTS.md and ~/.agents/skills/write-swift/SKILL.md.
import AppKit
import CoreAudio
import EventKit
import SystemConfiguration
import os

private let logger = Logger(subsystem: "com.bjoernaagaard.sketchybar", category: "popup")

enum PopupKind: String {
    case volume, clock, network, tailscale, media
}

// Commands for the running helper. Strings exist only at the shell and notification boundary.
enum PopupCommand {
    case toggle(PopupKind), hover, hoverEnd, start, stop

    init?(_ raw: String) {
        switch raw {
        case "media-hover": self = .hover
        case "media-hover-end": self = .hoverEnd
        case "start": self = .start
        case "stop": self = .stop
        default:
            guard let popup = PopupKind(rawValue: raw) else { return nil }
            self = .toggle(popup)
        }
    }

    var rawValue: String {
        switch self {
        case .toggle(let popup): popup.rawValue
        case .hover: "media-hover"
        case .hoverEnd: "media-hover-end"
        case .start: "start"
        case .stop: "stop"
        }
    }
}

enum NetworkKind: String, Codable {
    case ethernet, wifi, network, none
}

// System frameworks only. This process owns popups, never another bar.
struct Audio {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func scalar<T: BitwiseCopyable>(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress, _ initial: T) -> T? {
        var address = address
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
        }
        return status == noErr ? value : nil
    }

    static func set<T: BitwiseCopyable>(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress, _ value: T) throws {
        var address = address
        var value = value
        let status = withUnsafePointer(to: &value) {
            AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<T>.size), $0)
        }
        if status != noErr { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    static func writable(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        var writable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(id, &address, &writable) == noErr && writable.boolValue
    }

    static var current: AudioObjectID {
        scalar(system, address(kAudioHardwarePropertyDefaultOutputDevice), AudioObjectID(0)) ?? 0
    }

    static func devices() -> [(id: AudioObjectID, name: String)] {
        var property = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &property, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &property, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var streams = address(kAudioDevicePropertyStreams, kAudioDevicePropertyScopeOutput)
            var bytes: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &bytes) == noErr, bytes > 0,
                  scalar(id, address(kAudioDevicePropertyDeviceIsAlive), UInt32(0)) == 1 else { return nil }
            var name: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var nameProperty = address(kAudioObjectPropertyName)
            guard AudioObjectGetPropertyData(id, &nameProperty, 0, nil, &nameSize, &name) == noErr,
                  let name else { return nil }
            return (id, name.takeRetainedValue() as String)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func channels(_ id: AudioObjectID) -> [AudioObjectPropertyElement] {
        var property = address(kAudioDevicePropertyStreamConfiguration, kAudioDevicePropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &property, 0, nil, &size) == noErr, size > 0 else { return [] }
        let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { memory.deallocate() }
        guard AudioObjectGetPropertyData(id, &property, 0, nil, &size, memory) == noErr else { return [] }
        let buffers = UnsafeMutableAudioBufferListPointer(memory.assumingMemoryBound(to: AudioBufferList.self))
        let count = buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
        return count > 0 ? (1...count).map { UInt32($0) } : []
    }

    static func controls(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectPropertyAddress] {
        let main = address(selector, kAudioDevicePropertyScopeOutput)
        if writable(id, main) { return [main] }
        return channels(id).map { address(selector, kAudioDevicePropertyScopeOutput, $0) }.filter { writable(id, $0) }
    }

    static func volume(_ id: AudioObjectID) -> Float? {
        let values = controls(id, kAudioDevicePropertyVolumeScalar).compactMap { scalar(id, $0, Float(0)) }
        return values.isEmpty ? nil : values.reduce(0, +) / Float(values.count)
    }

    static func muted(_ id: AudioObjectID) -> Bool {
        let values = controls(id, kAudioDevicePropertyMute).compactMap { scalar(id, $0, UInt32(0)) }
        return !values.isEmpty && values.allSatisfy { $0 != 0 }
    }

    static func setVolume(_ value: Float) throws {
        let id = current
        for property in controls(id, kAudioDevicePropertyVolumeScalar) { try set(id, property, min(1, max(0, value))) }
    }

    static func setMuted(_ value: Bool) throws {
        let id = current
        for property in controls(id, kAudioDevicePropertyMute) { try set(id, property, UInt32(value ? 1 : 0)) }
    }

    static func select(_ id: AudioObjectID) throws {
        try set(system, address(kAudioHardwarePropertyDefaultOutputDevice), id)
    }

    static func snapshot() -> [String: Any] {
        let id = current
        return ["current": id, "volume": volume(id).map { Int(($0 * 100).rounded()) } as Any? ?? NSNull(),
                "muted": muted(id), "devices": devices().map { ["id": $0.id, "name": $0.name] as [String: Any] }]
    }
}

enum MediaError: LocalizedError {
    case missingCLI
    case commandFailed(String)
    case invalidOutput
    case invalidPosition

    var errorDescription: String? {
        switch self {
        case .missingCLI: "The media-control command was not found on PATH."
        case .commandFailed(let message): message
        case .invalidOutput: "media-control returned information this helper cannot read."
        case .invalidPosition: "The playback position is invalid."
        }
    }
}

enum MediaAction: String {
    case playPause = "play-pause", next, previous

    var argument: String {
        switch self {
        case .playPause: "toggle-play-pause"
        case .next: "next-track"
        case .previous: "previous-track"
        }
    }
}

struct MediaTiming {
    let elapsed: Double
    let duration: Double

    static func format(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}

struct PendingMediaSeek {
    let position: Double
    let requestedAt = Date()
    let trackSignature: [String]
}

struct MediaSnapshot: Codable, Equatable {
    let title: String
    let artist: String
    let bundleIdentifier: String
    let processIdentifier: Int32?
    let playing: Bool
    let duration: Double?
    let elapsedTime: Double?
    let elapsedTimeNow: Double?
    let timestamp: Date?
    let artworkData: Data?

    enum CodingKeys: String, CodingKey {
        case title, artist, bundleIdentifier, processIdentifier, playing, duration, elapsedTime, elapsedTimeNow, timestamp, artworkData
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        title = try values.decodeIfPresent(String.self, forKey: .title) ?? ""
        artist = try values.decodeIfPresent(String.self, forKey: .artist) ?? ""
        bundleIdentifier = try values.decodeIfPresent(String.self, forKey: .bundleIdentifier) ?? ""
        processIdentifier = try values.decodeIfPresent(Int32.self, forKey: .processIdentifier)
        playing = try values.decodeIfPresent(Bool.self, forKey: .playing) ?? false
        duration = try values.decodeIfPresent(Double.self, forKey: .duration)
        elapsedTime = try values.decodeIfPresent(Double.self, forKey: .elapsedTime)
        elapsedTimeNow = try values.decodeIfPresent(Double.self, forKey: .elapsedTimeNow)
        timestamp = try values.decodeIfPresent(String.self, forKey: .timestamp).flatMap { try? Date($0, strategy: .iso8601) }
        artworkData = try values.decodeIfPresent(Data.self, forKey: .artworkData)
    }

    var applicationName: String {
        if let processIdentifier, let name = NSRunningApplication(processIdentifier: processIdentifier)?.localizedName {
            return name
        }
        return bundleIdentifier
    }

    var trackSignature: [String] {
        [title, artist, bundleIdentifier]
    }

    var timing: MediaTiming? {
        guard let duration, duration.isFinite, duration > 0, duration <= Double(Int.max),
              let elapsed = elapsedTimeNow ?? elapsedTime.map(advanced), elapsed.isFinite, elapsed >= 0 else { return nil }
        return MediaTiming(elapsed: min(elapsed, duration), duration: duration)
    }

    // `get --now` estimates the position. A streamed update reports it as of `timestamp`.
    private func advanced(_ elapsed: Double) -> Double {
        guard playing, let timestamp else { return elapsed }
        return elapsed + max(0, Date().timeIntervalSince(timestamp))
    }

    var contentSignature: [String] {
        [title, artist, bundleIdentifier, playing ? "playing" : "paused", timing == nil ? "untimed" : "timed"]
    }
}

// Owns the child and both pipes until their EOFs and termination have arrived.
final class ProcessCapture {
    nonisolated enum Event: Sendable {
        case output(Data), error(Data), outputEnd, errorEnd, exit(Int32), readFailure(any Error)
    }
    nonisolated struct Result: Sendable {
        let output: Data
        let errors: Data
        let status: Int32
    }
    let process = Process()
    let output = Pipe()
    let errors = Pipe()
    private static var running: [ObjectIdentifier: Process] = [:]

    static func terminateRunningChildren() {
        for process in running.values where process.isRunning { process.terminate() }
    }

    // With `lines`, each complete stdout line goes to the handler instead of the result.
    func run(_ executable: URL, _ arguments: [String], lines: ((Data) -> Void)? = nil) async throws -> Result {
        try Task.checkCancellation()
        let (events, continuation) = AsyncStream<Event>.makeStream()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = errors
        output.fileHandleForReading.readabilityHandler = { handle in
            do {
                let data = try handle.read(upToCount: 65536) ?? Data()
                if data.isEmpty { handle.readabilityHandler = nil; continuation.yield(.outputEnd) }
                else { continuation.yield(.output(data)) }
            } catch { handle.readabilityHandler = nil; continuation.yield(.readFailure(error)) }
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            do {
                let data = try handle.read(upToCount: 65536) ?? Data()
                if data.isEmpty { handle.readabilityHandler = nil; continuation.yield(.errorEnd) }
                else { continuation.yield(.error(data)) }
            } catch { handle.readabilityHandler = nil; continuation.yield(.readFailure(error)) }
        }
        process.terminationHandler = { process in continuation.yield(.exit(process.terminationStatus)) }
        defer {
            Self.running.removeValue(forKey: ObjectIdentifier(process))
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            process.terminationHandler = nil
            if process.isRunning { process.terminate() }
            try? output.fileHandleForReading.close()
            try? errors.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
            try? errors.fileHandleForWriting.close()
            continuation.finish()
        }
        try process.run()
        Self.running[ObjectIdentifier(process)] = process
        var data = Data(), failure = Data()
        var outputEnded = false, errorEnded = false
        var status: Int32?
        for await event in events {
            switch event {
            case .output(let bytes):
                data.append(bytes)
                while let lines, let end = data.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = Data(data[data.startIndex..<end])
                    data.removeSubrange(data.startIndex...end)
                    lines(line)
                }
            case .error(let bytes): failure.append(bytes)
            case .outputEnd: outputEnded = true
            case .errorEnd: errorEnded = true
            case .exit(let value): status = value
            case .readFailure(let error): throw error
            }
            if outputEnded && errorEnded, let status {
                try Task.checkCancellation()
                return Result(output: data, errors: failure, status: status)
            }
        }
        throw CancellationError()
    }
}

struct Media {
    static func executable() throws(MediaError) -> URL {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
        guard let path = paths.map({ "\($0)/media-control" }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw .missingCLI
        }
        return URL(fileURLWithPath: path)
    }

    static func read(artwork: Bool = false) async throws -> MediaSnapshot? {
        let result: ProcessCapture.Result
        do { result = try await ProcessCapture().run(executable(), ["get", "--now"] + (artwork ? [] : ["--no-artwork"])) }
        catch is CancellationError { throw CancellationError() }
        catch let error as MediaError { throw error }
        catch { throw MediaError.commandFailed(error.localizedDescription) }
        guard result.status == 0 else {
            let message = String(decoding: result.errors, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw MediaError.commandFailed(message.isEmpty ? "media-control get failed." : message)
        }
        guard !result.output.isEmpty else { return nil }
        do { return try JSONDecoder().decode(MediaSnapshot?.self, from: result.output) }
        catch { throw MediaError.invalidOutput }
    }

    static func perform(_ action: MediaAction) async throws {
        try await run([action.argument], description: action.argument)
    }

    static func seek(to seconds: Double) async throws {
        guard seconds.isFinite, seconds >= 0 else { throw MediaError.invalidPosition }
        try await run(["seek", String(seconds)], description: "seek")
    }

    private static func run(_ arguments: [String], description: String) async throws {
        let result: ProcessCapture.Result
        do { result = try await ProcessCapture().run(executable(), arguments) }
        catch is CancellationError { throw CancellationError() }
        catch let error as MediaError { throw error }
        catch { throw MediaError.commandFailed(error.localizedDescription) }
        guard result.status == 0 else {
            let message = String(decoding: result.errors, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw MediaError.commandFailed(message.isEmpty ? "media-control \(description) failed." : message)
        }
    }

}

struct NetworkConnection: Codable, Equatable {
    let name: String
    let interface: String
    let kind: NetworkKind
    let addresses: [String]
    let active: Bool
    let primary: Bool
}

struct NetworkState: Codable, Equatable {
    let connections: [NetworkConnection]
    let kind: NetworkKind

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

enum TailscaleError: LocalizedError {
    case missingCLI
    case commandFailed(String)
    case invalidOutput(String)

    var errorDescription: String? {
        switch self {
        case .missingCLI: "The tailscale command was not found on PATH. Install it with Homebrew."
        case .commandFailed(let message): message
        case .invalidOutput(let command): "tailscale \(command) returned output this helper cannot read."
        }
    }
}

// Values the bar item renders. Strings appear only at the JSON boundary with status.sh.
enum TailscaleKind: String, Codable {
    case running, exitNode = "exit-node", stopped, login, unavailable
}

enum TailscaleBackend: String, Decodable {
    case noState = "NoState", needsLogin = "NeedsLogin", needsMachineAuth = "NeedsMachineAuth"
    case stopped = "Stopped", starting = "Starting", running = "Running"
}

struct TailscaleNode: Decodable, Equatable {
    let hostName: String
    let dnsName: String
    let os: String
    let online: Bool
    let exitNode: Bool
    let exitNodeOption: Bool
    let addresses: [String]

    enum CodingKeys: String, CodingKey {
        case hostName = "HostName", dnsName = "DNSName", os = "OS", online = "Online"
        case exitNode = "ExitNode", exitNodeOption = "ExitNodeOption", addresses = "TailscaleIPs"
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        hostName = try values.decode(String.self, forKey: .hostName)
        dnsName = try values.decodeIfPresent(String.self, forKey: .dnsName) ?? ""
        os = try values.decodeIfPresent(String.self, forKey: .os) ?? ""
        online = try values.decodeIfPresent(Bool.self, forKey: .online) ?? false
        exitNode = try values.decodeIfPresent(Bool.self, forKey: .exitNode) ?? false
        exitNodeOption = try values.decodeIfPresent(Bool.self, forKey: .exitNodeOption) ?? false
        addresses = try values.decodeIfPresent([String].self, forKey: .addresses) ?? []
    }

    // Match the admin console, which names machines by their MagicDNS label.
    var name: String { dnsName.split(separator: ".").first.map(String.init) ?? hostName }
    var address: String? { addresses.first { $0.contains(".") } ?? addresses.first }
}

struct TailscaleStatus: Decodable, Equatable {
    struct Tailnet: Decodable, Equatable {
        let name: String
        enum CodingKeys: String, CodingKey { case name = "Name" }
    }

    let backend: TailscaleBackend
    let authURL: String
    let device: TailscaleNode?
    let tailnet: Tailnet?
    let peers: [TailscaleNode]

    enum CodingKeys: String, CodingKey {
        case backend = "BackendState", authURL = "AuthURL", device = "Self", tailnet = "CurrentTailnet", peers = "Peer"
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        backend = try values.decode(TailscaleBackend.self, forKey: .backend)
        authURL = try values.decodeIfPresent(String.self, forKey: .authURL) ?? ""
        device = try values.decodeIfPresent(TailscaleNode.self, forKey: .device)
        tailnet = try values.decodeIfPresent(Tailnet.self, forKey: .tailnet)
        peers = (try values.decodeIfPresent([String: TailscaleNode].self, forKey: .peers) ?? [:]).values.sorted {
            if $0.online != $1.online { return $0.online }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

struct TailscalePrefs: Decodable, Equatable {
    let acceptDNS: Bool
    let acceptRoutes: Bool
    let shieldsUp: Bool
    let allowLANAccess: Bool
    let advertisedRoutes: [String]

    enum CodingKeys: String, CodingKey {
        case acceptDNS = "CorpDNS", acceptRoutes = "RouteAll", shieldsUp = "ShieldsUp"
        case allowLANAccess = "ExitNodeAllowLANAccess", advertisedRoutes = "AdvertiseRoutes"
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        acceptDNS = try values.decode(Bool.self, forKey: .acceptDNS)
        acceptRoutes = try values.decode(Bool.self, forKey: .acceptRoutes)
        shieldsUp = try values.decode(Bool.self, forKey: .shieldsUp)
        allowLANAccess = try values.decode(Bool.self, forKey: .allowLANAccess)
        advertisedRoutes = try values.decodeIfPresent([String].self, forKey: .advertisedRoutes) ?? []
    }

    var advertisesExitNode: Bool { advertisedRoutes.contains("0.0.0.0/0") && advertisedRoutes.contains("::/0") }
}

// The Homebrew build has no app or menu. Its CLI talks to the root tailscaled
// socket, which accepts preference writes from the logged-in user.
struct Tailscale: Equatable {
    let status: TailscaleStatus
    let prefs: TailscalePrefs

    static func executable() throws(TailscaleError) -> URL {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
        guard let path = paths.map({ "\($0)/tailscale" }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw .missingCLI
        }
        return URL(fileURLWithPath: path)
    }

    // The CLI warns on stderr when it and the daemon differ by a patch version.
    static func message(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self).split(separator: "\n")
            .filter { !$0.hasPrefix("Warning: client version") }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decode<T: Decodable>(_ type: T.Type, arguments: [String], result: ProcessCapture.Result) throws -> T {
        guard result.status == 0 else {
            let text = message(result.errors)
            throw TailscaleError.commandFailed(text.isEmpty ? "tailscale \(arguments.joined(separator: " ")) failed." : text)
        }
        do { return try JSONDecoder().decode(type, from: result.output) }
        catch { throw TailscaleError.invalidOutput(arguments.joined(separator: " ")) }
    }

    static func read() async throws -> Tailscale {
        let executable = try executable()
        let statusCapture = ProcessCapture()
        let prefsCapture = ProcessCapture()
        async let statusResult = statusCapture.run(executable, ["status", "--json"])
        async let prefsResult = prefsCapture.run(executable, ["debug", "prefs"])
        let (status, prefs) = try await (statusResult, prefsResult)
        return try Tailscale(status: decode(TailscaleStatus.self, arguments: ["status", "--json"], result: status),
                             prefs: decode(TailscalePrefs.self, arguments: ["debug", "prefs"], result: prefs))
    }

    static func kind() async -> TailscaleKind {
        guard let executable = try? executable(),
              let result = try? await ProcessCapture().run(executable, ["status", "--json"]),
              let status = try? decode(TailscaleStatus.self, arguments: ["status", "--json"], result: result) else { return .unavailable }
        switch status.backend {
        case .running: return status.peers.contains { $0.exitNode } ? .exitNode : .running
        case .needsLogin, .needsMachineAuth: return .login
        case .stopped, .starting, .noState: return .stopped
        }
    }

}

final class ValueButton: NSButton {
    var value = ""
}

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
        for name in ["POPUP_RADIUS", "POPUP_WIDTH", "POPUP_GAP", "POPUP_PADDING", "POPUP_ROW", "CALENDAR_TODAY_SIZE",
                     "ISLAND_WING", "ISLAND_RADIUS", "ISLAND_RESPONSE"] {
            guard let value = Double(try required(name)), value.isFinite, value >= 0 else { throw ConfigurationError.invalidValue(name) }
            numbers[name] = CGFloat(value)
        }
        self.numbers = numbers
        var colors: [String: NSColor] = [:]
        for name in ["TEXT", "TEXT2", "TEXT3", "BAR_COLOR", "BAR_EDGE", "ISLAND_COLOR"] {
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

    func color(_ name: String) -> NSColor {
        guard let value = colors[name] else { preconditionFailure("Unknown color key: \(name)") }
        return value
    }

    var font: NSFont { NSFont(name: "SF Pro Semibold", size: 13) ?? .systemFont(ofSize: 13, weight: .semibold) }
}

final class PopupPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
}

final class Surface: NSView {
    let theme: Theme
    init(frame: NSRect, theme: Theme) { self.theme = theme; super.init(frame: frame) }
    required init?(coder: NSCoder) { fatalError("Surface is constructed in code, not decoded from an archive.") }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard enclosingScrollView == nil else { return }
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                               xRadius: theme.number("POPUP_RADIUS"), yRadius: theme.number("POPUP_RADIUS"))
        theme.color("BAR_COLOR").setFill(); path.fill()
        theme.color("BAR_EDGE").setStroke(); path.lineWidth = 1; path.stroke()
    }
}

// A media-control stream line. `--no-diff` sends the whole snapshot each time.
struct MediaStreamEvent: Decodable {
    let payload: MediaSnapshot?
}

// The camera housing on the bar's display, in AppKit screen coordinates.
struct Notch: Equatable {
    let midX: CGFloat
    let top: CGFloat
    let width: CGFloat
    let height: CGFloat

    init?(screen: NSScreen) {
        let height = screen.safeAreaInsets.top
        guard height > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else { return nil }
        let width = screen.frame.width - left.width - right.width
        guard width > 0 else { return nil }
        midX = screen.frame.minX + left.width + width / 2
        top = screen.frame.maxY
        self.width = width
        self.height = height
    }

    // SketchyBar's display=main is CGMainDisplayID, which AppKit lists first.
    static var main: Notch? { NSScreen.screens.first.flatMap(Notch.init(screen:)) }
}

// A critically damped spring. A new target keeps the current value and velocity,
// so a shrinking island can grow again without a jump.
struct Spring {
    var value: CGFloat
    var velocity: CGFloat = 0
    var target: CGFloat

    init(_ value: CGFloat) { self.value = value; target = value }

    mutating func step(_ seconds: CGFloat, response: CGFloat) {
        guard response > 0 else { settle(); return }
        let omega = 2 * .pi / response
        let offset = value - target
        let rate = velocity + omega * offset
        let decay = exp(-omega * seconds)
        value = target + (offset + rate * seconds) * decay
        velocity = (rate - omega * (offset + rate * seconds)) * decay
    }

    mutating func settle() { value = target; velocity = 0 }

    var settled: Bool { abs(value - target) < 0.25 && abs(velocity) < 2 }
}

final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// The island's black shape. The strip as tall as the notch sits on the black bar, so only
// the part below the bar shows: concave fillets where it leaves the bar, then round corners.
final class IslandView: NSView {
    var stripHeight: CGFloat = 0
    // Artwork and meter beside the notch. Other subviews hang below the strip.
    let wings = NSView()
    let fillet: CGFloat
    let radius: CGFloat

    init(color: NSColor, fillet: CGFloat, radius: CGFloat) {
        self.fillet = fillet
        self.radius = radius
        super.init(frame: .zero)
        wantsLayer = true
        shape.fillColor = color.cgColor
        addSubview(wings)
    }
    required init?(coder: NSCoder) { fatalError("IslandView is constructed in code, not decoded from an archive.") }

    private var shape: CAShapeLayer {
        guard let layer = layer as? CAShapeLayer else { preconditionFailure("makeBackingLayer returns a CAShapeLayer.") }
        return layer
    }

    override func makeBackingLayer() -> CALayer { CAShapeLayer() }

    override func setFrameSize(_ size: NSSize) {
        super.setFrameSize(size)
        arrange()
    }

    // Subviews stay centered on the notch and keep their distance from the top edge.
    func arrange() {
        let size = bounds.size
        for view in subviews {
            let top = view === wings ? 0 : stripHeight
            view.setFrameOrigin(NSPoint(x: ((size.width - view.frame.width) / 2).rounded(), y: size.height - top - view.frame.height))
        }
        let path = CGMutablePath()
        let width = size.width, height = size.height, junction = height - stripHeight
        if junction < 0.5 {
            path.addRect(CGRect(origin: .zero, size: size))
        } else {
            let curve = min(fillet, junction / 2)
            let corner = max(0, min(radius, junction - curve, (width - fillet * 2) / 2))
            path.move(to: CGPoint(x: 0, y: height))
            path.addLine(to: CGPoint(x: width, y: height))
            path.addLine(to: CGPoint(x: width, y: junction))
            path.addQuadCurve(to: CGPoint(x: width - fillet, y: junction - curve), control: CGPoint(x: width - fillet, y: junction))
            path.addArc(tangent1End: CGPoint(x: width - fillet, y: 0), tangent2End: CGPoint(x: fillet, y: 0), radius: corner)
            path.addArc(tangent1End: CGPoint(x: fillet, y: 0), tangent2End: CGPoint(x: fillet, y: junction), radius: corner)
            path.addLine(to: CGPoint(x: fillet, y: junction - curve))
            path.addQuadCurve(to: CGPoint(x: 0, y: junction), control: CGPoint(x: fillet, y: junction))
            path.closeSubpath()
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.path = path
        CATransaction.commit()
    }
}

// Four bars beside the notch that move while media plays, like the island's waveform on iPhone.
final class LevelMeter: NSView {
    static let size = NSSize(width: 16, height: 12)
    private var bars: [CALayer] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for index in 0..<4 {
            let bar = CALayer()
            bar.frame = CGRect(x: CGFloat(index) * 4.5, y: 0, width: 2.5, height: Self.size.height)
            bar.cornerRadius = 1.25
            layer?.addSublayer(bar)
            bars.append(bar)
        }
    }
    required init?(coder: NSCoder) { fatalError("LevelMeter is constructed in code, not decoded from an archive.") }

    func update(playing: Bool, color: NSColor) {
        let moving = playing && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        for (index, bar) in bars.enumerated() {
            bar.backgroundColor = (playing ? color : color.withAlphaComponent(0.4)).cgColor
            if moving {
                guard bar.animation(forKey: "level") == nil else { continue }
                bar.transform = CATransform3DIdentity
                let level = CABasicAnimation(keyPath: "transform.scale.y")
                level.fromValue = 0.3
                level.toValue = 1
                level.duration = [0.42, 0.56, 0.36, 0.5][index]
                level.timeOffset = Double(index) * 0.17
                level.autoreverses = true
                level.repeatCount = .infinity
                level.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                bar.add(level, forKey: "level")
            } else {
                bar.removeAnimation(forKey: "level")
                bar.transform = CATransform3DMakeScale(1, playing ? 0.6 : 0.3, 1)
            }
        }
    }
}

// On a notched display the camera housing is the media surface. While a player has a track,
// wings beside the notch show its artwork and a level meter. Hovering grows the same black
// shape down into the media popup, and closing shrinks it back. Without media it hides
// behind the notch. Popups owns the island and decides what it shows when open.
final class Island: NSObject {
    private enum Shape { case hidden, compact, expanded }

    let theme: Theme
    unowned let popups: Popups
    let panel = IslandPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let view: IslandView
    private var wings: NSView { view.wings }
    private let artwork = NSImageView()
    private let meter = LevelMeter(frame: NSRect(origin: .zero, size: LevelMeter.size))
    private var content: NSView?
    private(set) var notch: Notch?
    private(set) var media: MediaSnapshot?
    private var accent: NSColor
    private var shape = Shape.hidden
    private var width = Spring(0)
    private var height = Spring(0)
    private var link: CADisplayLink?
    private var lastStep: CFTimeInterval?
    private var stream: Task<Void, Never>?

    init(theme: Theme, popups: Popups) {
        self.theme = theme
        self.popups = popups
        accent = theme.color("TEXT")
        view = IslandView(color: theme.color("ISLAND_COLOR"), fillet: theme.number("POPUP_GAP"), radius: theme.number("ISLAND_RADIUS"))
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Above the bar and normal windows, below the bar popups.
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.title = PopupKind.media.rawValue
        panel.contentView = view
        artwork.wantsLayer = true
        artwork.layer?.cornerRadius = 5
        artwork.layer?.masksToBounds = true
        artwork.imageScaling = .scaleProportionallyUpOrDown
        artwork.setAccessibilityLabel("Album artwork")
        wings.addSubview(artwork)
        wings.addSubview(meter)
        wings.alphaValue = 0
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.group)
        view.setAccessibilityLabel("Now Playing")
        view.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    var isExpanded: Bool { shape == .expanded }

    // Called at launch and whenever the displays change. Returns whether the bar layout must follow.
    @discardableResult func updateNotch() -> Bool {
        let next = Notch.main
        guard next != notch else { return false }
        notch = next
        guard let next else {
            stream?.cancel()
            stream = nil
            media = nil
            stopLink()
            shape = .hidden
            content?.removeFromSuperview()
            content = nil
            panel.orderOut(nil)
            return true
        }
        view.stripHeight = next.height
        let wing = theme.number("ISLAND_WING")
        let art = min(22, next.height - 10)
        wings.frame.size = NSSize(width: next.width + wing * 2, height: next.height)
        artwork.frame = NSRect(x: ((wing - art) / 2).rounded(), y: ((next.height - art) / 2).rounded(), width: art, height: art)
        meter.setFrameOrigin(NSPoint(x: (wings.frame.width - wing + (wing - LevelMeter.size.width) / 2).rounded(),
                                     y: ((next.height - LevelMeter.size.height) / 2).rounded()))
        view.arrange()
        let size = size(shape)
        width = Spring(size.width)
        height = Spring(size.height)
        render()
        startStream()
        return true
    }

    func stop() {
        stream?.cancel()
        stream = nil
        stopLink()
    }

    // Returns the view the media popup lays out in, below the notch.
    func expand(height: CGFloat) -> NSView {
        content?.removeFromSuperview()
        let view = FlippedView(frame: NSRect(x: 0, y: 0, width: theme.number("POPUP_WIDTH"), height: height))
        content = view
        self.view.addSubview(view)
        move(to: .expanded)
        // Lays out the new content and carries over the fade of the content it replaced.
        self.view.arrange()
        render()
        return view
    }

    func collapse() { move(to: media == nil ? .hidden : .compact) }

    private func apply(_ snapshot: MediaSnapshot?) {
        let next = snapshot?.title.isEmpty == false ? snapshot : nil
        if next?.artworkData != media?.artworkData {
            let image = next?.artworkData.flatMap(NSImage.init(data:))
            artwork.image = image ?? NSImage(systemSymbolName: "music.note", accessibilityDescription: "No artwork")
            artwork.contentTintColor = theme.color("TEXT2")
            accent = image.flatMap(Self.accent) ?? theme.color("TEXT")
        }
        media = next
        meter.update(playing: next?.playing == true, color: accent)
        view.setAccessibilityValue(next.map { [$0.title, $0.artist].filter { !$0.isEmpty }.joined(separator: ", ") })
        if shape != .expanded { collapse() }
    }

    // The artwork's average color, brightened so the meter reads on black like the iPhone waveform.
    private static func accent(_ image: NSImage) -> NSColor? {
        guard let pixel = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8, samplesPerPixel: 4,
                                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 4, bitsPerPixel: 32),
              let context = NSGraphicsContext(bitmapImageRep: pixel) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: 1, height: 1))
        NSGraphicsContext.restoreGraphicsState()
        guard let color = pixel.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB), color.saturationComponent > 0.15 else { return nil }
        return NSColor(hue: color.hueComponent, saturation: min(1, color.saturationComponent * 1.2),
                       brightness: max(0.8, color.brightnessComponent), alpha: 1)
    }

    private func startStream() {
        guard stream == nil else { return }
        stream = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let executable = try Media.executable()
                    _ = try await ProcessCapture().run(executable, ["stream", "--no-diff", "--debounce=100"]) { line in
                        guard let event = try? JSONDecoder().decode(MediaStreamEvent.self, from: line) else { return }
                        self?.apply(event.payload)
                    }
                } catch is CancellationError {
                    return
                } catch MediaError.missingCLI {
                    logger.error("Island media stream needs media-control on PATH.")
                    return
                } catch {
                    logger.error("Island media stream failed: \(error.localizedDescription, privacy: .private)")
                }
                // The stream ends when media-control or its system service restarts.
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func size(_ shape: Shape) -> NSSize {
        guard let notch else { return .zero }
        let fillet = theme.number("POPUP_GAP")
        let compact = notch.width + theme.number("ISLAND_WING") * 2
        switch shape {
        case .hidden: return NSSize(width: notch.width + fillet * 2, height: notch.height)
        case .compact: return NSSize(width: compact + fillet * 2, height: notch.height)
        case .expanded:
            return NSSize(width: max(compact, theme.number("POPUP_WIDTH")) + fillet * 2, height: notch.height + (content?.frame.height ?? 0))
        }
    }

    private func move(to next: Shape) {
        guard notch != nil else { return }
        shape = next
        if !panel.isVisible {
            guard next != .hidden else { return }
            let start = size(.hidden)
            width = Spring(start.width)
            height = Spring(start.height)
            render()
            panel.orderFrontRegardless()
        }
        let target = size(next)
        width.target = target.width
        height.target = target.height
        if link == nil && width.settled && height.settled {
            finish()
            return
        }
        // Reduce Motion: the shape jumps and only the contents cross-fade.
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            width.settle()
            height.settle()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                render(fading: true)
            }
            finish()
            return
        }
        guard link == nil else { return }
        lastStep = nil
        let link = view.displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    // The link runs on RunLoop.main, so AppKit calls this on the main actor.
    @objc private func step(_ link: CADisplayLink) {
        let seconds = lastStep.map { min(1 / 30, max(0, link.timestamp - $0)) } ?? 1 / 120
        lastStep = link.timestamp
        let response = theme.number("ISLAND_RESPONSE")
        width.step(seconds, response: response)
        height.step(seconds, response: response)
        if width.settled && height.settled {
            width.settle()
            height.settle()
            stopLink()
            render()
            finish()
        } else {
            render()
        }
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
    }

    private func finish() {
        if shape == .hidden { panel.orderOut(nil) }
        if shape != .expanded {
            content?.removeFromSuperview()
            content = nil
        }
    }

    // Opacity follows the geometry, so an interrupted move never leaves contents out of step.
    private func render(fading: Bool = false) {
        guard let notch else { return }
        panel.setFrame(NSRect(x: notch.midX - width.value / 2, y: notch.top - height.value, width: width.value, height: height.value), display: true)
        let hidden = size(.hidden).width, compact = size(.compact).width
        let open = content.map { min(1, max(0, (height.value - notch.height) / max(1, $0.frame.height))) } ?? 0
        let grown = min(1, max(0, (width.value - hidden) / max(1, compact - hidden)))
        (fading ? wings.animator() : wings).alphaValue = grown * max(0, 1 - open * 2)
        if let content { (fading ? content.animator() : content).alphaValue = max(0, open * 2 - 1) }
    }

    @objc func mouseEntered(with event: NSEvent) { popups.show(.media) }

    @objc func mouseExited(with event: NSEvent) { popups.islandExited() }
}

final class OutputButton: NSButton {
    var device: AudioObjectID = 0
}

struct CalendarEvent {
    let title: String
    let start: Date
    let allDay: Bool
    let calendar: String
    let color: NSColor
}

final class Popups: NSObject, NSApplicationDelegate {
    static let notification = Notification.Name("com.bjoernaagaard.sketchybar.popup")
    let theme: Theme
    let panel = PopupPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    var item: PopupKind?
    var openingTask: Task<Void, Never>?
    var refreshTask: Task<Void, Never>?
    var mediaActionTask: Task<Void, Never>?
    var mediaActionTasks: [UUID: Task<Void, Never>] = [:]
    var openingClicks: [NSPoint] = []
    var openingHasAnchor = false
    var anchor = NSRect.zero
    var monitors: [Any] = []
    var timer: Timer?
    var slider: NSSlider?
    var percentage: NSTextField?
    var mute: NSButton?
    var deviceSignature = ""
    var networkState: NetworkState?
    var media: MediaSnapshot?
    var mediaError: MediaError?
    var mediaSlider: NSSlider?
    var mediaElapsed: NSTextField?
    var mediaDuration: NSTextField?
    var mediaSeeking = false
    var pendingMediaSeek: PendingMediaSeek?
    var initialCommand = PopupCommand.toggle(.volume)
    var hoverCanClose = false
    lazy var island = Island(theme: theme, popups: self)
    // Media opened from the island grows out of the notch instead of using the popup panel.
    var inIsland = false
    var notchTask: Task<Void, Never>?
    var lock: Int32 = -1
    lazy var eventStore = EKEventStore()
    var calendarAccessTask: Task<Void, Never>?
    var events: [CalendarEvent] = []
    var calendarBusy = false
    var calendarDirty = true
    var calendarMinute = -1
    var calendarError: (any Error)?
    var tailscale: Result<Tailscale, TailscaleError>?
    var tailscaleRead = Date.distantPast
    // One CLI write at a time. Its process is owned here and ended at shutdown.
    var tailscaleCommand: Task<Void, Never>?
    var tailscaleLogin = false

    init(theme: Theme) {
        self.theme = theme
        super.init()
    }

    var popupWindow: NSPanel { inIsland ? island.panel : panel }

    // The island panel stays on screen while compact, so visibility alone does not mean open.
    var isOpen: Bool { item != nil && openingTask == nil && (inIsland ? island.isExpanded : panel.isVisible) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua)
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] _ in
            guard let self, self.isOpen || self.openingTask != nil else { return }
            // The source item must reach its click script so a second click toggles closed.
            if self.openingTask != nil {
                let point = NSEvent.mouseLocation
                if self.openingHasAnchor {
                    if !self.anchor.contains(point) { self.close() }
                } else { self.openingClicks.append(point) }
            } else if !self.anchor.contains(NSEvent.mouseLocation) { self.close() }
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            if event.keyCode == 53, self?.openingTask != nil { self?.close() }
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            if event.keyCode == 53 { self?.close(); return nil }
            return event
        }) { monitors.append(monitor) }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(close), name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(close), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(calendarChanged), name: .EKEventStoreChanged, object: nil)
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            // This timer is installed only on RunLoop.main. Assert that SDK boundary.
            MainActor.assumeIsolated {
                guard let self else { return }
                if kill(self.theme.barPID, 0) != 0 { NSApp.terminate(nil) }
                guard self.isOpen else { return }
                switch self.item {
                case .volume: self.refreshVolume()
                case .network: self.refreshNetwork()
                case .tailscale: if Date().timeIntervalSince(self.tailscaleRead) >= 2 { self.refreshTailscale() }
                case .media:
                    self.refreshMedia()
                    let pointer = NSEvent.mouseLocation
                    if self.hoverCanClose && !self.anchor.contains(pointer) && !self.popupWindow.frame.contains(pointer) { self.close() }
                case .clock:
                    if self.calendarMinute != Int(Date().timeIntervalSince1970 / 60) || self.calendarDirty { self.loadCalendar() }
                case nil: break
                }
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        island.updateNotch()
        switch initialCommand {
        case .toggle(let popup): toggle(popup)
        case .hover: show(.media)
        case .start, .hoverEnd, .stop: break
        }
    }

    @objc func screensChanged() {
        close()
        guard island.updateNotch() else { return }
        // notch.sh moves the bar between its floating and notched layouts.
        notchTask?.cancel()
        notchTask = Task { [weak self] in await self?.trigger("notch_change") }
    }

    func applicationWillTerminate(_ notification: Notification) {
        calendarAccessTask?.cancel()
        calendarAccessTask = nil
        close()
        for task in mediaActionTasks.values { task.cancel() }
        mediaActionTasks.removeAll()
        tailscaleCommand?.cancel()
        tailscaleCommand = nil
        notchTask?.cancel()
        notchTask = nil
        island.stop()
        ProcessCapture.terminateRunningChildren()
        timer?.invalidate()
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
    }

    @objc func receive(_ notification: Notification) {
        guard let raw = notification.userInfo?["item"] as? String, let command = PopupCommand(raw) else { return }
        switch command {
        case .stop: NSApp.terminate(nil)
        case .hover: show(.media)
        case .hoverEnd: if item == .media { hoverCanClose = true }
        case .start: break
        case .toggle(let popup): toggle(popup)
        }
    }

    func islandExited() {
        guard item == .media, inIsland else { return }
        hoverCanClose = true
        if !island.panel.frame.contains(NSEvent.mouseLocation) { close() }
    }

    func queryAnchor(_ item: PopupKind) async -> NSRect? {
        guard let result = try? await ProcessCapture().run(URL(fileURLWithPath: theme.sketchybarPath), ["--query", item.rawValue]),
              result.status == 0,
              let object = try? JSONSerialization.jsonObject(with: result.output) as? [String: Any],
              let rects = object["bounding_rects"] as? [String: [String: Any]],
              let rect = rects.sorted(by: { $0.key < $1.key }).first?.value,
              let origin = rect["origin"] as? [Double], let size = rect["size"] as? [Double],
              origin.count == 2, size.count == 2,
              let screen = NSScreen.screens.first else { return nil }
        return NSRect(x: origin[0], y: screen.frame.maxY - origin[1] - size[1], width: size[0], height: size[1])
    }

    func show(_ next: PopupKind) {
        if item == next && (isOpen || openingTask != nil) { return }
        toggle(next)
    }

    func toggle(_ next: PopupKind) {
        if item == next && (isOpen || openingTask != nil) { close(); return }
        close()
        item = next
        // The island already holds the streamed snapshot, so it opens without waiting for a read.
        if next == .media, island.notch != nil {
            inIsland = true
            anchor = island.panel.frame
            media = island.media
            mediaError = nil
            buildMedia()
            island.panel.makeKeyAndOrderFront(nil)
            return
        }
        openingHasAnchor = false
        openingTask = Task { [weak self] in
            guard let self else { return }
            guard let rect = await self.queryAnchor(next), !Task.isCancelled else {
                if !Task.isCancelled { self.close() }
                return
            }
            self.anchor = rect
            self.openingHasAnchor = true
            guard self.openingClicks.allSatisfy({ rect.contains($0) }) else { self.close(); return }
            self.openingClicks.removeAll()
            switch next {
            case .volume: self.buildVolume()
            case .network:
                self.networkState = NetworkState.read()
                self.buildNetwork()
            case .tailscale:
                await self.readTailscale()
                guard !Task.isCancelled else { return }
                self.buildTailscale()
            case .media:
                await self.readMedia()
                guard !Task.isCancelled else { return }
                self.buildMedia()
            case .clock:
                self.events = []
                self.calendarError = nil
                self.buildCalendar()
            }
            guard !Task.isCancelled else { return }
            self.openingTask = nil
            self.panel.makeKeyAndOrderFront(nil)
            if next == .volume { self.panel.makeFirstResponder(self.slider) }
            if next == .clock { self.loadCalendar(requestAccess: true) }
            if next == .media && self.hoverCanClose {
                let pointer = NSEvent.mouseLocation
                if !self.anchor.contains(pointer) && !self.popupWindow.frame.contains(pointer) { self.close() }
            }
        }
    }

    @objc func close() {
        openingTask?.cancel()
        openingTask = nil
        openingClicks.removeAll()
        openingHasAnchor = false
        refreshTask?.cancel()
        refreshTask = nil
        item = nil
        hoverCanClose = false
        mediaSeeking = false
        pendingMediaSeek = nil
        if inIsland {
            inIsland = false
            island.collapse()
        }
        panel.orderOut(nil)
    }

    func surface(height: CGFloat) -> NSView {
        if inIsland { return island.expand(height: height) }
        let width = theme.number("POPUP_WIDTH")
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.screens[0]
        let inset = theme.number("POPUP_GAP")
        let x = max(screen.frame.minX + inset, min(anchor.midX - width / 2, screen.frame.maxX - inset - width))
        let visibleHeight = min(height, anchor.minY - screen.visibleFrame.minY - inset * 2)
        panel.setFrame(NSRect(x: x, y: anchor.minY - inset - visibleHeight, width: width, height: visibleHeight), display: false)
        let view = Surface(frame: NSRect(x: 0, y: 0, width: width, height: height), theme: theme)
        if height > visibleHeight {
            let background = Surface(frame: NSRect(x: 0, y: 0, width: width, height: visibleHeight), theme: theme)
            let scroll = NSScrollView(frame: background.bounds.insetBy(dx: 1, dy: theme.number("POPUP_RADIUS")))
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = true
            scroll.documentView = view
            background.addSubview(scroll)
            panel.contentView = background
        } else {
            panel.contentView = view
        }
        panel.title = item?.rawValue ?? ""
        return view
    }

    @discardableResult func label(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat, color: String = "TEXT", in view: NSView) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.frame = NSRect(x: x, y: y, width: width, height: 22)
        field.font = theme.font
        field.textColor = theme.color(color)
        field.lineBreakMode = .byTruncatingTail
        field.toolTip = text
        view.addSubview(field)
        return field
    }

    func buildVolume(devices: [(id: AudioObjectID, name: String)]? = nil, current: AudioObjectID? = nil) {
        let devices = devices ?? Audio.devices()
        let current = current ?? Audio.current
        let pad = theme.number("POPUP_PADDING")
        let width = theme.number("POPUP_WIDTH")
        let row = theme.number("POPUP_ROW")
        let view = surface(height: pad * 2 + row * CGFloat(3 + devices.count))
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

    func readMedia() async {
        do {
            let snapshot = try await Media.read(artwork: true)
            guard !Task.isCancelled else { return }
            media = snapshot
            mediaError = nil
        } catch {
            guard !Task.isCancelled else { return }
            media = nil
            mediaError = error as? MediaError ?? .commandFailed(error.localizedDescription)
        }
    }

    func refreshMedia() {
        guard item == .media, refreshTask == nil, mediaActionTasks.isEmpty else { return }
        refreshTask = Task { [weak self] in
            guard let self else { return }
            let previous = self.media?.contentSignature
            let previousError = self.mediaError?.localizedDescription
            await self.readMedia()
            guard !Task.isCancelled, self.item == .media, self.isOpen else { return }
            self.refreshTask = nil
            if previous != self.media?.contentSignature || previousError != self.mediaError?.localizedDescription {
                self.buildMedia()
            } else { self.updateMediaTiming() }
        }
    }

    func buildMedia() {
        mediaSeeking = false
        mediaSlider = nil
        mediaElapsed = nil
        mediaDuration = nil
        let pad = theme.number("POPUP_PADDING")
        let width = theme.number("POPUP_WIDTH")
        let row = theme.number("POPUP_ROW")
        let artworkSize: CGFloat = 48
        let contentY = pad + row
        let timingHeight = media?.timing == nil ? 0 : row
        let view = surface(height: pad * 2 + row * 2 + artworkSize + 16 + timingHeight)
        label("Now Playing", x: pad, y: pad, width: width - pad * 2 - 100, in: view)
        let application = label(media?.applicationName ?? "", x: width - pad - 100, y: pad, width: 100, color: "TEXT3", in: view)
        application.alignment = .right

        let artwork = NSImageView(frame: NSRect(x: pad, y: contentY, width: artworkSize, height: artworkSize))
        artwork.wantsLayer = true
        artwork.layer?.cornerRadius = 6
        artwork.layer?.masksToBounds = true
        artwork.imageScaling = .scaleProportionallyUpOrDown
        if let data = media?.artworkData, let image = NSImage(data: data) {
            artwork.image = image
        } else {
            artwork.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "No artwork")
            artwork.contentTintColor = theme.color("TEXT2")
        }
        artwork.setAccessibilityLabel("Album artwork")
        view.addSubview(artwork)

        let textX = pad + artworkSize + 12
        let textWidth = width - textX - pad
        let title = media?.title.isEmpty == false ? media?.title ?? "" : "Not playing"
        let detail = mediaError?.localizedDescription ?? (media?.artist.isEmpty == false ? media?.artist ?? "" : "No active media")
        label(title, x: textX, y: contentY + 2, width: textWidth, in: view)
        label(detail, x: textX, y: contentY + 26, width: textWidth, color: "TEXT2", in: view)

        let controlsY = contentY + artworkSize + 12 + timingHeight
        if media?.timing != nil {
            let timeWidth: CGFloat = 56
            let progressY = contentY + artworkSize + 8
            mediaElapsed = label("", x: pad, y: progressY, width: timeWidth, color: "TEXT2", in: view)
            mediaDuration = label("", x: width - pad - timeWidth, y: progressY, width: timeWidth, color: "TEXT2", in: view)
            mediaDuration?.alignment = .right
            let timeFont = NSFont.monospacedDigitSystemFont(ofSize: theme.font.pointSize, weight: .semibold)
            mediaElapsed?.font = timeFont
            mediaDuration?.font = timeFont
            let slider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: self, action: #selector(seekMedia(_:)))
            slider.frame = NSRect(x: pad + timeWidth + 4, y: progressY,
                                  width: width - pad * 2 - timeWidth * 2 - 8, height: 24)
            slider.isContinuous = true
            slider.trackFillColor = theme.color("TEXT")
            slider.setAccessibilityLabel("Playback position")
            slider.toolTip = "Drag to seek"
            view.addSubview(slider)
            mediaSlider = slider
            updateMediaTiming()
        }
        let buttonWidth: CGFloat = 64
        let spacing: CGFloat = 8
        let controlsWidth = buttonWidth * 3 + spacing * 2
        let startX = (width - controlsWidth) / 2
        func control(_ symbol: String, _ help: String, x: CGFloat, action: Selector) {
            let button = NSButton(frame: NSRect(x: x, y: controlsY, width: buttonWidth, height: row))
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)
            button.imagePosition = .imageOnly
            button.bezelStyle = .inline
            button.contentTintColor = theme.color("TEXT")
            button.isEnabled = media != nil
            button.toolTip = help
            button.setAccessibilityLabel(help)
            button.target = self
            button.action = action
            view.addSubview(button)
        }
        control("backward.fill", "Previous", x: startX, action: #selector(previousMedia))
        control(media?.playing == true ? "pause.fill" : "play.fill", media?.playing == true ? "Pause" : "Play or pause",
                x: startX + buttonWidth + spacing, action: #selector(playPauseMedia))
        control("forward.fill", "Next", x: startX + (buttonWidth + spacing) * 2, action: #selector(nextMedia))
    }

    func updateMediaTiming() {
        guard let timing = media?.timing else { return }
        var elapsed = timing.elapsed
        if let pending = pendingMediaSeek {
            let age = Date().timeIntervalSince(pending.requestedAt)
            let expected = min(timing.duration, pending.position + (media?.playing == true ? age : 0))
            if pending.trackSignature != media?.trackSignature || age >= 3 {
                pendingMediaSeek = nil
            } else if abs(timing.elapsed - expected) <= 2 {
                pendingMediaSeek = nil
            } else {
                elapsed = expected
            }
        }
        mediaSlider?.maxValue = timing.duration
        mediaDuration?.stringValue = MediaTiming.format(timing.duration)
        guard !mediaSeeking else { return }
        mediaSlider?.doubleValue = elapsed
        mediaElapsed?.stringValue = MediaTiming.format(elapsed)
        mediaSlider?.setAccessibilityValue("\(MediaTiming.format(elapsed)) of \(MediaTiming.format(timing.duration))")
    }

    func seekMedia(to seconds: Double) {
        refreshTask?.cancel()
        refreshTask = nil
        let signature = media?.trackSignature ?? []
        pendingMediaSeek = PendingMediaSeek(position: seconds, trackSignature: signature)
        updateMediaTiming()
        let previous = mediaActionTask
        let id = UUID()
        let task = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            defer {
                self.mediaActionTasks[id] = nil
                if self.mediaActionTasks.isEmpty && self.item == .media && self.isOpen { self.refreshMedia() }
            }
            guard !Task.isCancelled else { return }
            do {
                let current = try await Media.read()
                guard !Task.isCancelled, current?.trackSignature == signature else { return }
                try await Media.seek(to: seconds)
                await self.trigger("media_change")
            } catch {
                guard !Task.isCancelled, self.item == .media, self.isOpen else { return }
                self.pendingMediaSeek = nil
                NSAlert(error: error).beginSheetModal(for: self.popupWindow, completionHandler: nil)
            }
        }
        mediaActionTask = task
        mediaActionTasks[id] = task
    }

    func performMedia(_ action: MediaAction) {
        pendingMediaSeek = nil
        refreshTask?.cancel()
        refreshTask = nil
        let previous = mediaActionTask
        let id = UUID()
        let task = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            defer {
                self.mediaActionTasks[id] = nil
                if self.mediaActionTasks.isEmpty && self.item == .media && self.isOpen { self.refreshMedia() }
            }
            guard !Task.isCancelled else { return }
            do {
                try await Media.perform(action)
                await self.trigger("media_change")
            } catch {
                guard !Task.isCancelled, self.item == .media, self.isOpen else { return }
                NSAlert(error: error).beginSheetModal(for: self.popupWindow, completionHandler: nil)
            }
        }
        mediaActionTask = task
        mediaActionTasks[id] = task
    }

    func trigger(_ event: String) async {
        _ = try? await ProcessCapture().run(URL(fileURLWithPath: theme.sketchybarPath), ["--trigger", event])
    }

    func refreshNetwork() {
        let state = NetworkState.read()
        if state != networkState {
            networkState = state
            buildNetwork()
        }
    }

    func buildNetwork() {
        let connections = networkState?.connections ?? []
        let pad = theme.number("POPUP_PADDING")
        let width = theme.number("POPUP_WIDTH")
        let row = theme.number("POPUP_ROW")
        let view = surface(height: pad * 2 + row * CGFloat(3 + connections.count * 2))
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

    func openSettings(_ address: String) {
        // Callers pass fixed URL literals. A parse failure is a programmer mistake.
        guard let url = URL(string: address) else { preconditionFailure("Invalid settings URL: \(address)") }
        NSWorkspace.shared.open(url)
        close()
    }

    @objc func openWiFiSettings() { openSettings("x-apple.systempreferences:com.apple.wifi-settings-extension") }

    @objc func openNetworkSettings() { openSettings("x-apple.systempreferences:com.apple.Network-Settings.extension") }

    func readTailscale() async {
        tailscaleRead = Date()
        do {
            let state = try await Tailscale.read()
            guard !Task.isCancelled else { return }
            tailscale = .success(state)
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
        let width = theme.number("POPUP_WIDTH")
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
        let view = surface(height: pad * 2 + row * rows)
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
                await self.trigger("tailscale_change")
                guard !Task.isCancelled else { return }
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

    @objc nonisolated func calendarChanged() {
        // EventKit can post from another thread. Only the UI update crosses actors.
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.calendarDirty = true
            if self.isOpen && self.item == .clock { self.loadCalendar() }
        }
    }

    func loadCalendar(requestAccess: Bool = false) {
        guard !calendarBusy else { return }
        let authorization = EKEventStore.authorizationStatus(for: .event)
        if authorization == .notDetermined && requestAccess {
            calendarBusy = true
            buildCalendar()
            // A permission request belongs to the app, not the currently open popup.
            calendarAccessTask = Task { [weak self] in
                guard let self else { return }
                do {
                    _ = try await self.eventStore.requestFullAccessToEvents()
                    self.calendarError = nil
                } catch {
                    self.calendarError = error
                }
                self.calendarBusy = false
                self.calendarAccessTask = nil
                guard !Task.isCancelled else { return }
                // The user may have switched or closed popups while permission was pending.
                self.calendarDirty = true
                if self.item == .clock && self.isOpen { self.loadCalendar() }
            }
            return
        }
        calendarMinute = Int(Date().timeIntervalSince1970 / 60)
        calendarDirty = false
        guard authorization == .fullAccess else {
            events = []
            calendarError = calendarError ?? NSError(domain: EKErrorDomain, code: EKError.Code.eventStoreNotAuthorized.rawValue)
            if item == .clock { buildCalendar() }
            return
        }
        calendarBusy = true
        calendarError = nil
        // Keep the store and its events on the main actor; do not share EKEventStore
        // with a dispatch queue. The UI consumes value snapshots, never EKEvent objects.
        let now = Date()
        let calendar = Calendar.autoupdatingCurrent
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        let predicate = eventStore.predicateForEvents(withStart: now, end: tomorrow, calendars: nil)
        // EventKit expands recurring occurrences. Include ongoing and all-day events,
        // but never cancelled, declined, or already-finished occurrences.
        events = eventStore.events(matching: predicate)
            .filter { event in
                event.endDate > now && event.startDate < tomorrow && event.status != .canceled &&
                !(event.attendees ?? []).contains { $0.isCurrentUser && $0.participantStatus == .declined }
            }
            .sorted { $0.startDate == $1.startDate ? ($0.title ?? "") < ($1.title ?? "") : $0.startDate < $1.startDate }
            .map { CalendarEvent(title: $0.title ?? "", start: $0.startDate, allDay: $0.isAllDay,
                                 calendar: $0.calendar.title, color: NSColor(cgColor: $0.calendar.cgColor) ?? .white) }
        calendarBusy = false
        if item == .clock { buildCalendar() }
    }

    func buildCalendar() {
        let now = Date()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        calendar.firstWeekday = 2
        let first = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!
        let days = calendar.range(of: .day, in: .month, for: now)!
        let offset = (calendar.component(.weekday, from: first) + 5) % 7
        let weeks = (offset + days.count + 6) / 7
        let pad = theme.number("POPUP_PADDING")
        let row = theme.number("POPUP_ROW")
        let width = theme.number("POPUP_WIDTH")
        let column = (width - pad * 2) / 7
        let eventsY = pad + row * CGFloat(weeks + 2) + theme.number("POPUP_GAP")
        let errorHeight: CGFloat = calendarError == nil ? 0 : row * 3
        let view = surface(height: eventsY + row + CGFloat(events.count) * row + errorHeight + pad)
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.calendar = calendar
        formatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        label(formatter.string(from: now), x: pad, y: pad, width: width - pad * 2, in: view)
        let weekdays = formatter.veryShortStandaloneWeekdaySymbols!
        for col in 0..<7 {
            let field = label(weekdays[(col + 1) % 7], x: pad + column * CGFloat(col), y: pad + row,
                              width: column, color: col >= 5 ? "TEXT3" : "TEXT2", in: view)
            field.alignment = .center
            field.toolTip = formatter.standaloneWeekdaySymbols[(col + 1) % 7]
            field.setAccessibilityLabel(field.toolTip)
        }
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        for day in days {
            let index = offset + day - 1
            let col = index % 7
            let x = pad + column * CGFloat(col)
            let y = pad + row * CGFloat(2 + index / 7)
            let today = day == calendar.component(.day, from: now)
            if today {
                let diameter = theme.number("CALENDAR_TODAY_SIZE")
                let circleX = ((x + (column - diameter) / 2) * panel.backingScaleFactor).rounded() / panel.backingScaleFactor
                let circle = NSView(frame: NSRect(x: circleX, y: y, width: diameter, height: diameter))
                circle.wantsLayer = true
                circle.layer?.cornerRadius = diameter / 2
                circle.layer?.backgroundColor = NSColor.white.cgColor
                view.addSubview(circle)
            }
            let field = label(String(day), x: x, y: y + 2, width: column, color: col >= 5 ? "TEXT3" : "TEXT", in: view)
            field.alignment = .center
            if today { field.textColor = theme.color("BAR_COLOR").withAlphaComponent(1) }
            let date = calendar.date(byAdding: .day, value: day - 1, to: first)!
            field.toolTip = formatter.string(from: date)
            field.setAccessibilityLabel(field.toolTip)
        }
        label("Today", x: pad, y: eventsY, width: width - pad * 2 - 40, in: view)
        let count = label(calendarError != nil ? "" : (calendarBusy ? "..." : String(events.count)), x: width - pad - 40, y: eventsY, width: 40, color: "TEXT2", in: view)
        count.alignment = .right
        if let error = calendarError {
            let message = NSTextField(wrappingLabelWithString: error.localizedDescription)
            message.font = theme.font
            message.textColor = theme.color("TEXT2")
            message.frame = NSRect(x: pad, y: eventsY + row, width: width - pad * 2, height: row * 2)
            view.addSubview(message)
            let button = NSButton(title: "Calendar", target: self, action: #selector(openCalendarPrivacy))
            button.frame = NSRect(x: pad, y: eventsY + row * 3, width: width - pad * 2, height: row)
            button.bezelStyle = .inline
            button.font = theme.font
            view.addSubview(button)
        }
        formatter.dateStyle = .none
        formatter.dateFormat = "HH:mm"
        for (index, event) in events.enumerated() {
            let y = eventsY + row * CGFloat(index + 1)
            let color = NSView(frame: NSRect(x: pad, y: y + 1, width: 3, height: 22))
            color.wantsLayer = true
            color.layer?.cornerRadius = 1.5
            color.layer?.backgroundColor = event.color.cgColor
            color.toolTip = event.calendar
            view.addSubview(color)
            let time = formatter.string(from: event.start)
            label(time, x: pad + 10, y: y + 2, width: 46, color: "TEXT2", in: view)
            let title = label(event.title, x: pad + 64, y: y + 2, width: width - pad * 2 - 64, in: view)
            title.toolTip = "\(event.calendar)\n\(event.title)\n\(DateFormatter.localizedString(from: event.start, dateStyle: .medium, timeStyle: event.allDay ? .none : .short))"
            title.setAccessibilityLabel(title.toolTip)
        }
    }

    @objc func openCalendarPrivacy() { openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") }

    @objc func changeVolume(_ sender: NSSlider) { perform { try Audio.setVolume(Float(sender.doubleValue / 100)) } }
    @objc func changeMute(_ sender: NSButton) { perform { try Audio.setMuted(sender.state == .on) } }
    @objc func changeDevice(_ sender: OutputButton) { perform { try Audio.select(sender.device) }; refreshVolume() }
    @objc func previousMedia() { performMedia(.previous) }
    @objc func playPauseMedia() { performMedia(.playPause) }
    @objc func nextMedia() { performMedia(.next) }
    @objc func seekMedia(_ sender: NSSlider) {
        guard media?.timing != nil else { return }
        let eventType = NSApp.currentEvent?.type
        if eventType == .leftMouseDown {
            mediaSeeking = true
            pendingMediaSeek = nil
        }
        let seconds = min(sender.maxValue, max(0, sender.doubleValue))
        mediaElapsed?.stringValue = MediaTiming.format(seconds)
        mediaSlider?.setAccessibilityValue("\(MediaTiming.format(seconds)) of \(MediaTiming.format(sender.maxValue))")
        let dragging = eventType == .leftMouseDown || eventType == .leftMouseDragged
        guard !dragging else { return }
        mediaSeeking = false
        seekMedia(to: seconds)
    }
}

// NSApplication.delegate is weak. This lazy process-lifetime owner keeps the UI
// controller alive without constructing AppKit windows for the JSON commands.
private enum PopupRuntime {
    static let delegate: Popups = {
        do { return Popups(theme: try Theme()) }
        catch {
            // ConfigurationError contains fixed key names, never environment values.
            logger.error("Popup configuration failed: \(error.localizedDescription, privacy: .public)")
            exit(EXIT_FAILURE)
        }
    }()
}

func runCLI(_ operation: @escaping () async throws -> Void) -> Never {
    Task {
        do { try await operation(); exit(EXIT_SUCCESS) }
        catch { logger.error("Command failed: \(error.localizedDescription, privacy: .private)"); exit(EXIT_FAILURE) }
    }
    RunLoop.main.run()
    exit(EXIT_FAILURE)
}

let arguments = CommandLine.arguments
if arguments.count > 1 && arguments[1] == "audio" {
    let data = try JSONSerialization.data(withJSONObject: Audio.snapshot(), options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
} else if arguments.count > 1 && arguments[1] == "network-state" {
    guard let state = NetworkState.read() else { exit(1) }
    let data = try JSONEncoder().encode(state)
    print(String(decoding: data, as: UTF8.self))
} else if arguments.count > 1 && arguments[1] == "notch" {
    // notch.sh reads this. null means the bar's display has no camera housing.
    let size = Notch.main.map { ["width": Int($0.width.rounded()), "height": Int($0.height.rounded())] }
    let data = try JSONEncoder().encode(size)
    print(String(decoding: data, as: UTF8.self))
} else if arguments.count > 1 && arguments[1] == PopupCommand.hoverEnd.rawValue {
    DistributedNotificationCenter.default().postNotificationName(Popups.notification, object: nil, userInfo: ["item": PopupCommand.hoverEnd.rawValue], deliverImmediately: true)
} else if arguments.count > 1 && arguments[1] == "media-state" {
    runCLI {
        let snapshot = try await Media.read()
        let data = try JSONEncoder().encode(snapshot)
        print(String(decoding: data, as: UTF8.self))
    }
} else if arguments.count > 2 && arguments[1] == "media" {
    guard let action = MediaAction(rawValue: arguments[2]) else {
        logger.error("Unknown media command: \(arguments[2])")
        exit(EXIT_FAILURE)
    }
    runCLI { try await Media.perform(action) }
} else if arguments.count > 1 && arguments[1] == "tailscale-state" {
    runCLI {
        let data = try await JSONEncoder().encode(["kind": Tailscale.kind()])
        print(String(decoding: data, as: UTF8.self))
    }
} else if arguments.count > 1 && arguments[1] == PopupCommand.stop.rawValue {
    DistributedNotificationCenter.default().postNotificationName(Popups.notification, object: nil, userInfo: ["item": PopupCommand.stop.rawValue], deliverImmediately: true)
    // sketchybarrc starts a helper right after this. Wait up to 2 s for the running one to
    // release its lock, so that command is not handed to a process that is exiting.
    guard let source = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("popup.swift") else { exit(EXIT_FAILURE) }
    let lock = open(source.path, O_RDONLY)
    var waits = 0
    while lock >= 0, flock(lock, LOCK_EX | LOCK_NB) != 0, waits < 100 {
        usleep(20_000)
        waits += 1
    }
} else {
    let raw = arguments.count > 1 ? arguments[1] : PopupKind.volume.rawValue
    guard let command = PopupCommand(raw) else {
        logger.error("Unknown popup command: \(raw)")
        exit(EXIT_FAILURE)
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = PopupRuntime.delegate
    delegate.initialCommand = command
    DistributedNotificationCenter.default().addObserver(delegate, selector: #selector(Popups.receive(_:)), name: Popups.notification, object: nil)
    // Lock the existing source inode, not a scratch file. The kernel releases it on exit.
    delegate.lock = open(delegate.theme.configDirectory + "/plugins/popup.swift", O_RDONLY)
    guard delegate.lock >= 0 else { exit(1) }
    if flock(delegate.lock, LOCK_EX | LOCK_NB) != 0 {
        DistributedNotificationCenter.default().postNotificationName(Popups.notification, object: nil, userInfo: ["item": command.rawValue], deliverImmediately: true)
        exit(0)
    }
    app.delegate = delegate
    app.run()
}
