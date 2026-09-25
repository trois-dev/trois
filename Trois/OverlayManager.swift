// Manages overlay windows for button replacement.
import Cocoa
import ApplicationServices

// AX calls block until the target app answers, so they run on this serial
// queue and their results are applied on main. Overlay motion and clipping
// never wait on them.
enum AXQueue {
    static let queue: DispatchQueue = {
        // The system-wide element sets the timeout for every AX call this
        // process makes, including ones on window and button elements. A hung
        // app then holds the queue for this long instead of the 6s default.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.0)
        return DispatchQueue(label: "com.trois.app.ax", qos: .userInteractive)
    }()

    static func async(_ work: @escaping () -> Void) {
        queue.async(execute: work)
    }
}

/// A target window's AX state, read on AXQueue.
struct WindowSnapshot {
    let window: AXUIElement
    let frame: CGRect
    // Nil for buttons that are missing or outside the window. Arc parks its
    // buttons left of the window while its sidebar is hidden.
    let buttons: ButtonFrames
    let closeButton: AXUIElement?
    let minimizeButton: AXUIElement?
    let zoomButton: AXUIElement?
    let isFullScreen: Bool
    let title: String?

    var buttonElements: [AXUIElement] {
        [closeButton, minimizeButton, zoomButton].compactMap { $0 }
    }
}

enum WindowRead {
    case window(WindowSnapshot)
    // No frame or no button elements.
    case unusable(frame: CGRect?)
    // The app didn't answer in time. Whatever was shown before still stands.
    case timedOut
}

class OverlayManager {
    private var closeOverlay: OverlayWindow?
    private var minimizeOverlay: OverlayWindow?
    private var zoomOverlay: OverlayWindow?
    private var border: BorderWindow?
    private var currentWindow: AXUIElement?
    let targetWID: CGWindowID
    let pid: pid_t
    private var isActive = false
    // Target frame in global top-left coordinates, as of the last placement.
    private(set) var targetFrame: CGRect = .zero
    // Button frames relative to the target's top-left corner. Buttons stay put
    // relative to that corner while the window moves, so a move needs no AX reads.
    private var offsets = ButtonFrames()
    private(set) var isRefreshing = false
    private var refreshAgain = false
    private var isVerifying = false
    private var removed = false
    // A press that hit a stale button element, retried after the next read.
    private var pendingPress: TrafficLightType?
    // Called on main after each refresh() is applied, with whether the button
    // offsets changed.
    var didRefresh: ((WindowRead, Bool) -> Void)?
    // Called on main when the border's drawn shape changes, so windows behind
    // it can be clipped again.
    var didChangeShape: (() -> Void)?

    init(targetWID: CGWindowID, pid: pid_t) {
        self.targetWID = targetWID
        self.pid = pid
    }

    /// Reads a window's frame and buttons. Slow; call on AXQueue.
    static func read(_ window: AXUIElement) -> WindowRead {
        do {
            guard let frame = try axFrame(of: window) else { return .unusable(frame: nil) }
            let close = try button(of: window, kAXCloseButtonAttribute)
            let minimize = try button(of: window, kAXMinimizeButtonAttribute)
            let zoom = try button(of: window, kAXZoomButtonAttribute)
            guard close != nil || minimize != nil || zoom != nil else {
                return .unusable(frame: frame)
            }
            func visibleFrame(of button: AXUIElement?) throws -> CGRect? {
                guard let button, let buttonFrame = try axFrame(of: button) else { return nil }
                return frame.contains(CGPoint(x: buttonFrame.midX, y: buttonFrame.midY)) ? buttonFrame : nil
            }
            let buttons = ButtonFrames(
                close: try visibleFrame(of: close),
                minimize: try visibleFrame(of: minimize),
                zoom: try visibleFrame(of: zoom)
            )
            let fullScreen = try value(of: window, "AXFullScreen") as? Bool ?? false
            let title = try value(of: window, kAXTitleAttribute) as? String
            return .window(WindowSnapshot(
                window: window, frame: frame, buttons: buttons,
                closeButton: close, minimizeButton: minimize, zoomButton: zoom,
                isFullScreen: fullScreen, title: title
            ))
        } catch {
            return .timedOut
        }
    }

