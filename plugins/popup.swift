// Before feature work, read ../AGENTS.md and ~/.agents/skills/write-swift/SKILL.md.
import AppKit
import CoreAudio
import EventKit
import IOKit
import SystemConfiguration
import os

private let logger = Logger(subsystem: "com.bjoernaagaard.sketchybar", category: "popup")
private let interactionLogger = Logger(subsystem: "com.bjoernaagaard.sketchybar", category: "popup.interaction")

enum PopupKind: String {
    case volume, clock, network, tailscale, media, system, front, battery, workspace, mode
}

enum PopupSource: Equatable {
    case volume, clock, network, tailscale, media, system, cpu, memory, front, frontIcon, battery, mode
    case workspace(String, String)

    init?(rawValue: String) {
        switch rawValue {
        case "volume": self = .volume
        case "clock": self = .clock
        case "network": self = .network
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
        case "start": self = .start
        case "stop": self = .stop
        default:
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
        case .start: "start"
        case .stop: "stop"
        case .volumeScroll: "volume-scroll"
        }
    }

    var userInfo: [String: String] {
        switch self {
        case .volumeScroll(let notches): ["item": rawValue, "argument": String(notches)]
        case .hover(let source), .hoverEnd(let source): ["item": rawValue, "argument": source.rawValue]
        case .toggle, .geometry, .start, .stop: ["item": rawValue]
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

enum NetworkKind: String {
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

    static func change(by points: Int) throws {
        guard let value = volume(current) else { return }
        try setVolume(Float(Int((value * 100).rounded()) + points) / 100)
    }

    // CoreAudio removes a listener only when given the same block object it was added with.
    typealias Listener = @convention(block) (UInt32, UnsafePointer<AudioObjectPropertyAddress>) -> Void

    // The listener runs on the main queue.
    static func listen(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress, _ listener: @escaping Listener) -> Bool {
        var address = address
        return AudioObjectAddPropertyListenerBlock(id, &address, .main, listener) == noErr
    }

    static func unlisten(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress, _ listener: @escaping Listener) {
        var address = address
        let status = AudioObjectRemovePropertyListenerBlock(id, &address, .main, listener)
        if status != noErr { logger.error("Removing an audio listener failed with status \(status, privacy: .public).") }
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

struct MediaSnapshot: Decodable, Equatable {
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

    // Takes only the bytes that are ready. FileHandle.read(upToCount:) waits for the full
    // count or EOF, and a process that streams sends neither.
    nonisolated static func reader(_ continuation: AsyncStream<Event>.Continuation, _ descriptor: Int32,
                                   bytes: @escaping @Sendable (Data) -> Event, end: Event) -> @Sendable (FileHandle) -> Void {
        { handle in
            var buffer = [UInt8](repeating: 0, count: 65536)
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            let code = errno
            if count > 0 {
                continuation.yield(bytes(Data(buffer[..<count])))
            } else if count == 0 || (code != EAGAIN && code != EINTR) {
                handle.readabilityHandler = nil
                continuation.yield(count == 0 ? end : .readFailure(POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)))
            }
        }
    }

    // With `lines`, each complete stdout line goes to the handler instead of the result.
    func run(_ executable: URL, _ arguments: [String], lines: ((Data) -> Void)? = nil) async throws -> Result {
        try Task.checkCancellation()
        let (events, continuation) = AsyncStream<Event>.makeStream()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = errors
        output.fileHandleForReading.readabilityHandler = Self.reader(continuation, output.fileHandleForReading.fileDescriptor,
                                                                    bytes: Event.output, end: .outputEnd)
        errors.fileHandleForReading.readabilityHandler = Self.reader(continuation, errors.fileHandleForReading.fileDescriptor,
                                                                    bytes: Event.error, end: .errorEnd)
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

private func readNetworkState(context: String) -> NetworkState? {
    let start = ProcessInfo.processInfo.systemUptime
    let state = NetworkState.read()
    let milliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1_000
    interactionLogger.debug("event=network_read context=\(context, privacy: .public) elapsed_ms=\(milliseconds) success=\(state != nil)")
    return state
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

// Values the bar item renders. Strings appear only at the trigger boundary with status.sh.
enum TailscaleKind: String {
    case running, exitNode = "exit-node", stopped, login, unavailable

    init(_ status: TailscaleStatus) {
        switch status.backend {
        case .running: self = status.peers.contains { $0.exitNode } ? .exitNode : .running
        case .needsLogin, .needsMachineAuth: self = .login
        case .stopped, .starting, .noState: self = .stopped
        }
    }
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
        return TailscaleKind(status)
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
        for name in ["POPUP_RADIUS", "POPUP_WIDTH", "POPUP_GAP", "POPUP_PADDING", "POPUP_ROW", "CALENDAR_TODAY_SIZE"] {
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

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class OutputButton: NSButton {
    var device: AudioObjectID = 0
}

struct FrontSnapshot: Decodable, Equatable {
    let appName: String?
    let windowTitle: String?

    enum CodingKeys: String, CodingKey {
        case appName = "app-name", windowTitle = "window-title"
    }
}

struct CalendarEvent {
    let title: String
    let start: Date
    let allDay: Bool
    let calendar: String
    let color: NSColor
}

// How strained a reading is. The bar and the system popup tint the same way.
enum Strain: String {
    case normal, warn, crit
}

enum MemoryPressure: Int32 {
    case normal = 1, warning = 2, critical = 4

    var title: String {
        switch self {
        case .normal: "Normal"
        case .warning: "Warning"
        case .critical: "Critical"
        }
    }

    var strain: Strain {
        switch self {
        case .normal: .normal
        case .warning: .warn
        case .critical: .crit
        }
    }
}

// Cumulative CPU ticks since boot. The kernel counters are 32-bit and wrap, so differences wrap too.
struct CPUTicks {
    let user: UInt32
    let system: UInt32
    let idle: UInt32

    // Like Activity Monitor and SketchyBar's cpu_load, nice time is left out.
    func load(since earlier: CPUTicks) -> CPULoad {
        let user = Double(user &- earlier.user), system = Double(system &- earlier.system)
        let total = user + system + Double(idle &- earlier.idle)
        return total > 0 ? CPULoad(user: user / total, system: system / total) : CPULoad(user: 0, system: 0)
    }
}

// Fractions of the interval, from 0 to 1.
struct CPULoad: Equatable {
    let user: Double
    let system: Double
    var total: Double { user + system }
}

// Activity Monitor's Memory Used is App + Wired + Compressed.
struct MemoryUsage: Equatable {
    let app: UInt64
    let wired: UInt64
    let compressed: UInt64
    let total: UInt64
    var used: UInt64 { app + wired + compressed }
}

struct Capacity: Equatable {
    let used: UInt64
    let total: UInt64
}

struct InterfaceBytes {
    let received: UInt32
    let sent: UInt32
}

struct NetworkRate: Equatable {
    let interface: String
    let received: Double
    let sent: Double
}

struct CoreCluster: Equatable {
    let title: String
    let load: Double
}

struct ProcessLoad {
    let name: String
    let percent: Int
}

// Unprivileged public reads. Unsafe Mach, sysctl, getifaddrs, IOKit, and libproc access stays here.
struct SystemRead {
    static let host = mach_host_self()

    static func number<T: BitwiseCopyable>(_ name: String, _ initial: T) -> T? {
        var value = initial
        var size = MemoryLayout<T>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 && size == MemoryLayout<T>.size ? value : nil
    }

    static func text(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func cpu() -> CPUTicks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard status == KERN_SUCCESS else { return nil }
        return CPUTicks(user: info.cpu_ticks.0, system: info.cpu_ticks.1, idle: info.cpu_ticks.2)
    }

    static func cores() -> [CPUTicks] {
        var cpus: natural_t = 0
        var info: processor_info_array_t?
        var count: mach_msg_type_number_t = 0
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &cpus, &info, &count) == KERN_SUCCESS, let info else { return [] }
        defer { vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), vm_size_t(count) * vm_size_t(MemoryLayout<integer_t>.stride)) }
        let values = UnsafeBufferPointer(start: info, count: Int(count))
        let stride = Int(CPU_STATE_MAX)
        guard values.count >= Int(cpus) * stride else { return [] }
        return (0..<Int(cpus)).map { cpu in
            let base = cpu * stride
            return CPUTicks(user: UInt32(bitPattern: values[base + Int(CPU_STATE_USER)]),
                            system: UInt32(bitPattern: values[base + Int(CPU_STATE_SYSTEM)]),
                            idle: UInt32(bitPattern: values[base + Int(CPU_STATE_IDLE)]))
        }
    }

    // Apple silicon numbers its logical CPUs by cluster with efficiency cores first, which the
    // device tree's cluster-type confirms. Titles and counts come from hw.perflevel*.
    static let clusters: [(title: String, cpus: Range<Int>)] = {
        let levels = number("hw.nperflevels", Int32(0)) ?? 0
        guard levels > 1 else {
            let count = Int(number("hw.logicalcpu", Int32(0)) ?? 0)
            return [("Cores (\(count))", 0..<count)]
        }
        var start = 0
        return (0..<levels).reversed().map { level in
            let count = Int(number("hw.perflevel\(level).logicalcpu", Int32(0)) ?? 0)
            let name = text("hw.perflevel\(level).name") ?? "Level \(level)"
            defer { start += count }
            return ("\(name) cores (\(count))", start..<start + count)
        }.reversed()
    }()

    static let pageSize: UInt64 = {
        var size: vm_size_t = 0
        return host_page_size(host, &size) == KERN_SUCCESS ? UInt64(size) : 16384
    }()

    static func memory() -> MemoryUsage? {
        var info = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(host, HOST_VM_INFO64, $0, &count) }
        }
        guard status == KERN_SUCCESS else { return nil }
        let app = UInt64(info.internal_page_count) - min(UInt64(info.internal_page_count), UInt64(info.purgeable_count))
        return MemoryUsage(app: app * pageSize, wired: UInt64(info.wire_count) * pageSize,
                           compressed: UInt64(info.compressor_page_count) * pageSize, total: ProcessInfo.processInfo.physicalMemory)
    }

    static func pressure() -> MemoryPressure {
        number("kern.memorystatus_vm_pressure_level", Int32(0)).flatMap(MemoryPressure.init) ?? .normal
    }

    static func swap() -> Capacity? {
        number("vm.swapusage", xsw_usage()).map { Capacity(used: $0.xsu_used, total: $0.xsu_total) }
    }

    static func disk() -> Capacity? {
        var stats = statfs()
        guard statfs("/", &stats) == 0 else { return nil }
        let block = UInt64(stats.f_bsize)
        return Capacity(used: (stats.f_blocks - stats.f_bavail) * block, total: stats.f_blocks * block)
    }

    static func bytes(_ interface: String) -> InterfaceBytes? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK),
                  let data = entry.pointee.ifa_data, String(cString: entry.pointee.ifa_name) == interface else { continue }
            let counters = data.load(as: if_data.self)
            return InterfaceBytes(received: counters.ifi_ibytes, sent: counters.ifi_obytes)
        }
        return nil
    }

    static func bootTime() -> Date? {
        number("kern.boottime", timeval()).map { Date(timeIntervalSince1970: Double($0.tv_sec) + Double($0.tv_usec) / 1_000_000) }
    }

    // The highest utilization any GPU reports.
    static func gpu() -> Int? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var result: Int?
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let property = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0),
                  let statistics = property.takeRetainedValue() as? [String: Any],
                  let value = statistics["Device Utilization %"] as? Int else { continue }
            result = max(result ?? 0, value)
        }
        return result
    }

    // rusage times are in Mach time units, which are not nanoseconds on Apple silicon.
    static let nanosecondsPerTick: Double = {
        var timebase = mach_timebase_info_data_t()
        return mach_timebase_info(&timebase) == KERN_SUCCESS && timebase.denom > 0 ? Double(timebase.numer) / Double(timebase.denom) : 1
    }()

    // CPU time in nanoseconds for each process the user owns. Other users' processes are not readable.
    static func processTimes() -> [pid_t: Double] {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        guard capacity > 64 else { return [:] }
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
        guard count > 0 else { return [:] }
        let user = getuid()
        var times: [pid_t: Double] = [:]
        for pid in pids.prefix(min(count, capacity)) where pid > 0 {
            var info = proc_bsdshortinfo()
            let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size, info.pbsi_uid == user else { continue }
            var usage = rusage_info_v2()
            let status = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
            }
            guard status == 0 else { continue }
            times[pid] = Double(usage.ri_user_time + usage.ri_system_time) * nanosecondsPerTick
        }
        return times
    }

    static func processName(_ pid: pid_t) -> String {
        if let name = NSRunningApplication(processIdentifier: pid)?.localizedName { return name }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXCOMLEN) + 1)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return "Process \(pid)" }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
}

