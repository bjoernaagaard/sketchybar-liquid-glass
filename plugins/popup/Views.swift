import AppKit
import CoreAudio

final class ValueButton: NSButton {
    var value = ""
}

final class PopupPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class OutputButton: NSButton {
    var device: AudioObjectID = 0
}