    /// Places the overlays from a read. Returns false when the window has no
    /// buttons, which also takes its overlays off screen.
    @discardableResult
    func apply(_ read: WindowRead) -> Bool {
        switch read {
        case .timedOut:
            return false
        case .unusable(let frame):
            if let frame {
                targetFrame = frame
            }
            offsets = ButtonFrames()
            closeOverlay?.orderOut(nil)
            minimizeOverlay?.orderOut(nil)
            zoomOverlay?.orderOut(nil)
            border?.orderOut()
            return false
        case .window(let snapshot):
            // The window may have moved while AX was read. Offsets hold either
            // way, so place them against where the window is now.
            let axFrame = snapshot.frame
            let origin = WindowServer.bounds(of: targetWID)?.origin ?? axFrame.origin
            targetFrame = CGRect(origin: origin, size: axFrame.size)
            offsets = ButtonFrames(
                close: snapshot.buttons.close?.offsetBy(dx: -axFrame.minX, dy: -axFrame.minY),
                minimize: snapshot.buttons.minimize?.offsetBy(dx: -axFrame.minX, dy: -axFrame.minY),
                zoom: snapshot.buttons.zoom?.offsetBy(dx: -axFrame.minX, dy: -axFrame.minY)
            )
            updateOverlays(for: snapshot)
            return true
        }
    }

    /// Re-reads the window apply(_:) last used, then calls didRefresh. For
    /// resizes and layout changes. Requests made while one runs are merged into
    /// one more read.
    func refresh() {
        guard let window = currentWindow, !removed else { return }
        guard !isRefreshing else {
            refreshAgain = true
            return
        }
        isRefreshing = true
        AXQueue.async { [weak self] in
            let read = Self.read(window)
            DispatchQueue.main.async {
                guard let self, !self.removed else { return }
                self.isRefreshing = false
                let oldOffsets = self.offsets
                self.apply(read)
                self.didRefresh?(read, self.offsets != oldOffsets)
                if self.refreshAgain {
                    self.refreshAgain = false
                    self.refresh()
                } else if let type = self.pendingPress {
                    self.pendingPress = nil
                    self.overlay(for: type)?.press(retry: false)
                }
            }
        }
    }

    /// Moves the overlays with the target using cached offsets, in one
    /// window-server transaction.
    func follow(targetFrame frame: CGRect, includingBorder: Bool = true) {
        targetFrame.origin = frame.origin
        var moves: [(overlay: OverlayWindow, center: CGPoint)] = []
        for (overlay, offset) in overlaysWithOffsets() where overlay.isVisible {
            moves.append((overlay, CGPoint(x: frame.minX + offset.midX, y: frame.minY + offset.midY)))
        }
        let movingBorder = includingBorder && border?.isVisible == true ? border : nil
        guard !moves.isEmpty || movingBorder != nil else { return }
        var serverMoves = moves.map { (wid: CGWindowID($0.overlay.windowNumber), origin: $0.overlay.origin(centeredOn: $0.center)) }
        var below: [(wid: CGWindowID, target: CGWindowID)] = []
        if let movingBorder {
            serverMoves.append((movingBorder.windowNumber, movingBorder.origin(following: frame.origin)))
            below.append((movingBorder.windowNumber, targetWID))
        }
        if WindowServer.move(serverMoves, below: below) {
            for m in moves { m.overlay.didMoveOnServer(center: m.center) }
            movingBorder?.didMoveOnServer(targetOrigin: frame.origin)
        } else {
            for m in moves { m.overlay.move(center: m.center) }
            movingBorder?.move(targetOrigin: frame.origin)
        }
    }

    /// Follows a live resize: overlays move with the top-left corner and the
    /// border redraws at the new size, both without an AX read.
    func resize(targetFrame frame: CGRect) {
        follow(targetFrame: frame, includingBorder: false)
        border?.resize(to: frame)
    }

    /// Puts the border back directly below the target.
    func reorderBorder() {
        border?.reorder()
    }

    /// Clips each overlay to the part not covered by `covers`, the frames of
    /// windows in front of the target in global top-left coordinates. The
    /// border sits in the window stack, so it needs no clipping.
    func clip(covering covers: [CGRect]) {
        closeOverlay?.clip(covering: covers)
        minimizeOverlay?.clip(covering: covers)
        zoomOverlay?.clip(covering: covers)
    }

    /// What this window and its border cover, given the window's frame: the
    /// window itself plus the parts of the border that draw. Transparent parts
    /// of the border leave windows behind it showing.
    func coverRects(for frame: CGRect) -> [CGRect] {
        guard let border, border.isVisible else { return [frame] }
        let outer = border.outerFrame
        let dx = outer.minX + frame.minX - targetFrame.minX
        let dy = outer.minY + frame.minY - targetFrame.minY
        return [frame] + border.shape.map { $0.offsetBy(dx: dx, dy: dy) }
    }

    /// Whether this is the focused window, which picks the active frame.
    func setActive(_ active: Bool) {
        isActive = active
        border?.setActive(active)
        closeOverlay?.setWindowActive(active)
        minimizeOverlay?.setWindowActive(active)
        zoomOverlay?.setWindowActive(active)
    }

