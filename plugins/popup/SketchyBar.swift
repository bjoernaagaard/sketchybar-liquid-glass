import AppKit
import CoreAudio
import SystemConfiguration

// One item as `sketchybar --query <item>` reports it.
struct ItemQuery: Decodable {
    struct Text: Decodable {
        let value: String
        let paddingLeft: Double
        let paddingRight: Double

        enum CodingKeys: String, CodingKey {
            case value, paddingLeft = "padding_left", paddingRight = "padding_right"
        }
    }

    struct Bounds: Decodable {
        let origin: [Double]
        let size: [Double]
    }

    let name: String
    let icon: Text?
    let label: Text?
    let boundingRects: [String: Bounds]

    enum CodingKeys: String, CodingKey {
        case name, icon, label, boundingRects = "bounding_rects"
    }

    // `sketchybar --query a --query b` prints one JSON object per item, back to back. This splits the output
    // at its top-level braces, skipping braces inside strings, and decodes each object. An item that cannot be
    // read is missing from the result, so callers match by `name`, not by position.
    static func decodeAll(_ data: Data) -> [ItemQuery] {
        var queries: [ItemQuery] = []
        var depth = 0, start = data.startIndex
        var inString = false, escaped = false
        for index in data.indices {
            let byte = data[index]
            if inString {
                if escaped { escaped = false }
                else if byte == UInt8(ascii: "\\") { escaped = true }
                else if byte == UInt8(ascii: "\"") { inString = false }
                continue
            }
            switch byte {
            case UInt8(ascii: "\""): inString = true
            case UInt8(ascii: "{"):
                if depth == 0 { start = index }
                depth += 1
            case UInt8(ascii: "}") where depth > 0:
                depth -= 1
                if depth == 0, let query = try? JSONDecoder().decode(ItemQuery.self, from: data[start...index]) { queries.append(query) }
            default: break
            }
        }
        return queries
    }

    // SketchyBar measures from the top left of the display. Only x and the width matter here.
    func bounds(display index: Int) -> (minX: Double, width: Double)? {
        guard let rect = boundingRects["display-\(index)"], rect.origin.count == 2, rect.size.count == 2,
              rect.size[0] > 0 else { return nil }
        return (rect.origin[0], rect.size[0])
    }

    // The rectangle in AppKit screen coordinates, whose origin is the bottom left of the screen.
    func frame(display index: Int, on screen: NSScreen) -> NSRect? {
        guard let rect = boundingRects["display-\(index)"], rect.origin.count == 2, rect.size.count == 2,
              rect.size[0] > 0, rect.size[1] > 0 else { return nil }
        return NSRect(x: screen.frame.minX + rect.origin[0], y: screen.frame.maxY - rect.origin[1] - rect.size[1],
                      width: rect.size[0], height: rect.size[1])
    }
}

// What a bar item shows. Strings exist only in `variables`, at the sketchybar trigger boundary.
enum BarState: Equatable {
    case volume(percent: Int?, muted: Bool)
    case network(NetworkKind)
    case media(label: String, width: Int, playing: Bool)
    case mediaUnavailable(label: String, width: Int)
    case mediaProgress(Int)
    case tailscale(TailscaleKind)
    case system(cpu: Int, memory: Int, cpuStrain: Strain, memoryStrain: Strain, diskStrain: Strain)

    // Each item subscribes to its own event in sketchybarrc, and status.sh reads the variables.
    var event: String {
        switch self {
        case .volume: "volume_state"
        case .network: "network_state"
        case .media, .mediaUnavailable: "media_state"
        case .mediaProgress: "media_progress"
        case .tailscale: "tailscale_state"
        case .system: "system_state"
        }
    }

    var variables: [String] {
        switch self {
        case .volume(let percent, let muted): ["VOLUME=\(percent.map(String.init) ?? "fixed")", "MUTED=\(muted)"]
        case .network(let kind): ["KIND=\(kind.rawValue)"]
        case .media(let label, let width, let playing): ["MEDIA=\(playing ? "playing" : "paused")", "LABEL=\(label)", "WIDTH=\(width)"]
        case .mediaUnavailable(let label, let width): ["MEDIA=unavailable", "LABEL=\(label)", "WIDTH=\(width)"]
        case .mediaProgress(let width): ["WIDTH=\(width)"]
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