// One reading every 2 s. The bar shows CPU and memory from it, and the open popup shows all of it.
struct SystemSample: Equatable {
    let time: UInt64
    let cpu: CPULoad
    let clusters: [CoreCluster]
    let memory: MemoryUsage
    let pressure: MemoryPressure
    let swap: Capacity?
    let disk: Capacity?
    let network: NetworkRate?
    let thermal: ProcessInfo.ThermalState
    // CPU above 80 % for 5 samples in a row, which is 10 s.
    let busy: Bool

    var cpuStrain: Strain { thermal == .serious || thermal == .critical ? .crit : busy ? .warn : .normal }
    var diskStrain: Strain { disk.map { $0.total > 0 && ($0.total - $0.used) * 10 < $0.total } == true ? .warn : .normal }

    var bar: BarState {
        .system(cpu: Int((cpu.total * 100).rounded()),
                memory: memory.total > 0 ? Int((Double(memory.used) * 100 / Double(memory.total)).rounded()) : 0,
                cpuStrain: cpuStrain, memoryStrain: pressure.strain, diskStrain: diskStrain)
    }
}

// Keeps the previous counters, because CPU load and network speed are differences over time.
struct SystemSampler {
    private var time: UInt64 = 0
    private var cpu: CPUTicks?
    private var cores: [CPUTicks] = []
    private var network: (interface: String, bytes: InterfaceBytes)?
    private var busySamples = 0

