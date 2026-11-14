import AppKit

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
        guard let url = executableOnPath("tailscale") else { throw .missingCLI }
        return url
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