    /// Brings AppKit's cached frames in line after window-server moves.
    func syncAppKitFrames() {
        closeOverlay?.syncAppKitFrame()
        minimizeOverlay?.syncAppKitFrame()
        zoomOverlay?.syncAppKitFrame()
    }

    /// Reads only the close button and refreshes if it isn't where the overlays
    /// assume. About half the cost of a full read, for frequent checks.
    func verify() {
        guard let window = currentWindow, !removed, !isRefreshing, !isVerifying else { return }
        isVerifying = true
        AXQueue.async { [weak self] in
            // Outer nil when the app didn't answer in time.
            let closeFrame: CGRect??
            do {
                closeFrame = .some(try Self.button(of: window, kAXCloseButtonAttribute).flatMap { try Self.axFrame(of: $0) })
            } catch {
                closeFrame = nil
            }
            DispatchQueue.main.async {
                guard let self, !self.removed else { return }
                self.isVerifying = false
                guard let closeFrame, !self.isRefreshing else { return }
                if !self.closeButtonMatches(closeFrame) {
                    self.refresh()
                }
            }
        }
    }

    private func closeButtonMatches(_ closeFrame: CGRect?) -> Bool {
        guard let offset = offsets.close else {
            // Not shown: fine while it stays missing or outside the window.
            guard let closeFrame else { return true }
            return !targetFrame.contains(CGPoint(x: closeFrame.midX, y: closeFrame.midY))
        }
        guard let closeFrame else { return false }
        return abs(closeFrame.minX - (targetFrame.minX + offset.minX)) < 1 &&
            abs(closeFrame.minY - (targetFrame.minY + offset.minY)) < 1
    }

    private func overlay(for type: TrafficLightType) -> OverlayWindow? {
        switch type {
        case .close: return closeOverlay
        case .minimize: return minimizeOverlay
        case .zoom: return zoomOverlay
        }
    }

    private func makeOverlay(_ type: TrafficLightType) -> OverlayWindow {
        let overlay = OverlayWindow(buttonType: type)
        overlay.setWindowActive(isActive)
        overlay.pressFailed = { [weak self] in
            guard let self else { return }
            self.pendingPress = type
            self.refresh()
        }
        return overlay
    }

    private func overlaysWithOffsets() -> [(OverlayWindow, CGRect)] {
        var result: [(OverlayWindow, CGRect)] = []
        if let o = closeOverlay, let f = offsets.close { result.append((o, f)) }
        if let o = minimizeOverlay, let f = offsets.minimize { result.append((o, f)) }
        if let o = zoomOverlay, let f = offsets.zoom { result.append((o, f)) }
        return result
    }

    private struct AXTimedOut: Error {}

