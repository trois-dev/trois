// Draws a Kaleidoscope window frame around a tracked window in overlay mode.
import Cocoa
import ApplicationServices

/// The frame from the applied theme, if it has one and borders are on.
enum WindowFrameStore {
    private static var cachedPath: String?
    private static var cached: WindowFrame?

    static var current: WindowFrame? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "windowBorders") as? Bool ?? true,
              let path = defaults.string(forKey: "windowFrameDirectory") else { return nil }
        if path != cachedPath {
            cachedPath = path
            cached = WindowFrame(directory: URL(fileURLWithPath: path, isDirectory: true))
        }
        return cached
    }
}

/// What a border needs to know about its window, from an AX read.
struct BorderTarget {
    let window: AXUIElement
    let title: String?
    let close: AXUIElement?
    let minimize: AXUIElement?
    let zoom: AXUIElement?

    /// Widgets the frame draws and makes clickable. With frame buttons off
    /// the buttons stay at the traffic lights, and the frame draws the
    /// scheme's art for a window without them.
    var widgets: Set<WindowFrame.Widget> {
        guard UserDefaults.standard.bool(forKey: "frameButtons") else { return [] }
        var set: Set<WindowFrame.Widget> = []
        if close != nil { set.insert(.close) }
        if zoom != nil { set.insert(.zoom) }
        if minimize != nil { set.insert(.collapse) }
        return set
    }
}

// Sits above the target like the button overlays, so windows in front of the
// target clip it. Its event shape leaves out the window's own area and
// whatever covers the frame, so clicks there reach the windows below; a
// transparent pixel alone does not pass a click through. Inside the shape,
// widgets press the window's buttons and the rest drags the window.
// Widgets are only drawn when the frameButtons setting is on.
final class BorderWindow: NSWindow {
    private let frameView = NSView()
    // AppKit owns the view's own layer contents, so the image goes on a sublayer.
    private let imageLayer = CALayer()
    private var windowFrame: WindowFrame
    private var target: BorderTarget?
    private var pid: pid_t = 0
    // Target frame in global top-left coordinates.
    private var targetFrame: CGRect = .zero
    private var isActive = false
    private var pressedWidget: WindowFrame.Widget?
    private var trackingWidget: WindowFrame.Widget?
    private var layout: WindowFrame.Layout?
    // Called when the drawn shape changes.
    var shapeChanged: (() -> Void)?

    /// Where the border draws, in top-left coordinates of the border window.
    var shape: [CGRect] { layout?.shape ?? [] }
    private var layoutWidgets: Set<WindowFrame.Widget>?
    // Covered parts currently masked out, in view coordinates.
    private var clipRects: [CGRect]? = []
    // Drag state: mouse and target origin at mouse down, both global top-left.
    private var dragStart: (mouse: CGPoint, origin: CGPoint)?
    private var pendingPosition: CGPoint?
    private var isSettingPosition = false
    // Set after a window-server move AppKit didn't see.
    private var appKitStale = false
    // Smallest corner rounding of standard windows; toolbar windows round
    // more, so a sliver of their corners may still show through.
    private static let cornerRadius: CGFloat = {
        if #available(macOS 26, *) { return 16 }
        return 10
    }()

    init(frame windowFrame: WindowFrame) {
        self.windowFrame = windowFrame
        super.init(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        level = .floating
        isReleasedWhenClosed = false
        animationBehavior = .none
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .stationary]
        // Until an event shape is set, clicks must fall through.
        ignoresMouseEvents = true
        frameView.wantsLayer = true
        imageLayer.magnificationFilter = .nearest
        imageLayer.minificationFilter = .nearest
        imageLayer.anchorPoint = .zero
        frameView.layer?.addSublayer(imageLayer)
        contentView = frameView
    }

    /// Frame inset around a target, in global top-left coordinates.
    var outerFrame: CGRect {
        let i = windowFrame.insets
        return CGRect(x: targetFrame.minX - i.left, y: targetFrame.minY - i.top,
                      width: targetFrame.width + i.left + i.right, height: targetFrame.height + i.top + i.bottom)
    }

    func setFrame(_ frame: WindowFrame) {
        guard frame.directory != windowFrame.directory else { return }
        windowFrame = frame
        clipRects = nil
        redraw()
        place()
    }

