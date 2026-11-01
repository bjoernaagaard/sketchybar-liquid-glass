import AppKit

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