    // Nil when the attribute is missing. Throws when the app didn't answer.
    private static func value(of element: AXUIElement, _ attribute: String) throws -> CFTypeRef? {
        var ref: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &ref)
        if error == .cannotComplete { throw AXTimedOut() }
        return error == .success ? ref : nil
    }

    private static func axFrame(of element: AXUIElement) throws -> CGRect? {
        guard let positionRef = try value(of: element, kAXPositionAttribute),
              let sizeRef = try value(of: element, kAXSizeAttribute) else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionRef as! AXValue, .cgPoint, &position)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        return CGRect(origin: position, size: size)
    }

    private static func button(of window: AXUIElement, _ attribute: String) throws -> AXUIElement? {
        guard let ref = try value(of: window, attribute) else { return nil }
        return (ref as! AXUIElement)
    }

    private func updateOverlays(for snapshot: WindowSnapshot) {
        currentWindow = snapshot.window
        let zoomed = snapshot.isFullScreen || fillsScreen(targetFrame)

        if let offset = offsets.close {
            if closeOverlay == nil {
                closeOverlay = makeOverlay(.close)
            }
            closeOverlay?.updateFrame(offset.offsetBy(dx: targetFrame.minX, dy: targetFrame.minY))
            closeOverlay?.targetButton = snapshot.closeButton
        } else {
            closeOverlay?.orderOut(nil)
        }

        if let offset = offsets.minimize {
            if minimizeOverlay == nil {
                minimizeOverlay = makeOverlay(.minimize)
            }
            minimizeOverlay?.updateFrame(offset.offsetBy(dx: targetFrame.minX, dy: targetFrame.minY))
            minimizeOverlay?.targetButton = snapshot.minimizeButton
        } else {
            minimizeOverlay?.orderOut(nil)
        }

        if let offset = offsets.zoom {
            if zoomOverlay == nil {
                zoomOverlay = makeOverlay(.zoom)
            }
            zoomOverlay?.updateFrame(offset.offsetBy(dx: targetFrame.minX, dy: targetFrame.minY))
            zoomOverlay?.targetButton = snapshot.zoomButton
            zoomOverlay?.setZoomedState(zoomed)
        } else {
            zoomOverlay?.orderOut(nil)
        }

        updateBorder(for: snapshot)
    }

    private func updateBorder(for snapshot: WindowSnapshot) {
        // Full-screen windows have nowhere to put a frame.
        guard let frame = WindowFrameStore.current, !snapshot.isFullScreen else {
            border?.close()
            border = nil
            return
        }
        if border == nil {
            border = BorderWindow(frame: frame, targetWID: targetWID)
            border?.setActive(isActive)
            border?.shapeChanged = { [weak self] in self?.didChangeShape?() }
        }
        border?.setFrame(frame)
        let target = BorderTarget(window: snapshot.window, title: snapshot.title,
                                  close: snapshot.closeButton, minimize: snapshot.minimizeButton,
                                  zoom: snapshot.zoomButton)
        border?.update(target: target, pid: pid, frame: targetFrame)
    }

    /// Check if a window frame (global top-left) fills its screen, zoomed but not fullscreen
    private func fillsScreen(_ frame: CGRect) -> Bool {
        let position = frame.origin
        let size = frame.size

        // Find the screen containing this window
        guard let primaryScreen = NSScreen.screens.first else { return false }
        let cocoaY = primaryScreen.frame.height - position.y
        let windowCenter = CGPoint(x: position.x + size.width / 2, y: cocoaY - size.height / 2)

        for screen in NSScreen.screens {
            if screen.frame.contains(windowCenter) {
                // Check if window fills most of the visible frame (accounting for menu bar/dock)
                let visibleFrame = screen.visibleFrame
                let fillsWidth = size.width >= visibleFrame.width * 0.95
                let fillsHeight = size.height >= visibleFrame.height * 0.95
                return fillsWidth && fillsHeight
            }
        }
        return false
    }

    func removeAllOverlays() {
        removed = true
        closeOverlay?.close()
        minimizeOverlay?.close()
        zoomOverlay?.close()
        border?.close()
        closeOverlay = nil
        minimizeOverlay = nil
        zoomOverlay = nil
        border = nil
    }

    func reloadImages() {
        closeOverlay?.reloadTheme()
        minimizeOverlay?.reloadTheme()
        zoomOverlay?.reloadTheme()
        // The theme's frame may have come or gone; the next read sets it up.
        refresh()
    }
}

/// `bounds` minus the union of `covered`, in one boolean operation however
/// many rects there are. Overlapping rects are fine under the winding rule.
func visiblePath(_ bounds: CGRect, minus covered: [CGRect]) -> CGPath {
    let union = CGMutablePath()
    union.addRects(covered)
    return CGPath(rect: bounds, transform: nil).subtracting(union, using: .winding)
}

/// Theme button art without the transparent margin around it. Kaleidoscope 1.x
/// icons are 16x16 with the art in the top-left 13x13, so centering the whole
/// canvas on a traffic light puts the art off center. One box covers every
/// state of a button, so pressing it doesn't shift the art.
enum ButtonArt {
    /// How art smaller than the system button's circle is fitted over it.
    enum Sizing: String, CaseIterable {
        // Trimmed, drawn 1:1, edge pixels grown outward until the circle is covered.
        case bleed
        // Untrimmed and unscaled. The circle can show around small art.
        case original
        // Trimmed and scaled by any factor until it covers the circle.
        case stretch

        static let defaultsKey = "buttonSizing"

        static var current: Sizing {
            UserDefaults.standard.string(forKey: defaultsKey).flatMap(Sizing.init) ?? .bleed
        }

        var title: String {
            switch self {
            case .bleed: return "Fill gaps"
            case .original: return "Unchanged"
            case .stretch: return "Scale up"
            }
        }

        var help: String {
            switch self {
            case .bleed: return "Actual size, edges extended to cover the button"
            case .original: return "Not trimmed or scaled. The button can show around small art"
            case .stretch: return "Trimmed and scaled until it covers the button"
            }
        }
    }