    /// Places and redraws the border for a fresh AX read.
    func update(target: BorderTarget, pid: pid_t, frame: CGRect) {
        let resized = frame.size != targetFrame.size
        // Widgets also change when the frameButtons setting does.
        let retitled = target.title != self.target?.title || target.widgets != layoutWidgets
        self.target = target
        self.pid = pid
        targetFrame = frame
        if resized || retitled || layout == nil {
            redraw()
        }
        place()
        orderFront(nil)
    }

    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        redraw()
    }

    /// Window-server origin (global top-left) for a target at `origin`.
    func origin(following origin: CGPoint) -> CGPoint {
        let i = windowFrame.insets
        return CGPoint(x: origin.x - i.left, y: origin.y - i.top)
    }

    /// Records a move the window server already applied.
    func didMoveOnServer(targetOrigin: CGPoint) {
        targetFrame.origin = targetOrigin
        appKitStale = true
    }

    /// AppKit fallback when SkyLight transactions are unavailable.
    func move(targetOrigin: CGPoint) {
        targetFrame.origin = targetOrigin
        place()
    }

    func syncAppKitFrame() {
        guard appKitStale else { return }
        place()
    }

    private func place() {
        appKitStale = false
        guard let primary = NSScreen.screens.first else { return }
        let outer = outerFrame
        // Global top-left to AppKit bottom-left.
        setFrame(NSRect(x: outer.minX, y: primary.frame.height - outer.maxY,
                        width: outer.width, height: outer.height), display: false)
        updateEventShape()
    }

    private func redraw() {
        guard targetFrame.width > 0, targetFrame.height > 0 else { return }
        let scale = screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        guard let (image, layout) = windowFrame.render(
            windowSize: targetFrame.size, active: isActive, widgets: target?.widgets ?? [],
            title: target?.title, pressedWidget: pressedWidget,
            cornerRadius: Self.cornerRadius, scale: scale
        ) else { return }
        let oldShape = self.layout?.shape
        self.layout = layout
        layoutWidgets = target?.widgets
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = image
        imageLayer.contentsScale = scale
        imageLayer.frame = CGRect(origin: .zero, size: layout.size)
        CATransaction.commit()
        if frame.size != layout.size {
            clipRects = nil
            place()
        } else if oldShape != layout.shape {
            updateEventShape()
        }
        if oldShape != layout.shape {
            shapeChanged?()
        }
    }

    /// Masks out the parts covered by `covers` (global top-left frames).
    func clip(covering covers: [CGRect]) {
        let outer = outerFrame
        let bounds = CGRect(origin: .zero, size: outer.size)
        let covered: [CGRect] = covers.compactMap { cover in
            let part = cover.intersection(outer)
            guard !part.isNull, !part.isEmpty else { return nil }
            return CGRect(x: part.minX - outer.minX, y: outer.maxY - part.maxY, width: part.width, height: part.height)
        }
        guard covered != clipRects else { return }
        let layer = imageLayer
        clipRects = covered
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if covered.isEmpty {
            layer.mask = nil
        } else {
            let mask = CAShapeLayer()
            mask.frame = bounds
            mask.path = visiblePath(bounds, minus: covered)
            layer.mask = mask
        }
        CATransaction.commit()
        updateEventShape()
    }

    private func updateEventShape() {
        let outer = outerFrame
        let bounds = CGRect(origin: .zero, size: outer.size)
        let i = windowFrame.insets
        let hole = CGRect(x: i.left, y: i.top, width: targetFrame.width, height: targetFrame.height)
        // Clip rects are bottom-left; the event shape is top-left.
        let covered = (clipRects ?? []).map { CGRect(x: $0.minX, y: bounds.height - $0.maxY, width: $0.width, height: $0.height) }
        if covered.contains(where: { $0.contains(bounds) }) {
            ignoresMouseEvents = true
            return
        }
        // Only drawn parts take clicks; transparent ones pass them through.
        let drawn = shape
        guard !drawn.isEmpty else {
            ignoresMouseEvents = true
            return
        }
        // Toggling ignoresMouseEvents can reset the shape, so it goes first.
        // Without a shape the whole window would take clicks, so it takes none.
        ignoresMouseEvents = false
        if !WindowServer.setEventShape(of: CGWindowID(windowNumber), include: drawn, exclude: [hole] + covered) {
            ignoresMouseEvents = true
        }
    }

    // MARK: - Mouse

    /// Event location in layout coordinates (top-left origin).
    private func layoutPoint(_ event: NSEvent) -> CGPoint {
        let p = event.locationInWindow
        return CGPoint(x: p.x, y: frame.height - p.y)
    }

    private func widget(at point: CGPoint) -> WindowFrame.Widget? {
        layout?.widgets.first { $0.value.contains(point) }?.key
    }

    private static func mouseLocation() -> CGPoint {
        let m = NSEvent.mouseLocation
        let height = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: m.x, y: height - m.y)
    }

    override func mouseDown(with event: NSEvent) {
        raiseTarget()
        if let widget = widget(at: layoutPoint(event)) {
            trackingWidget = widget
            setPressed(widget)
        } else if event.clickCount == 2 {
            // Double-clicking a title bar zooms, as on the Mac.
            press(.zoom)
        } else {
            dragStart = (Self.mouseLocation(), targetFrame.origin)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if let trackingWidget {
            let inside = widget(at: layoutPoint(event)) == trackingWidget
            setPressed(inside ? trackingWidget : nil)
            return
        }
        guard let dragStart else { return }
        let mouse = Self.mouseLocation()
        setTargetPosition(CGPoint(x: dragStart.origin.x + mouse.x - dragStart.mouse.x,
                                  y: dragStart.origin.y + mouse.y - dragStart.mouse.y))
    }

    override func mouseUp(with event: NSEvent) {
        if let trackingWidget, pressedWidget == trackingWidget {
            press(trackingWidget)
        }
        trackingWidget = nil
        dragStart = nil
        setPressed(nil)
    }

    private func setPressed(_ widget: WindowFrame.Widget?) {
        guard widget != pressedWidget else { return }
        pressedWidget = widget
        redraw()
    }

    private func press(_ widget: WindowFrame.Widget) {
        let element: AXUIElement?
        switch widget {
        case .close: element = target?.close
        case .zoom: element = target?.zoom
        case .collapse: element = target?.minimize
        }
        guard let element else { return }
        AXQueue.async {
            AXUIElementPerformAction(element, kAXPressAction as CFString)
        }
    }

    private func raiseTarget() {
        guard let window = target?.window else { return }
        NSRunningApplication(processIdentifier: pid)?.activate()
        AXQueue.async {
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }
    }

    // Moves the target through AX. Positions requested while one is being set
    // collapse into the latest.
    private func setTargetPosition(_ position: CGPoint) {
        guard let window = target?.window else { return }
        guard !isSettingPosition else {
            pendingPosition = position
            return
        }
        isSettingPosition = true
        AXQueue.async { [weak self] in
            var point = position
            if let value = AXValueCreate(.cgPoint, &point) {
                AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isSettingPosition = false
                if let next = self.pendingPosition {
                    self.pendingPosition = nil
                    self.setTargetPosition(next)
                }
            }
        }
    }
}