    // The first call only primes the counters.
    mutating func sample(interface: String?) -> SystemSample? {
        let now = SystemRead.now()
        let ticks = SystemRead.cpu(), cores = SystemRead.cores()
        let bytes = interface.flatMap(SystemRead.bytes)
        defer {
            time = now
            cpu = ticks
            self.cores = cores
            if let interface, let bytes { network = (interface, bytes) } else { network = nil }
        }
        guard let ticks, let previous = cpu, now > time, let memory = SystemRead.memory() else { return nil }
        let load = ticks.load(since: previous)
        busySamples = load.total > 0.8 ? busySamples + 1 : 0
        let clusters = cores.count == self.cores.count ? SystemRead.clusters.compactMap { cluster -> CoreCluster? in
            let range = cluster.cpus.clamped(to: 0..<cores.count)
            guard !range.isEmpty else { return nil }
            let total = range.reduce(0) { $0 + cores[$1].load(since: self.cores[$1]).total }
            return CoreCluster(title: cluster.title, load: total / Double(range.count))
        } : []
        var rate: NetworkRate?
        if let interface, let bytes, let network, network.interface == interface {
            let seconds = Double(now - time) / 1_000_000_000
            rate = NetworkRate(interface: interface, received: Double(bytes.received &- network.bytes.received) / seconds,
                               sent: Double(bytes.sent &- network.bytes.sent) / seconds)
        }
        return SystemSample(time: now, cpu: load, clusters: clusters, memory: memory, pressure: SystemRead.pressure(),
                            swap: SystemRead.swap(), disk: SystemRead.disk(), network: rate,
                            thermal: ProcessInfo.processInfo.thermalState, busy: busySamples >= 5)
    }
}

// Top processes by CPU since the previous call. Read only while the system popup is open.
struct ProcessSampler {
    private var time: UInt64 = 0
    private var times: [pid_t: Double] = [:]

    mutating func sample(count: Int) -> [ProcessLoad]? {
        let now = SystemRead.now()
        let current = SystemRead.processTimes()
        defer { time = now; times = current }
        guard time > 0, now > time else { return nil }
        let elapsed = Double(now - time)
        return current.compactMap { pid, cpu in times[pid].flatMap { cpu >= $0 ? (pid, (cpu - $0) / elapsed) : nil } }
            .sorted { $0.1 > $1.1 }
            .prefix(count)
            .map { ProcessLoad(name: SystemRead.processName($0.0), percent: Int(($0.1 * 100).rounded())) }
    }
}

// What a bar item shows. Strings exist only in `variables`, at the sketchybar trigger boundary.
enum BarState: Equatable {
    case volume(percent: Int?, muted: Bool)
    case network(NetworkKind)
    case media(title: String, artist: String, playing: Bool)
    case mediaUnavailable
    case tailscale(TailscaleKind)
    case system(cpu: Int, memory: Int, cpuStrain: Strain, memoryStrain: Strain, diskStrain: Strain)

    // Each item subscribes to its own event in sketchybarrc, and status.sh reads the variables.
    var event: String {
        switch self {
        case .volume: "volume_state"
        case .network: "network_state"
        case .media, .mediaUnavailable: "media_state"
        case .tailscale: "tailscale_state"
        case .system: "system_state"
        }
    }

    var variables: [String] {
        switch self {
        case .volume(let percent, let muted): ["VOLUME=\(percent.map(String.init) ?? "fixed")", "MUTED=\(muted)"]
        case .network(let kind): ["KIND=\(kind.rawValue)"]
        case .media(let title, let artist, let playing): ["MEDIA=\(playing ? "playing" : "paused")", "TITLE=\(title)", "ARTIST=\(artist)"]
        case .mediaUnavailable: ["MEDIA=unavailable"]
        case .tailscale(let kind): ["KIND=\(kind.rawValue)"]
        case .system(let cpu, let memory, let cpuStrain, let memoryStrain, let diskStrain):
            ["CPU=\(cpu)", "MEM=\(memory)", "CPU_LEVEL=\(cpuStrain.rawValue)", "MEM_LEVEL=\(memoryStrain.rawValue)",
             "DISK_LEVEL=\(diskStrain.rawValue)"]
        }
    }
}

// Watches volume, the output device, network, Tailscale, and system resources, and sends each change to the bar.
// Popups feeds it media from its media-control stream.
final class BarFeed {
    private let sketchybar: URL
    private var pushed: [String: BarState] = [:]
    private var pending: [String: BarState] = [:]
    private var pushing: Task<Void, Never>?
    private var audioListener: Audio.Listener?
    private var audioDevice: AudioObjectID?
    private var audioWatches: [(id: AudioObjectID, address: AudioObjectPropertyAddress)] = []
    private var network: (store: SCDynamicStore, source: CFRunLoopSource)?
    private var tailscale: Task<Void, Never>?
    private var systemLoop: Task<Void, Never>?
    private var sampler = SystemSampler()
    private var primaryInterface: String?
    private(set) var system: SystemSample?

    init(sketchybar: URL) { self.sketchybar = sketchybar }