    /// Loads each file at its pixel size, trimmed to the opaque box shared by
    /// all images of the same pixel size. Missing files come back nil.
    static func load(_ paths: [String?], trim: Bool = true) -> [NSImage?] {
        let images: [CGImage?] = paths.map { path in
            guard let path, let image = NSImage(contentsOfFile: path) else { return nil }
            return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        guard trim else {
            return images.map { $0.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) } }
        }
        // Keyed by pixel width and height.
        var boxes: [[Int]: CGRect] = [:]
        for case let image? in images {
            let size = [image.width, image.height]
            guard let box = opaqueBounds(image) else { continue }
            boxes[size] = boxes[size].map { $0.union(box) } ?? box
        }
        return images.map { image in
            guard let image else { return nil }
            let size = [image.width, image.height]
            let cropped = boxes[size].flatMap { image.cropping(to: $0) } ?? image
            return NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
        }
    }

    /// Smallest rect, in pixels with a top-left origin, holding every pixel
    /// that isn't fully transparent. Nil for a blank image.
    static func opaqueBounds(_ image: CGImage) -> CGRect? {
        let width = image.width, height = image.height
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        // Row 0 of the bitmap is the top of the image.
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where data[(y * width + x) * 4 + 3] > 0 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// Fits `image` (1px = 1pt) over a system circle `cover` points wide on a
    /// display with `backing` device pixels per point. Art that already covers
    /// it comes back unchanged.
    static func sized(_ image: NSImage, cover: CGFloat, backing: CGFloat, mode: Sizing) -> NSImage {
        let size = image.size
        guard size.width > 0, size.height > 0,
              size.width < cover || size.height < cover else { return image }
        switch mode {
        case .original:
            return image
        case .stretch:
            // Nearest neighbor keeps pixel art sharp, but a non-integer scale
            // makes some pixels a device pixel wider than others.
            let scale = max(cover / size.width, cover / size.height)
            let target = NSSize(width: ceil(size.width * scale), height: ceil(size.height * scale))
            return NSImage(size: target, flipped: false) { rect in
                NSGraphicsContext.current?.imageInterpolation = .none
                image.draw(in: rect)
                return true
            }
        case .bleed:
            guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return image }
            return bled(cgImage, cover: cover, backing: backing) ?? image
        }
    }

    /// Draws the art at a whole number of device pixels per art pixel, then
    /// grows its outer edge one device pixel ring at a time, copying the
    /// nearest opaque color, until no transparent pixel inside the circle is
    /// reachable from outside. Holes enclosed by the art stay transparent.
    private static func bled(_ image: CGImage, cover: CGFloat, backing: CGFloat) -> NSImage? {
        let s = max(1, Int(backing.rounded()))
        let w = image.width, h = image.height
        let diameter = cover * CGFloat(s)
        // Very small art on a 2x display: 1.5x is exactly 3 device pixels per
        // art pixel, so it stays sharp and needs less bleed.
        let k = s == 2 && CGFloat(min(w, h)) + 3 < cover ? 3 : s
        let artW = w * k, artH = h * k
        // Room for the bleed to grow past the circle on square art.
        let margin = 2 * s
        let side = Int(ceil(diameter)) + 2 * margin
        let width = max(artW, side), height = max(artH, side)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        context.interpolationQuality = .none
        let ox = (width - artW) / 2, oy = (height - artH) / 2
        context.draw(image, in: CGRect(x: ox, y: oy, width: artW, height: artH))

        // Pixels are centered at +0.5. The disc is a device pixel wider than
        // the circle to cover its antialiased rim.
        let cx = CGFloat(width) / 2, cy = CGFloat(height) / 2
        let r = (diameter + 1) / 2
        func inDisc(_ x: Int, _ y: Int) -> Bool {
            let dx = CGFloat(x) + 0.5 - cx, dy = CGFloat(y) + 0.5 - cy
            return dx * dx + dy * dy <= r * r
        }
        func alpha(_ i: Int) -> UInt8 { data[i * 4 + 3] }

        // Transparent pixels connected to the border.
        var outside = [Bool](repeating: false, count: width * height)
        var stack: [Int] = []
        for x in 0..<width { stack.append(x); stack.append((height - 1) * width + x) }
        for y in 0..<height { stack.append(y * width); stack.append(y * width + width - 1) }
        while let i = stack.popLast() {
            guard !outside[i], alpha(i) == 0 else { continue }
            outside[i] = true
            let x = i % width, y = i / width
            if x > 0 { stack.append(i - 1) }
            if x < width - 1 { stack.append(i + 1) }
            if y > 0 { stack.append(i - width) }
            if y < height - 1 { stack.append(i + width) }
        }

        func uncovered() -> Bool {
            for y in 0..<height {
                for x in 0..<width where outside[y * width + x] && alpha(y * width + x) == 0 && inDisc(x, y) {
                    return true
                }
            }
            return false
        }

        // Each pass adds one ring in all 8 directions, so square art stays square.
        var passes = 0
        while uncovered() && passes < width {
            passes += 1
            var fills: [(Int, Int)] = []
            for y in 0..<height {
                for x in 0..<width {
                    let i = y * width + x
                    guard outside[i], alpha(i) == 0 else { continue }
                    // Side neighbors first, so a rounded corner copies the
                    // outline next to it rather than the fill diagonally inside.
                    var best = -1
                    for diagonal in [false, true] where best < 0 {
                        for ny in max(0, y - 1)...min(height - 1, y + 1) {
                            for nx in max(0, x - 1)...min(width - 1, x + 1) where (nx != x && ny != y) == diagonal {
                                let n = ny * width + nx
                                if alpha(n) > 0 && (best < 0 || alpha(n) > alpha(best)) { best = n }
                            }
                        }
                    }
                    if best >= 0 { fills.append((i, best)) }
                }
            }
            if fills.isEmpty { break }
            // Premultiplied: unpremultiply the source so the fill is fully opaque.
            for (i, n) in fills {
                let a = Int(data[n * 4 + 3])
                for c in 0..<3 { data[i * 4 + c] = UInt8(min(255, Int(data[n * 4 + c]) * 255 / a)) }
                data[i * 4 + 3] = 255
            }
        }

        // Crop to the opaque pixels, symmetric about the center so the art
        // stays centered on the button.
        guard let filled = context.makeImage(), let box = opaqueBounds(filled) else { return nil }
        let halfW = max(CGFloat(width) / 2 - box.minX, box.maxX - CGFloat(width) / 2)
        let halfH = max(CGFloat(height) / 2 - box.minY, box.maxY - CGFloat(height) / 2)
        let crop = CGRect(x: CGFloat(width) / 2 - halfW, y: CGFloat(height) / 2 - halfH, width: 2 * halfW, height: 2 * halfH).integral
        guard let cropped = filled.cropping(to: crop) else { return nil }
        return NSImage(cgImage: cropped, size: NSSize(width: CGFloat(cropped.width) / CGFloat(s),
                                                        height: CGFloat(cropped.height) / CGFloat(s)))
    }
}

