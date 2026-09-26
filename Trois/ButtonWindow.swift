// Draws traffic-light overlays as raw window-server windows above their target.
import Cocoa
import ApplicationServices

/// What OverlayManager needs from a traffic-light overlay.
protocol TrafficLightOverlay: AnyObject {
    var buttonType: TrafficLightType { get }
    var targetButton: AXUIElement? { get set }
    // Called on main when a press found targetButton gone, e.g. after Arc
    // rebuilt its buttons.
    var pressFailed: (() -> Void)? { get set }
    // Called on main for an Option-click, which presses this button on every
    // window of the app.
    var pressAll: (() -> Void)? { get set }
    // Called on main just before a click presses the button.
    var willPress: (() -> Void)? { get set }
    var surface: TitleBarColor.Surface { get set }
    var isVisible: Bool { get }
    var serverID: CGWindowID { get }
    /// The window the overlay sits directly above: the target, or its
    /// full-screen title bar.
    var orderAbove: CGWindowID { get set }
    /// Whether moves must also order the overlay above `orderAbove`.
    var ordersAboveTarget: Bool { get }
    func updateFrame(_ frame: CGRect)
    func origin(centeredOn center: CGPoint) -> CGPoint
    func didMoveOnServer(center: CGPoint)
    func move(center: CGPoint)
    func clip(covering covers: [CGRect])
    func syncAppKitFrame()
    func setWindowActive(_ active: Bool)
    func setZoomedState(_ zoomed: Bool)
    func reloadTheme()
    func press(retry: Bool)
    func reorder()
    func hide()
    func close()
}

// A raw window-server window at the target's level, ordered directly above the
// target, so windows in front of the target cover the button too and nothing
// needs clipping. AppKit windows can't be ordered against another app's window,
// so this isn't an NSWindow, like BorderWindow. The window server sends clicks
// to our main connection tagged with this window's number, and a local monitor
// routes them here. Mouse moves over it reach no AppKit window, but a global
// monitor still sees them, which drives hover.
final class ButtonWindow: TrafficLightOverlay {
    let buttonType: TrafficLightType
    let serverID: CGWindowID
    var targetButton: AXUIElement?
    var pressFailed: (() -> Void)?
    var pressAll: (() -> Void)?
    var willPress: (() -> Void)?
    var orderAbove: CGWindowID = 0
    var ordersAboveTarget: Bool { true }
    var surface: TitleBarColor.Surface {
        get { picker.surface }
        set {
            guard newValue != picker.surface else { return }
            picker.surface = newValue
            reloadImageForMouseState()
        }
    }
    private(set) var isVisible = false
    private var picker: ButtonArtPicker
    private var closed = false
    private var isMouseDown = false
    // The arrow cursor is pushed while the mouse is inside, and popped when
    // it leaves by any route: an exit, a drag out, a hide or a close.
    private var isMouseInside = false {
        didSet {
            guard isMouseInside != oldValue else { return }
            if isMouseInside { NSCursor.arrow.push() } else { NSCursor.pop() }
        }
    }
    // Background windows show the theme's disabled art while the mouse is away.
    private var windowIsActive = true
    private var image: NSImage?
    private var imageSize = NSSize(width: 14, height: 14)
    // Button center in global top-left coordinates.
    private var buttonCenter: CGPoint = .zero
    // Size of the window-server shape and the context drawing into it, kept
    // across shape changes.
    private var shapeSize: CGSize = .zero
    private var context: CGContext?
    private var resolution: CGFloat = 0
    private var subLevel: Int32 = 0

