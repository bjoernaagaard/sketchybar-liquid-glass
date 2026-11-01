import AppKit

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

enum MediaAction: String, CaseIterable {
    case playPause = "play-pause", next, previous

    // The bar controls call popup.sh with these names. They cross the shell boundary only here.
    var command: String {
        switch self {
        case .playPause: "media-toggle"
        case .next: "media-next"
        case .previous: "media-previous"
        }
    }

    init?(command: String) {
        guard let action = Self.allCases.first(where: { $0.command == command }) else { return nil }
        self = action
    }

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

// What the media item shows, before it is fitted to the island.
enum MediaDisplay: Equatable {
    case unavailable
    case track(title: String, artist: String, playing: Bool)

    init(_ snapshot: MediaSnapshot?) {
        self = .track(title: snapshot?.title ?? "", artist: snapshot?.artist ?? "", playing: snapshot?.playing ?? false)
    }

    var text: String {
        switch self {
        case .unavailable: "Media unavailable"
        case .track(let title, let artist, _): title.isEmpty ? "Not playing" : artist.isEmpty ? title : "\(title) · \(artist)"
        }
    }

    func state(_ fit: MediaFit) -> BarState {
        switch self {
        case .unavailable: .mediaUnavailable(label: fit.label, width: fit.width)
        case .track(_, _, let playing): .media(label: fit.label, width: fit.width, playing: playing)
        }
    }
}

// Measured positions, in points. None of them depends on the media item's own width: SketchyBar
// keeps q positions in unsigned integers, so an item wider than the space left of the notch wraps
// to the far end of the bar, and a fit based on its position could never shrink it back.
struct MediaLayout {
    let leftEdge: Double       // half.left right edge
    let rightEdge: Double      // where the media item must end: the left edge of media.prev, the control nearest it
    let islandEnd: Double      // island.media.end right edge, which SketchyBar pins at notch.gap
    let startWidth: Double     // island.media.start, the island's padding before the media item
    let reserved: Double       // icon padding, glyph, and label padding: what the title cannot use

    // The island runs from the gap after the left island to its pinned end, once the fit has settled.
    func islandWidth(gap: Double) -> Double { islandEnd - (leftEdge + gap) }
}

// The media item's width and title. The island's right edge is pinned by SketchyBar, so the item
// fills the space from the left island plus the gap, and the title shortens to fit.
struct MediaFit: Equatable {
    let width: Int
    let label: String

    init(text: String, layout: MediaLayout, gap: Double, font: NSFont) {
        let fitted = layout.rightEdge - (layout.leftEdge + gap + layout.startWidth)
        width = max(Int(layout.reserved.rounded(.up)), Int(fitted.rounded(.down)))
        let available = Double(width) - layout.reserved
        func measure(_ string: String) -> Double { Double((string as NSString).size(withAttributes: [.font: font]).width.rounded(.up)) }
        guard measure(text) > available else { label = text; return }
        // Largest prefix whose width, with an ellipsis, fits. Width grows with the prefix.
        let characters = Array(text)
        func candidate(_ count: Int) -> String {
            String(characters.prefix(count)).trimmingCharacters(in: .whitespaces) + "…"
        }
        var low = 0, high = characters.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if measure(candidate(middle)) <= available { low = middle } else { high = middle - 1 }
        }
        label = measure(candidate(low)) <= available ? candidate(low) : ""
    }
}

// A media-control stream line. `--no-diff` sends the whole snapshot each time.
struct MediaStreamEvent: Decodable {
    let payload: MediaSnapshot?
}