enum TrafficLightType {
    case close
    case minimize
    case zoom
}

class OverlayWindow: NSWindow {
    let buttonType: TrafficLightType
    var targetButton: AXUIElement?
    // Called on main when a press found targetButton gone, e.g. after Arc
    // rebuilt its buttons.
    var pressFailed: (() -> Void)?
    private var imageView: NSImageView!
    private var trackingArea: NSTrackingArea?
    private var isMouseDown = false
    private var isMouseInside = false
    private var imageSize: NSSize = NSSize(width: 14, height: 14)
    private var buttonCenter: CGPoint = .zero
    private var windowIsZoomed = false
    // Background windows show the theme's disabled art while the mouse is away.
    private var windowIsActive = true
    // Diameter of the system button's circle, which images must cover. The
    // system draws it 1pt inside the AX button frame: 14pt in a 16pt frame on
    // macOS 27, 12pt before.
    private var coverSize: CGFloat = 14
    // Device pixels per point on the display under the button.
    private var backingScale: CGFloat = NSScreen.main?.backingScaleFactor ?? 2
    // Set after a window-server move AppKit didn't see. AppKit's cached frame
    // keeps the old origin until syncAppKitFrame().
    private var appKitStale = false
    // Covered parts currently masked out, in view coordinates. Nil forces an update.
    private var clipRects: [CGRect]? = []
    // Sized art by key, state, cover, scale and sizing mode, so hovering doesn't
    // reload and reprocess files. Nil entries remember a missing image.
    private var artCache: [String: NSImage?] = [:]