    /// Off by setting the rawButtons default to false, which brings back the
    /// floating, clipped panels.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "rawButtons") as? Bool ?? true
    }

    /// Nil when SkyLight can't make the window.
    init?(buttonType: TrafficLightType) {
        let cid = SkyLight.cid
        guard cid != 0,
              let newWindow = SkyLight.newWindow,
              let newRegion = SkyLight.newRegionWithRectList,
              let releaseRegion = SkyLight.releaseRegion,
              SkyLight.windowContextCreate != nil,
              SkyLight.setWindowShape != nil,
              SkyLight.transactionOrder != nil else { return nil }
        var rect = CGRect(x: 0, y: 0, width: 1, height: 1)
        var region: OpaquePointer?
        guard newRegion(&rect, 1, &region) == 0, let region else { return nil }
        defer { _ = releaseRegion(region) }
        var wid: UInt32 = 0
        guard newWindow(cid, Int32(CGWindowBackingType.backingStoreBuffered.rawValue), -9999, -9999, region, &wid) == 0,
              wid != 0 else { return nil }
        serverID = wid
        self.buttonType = buttonType
        picker = ButtonArtPicker(buttonType: buttonType)

        // Bit 16 is what a non-activating panel sets: a click leaves Trois in
        // the background, so the target app keeps focus.
        var tags: UInt64 = 1 << 16
        _ = SkyLight.setWindowTags?(cid, wid, &tags, 64)
        _ = SkyLight.setWindowOpacity?(cid, wid, false)
        _ = SkyLight.setShadowProperties?(wid, ["com.apple.WindowShadowDensity": 0] as CFDictionary)
        Self.register(self)
        if BorderWindow.hiddenForMissionControl { applyAlpha() }
        loadCustomImage()
    }

    deinit {
        close()
    }

    // MARK: - Placement

    func updateFrame(_ frame: CGRect) {
        buttonCenter = CGPoint(x: frame.midX, y: frame.midY)
        // Rescale images if this window's buttons are a different size or it
        // moved to a display with a different scale.
        let size = min(frame.width, frame.height) - 2
        let scale = backingScale(at: buttonCenter)
        if (size > 0 && size != picker.coverSize) || scale != picker.backingScale {
            if size > 0 { picker.coverSize = size }
            picker.backingScale = scale
            reloadImageForMouseState()
        }
        place()
    }

    /// Window-server origin (global top-left) that centers this overlay on `center`.
    func origin(centeredOn center: CGPoint) -> CGPoint {
        CGPoint(x: snapped(center.x - imageSize.width / 2), y: snapped(center.y - imageSize.height / 2))
    }

    /// Records a move the window server already applied.
    func didMoveOnServer(center: CGPoint) {
        buttonCenter = center
    }

    /// Fallback when the batched move couldn't be sent.
    func move(center: CGPoint) {
        buttonCenter = center
        place()
    }

    // Covering windows cover this window in the stack.
    func clip(covering covers: [CGRect]) {}

    // No AppKit frame to sync, but an exit may have been missed during motion.
    func syncAppKitFrame() {
        if isMouseInside && !isMouseDown && !frame.contains(Self.mouseLocation()) {
            resetMouse()
        }
    }

    /// Puts the button back directly above its target, e.g. after the target
    /// was raised and left it behind, or after a RaiseGuard lift ended.
    func reorder() {
        guard isVisible, !closed else { return }
        commit { tx, order in
            _ = SkyLight.transactionSetSubLevel?(tx, self.serverID, self.subLevel + RaiseGuard.lift(of: self.serverID))
            _ = order(tx, self.serverID, 1, self.orderAbove)
        }
    }

    func hide() {
        resetMouse()
        guard isVisible, !closed else { return }
        isVisible = false
        commit { tx, order in _ = order(tx, self.serverID, 0, 0) }
    }

    func close() {
        guard !closed else { return }
        resetMouse()
        closed = true
        isVisible = false
        context = nil
        Self.unregister(serverID)
        _ = SkyLight.releaseWindow?(SkyLight.cid, serverID)
    }

    // Global top-left frame of the drawn button.
    private var frame: CGRect {
        CGRect(origin: origin(centeredOn: buttonCenter), size: imageSize)
    }

    // Level and Space follow the target; then the button moves and is ordered
    // directly above it in one commit.
    private func place() {
        guard !closed, buttonCenter != .zero, orderAbove != 0 else { return }
        let level = WindowServer.info(of: orderAbove)?.level ?? 0
        subLevel = WindowServer.subLevel(of: orderAbove)
        if let space = WindowServer.space(of: orderAbove), space != WindowServer.space(of: serverID) {
            WindowServer.moveToSpace(serverID, space)
        }
        let origin = frame.origin
        commit { tx, order in
            _ = SkyLight.transactionSetLevel?(tx, self.serverID, level)
            _ = SkyLight.transactionSetSubLevel?(tx, self.serverID, self.subLevel + RaiseGuard.lift(of: self.serverID))
            _ = SkyLight.transactionMove?(tx, self.serverID, origin)
            _ = order(tx, self.serverID, 1, self.orderAbove)
        }
        isVisible = true
    }

    private func commit(_ build: (CFTypeRef, SkyLight.TransactionOrderFn) -> Void) {
        guard let create = SkyLight.transactionCreate, let commit = SkyLight.transactionCommit,
              let order = SkyLight.transactionOrder,
              let tx = create(SkyLight.cid)?.takeRetainedValue() else { return }
        build(tx, order)
        _ = commit(tx, 0)
    }

    /// Scale of the display under a global top-left point.
    private func backingScale(at point: CGPoint) -> CGFloat {
        let height = NSScreen.screens.first?.frame.height ?? 0
        let cocoa = CGPoint(x: point.x, y: height - point.y)
        let screen = NSScreen.screens.first { $0.frame.contains(cocoa) }
        return screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    /// Rounds down to the device pixel grid so pixel art isn't resampled.
    private func snapped(_ value: CGFloat) -> CGFloat {
        (value * picker.backingScale).rounded(.down) / picker.backingScale
    }

    // MARK: - Art

    func setWindowActive(_ active: Bool) {
        guard active != windowIsActive else { return }
        windowIsActive = active
        reloadImageForMouseState()
    }

    func setZoomedState(_ zoomed: Bool) {
        guard buttonType == .zoom, picker.isZoomed != zoomed else { return }
        picker.isZoomed = zoomed
        reloadImageForMouseState()
    }

    /// Shows the theme's art again, after ButtonArtPicker.clearCache().
    func reloadTheme() {
        reloadImageForMouseState()
    }

    private func loadCustomImage() {
        loadImageForState(windowIsActive ? "" : "Disabled")
    }

    // The one place art follows the mouse. Pressed only while a press that
    // started here is held over the button.
    private func reloadImageForMouseState() {
        if isMouseDown && isMouseInside {
            loadImageForState("Pressed")
        } else if isMouseInside {
            loadImageForState("Hover")
        } else {
            loadCustomImage()
        }
    }

    private func loadImageForState(_ state: String) {
        guard let (image, sizes) = picker.pick(state) else { return }
        self.image = image
        let resized = sizes && image.size != imageSize
        if sizes {
            imageSize = image.size
        }
        draw()
        // A new size moves the origin that centers it.
        if resized && isVisible {
            place()
        }
    }

    private func draw() {
        guard !closed, let image else { return }
        let cid = SkyLight.cid
        // The shape fits the resting art. Other states are centered on it and
        // cropped to it, as an image view showed them.
        let size = imageSize
        _ = SkyLight.freezeWindow?(cid, serverID, nil)
        defer { _ = SkyLight.thawWindow?(cid, serverID) }
        if picker.backingScale != resolution {
            resolution = picker.backingScale
            _ = SkyLight.setWindowResolution?(cid, serverID, Double(resolution))
        }
        if size != shapeSize {
            setShape(size)
        }
        // One context for the window's life. A new one made after a reshape
        // can still draw into the old backing store, losing the art.
        if context == nil {
            context = SkyLight.windowContextCreate?(cid, serverID, nil)?.takeRetainedValue()
            context?.interpolationQuality = .none
        }
        guard let context else { return }
        let rect = CGRect(x: (size.width - image.size.width) / 2, y: (size.height - image.size.height) / 2,
                          width: image.size.width, height: image.size.height)
        context.saveGState()
        context.clear(CGRect(origin: .zero, size: shapeSize))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: rect, from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        context.restoreGState()
        context.flush()
        _ = SkyLight.flushWindow?(cid, serverID, nil)
    }

    private func setShape(_ size: CGSize) {
        guard let newRegion = SkyLight.newRegionWithRectList, let release = SkyLight.releaseRegion,
              let setShape = SkyLight.setWindowShape else { return }
        var rect = CGRect(origin: .zero, size: size)
        var region: OpaquePointer?
        guard newRegion(&rect, 1, &region) == 0, let region else { return }
        defer { _ = release(region) }
        let origin = isVisible ? frame.origin : CGPoint(x: -9999, y: -9999)
        _ = setShape(SkyLight.cid, serverID, Float(origin.x), Float(origin.y), region)
        shapeSize = size
        _ = WindowServer.setEventShape(of: serverID, include: [rect], exclude: [])
    }

    // MARK: - Mission Control

    private func applyAlpha() {
        guard !closed else { return }
        _ = SkyLight.setWindowAlpha?(SkyLight.cid, serverID, BorderWindow.hiddenForMissionControl ? 0 : 1)
    }

    /// Hides or shows every button with the borders; see BorderWindow.hiddenForMissionControl.
    static func missionControlChanged() {
        for entry in buttons.values {
            entry.button?.applyAlpha()
        }
    }

    // MARK: - Mouse

    private struct Weak {
        weak var button: ButtonWindow?
    }
    private static var buttons: [CGWindowID: Weak] = [:]
    private static var clickMonitor: Any?
    private static var moveMonitor: Any?

    /// Whether `wid` is one of our button windows.
    static func isButton(_ wid: CGWindowID) -> Bool {
        buttons[wid] != nil
    }

    private static func register(_ button: ButtonWindow) {
        buttons[button.serverID] = Weak(button: button)
        guard clickMonitor == nil else { return }
        // AppKit knows no window for these events, so they'd be dropped after the monitor.
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { event in
            guard let button = buttons[CGWindowID(event.windowNumber)]?.button else { return event }
            button.handle(event)
            return nil
        }
        moveMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { _ in
            mouseMoved()
        }
    }

    private static func unregister(_ wid: CGWindowID) {
        buttons[wid] = nil
    }

    // Hover goes to the button under the mouse, if the window server would send
    // it a click there; one covered by another window gets none.
    private static func mouseMoved() {
        let point = mouseLocation()
        var hit: ButtonWindow?
        for entry in buttons.values {
            guard let button = entry.button, button.isVisible, !button.isMouseDown else { continue }
            if button.frame.contains(point) {
                hit = button
            } else if button.isMouseInside {
                button.isMouseInside = false
                button.reloadImageForMouseState()
            }
        }
        guard let hit else { return }
        let inside = WindowServer.window(at: point).map { $0 == hit.serverID } ?? true
        guard inside != hit.isMouseInside else { return }
        hit.isMouseInside = inside
        hit.reloadImageForMouseState()
    }

    private static func mouseLocation() -> CGPoint {
        let m = NSEvent.mouseLocation
        let height = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: m.x, y: height - m.y)
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            isMouseDown = true
            isMouseInside = true
            reloadImageForMouseState()
        case .leftMouseDragged:
            let inside = frame.contains(Self.mouseLocation())
            guard inside != isMouseInside else { return }
            isMouseInside = inside
            reloadImageForMouseState()
        case .leftMouseUp:
            if isMouseDown && isMouseInside {
                willPress?()
                if event.modifierFlags.contains(.option), buttonType != .zoom, let pressAll {
                    pressAll()
                } else {
                    press(retry: true)
                }
            }
            isMouseDown = false
            reloadImageForMouseState()
        default:
            break
        }
    }

    // The mouse can be inside when the button goes, e.g. after a click on close.
    private func resetMouse() {
        guard isMouseDown || isMouseInside else { return }
        isMouseDown = false
        isMouseInside = false
        reloadImageForMouseState()
    }

    func press(retry: Bool) {
        guard let button = targetButton else { return }
        AXQueue.async { [weak self] in
            let error = AXUIElementPerformAction(button, kAXPressAction as CFString)
            guard retry, error == .invalidUIElement else { return }
            DispatchQueue.main.async {
                self?.pressFailed?()
            }
        }
    }
}