    func start() {
        // Audio.listen delivers on the main queue, which the main actor runs on.
        let listener: Audio.Listener = { _, _ in MainActor.assumeIsolated { self.audioChanged() } }
        audioListener = listener
        let device = Audio.address(kAudioHardwarePropertyDefaultOutputDevice)
        if Audio.listen(Audio.system, device, listener) { audioWatches.append((Audio.system, device)) }
        network = NetworkState.watch(self)
        audioChanged()
        networkChanged()
        pollTailscale()
        sampleSystem()
        systemLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self else { return }
                self.sampleSystem()
            }
        }
    }

    // A restarted bar or a wake gets every value again, then fresh reads.
    func pushAll() {
        for state in pushed.values { publish(state, force: true) }
        audioChanged()
        networkChanged()
        pollTailscale()
    }

    func stop() {
        tailscale?.cancel()
        tailscale = nil
        systemLoop?.cancel()
        systemLoop = nil
        pushing?.cancel()
        pushing = nil
        pending.removeAll()
        if let audioListener { for watch in audioWatches { Audio.unlisten(watch.id, watch.address, audioListener) } }
        audioWatches.removeAll()
        audioListener = nil
        if let network { CFRunLoopSourceInvalidate(network.source) }
        network = nil
    }

    // Triggers run one at a time, so the bar sees changes in order. A burst sends only the latest.
    func publish(_ state: BarState, force: Bool = false) {
        guard force || pushed[state.event] != state else { return }
        pushed[state.event] = state
        pending[state.event] = state
        guard pushing == nil else { return }
        pushing = Task { [weak self] in
            while !Task.isCancelled, let self, let (event, state) = self.pending.first {
                self.pending[event] = nil
                _ = try? await ProcessCapture().run(self.sketchybar, ["--trigger", event] + state.variables)
            }
            self?.pushing = nil
        }
    }

    func networkChanged() {
        guard let state = readNetworkState(context: "bar") else { return }
        primaryInterface = (state.connections.first { $0.primary } ?? state.connections.first { $0.active })?.interface
        publish(.network(state.kind))
    }

    // Pushes only when a rounded number or a strain level changes, because publish skips equal states.
    func sampleSystem() {
        guard let sample = sampler.sample(interface: primaryInterface) else { return }
        system = sample
        publish(sample.bar)
    }

    func pollTailscale() {
        tailscale?.cancel()
        tailscale = Task { [weak self] in
            while !Task.isCancelled {
                let kind = await Tailscale.kind()
                guard !Task.isCancelled, let self else { return }
                self.publish(.tailscale(kind))
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func audioChanged() {
        let id = Audio.current
        if id != audioDevice { watch(id) }
        publish(.volume(percent: Audio.volume(id).map { Int(($0 * 100).rounded()) }, muted: Audio.muted(id)))
    }

    private func watch(_ device: AudioObjectID) {
        guard let audioListener else { return }
        for watch in audioWatches where watch.id != Audio.system { Audio.unlisten(watch.id, watch.address, audioListener) }
        audioWatches.removeAll { $0.id != Audio.system }
        audioDevice = device
        let controls = Audio.controls(device, kAudioDevicePropertyVolumeScalar) + Audio.controls(device, kAudioDevicePropertyMute)
        for address in controls where Audio.listen(device, address, audioListener) { audioWatches.append((device, address)) }
    }
}

final class Popups: NSObject, NSApplicationDelegate {
    static let notification = Notification.Name("com.bjoernaagaard.sketchybar.popup")
    let theme: Theme
    let panel = PopupPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    var lifecycle: PopupLifecycle = .closed
    var item: PopupKind? { lifecycle.target?.kind }
    var candidateTask: Task<Void, Never>?
    var candidate: PopupTarget?
    var candidateProbes: [String: Task<Void, Never>] = [:]
    var probeSources: [String: PopupSource] = [:]
    var pendingClick: NSPoint?
    var geometryGeneration = 0
    var geometryTask: Task<Void, Never>?
    var refreshTask: Task<Void, Never>?
    var mediaActionTask: Task<Void, Never>?
    var mediaActionTasks: [UUID: Task<Void, Never>] = [:]
    var suppressionPoints: [NSPoint] = []
    var openingHasAnchor = false
    var anchor = NSRect.zero
    var monitors: [Any] = []
    var timer: Timer?
    var slider: NSSlider?
    var percentage: NSTextField?
    var mute: NSButton?
    var deviceSignature = ""
    var networkState: NetworkState?
    var front: FrontSnapshot?
    var information: [String] = []
    var media: MediaSnapshot?
    var mediaError: MediaError?
    var mediaSlider: NSSlider?
    var mediaElapsed: NSTextField?
    var mediaDuration: NSTextField?
    var mediaSeeking = false
    var pendingMediaSeek: PendingMediaSeek?
    var initialCommand = PopupCommand.toggle(.volume)
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
    let bar: BarFeed
    // One media-control stream feeds the bar item and the media popup.
    var mediaStream: Task<Void, Never>?
    var streamedMedia: MediaSnapshot?
    // The system popup shows the bar's latest sample and adds GPU and top processes while open.
    var systemShown: SystemSample?
    var processes = ProcessSampler()
    var topProcesses: [ProcessLoad] = []

    init(theme: Theme) {
        self.theme = theme
        bar = BarFeed(sketchybar: URL(fileURLWithPath: theme.sketchybarPath))
        super.init()
    }

    var isOpen: Bool {
        if case .open = lifecycle { return true }
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.acceptsMouseMovedEvents = true
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged], handler: { [weak self] _ in
            self?.pointerMoved()
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged], handler: { [weak self] event in
            self?.pointerMoved()
            return event
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] _ in
            guard let self, self.isOpen || self.candidate != nil else { return }
            self.outsideClick(at: NSEvent.mouseLocation)
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] event in
            guard let self, self.lifecycle.target != nil || self.candidate != nil else { return event }
            let point = NSEvent.mouseLocation
            if !(self.isOpen && self.panel.frame.contains(point)) { self.outsideClick(at: point) }
            return event
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            if event.keyCode == 53, let self, self.lifecycle.target != nil || self.candidate != nil {
                interactionLogger.debug("event=dismiss_reason reason=escape")
                self.close()
            }
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            if event.keyCode == 53, let self, self.lifecycle.target != nil || self.candidate != nil {
                interactionLogger.debug("event=dismiss_reason reason=escape")
                self.close()
                return nil
            }
            return event
        }) { monitors.append(monitor) }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(close), name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(woke), name: NSWorkspace.didWakeNotification, object: nil)
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
                case .media: self.refreshMedia()
                case .clock:
                    if self.calendarMinute != Int(Date().timeIntervalSince1970 / 60) || self.calendarDirty { self.loadCalendar() }
                case .system: if self.bar.system != self.systemShown { self.refreshSystem() }
                case .front: self.refreshFront()
                case .battery, .workspace, .mode: self.refreshInformation()
                case nil: break
                }
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        bar.start()
        startMediaStream()
        switch initialCommand {
        case .toggle(let source): show(source)
        case .hover(let source): show(source)
        case .volumeScroll(let notches): scrollVolume(notches)
        case .geometry, .start, .hoverEnd, .stop: break
        }
    }

    // Each notch moves the volume 2 percentage points. Notifications arrive one at a time on the main
    // actor, so each notch starts from the volume the previous one wrote.
    func scrollVolume(_ notches: Int) {
        do { try Audio.change(by: 2 * notches) }
        catch { logger.error("Changing the volume failed: \(error.localizedDescription, privacy: .public)") }
    }

    @objc func woke() { bar.pushAll() }

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
                    self?.bar.publish(.mediaUnavailable)
                    return
                } catch {
                    logger.error("The media stream failed: \(error.localizedDescription, privacy: .private)")
                    self?.bar.publish(.mediaUnavailable)
                }
                // The stream ends when media-control or its system service restarts.
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func streamed(_ snapshot: MediaSnapshot?) {
        streamedMedia = snapshot
        bar.publish(.media(title: snapshot?.title ?? "", artist: snapshot?.artist ?? "", playing: snapshot?.playing ?? false))
    }

    @objc func screensChanged() {
        close()
        // notch.sh sets the notch width for the new display.
        notchTask?.cancel()
        notchTask = Task { [weak self] in await self?.trigger("notch_change") }
    }

    func applicationWillTerminate(_ notification: Notification) {
        calendarAccessTask?.cancel()
        calendarAccessTask = nil
        candidateTask?.cancel()
        candidateTask = nil
        candidate = nil
        close()
        for task in mediaActionTasks.values { task.cancel() }
        mediaActionTasks.removeAll()
        tailscaleCommand?.cancel()
        tailscaleCommand = nil
        notchTask?.cancel()
        notchTask = nil
        mediaStream?.cancel()
        mediaStream = nil
        bar.stop()
        ProcessCapture.terminateRunningChildren()
        timer?.invalidate()
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
    }

    @objc func receive(_ notification: Notification) {
        guard let command = PopupCommand(userInfo: notification.userInfo) else { return }
        switch command {
        case .hover(let source):
            interactionLogger.debug("event=received action=hover kind=\(source.kind.rawValue, privacy: .public)")
        case .toggle(let source):
            interactionLogger.debug("event=received action=toggle kind=\(source.kind.rawValue, privacy: .public)")
        case .hoverEnd(let source):
            interactionLogger.debug("event=received action=hover-end kind=\(source.kind.rawValue, privacy: .public)")
        default: break
        }
        switch command {
        case .stop: NSApp.terminate(nil)
        case .volumeScroll(let notches): scrollVolume(notches)
        case .geometry: geometryChanged()
        case .hover(let source): show(source)
        case .hoverEnd(let source):
            if lifecycle.target?.source.identity == source.identity { pointerMoved() }
            else if case .dismissed(let identity, _) = lifecycle, identity == source.identity { pointerMoved() }
        case .start: bar.pushAll()
        case .toggle(let source): show(source)
        }
    }

    func outsideClick(at point: NSPoint) {
        if openingHasAnchor && anchor.contains(point) { return }
        if candidate != nil {
            interactionLogger.debug("event=pending_click candidate=\(self.candidate?.id.uuidString ?? "none", privacy: .public)")
            pendingClick = point
        } else {
            interactionLogger.debug("event=dismiss_reason reason=outside_click kind=\(self.item?.rawValue ?? "none", privacy: .public)")
            close()
        }
    }

    func geometryChanged() {
        geometryGeneration += 1
        geometryTask?.cancel()
        geometryTask = nil
        guard let target = lifecycle.target, openingHasAnchor else { return }
        let generation = geometryGeneration
        let source: PopupSource
        switch target.source {
        case .front, .frontIcon: source = .front
        case .system, .cpu, .memory: source = .system
        case .workspace(let id, _): source = .workspace(id, "ws.\(id)")
        default: source = target.source
        }
        geometryTask = Task { [weak self] in
            guard let self else { return }
            let rect = await self.queryAnchor(source)
            guard !Task.isCancelled, self.geometryGeneration == generation,
                  self.lifecycle.target?.id == target.id else { return }
            self.geometryTask = nil
            guard let rect else { return }
            self.anchor = rect
            if self.isOpen {
                let screen = NSScreen.screens.first { $0.frame.intersects(rect) } ?? NSScreen.screens[0]
                let inset = self.theme.number("POPUP_GAP")
                let frame = self.panel.frame
                let x = max(screen.frame.minX + inset, min(rect.midX - frame.width / 2, screen.frame.maxX - inset - frame.width))
                self.panel.setFrameOrigin(NSPoint(x: x, y: rect.minY - inset - frame.height))
            }
            self.pointerMoved()
        }
    }

    func queryAnchor(_ source: PopupSource) async -> NSRect? {
        let executable = URL(fileURLWithPath: theme.sketchybarPath)
        guard let displays = try? await ProcessCapture().run(executable, ["--query", "displays"]),
              !Task.isCancelled, displays.status == 0,
              let objects = try? JSONSerialization.jsonObject(with: displays.output) as? [[String: Any]],
              let display = objects.first(where: { ($0["DirectDisplayID"] as? NSNumber)?.uint32Value == CGMainDisplayID() }),
              let index = display["arrangement-id"] as? Int, let screen = NSScreen.screens.first else { return nil }
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

    func pointerMoved() {
        let point = NSEvent.mouseLocation
        if case .dismissed(_, let bounds) = lifecycle {
            if let bounds {
                if !bounds.contains(point) { lifecycle = .closed }
            } else {
                suppressionPoints.append(point)
                if suppressionPoints.count > 4 {
                    suppressionPoints = [suppressionPoints.min(by: { $0.x < $1.x }), suppressionPoints.max(by: { $0.x < $1.x }),
                                         suppressionPoints.min(by: { $0.y < $1.y }), suppressionPoints.max(by: { $0.y < $1.y })].compactMap { $0 }
                }
            }
            return
        }
        guard lifecycle.target != nil, openingHasAnchor, geometryTask == nil else { return }
        if anchor.contains(point) { return }
        if isOpen {
            let popup = panel.frame
            if popup.contains(point) { return }
            let left = max(anchor.minX, popup.minX)
            let right = min(anchor.maxX, popup.maxX)
            if right > left {
                let corridor = NSRect(x: left, y: popup.maxY, width: right - left, height: max(0, anchor.minY - popup.maxY))
                if corridor.contains(point) { return }
            }
        }
        interactionLogger.debug("event=dismiss_reason reason=pointer_exit kind=\(self.item?.rawValue ?? "none", privacy: .public)")
        dismiss(suppress: false)
    }

    func show(_ source: PopupSource) {
        if lifecycle.target?.source.identity == source.identity {
            interactionLogger.debug("event=show_ignored reason=already_active kind=\(source.kind.rawValue, privacy: .public)")
            return
        }
        if candidate?.source.identity == source.identity {
            interactionLogger.debug("event=show_ignored reason=already_candidate kind=\(source.kind.rawValue, privacy: .public)")
            return
        }
        if case .dismissed(let identity, let bounds) = lifecycle, identity == source.identity {
            guard let bounds else {
                interactionLogger.debug("event=show_ignored reason=suppressed_pending kind=\(source.kind.rawValue, privacy: .public)")
                return
            }
            if bounds.contains(NSEvent.mouseLocation) {
                interactionLogger.debug("event=show_ignored reason=suppressed_inside kind=\(source.kind.rawValue, privacy: .public)")
                return
            }
        }
        if candidate != nil {
            guard candidateProbes[source.identity] == nil else { return }
            probeSources[source.identity] = source
            interactionLogger.debug("event=probe_start kind=\(source.kind.rawValue, privacy: .public) candidate=\(self.candidate?.id.uuidString ?? "none", privacy: .public)")
            candidateProbes[source.identity] = Task { [weak self] in
                guard let self else { return }
                var rect: NSRect?
                repeat {
                    let generation = self.geometryGeneration
                    rect = await self.queryAnchor(source)
                    guard !Task.isCancelled else {
                        interactionLogger.debug("event=probe_cancelled kind=\(source.kind.rawValue, privacy: .public) generation=\(generation)")
                        return
                    }
                    interactionLogger.debug("event=probe_anchor kind=\(source.kind.rawValue, privacy: .public) generation=\(generation) current_generation=\(self.geometryGeneration) found=\(rect != nil) contains=\(rect?.contains(NSEvent.mouseLocation) == true)")
                    if generation == self.geometryGeneration { break }
                } while true
                self.candidateProbes[source.identity] = nil
                self.probeSources[source.identity] = nil
                guard let rect, rect.contains(NSEvent.mouseLocation) else {
                    interactionLogger.debug("event=probe_rejected kind=\(source.kind.rawValue, privacy: .public) reason=anchor_or_pointer")
                    return
                }
                interactionLogger.debug("event=probe_accepted kind=\(source.kind.rawValue, privacy: .public) replaced_candidate=\(self.candidate?.id.uuidString ?? "none", privacy: .public)")
                self.candidateTask?.cancel()
                self.candidateTask = nil
                self.candidate = nil
                self.pendingClick = nil
                self.show(source)
            }
            return
        }
        if case .dismissed(_, nil) = lifecycle { lifecycle = .closed; suppressionPoints.removeAll() }
        let target = PopupTarget(id: UUID(), source: source)
        candidate = target
        interactionLogger.debug("event=candidate_start kind=\(source.kind.rawValue, privacy: .public) id=\(target.id.uuidString, privacy: .public) generation=\(self.geometryGeneration)")
        let next = source.kind
        candidateTask = Task { [weak self] in
            guard let self else { return }
            var rect: NSRect?
            repeat {
                let generation = self.geometryGeneration
                rect = await self.queryAnchor(source)
                guard !Task.isCancelled, self.candidate?.id == target.id else {
                    interactionLogger.debug("event=candidate_cancelled kind=\(next.rawValue, privacy: .public) id=\(target.id.uuidString, privacy: .public) cancelled=\(Task.isCancelled) current=\(self.candidate?.id == target.id)")
                    return
                }
                interactionLogger.debug("event=candidate_anchor kind=\(next.rawValue, privacy: .public) id=\(target.id.uuidString, privacy: .public) generation=\(generation) current_generation=\(self.geometryGeneration) found=\(rect != nil) contains=\(rect?.contains(NSEvent.mouseLocation) == true)")
                if generation == self.geometryGeneration { break }
            } while true
            if let point = self.pendingClick {
                self.pendingClick = nil
                if rect?.contains(point) != true { self.close() }
            }
            self.candidate = nil
            self.candidateTask = nil
            if case .dismissed(let identity, nil) = self.lifecycle, identity == source.identity {
                interactionLogger.debug("event=candidate_rejected kind=\(next.rawValue, privacy: .public) id=\(target.id.uuidString, privacy: .public) reason=suppressed")
                let exited = rect.map { bounds in self.suppressionPoints.contains { !bounds.contains($0) } } ?? true
                self.suppressionPoints.removeAll()
                if let rect, !exited, rect.contains(NSEvent.mouseLocation) {
                    self.lifecycle = .dismissed(identity, rect)
                } else {
                    self.lifecycle = .closed
                    if let rect, exited, rect.contains(NSEvent.mouseLocation) { self.show(source) }
                }
                return
            }
            guard let rect, rect.contains(NSEvent.mouseLocation) else {
                interactionLogger.debug("event=candidate_rejected kind=\(next.rawValue, privacy: .public) id=\(target.id.uuidString, privacy: .public) reason=anchor_or_pointer")
                if let source = self.probeSources.values.first {
                    self.candidateProbes[source.identity]?.cancel()
                    self.candidateProbes[source.identity] = nil
                    self.probeSources[source.identity] = nil
                    self.show(source)
                }
                return
            }
            interactionLogger.debug("event=candidate_accepted kind=\(next.rawValue, privacy: .public) id=\(target.id.uuidString, privacy: .public)")
            self.dismiss(suppress: false)
            self.lifecycle = .opening(target)
            self.anchor = rect
            self.openingHasAnchor = true
            switch next {
            case .volume: self.buildVolume()
            case .network:
                self.networkState = readNetworkState(context: "opening")
                self.buildNetwork()
            case .tailscale:
                self.tailscale = nil
                self.buildTailscale()
            case .media:
                self.media = self.streamedMedia
                self.mediaError = nil
                self.buildMedia()
            case .clock:
                self.events = []
                self.calendarError = nil
                self.buildCalendar()
            case .system:
                if self.bar.system == nil { self.bar.sampleSystem() }
                self.processes = ProcessSampler()
                self.topProcesses = self.processes.sample(count: 3) ?? []
                self.buildSystem()
            case .front:
                self.front = nil
                self.buildFront()
            case .battery, .workspace, .mode:
                self.information = ["Loading"]
                self.buildInformation()
            }
            guard !Task.isCancelled, self.lifecycle.target?.id == target.id else {
                interactionLogger.debug("event=panel_cancelled kind=\(next.rawValue, privacy: .public) id=\(target.id.uuidString, privacy: .public)")
                return
            }
            self.lifecycle = .open(target)
            self.panel.makeKeyAndOrderFront(nil)
            interactionLogger.debug("event=panel_ordered kind=\(next.rawValue, privacy: .public) id=\(target.id.uuidString, privacy: .public) panel=popup")
            if next == .volume { self.panel.makeFirstResponder(self.slider) }
            if next == .clock { self.loadCalendar() }
            if next == .tailscale { self.refreshTailscale() }
            if next == .media { self.refreshMedia() }
            if next == .front { self.refreshFront() }
            if next == .battery || next == .workspace || next == .mode { self.refreshInformation() }
            self.pointerMoved()
        }
    }

    @objc func close() { dismiss(suppress: true) }

    func dismiss(suppress: Bool) {
        let target = suppress ? (candidate ?? lifecycle.target) : lifecycle.target
        if let target {
            interactionLogger.debug("event=dismiss kind=\(target.kind.rawValue, privacy: .public) id=\(target.id.uuidString, privacy: .public) reason=\(suppress ? "close" : "replacement_or_pointer_exit", privacy: .public) candidate=\(self.candidate?.id.uuidString ?? "none", privacy: .public)")
        }
        let bounds: NSRect? = candidate != nil && suppress ? nil : (openingHasAnchor ? anchor : nil)
        openingHasAnchor = false
        geometryTask?.cancel()
        geometryTask = nil
        for task in candidateProbes.values { task.cancel() }
        candidateProbes.removeAll()
        probeSources.removeAll()
        pendingClick = nil
        refreshTask?.cancel()
        refreshTask = nil
        if suppress, let target {
            suppressionPoints = bounds == nil ? [NSEvent.mouseLocation] : []
            lifecycle = .dismissed(target.source.identity, bounds)
        } else {
            suppressionPoints.removeAll()
            lifecycle = .closed
        }
        mediaSeeking = false
        pendingMediaSeek = nil
        panel.orderOut(nil)
    }

    func surface(height: CGFloat) -> NSView {
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
            } catch {
                guard !Task.isCancelled, self.item == .media, self.isOpen else { return }
                self.pendingMediaSeek = nil
                NSAlert(error: error).beginSheetModal(for: self.panel, completionHandler: nil)
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
            } catch {
                guard !Task.isCancelled, self.item == .media, self.isOpen else { return }
                NSAlert(error: error).beginSheetModal(for: self.panel, completionHandler: nil)
            }
        }
        mediaActionTask = task
        mediaActionTasks[id] = task
    }

    func trigger(_ event: String) async {
        _ = try? await ProcessCapture().run(URL(fileURLWithPath: theme.sketchybarPath), ["--trigger", event])
    }

    func readFront() async -> FrontSnapshot? {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
        guard let path = paths.map({ "\($0)/aerospace" }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }),
              let result = try? await ProcessCapture().run(URL(fileURLWithPath: path),
                  ["list-windows", "--focused", "--json", "--format", "%{app-name} %{window-title}"]),
              !Task.isCancelled, result.status == 0,
              let windows = try? JSONDecoder().decode([FrontSnapshot].self, from: result.output) else { return nil }
        return windows.first
    }

    func refreshFront() {
        guard let target = lifecycle.target, target.kind == .front, isOpen, refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            guard let self else { return }
            let next = await self.readFront()
            guard !Task.isCancelled, self.lifecycle.target?.id == target.id, self.isOpen else { return }
            self.refreshTask = nil
            if self.front != next { self.front = next; self.buildFront() }
        }
    }

    func buildFront() {
        let pad = theme.number("POPUP_PADDING")
        let width = theme.number("POPUP_WIDTH")
        let row = theme.number("POPUP_ROW")
        let view = surface(height: pad * 2 + row * 3)
        label("Front app", x: pad, y: pad, width: width - pad * 2, in: view)
        let name = front?.appName.flatMap { $0.isEmpty ? nil : $0 } ?? "Unavailable"
        let title = front?.windowTitle.flatMap { $0.isEmpty ? nil : $0 } ?? "Window unavailable"
        label(name, x: pad, y: pad + row, width: width - pad * 2, in: view)
        label(title, x: pad, y: pad + row * 2, width: width - pad * 2, color: "TEXT2", in: view)
    }

    func refreshInformation() {
        guard let target = lifecycle.target, isOpen, refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            guard let self else { return }
            let next = await self.readInformation(target.source)
            guard !Task.isCancelled, self.lifecycle.target?.id == target.id, self.isOpen else { return }
            self.refreshTask = nil
            if target.kind == .mode, next == nil { self.dismiss(suppress: false); return }
            let lines = next ?? ["Unavailable"]
            if self.information != lines { self.information = lines; self.buildInformation() }
        }
    }

    func readInformation(_ source: PopupSource) async -> [String]? {
        let capture = ProcessCapture()
        if source.kind == .battery {
            guard let result = try? await capture.run(URL(fileURLWithPath: "/usr/bin/pmset"), ["-g", "batt"]),
                  !Task.isCancelled, result.status == 0 else { return nil }
            let output = String(decoding: result.output, as: UTF8.self)
            let lines = output.components(separatedBy: .newlines)
            var values: [String] = []
            if let first = lines.first {
                if first.contains("AC Power") { values.append("AC Power") }
                else if first.contains("Battery Power") { values.append("Battery Power") }
            }
            let pattern = try? NSRegularExpression(pattern: "([0-9]+)%|([0-9]+:[0-9]{2}) remaining")
            let range = NSRange(output.startIndex..., in: output)
            for match in pattern?.matches(in: output, range: range) ?? [] {
                if let r = Range(match.range, in: output) { values.append(String(output[r])) }
            }
            return values.isEmpty ? nil : values
        }
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
        guard let path = paths.map({ "\($0)/aerospace" }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        let executable = URL(fileURLWithPath: path)
        if case .workspace(let id, _) = source {
            guard let result = try? await capture.run(executable, ["list-windows", "--workspace", id, "--json", "--format", "%{app-name}"]),
                  !Task.isCancelled, result.status == 0,
                  let windows = try? JSONSerialization.jsonObject(with: result.output) as? [[String: Any]] else { return nil }
            var counts: [String: Int] = [:]
            for window in windows {
                let name = (window["app-name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Unknown app"
                counts[name, default: 0] += 1
            }
            if counts.isEmpty { return ["No windows"] }
            return counts.keys.sorted().map { "\($0)  \(counts[$0] ?? 0)" }
        }
        if source.kind == .mode {
            guard let current = try? await capture.run(executable, ["list-modes", "--current"]),
                  !Task.isCancelled, current.status == 0 else { return ["Unavailable"] }
            let mode = String(decoding: current.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !mode.isEmpty, mode != "main" else { return nil }
            guard mode.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }),
                  let result = try? await ProcessCapture().run(executable, ["config", "--get", "mode.\(mode).binding", "--json"]),
                  !Task.isCancelled, result.status == 0,
                  let bindings = try? JSONSerialization.jsonObject(with: result.output) as? [String: String] else { return [mode, "Unavailable"] }
            let safeActions: Set<String> = ["mode main", "resize width -50", "resize width +50", "resize height -50",
                                            "resize height +50", "balance-sizes", "flatten-workspace-tree",
                                            "close-all-windows-but-current", "join-with left", "join-with right",
                                            "join-with up", "join-with down"]
            return [mode] + bindings.keys.sorted().map { key in
                let action = bindings[key] ?? ""
                let commands = action.components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespaces) }
                return commands.allSatisfy { safeActions.contains($0) } ? "\(key)  \(action)" : key
            }
        }
        return nil
    }

    func buildInformation() {
        guard let source = lifecycle.target?.source else { return }
        let title: String
        switch source {
        case .battery: title = "Battery"
        case .workspace(let id, _): title = "Workspace \(id)"
        case .mode: title = "Mode"
        default: return
        }
        let pad = theme.number("POPUP_PADDING")
        let width = theme.number("POPUP_WIDTH")
        let row = theme.number("POPUP_ROW")
        let view = surface(height: pad * 2 + row * CGFloat(1 + information.count))
        label(title, x: pad, y: pad, width: width - pad * 2, in: view)
        for (index, line) in information.enumerated() {
            label(line, x: pad, y: pad + row * CGFloat(index + 1), width: width - pad * 2, color: "TEXT2", in: view)
        }
    }

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
        let width = theme.number("POPUP_WIDTH")
        let row = theme.number("POPUP_ROW")
        let clusters = sample?.clusters ?? []
        // Three process rows always, so the panel keeps its height between refreshes.
        let rows = CGFloat(15 + clusters.count + 3)
        let meterHeight: CGFloat = 8, legendHeight: CGFloat = 24
        let view = surface(height: pad * 2 + row * rows + meterHeight * 2 + legendHeight)
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

    @objc nonisolated func calendarChanged() {
        // EventKit can post from another thread. Only the UI update crosses actors.
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.calendarDirty = true
            if self.isOpen && self.item == .clock { self.loadCalendar() }
        }
    }

    @objc func requestCalendarAccess() {
        guard !calendarBusy, EKEventStore.authorizationStatus(for: .event) == .notDetermined else { return }
        calendarBusy = true
        buildCalendar()
        // A permission request belongs to the app, not the currently open popup.
        calendarAccessTask = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.eventStore.requestFullAccessToEvents()
                guard !Task.isCancelled else { return }
                self.calendarError = nil
            } catch {
                guard !Task.isCancelled else { return }
                self.calendarError = error
            }
            self.calendarBusy = false
            self.calendarAccessTask = nil
            // The user may have switched or closed popups while permission was pending.
            self.calendarDirty = true
            if self.item == .clock && self.isOpen { self.loadCalendar() }
        }
    }

    func loadCalendar() {
        guard !calendarBusy else { return }
        let authorization = EKEventStore.authorizationStatus(for: .event)
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
            let canRequest = EKEventStore.authorizationStatus(for: .event) == .notDetermined
            let button = NSButton(title: canRequest ? "Allow calendar access" : "Calendar", target: self,
                                  action: canRequest ? #selector(requestCalendarAccess) : #selector(openCalendarPrivacy))
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
if arguments.count > 2 && arguments[1] == "volume-scroll" {
    // Concurrent launches would overwrite each other's volume, so the resident helper applies every notch.
    guard let command = PopupCommand(arguments[1], argument: arguments[2]) else {
        logger.error("Invalid scroll delta: \(arguments[2], privacy: .public)")
        exit(EXIT_FAILURE)
    }
    command.post()
} else if arguments.count > 1 && arguments[1] == "mute-toggle" {
    do { try Audio.setMuted(!Audio.muted(Audio.current)) }
    catch { logger.error("Toggling mute failed: \(error.localizedDescription, privacy: .public)"); exit(EXIT_FAILURE) }
} else if arguments.count > 1 && arguments[1] == "notch" {
    // notch.sh reads this. null means the bar's display has no camera housing.
    let size = Notch.main.map { ["width": Int($0.width.rounded()), "height": Int($0.height.rounded())] }
    let data = try JSONEncoder().encode(size)
    print(String(decoding: data, as: UTF8.self))
} else if arguments.count > 2 && arguments[1] == "media" {
    guard let action = MediaAction(rawValue: arguments[2]) else {
        logger.error("Unknown media command: \(arguments[2])")
        exit(EXIT_FAILURE)
    }
    runCLI { try await Media.perform(action) }
} else if arguments.count > 1 && arguments[1] == PopupCommand.geometry.rawValue {
    PopupCommand.geometry.post()
} else if arguments.count > 1 && arguments[1] == PopupCommand.stop.rawValue {
    PopupCommand.stop.post()
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
    guard let command = PopupCommand(raw, argument: arguments.count > 2 ? arguments[2] : nil) else {
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
        command.post()
        exit(0)
    }
    app.delegate = delegate
    app.run()
}
