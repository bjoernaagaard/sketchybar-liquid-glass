// Before feature work, read ../../AGENTS.md and ~/.agents/skills/write-swift/SKILL.md.

import AppKit

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
} else if arguments.count > 1 && arguments[1] == PopupCommand.geometry.rawValue {
    PopupCommand.geometry.post()
} else if arguments.count > 2 && arguments[1] == "workspace-update" {
    guard let command = PopupCommand(arguments[1], argument: arguments[2]) else { exit(EXIT_FAILURE) }
    command.post()
} else if arguments.count > 1 && arguments[1] == PopupCommand.stop.rawValue {
    PopupCommand.stop.post()
    // sketchybarrc starts a helper right after this. Wait up to 2 s for the running one to
    // release its lock, so that command is not handed to a process that is exiting.
    guard let source = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("popup/main.swift") else { exit(EXIT_FAILURE) }
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
    delegate.lock = open(delegate.theme.configDirectory + "/plugins/popup/main.swift", O_RDONLY)
    guard delegate.lock >= 0 else {
        logger.error("Opening the helper lock failed: \(String(cString: strerror(errno)), privacy: .public)")
        exit(EXIT_FAILURE)
    }
    if flock(delegate.lock, LOCK_EX | LOCK_NB) != 0 {
        command.post()
        exit(0)
    }
    app.delegate = delegate
    app.run()
}
