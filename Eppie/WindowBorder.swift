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

    /// Rereads the frame on next use. A folder's contents can change under
    /// the same path, as the Custom tab's draft does.
    static func invalidate() {
        cachedPath = nil
        cached = nil
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

// A raw window-server window at its target's level, ordered directly below the
// target, so whatever covers the target covers the frame too. AppKit windows
// can't be ordered against another app's window, so this isn't an NSWindow.
// Clicks still arrive through AppKit: the window server sends them to our main
// connection tagged with this window's number, and a local monitor routes them
// here. The event shape leaves out the window's own area and transparent parts
// of the art, so clicks there reach the windows below. Inside it, widgets
// press the window's buttons and the rest drags the window.
// Widgets are only drawn when the frameButtons setting is on.
final class BorderWindow {
    let windowNumber: CGWindowID
    private let targetWID: CGWindowID
    private var windowFrame: WindowFrame
    private var target: BorderTarget?
    private var pid: pid_t = 0
    // Target frame in global top-left coordinates.
    private var targetFrame: CGRect = .zero
    private var isActive = false
    private var pressedWidget: WindowFrame.Widget?
    private var trackingWidget: WindowFrame.Widget?
    private var layout: WindowFrame.Layout?
    private var layoutWidgets: Set<WindowFrame.Widget>?
    // Size of the window-server shape and the context drawing into it. The
    // context is tied to the backing store it was made for, so a new shape
    // needs a new context.
    private var shapeSize: CGSize = .zero
    private var context: CGContext?
    private var level: Int32 = 0
    private var cornerRadius = BorderWindow.fallbackCornerRadius
    private var closed = false
    // Drag state: mouse and target origin at mouse down, both global top-left.
    private var dragStart: (mouse: CGPoint, origin: CGPoint)?
    private var pendingPosition: CGPoint?
    private var isSettingPosition = false
    // Called when the drawn shape changes.
    var shapeChanged: (() -> Void)?

    /// Where the border draws, in top-left coordinates of the border window.
    var shape: [CGRect] { layout?.shape ?? [] }
    private(set) var isVisible = false

    var alphaValue: CGFloat = 1 {
        didSet {
            guard alphaValue != oldValue else { return }
            applyAlpha()
        }
    }

    /// Hides every border while Mission Control or App Exposé shows. AppKit
    /// hides its own transient windows then, but not raw window-server ones.
    static var hiddenForMissionControl = false {
        didSet {
            guard hiddenForMissionControl != oldValue else { return }
            for entry in borders.values {
                entry.border?.applyAlpha()
            }
        }
    }

    private func applyAlpha() {
        guard !closed else { return }
        let alpha = Self.hiddenForMissionControl ? 0 : alphaValue
        _ = SkyLight.setWindowAlpha?(SkyLight.cid, windowNumber, Float(alpha))
    }

    // Used where the window server doesn't report a radius, before macOS 26.
    static let fallbackCornerRadius: CGFloat = {
        if #available(macOS 26, *) { return 16 }
        return 10
    }()
    // Art is drawn at 2x whatever the display, like the window's backing store.
    private static let scale: CGFloat = 2

    /// Nil when SkyLight can't make the window.
    init?(frame windowFrame: WindowFrame, targetWID: CGWindowID) {
        let cid = SkyLight.cid
        guard cid != 0,
              let newWindow = SkyLight.newWindow,
              let newRegion = SkyLight.newRegionWithRectList,
              let releaseRegion = SkyLight.releaseRegion,
              SkyLight.windowContextCreate != nil,
              SkyLight.transactionOrder != nil else { return nil }
        var rect = CGRect(x: 0, y: 0, width: 1, height: 1)
        var region: OpaquePointer?
        guard newRegion(&rect, 1, &region) == 0, let region else { return nil }
        defer { _ = releaseRegion(region) }
        var wid: UInt32 = 0
        guard newWindow(cid, Int32(CGWindowBackingType.backingStoreBuffered.rawValue), -9999, -9999, region, &wid) == 0,
              wid != 0 else { return nil }
        windowNumber = wid
        self.targetWID = targetWID
        self.windowFrame = windowFrame

        // Bit 16 is what a non-activating panel sets: a click on the frame
        // leaves Trois in the background, so the focused window stays active.
        var tags: UInt64 = 1 << 16
        _ = SkyLight.setWindowTags?(cid, wid, &tags, 64)
        _ = SkyLight.setWindowResolution?(cid, wid, Self.scale)
        // Not opaque, so transparent pixels show what's behind.
        _ = SkyLight.setWindowOpacity?(cid, wid, false)
        _ = SkyLight.setShadowProperties?(wid, ["com.apple.WindowShadowDensity": 0] as CFDictionary)
        Self.register(self)
        if Self.hiddenForMissionControl { applyAlpha() }
    }

    deinit {
        close()
    }

    /// Frame inset around a target, in global top-left coordinates.
    var outerFrame: CGRect {
        let i = windowFrame.insets
        return CGRect(x: targetFrame.minX - i.left, y: targetFrame.minY - i.top,
                      width: targetFrame.width + i.left + i.right, height: targetFrame.height + i.top + i.bottom)
    }

    func setFrame(_ frame: WindowFrame) {
        guard frame.identity != windowFrame.identity else { return }
        windowFrame = frame
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
        let restyled = readTargetInfo()
        if resized || retitled || restyled || layout == nil {
            redraw()
        }
        place()
    }

    /// Follows a size change, redrawing at the new size in the same screen update.
    func resize(to frame: CGRect) {
        let resized = frame.size != targetFrame.size
        targetFrame = frame
        if resized {
            redraw()
        } else {
            place()
        }
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
    }

    /// Fallback when the batched move couldn't be sent.
    func move(targetOrigin: CGPoint) {
        targetFrame.origin = targetOrigin
        place()
    }

    /// Puts the border back directly below its target, e.g. after an app
    /// raised its windows and left it behind.
    func reorder() {
        guard isVisible, !closed else { return }
        commit { tx, order in _ = order(tx, self.windowNumber, -1, self.targetWID) }
    }

    func orderOut() {
        guard isVisible, !closed else { return }
        isVisible = false
        commit { tx, order in _ = order(tx, self.windowNumber, 0, 0) }
    }

    func close() {
        guard !closed else { return }
        closed = true
        isVisible = false
        context = nil
        Self.unregister(windowNumber)
        _ = SkyLight.releaseWindow?(SkyLight.cid, windowNumber)
    }

    // Level, corner radius and Space follow the target. Returns true when the
    // art needs redrawing.
    private func readTargetInfo() -> Bool {
        var restyled = false
        if let info = WindowServer.info(of: targetWID) {
            level = info.level
            let radius = info.cornerRadius ?? Self.fallbackCornerRadius
            restyled = radius != cornerRadius
            cornerRadius = radius
        }
        if let space = WindowServer.space(of: targetWID), space != WindowServer.space(of: windowNumber) {
            WindowServer.moveToSpace(windowNumber, space)
        }
        return restyled
    }

    private func commit(_ build: (CFTypeRef, SkyLight.TransactionOrderFn) -> Void) {
        guard let create = SkyLight.transactionCreate, let commit = SkyLight.transactionCommit,
              let order = SkyLight.transactionOrder,
              let tx = create(SkyLight.cid)?.takeRetainedValue() else { return }
        build(tx, order)
        _ = commit(tx, 0)
    }

    // Moves the border around the target and orders it directly below, in one commit.
    private func place() {
        guard !closed, layout != nil else { return }
        let origin = outerFrame.origin
        commit { tx, order in
            _ = SkyLight.transactionSetLevel?(tx, windowNumber, level)
            _ = SkyLight.transactionMove?(tx, windowNumber, origin)
            _ = order(tx, windowNumber, -1, targetWID)
        }
        isVisible = true
    }

    private func redraw() {
        guard !closed, targetFrame.width > 0, targetFrame.height > 0 else { return }
        guard let (image, layout) = windowFrame.render(
            windowSize: targetFrame.size, active: isActive, widgets: target?.widgets ?? [],
            title: target?.title, pressedWidget: pressedWidget,
            cornerRadius: cornerRadius, scale: Self.scale
        ) else { return }
        let oldShape = self.layout?.shape
        self.layout = layout
        layoutWidgets = target?.widgets
        let cid = SkyLight.cid
        let reshape = layout.size != shapeSize

        // The context draws straight into the backing store, and a screen update
        // can land mid-draw, e.g. while a click raises a window. Freezing keeps
        // the old art on screen until the new art is flushed. A new size also
        // changes the shape and position, so screen updates are held too, making
        // all three appear together.
        if reshape {
            _ = SkyLight.disableUpdate?(cid)
        }
        _ = SkyLight.freezeWindow?(cid, windowNumber, nil)
        if reshape {
            setShape(layout.size)
        }
        if context == nil {
            context = SkyLight.windowContextCreate?(cid, windowNumber, nil)?.takeRetainedValue()
            context?.interpolationQuality = .none
        }
        if let context {
            // Copy replaces every pixel, transparent ones included, so no clear is needed.
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(origin: .zero, size: layout.size))
            context.flush()
            _ = SkyLight.flushWindow?(cid, windowNumber, nil)
        }
        // A hidden border keeps its new shape off screen until placed.
        if reshape && isVisible {
            place()
        }
        _ = SkyLight.thawWindow?(cid, windowNumber)
        if reshape {
            _ = SkyLight.reenableUpdate?(cid)
        }
        if reshape || oldShape != layout.shape {
            updateEventShape()
        }
        if oldShape != layout.shape {
            shapeChanged?()
        }
    }

    private func setShape(_ size: CGSize) {
        guard let newRegion = SkyLight.newRegionWithRectList, let release = SkyLight.releaseRegion,
              let setShape = SkyLight.setWindowShape else { return }
        var rect = CGRect(origin: .zero, size: size)
        var region: OpaquePointer?
        guard newRegion(&rect, 1, &region) == 0, let region else { return }
        defer { _ = release(region) }
        let origin = outerFrame.origin
        _ = setShape(SkyLight.cid, windowNumber, Float(origin.x), Float(origin.y), region)
        shapeSize = size
        context = nil
    }

    private func updateEventShape() {
        let i = windowFrame.insets
        let hole = CGRect(x: i.left, y: i.top, width: targetFrame.width, height: targetFrame.height)
        // Only drawn parts take clicks; transparent ones pass them through.
        // An empty shape takes none.
        _ = WindowServer.setEventShape(of: windowNumber, include: shape, exclude: [hole])
    }

    // MARK: - Mouse

    private struct Weak {
        weak var border: BorderWindow?
    }
    private static var borders: [CGWindowID: Weak] = [:]
    private static var monitor: Any?

    /// Whether `wid` is one of our border windows.
    static func isBorder(_ wid: CGWindowID) -> Bool {
        borders[wid] != nil
    }

    private static func register(_ border: BorderWindow) {
        borders[border.windowNumber] = Weak(border: border)
        guard monitor == nil else { return }
        // AppKit knows no window for these events, so they'd be dropped after the monitor.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { event in
            guard let border = borders[CGWindowID(event.windowNumber)]?.border else { return event }
            border.handle(event)
            return nil
        }
    }

    private static func unregister(_ wid: CGWindowID) {
        borders[wid] = nil
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown: mouseDown(with: event)
        case .leftMouseDragged: mouseDragged(with: event)
        case .leftMouseUp: mouseUp(with: event)
        default: break
        }
    }

    /// Event location in layout coordinates (top-left origin).
    private func layoutPoint(_ event: NSEvent) -> CGPoint {
        let p = event.cgEvent?.location ?? Self.mouseLocation()
        let outer = outerFrame
        return CGPoint(x: p.x - outer.minX, y: p.y - outer.minY)
    }

    private func widget(at point: CGPoint) -> WindowFrame.Widget? {
        layout?.widgets.first { $0.value.contains(point) }?.key
    }

    private static func mouseLocation() -> CGPoint {
        let m = NSEvent.mouseLocation
        let height = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: m.x, y: height - m.y)
    }

    private func mouseDown(with event: NSEvent) {
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

    private func mouseDragged(with event: NSEvent) {
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

    private func mouseUp(with event: NSEvent) {
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