    init(buttonType: TrafficLightType) {
        self.buttonType = buttonType
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 14, height: 14),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        self.level = .floating
        // Owned by OverlayManager. close() must not also release it.
        self.isReleasedWhenClosed = false
        // orderOut otherwise fades for about 250ms, trailing buttons that vanish at once.
        self.animationBehavior = .none
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = false
        self.ignoresMouseEvents = false
        // Transient hides it for Mission Control and Exposé, where the window it covers shrinks away.
        // Full-screen auxiliary lets it show on a full-screen window's Space.
        self.collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary]

        setupImageView()
        setupTracking()
    }

    private func setupImageView() {
        imageView = NSImageView(frame: NSRect(x: 0, y: 0, width: 14, height: 14))
        imageView.imageScaling = .scaleNone  // Use natural image size
        imageView.imageAlignment = .alignCenter
        imageView.wantsLayer = true

        loadCustomImage()

        contentView = imageView
    }

    private func setupTracking() {
        let view = contentView!
        trackingArea = NSTrackingArea(
            rect: view.bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        view.addTrackingArea(trackingArea!)
    }

    /// The art for a button the mouse isn't on: normal, or disabled in a background window.
    func loadCustomImage() {
        loadImageForState(windowIsActive ? "" : "Disabled")
    }

    func setWindowActive(_ active: Bool) {
        guard active != windowIsActive else { return }
        windowIsActive = active
        reloadImageForMouseState()
    }

    /// Reads the theme's files again after they changed.
    func reloadTheme() {
        artCache.removeAll()
        reloadImageForMouseState()
    }

    // The mouse can be inside when the window goes, e.g. after a click on close.
    override func close() {
        if isMouseInside {
            isMouseInside = false
            NSCursor.pop()
        }
        super.close()
    }

    func loadHoverImage() {
        loadImageForState("Hover")
    }

    func loadPressedImage() {
        loadImageForState("Pressed")
    }

    /// Update zoomed state - affects which images are shown for zoom button
    func setZoomedState(_ zoomed: Bool) {
        guard buttonType == .zoom else { return }
        if windowIsZoomed != zoomed {
            windowIsZoomed = zoomed
            // Reload image to show restore/maximize appropriately
            reloadImageForMouseState()
        }
    }

    private func reloadImageForMouseState() {
        if isMouseDown {
            loadPressedImage()
        } else if isMouseInside {
            loadHoverImage()
        } else {
            loadCustomImage()
        }
    }

    private func loadImageForState(_ state: String) {
        let baseKey: String
        switch buttonType {
        case .close: baseKey = "closeButton"
        case .minimize: baseKey = "minimizeButton"
        case .zoom:
            // Use restore images when window is zoomed, maximize images otherwise
            baseKey = windowIsZoomed ? "restoreButton" : "zoomButton"
        }

        if let image = art(baseKey, state: state) {
            imageView.image = image
            // Update size based on image if this is a resting state
            if state.isEmpty || state == "Disabled" {
                updateImageSize(image.size)
            }
        } else if state == "Disabled" {
            loadImageForState("")
        } else if state.isEmpty {
            // Fallback: try zoom button images if restore not available
            if windowIsZoomed, let image = art("zoomButton", state: state) {
                imageView.image = image
                updateImageSize(image.size)
                return
            }
            // Only fall back to default for normal state
            let defaultImage = createDefaultImage()
            imageView.image = defaultImage
            updateImageSize(defaultImage.size)
        }
        // For hover/pressed, if no image, keep current image
    }

    /// The image for `baseKey` in `state`, trimmed to the box shared by all of
    /// that button's states. Zoom and restore share one box.
    private func trimmedImage(_ baseKey: String, state: String) -> NSImage? {
        let defaults = UserDefaults.standard
        let bases = buttonType == .zoom ? ["zoomButton", "restoreButton"] : [baseKey]
        let states = ["", "Hover", "Pressed", "Disabled"]
        let keys = bases.flatMap { base in states.map { base + $0 + "Image" } }
        guard let index = keys.firstIndex(of: baseKey + state + "Image") else { return nil }
        let trim = ButtonArt.Sizing.current != .original
        return ButtonArt.load(keys.map { defaults.string(forKey: $0) }, trim: trim)[index]
    }

    /// The trimmed image, fitted over the system button's circle per the Buttons setting.
    private func art(_ baseKey: String, state: String) -> NSImage? {
        let mode = ButtonArt.Sizing.current
        let key = "\(baseKey)\(state)|\(coverSize)|\(backingScale)|\(mode.rawValue)"
        if let cached = artCache[key] { return cached }
        let image = trimmedImage(baseKey, state: state).map {
            ButtonArt.sized($0, cover: coverSize, backing: backingScale, mode: mode)
        }
        artCache[key] = image
        return image
    }

    /// Scale of the display under the button. AppKit's own screen can be stale
    /// after a window-server move, so this looks it up from the button center.
    private func currentBackingScale() -> CGFloat {
        if buttonCenter != .zero {
            let point = convertAXToCocoaCoordinates(buttonCenter)
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) {
                return screen.backingScaleFactor
            }
        }
        return screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    /// Rounds down to the device pixel grid so pixel art isn't resampled.
    private func snapped(_ value: CGFloat) -> CGFloat {
        (value * backingScale).rounded(.down) / backingScale
    }

    // File images arrive with size already set to their pixel dimensions.
    private func updateImageSize(_ size: NSSize) {
        imageSize = size
        imageView.frame = NSRect(origin: .zero, size: size)
        clipRects = nil
        setContentSize(size)
        // Re-center on button position
        repositionOnCenter()
    }

    private func repositionOnCenter() {
        guard buttonCenter != .zero else { return }
        appKitStale = false

        let cocoaPoint = convertAXToCocoaCoordinates(buttonCenter)
        let x = snapped(cocoaPoint.x - imageSize.width / 2)
        let y = snapped(cocoaPoint.y - imageSize.height / 2)

        setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// Converts AX coordinates (top-left origin on primary screen) to Cocoa coordinates (bottom-left origin)
    private func convertAXToCocoaCoordinates(_ axPoint: CGPoint) -> CGPoint {
        // AX uses top-left origin at primary screen, Cocoa uses bottom-left origin
        // The primary screen defines the coordinate transformation baseline
        guard let primaryScreen = NSScreen.screens.first else {
            return axPoint
        }
        return CGPoint(
            x: axPoint.x,
            y: primaryScreen.frame.height - axPoint.y
        )
    }

    // A circle the size of the system one, with the same 1pt margin.
    private func createDefaultImage() -> NSImage {
        let size = NSSize(width: coverSize + 2, height: coverSize + 2)
        let image = NSImage(size: size)
        image.lockFocus()

        let color: NSColor
        switch buttonType {
        case .close: color = .systemRed
        case .minimize: color = .systemYellow
        case .zoom: color = .systemGreen
        }

        color.setFill()
        let path = NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: coverSize, height: coverSize))
        path.fill()

        image.unlockFocus()
        return image
    }

    func updateFrame(_ frame: CGRect) {
        // Store center of button in AX coordinates (top-left origin)
        buttonCenter = CGPoint(
            x: frame.origin.x + frame.size.width / 2,
            y: frame.origin.y + frame.size.height / 2
        )

        // Rescale images if this window's buttons are a different size
        // or it moved to a display with a different scale.
        let size = min(frame.width, frame.height) - 2
        let scale = currentBackingScale()
        if (size > 0 && size != coverSize) || scale != backingScale {
            if size > 0 { coverSize = size }
            backingScale = scale
            reloadImageForMouseState()
        }

        // Convert to Cocoa coordinates and position window centered on button
        let cocoaPoint = convertAXToCocoaCoordinates(buttonCenter)
        let x = snapped(cocoaPoint.x - imageSize.width / 2)
        let y = snapped(cocoaPoint.y - imageSize.height / 2)

        let cocoaFrame = NSRect(x: x, y: y, width: imageSize.width, height: imageSize.height)
        appKitStale = false
        setFrame(cocoaFrame, display: true)
        orderFront(nil)
    }

    /// Window-server origin (global top-left) that centers this overlay on `center`.
    func origin(centeredOn center: CGPoint) -> CGPoint {
        CGPoint(x: snapped(center.x - imageSize.width / 2), y: snapped(center.y - imageSize.height / 2))
    }

    /// Records a move the window server already applied.
    func didMoveOnServer(center: CGPoint) {
        buttonCenter = center
        appKitStale = true
    }

    /// AppKit fallback when SkyLight transactions are unavailable.
    func move(center: CGPoint) {
        buttonCenter = center
        repositionOnCenter()
    }

    /// Masks out the parts covered by `covers` (global top-left frames). Clicks
    /// fall through the masked parts because they draw nothing.
    func clip(covering covers: [CGRect]) {
        let frame = CGRect(origin: origin(centeredOn: buttonCenter), size: imageSize)
        let bounds = CGRect(origin: .zero, size: imageSize)
        // Flip each covered part into the view's bottom-left coordinates.
        let covered: [CGRect] = covers.compactMap { cover in
            let part = cover.intersection(frame)
            guard !part.isNull, !part.isEmpty else { return nil }
            return CGRect(x: part.minX - frame.minX, y: frame.maxY - part.maxY, width: part.width, height: part.height)
        }
        guard covered != clipRects, let layer = imageView.layer else { return }
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

        // Fully covered overlays must not catch clicks meant for the covering window.
        ignoresMouseEvents = covered.contains { $0.contains(bounds) }
    }

    /// Tells AppKit where the window server already has the overlay. Deferred
    /// until motion stops so the AppKit round-trip stays off the hot path.
    func syncAppKitFrame() {
        guard appKitStale else { return }
        repositionOnCenter()
    }

    override func mouseDown(with event: NSEvent) {
        isMouseDown = true
        loadPressedImage()
    }

    override func mouseUp(with event: NSEvent) {
        // Only perform action if mouse is still inside
        if isMouseDown && isMouseInside {
            press(retry: true)
        }
        isMouseDown = false
        // Restore appropriate image
        if isMouseInside {
            loadHoverImage()
        } else {
            loadCustomImage()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        // Check if mouse is still within bounds
        let location = event.locationInWindow
        let inside = contentView?.bounds.contains(location) ?? false

        if inside != isMouseInside {
            isMouseInside = inside
            if isMouseDown {
                if inside {
                    loadPressedImage()
                } else {
                    loadCustomImage()
                }
            }
        }
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

    override func mouseEntered(with event: NSEvent) {
        isMouseInside = true
        if isMouseDown {
            loadPressedImage()
        } else {
            loadHoverImage()
        }
        NSCursor.arrow.push()
    }

    override func mouseExited(with event: NSEvent) {
        isMouseInside = false
        if !isMouseDown {
            loadCustomImage()
        }
        NSCursor.pop()
    }
}
