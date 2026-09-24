// Manages overlay windows for button replacement.
import Cocoa
import ApplicationServices

class OverlayManager {
    private var closeOverlay: OverlayWindow?
    private var minimizeOverlay: OverlayWindow?
    private var zoomOverlay: OverlayWindow?
    private var currentWindow: AXUIElement?

    func updateOverlays(for window: AXUIElement, frames: ButtonFrames) {
        currentWindow = window
        let zoomed = isWindowZoomed(window)

        if let closeFrame = frames.close {
            if closeOverlay == nil {
                closeOverlay = OverlayWindow(buttonType: .close)
            }
            closeOverlay?.updateFrame(closeFrame)
            closeOverlay?.targetButton = getButton(for: window, attribute: kAXCloseButtonAttribute as CFString)
            closeOverlay?.alphaValue = 1
        } else {
            closeOverlay?.orderOut(nil)
        }

        if let minimizeFrame = frames.minimize {
            if minimizeOverlay == nil {
                minimizeOverlay = OverlayWindow(buttonType: .minimize)
            }
            minimizeOverlay?.updateFrame(minimizeFrame)
            minimizeOverlay?.targetButton = getButton(for: window, attribute: kAXMinimizeButtonAttribute as CFString)
            minimizeOverlay?.alphaValue = 1
        } else {
            minimizeOverlay?.orderOut(nil)
        }

        if let zoomFrame = frames.zoom {
            if zoomOverlay == nil {
                zoomOverlay = OverlayWindow(buttonType: .zoom)
            }
            zoomOverlay?.updateFrame(zoomFrame)
            zoomOverlay?.targetButton = getButton(for: window, attribute: kAXZoomButtonAttribute as CFString)
            zoomOverlay?.setZoomedState(zoomed)
            zoomOverlay?.alphaValue = 1
        } else {
            zoomOverlay?.orderOut(nil)
        }
    }

    /// Check if window is in zoomed/fullscreen state
    private func isWindowZoomed(_ window: AXUIElement) -> Bool {
        // Check fullscreen attribute first
        var fullscreenRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &fullscreenRef) == .success,
           let isFullscreen = fullscreenRef as? Bool, isFullscreen {
            return true
        }

        // Check if window fills the screen (zoomed but not fullscreen)
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success else {
            return false
        }

        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionRef as! AXValue, .cgPoint, &position)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)

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

    private func getButton(for window: AXUIElement, attribute: CFString) -> AXUIElement? {
        var buttonRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, attribute, &buttonRef) == .success else {
            return nil
        }
        return (buttonRef as! AXUIElement)
    }

    func removeAllOverlays() {
        closeOverlay?.close()
        minimizeOverlay?.close()
        zoomOverlay?.close()
        closeOverlay = nil
        minimizeOverlay = nil
        zoomOverlay = nil
    }

    func hideOverlays() {
        closeOverlay?.alphaValue = 0
        minimizeOverlay?.alphaValue = 0
        zoomOverlay?.alphaValue = 0
    }

    func showOverlays() {
        closeOverlay?.alphaValue = 1
        minimizeOverlay?.alphaValue = 1
        zoomOverlay?.alphaValue = 1
    }

    func reloadImages() {
        closeOverlay?.loadCustomImage()
        minimizeOverlay?.loadCustomImage()
        zoomOverlay?.loadCustomImage()
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
    private var imageView: NSImageView!
    private var trackingArea: NSTrackingArea?
    private var isMouseDown = false
    private var isMouseInside = false
    private var imageSize: NSSize = NSSize(width: 14, height: 14)
    private var buttonCenter: CGPoint = .zero
    private var windowIsZoomed = false

    init(buttonType: TrafficLightType) {
        self.buttonType = buttonType
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 14, height: 14),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        self.level = .floating
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = false
        self.ignoresMouseEvents = false
        self.collectionBehavior = [.canJoinAllSpaces, .stationary]

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

    func loadCustomImage() {
        loadImageForState("")
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
            if isMouseDown {
                loadPressedImage()
            } else if isMouseInside {
                loadHoverImage()
            } else {
                loadCustomImage()
            }
        }
    }

    private func loadImageForState(_ state: String) {
        let defaults = UserDefaults.standard
        let baseKey: String
        switch buttonType {
        case .close: baseKey = "closeButton"
        case .minimize: baseKey = "minimizeButton"
        case .zoom:
            // Use restore images when window is zoomed, maximize images otherwise
            baseKey = windowIsZoomed ? "restoreButton" : "zoomButton"
        }

        let key = baseKey + state + "Image"

        if let path = defaults.string(forKey: key),
           let image = NSImage(contentsOfFile: path) {
            // Normalize image size to pixel dimensions (ignore DPI)
            normalizeImageSize(image)
            imageView.image = image
            // Update size based on image if this is the normal state
            if state.isEmpty {
                updateImageSize(image.size)
            }
        } else if state.isEmpty {
            // Fallback: try zoom button images if restore not available
            if windowIsZoomed {
                let fallbackKey = "zoomButton" + state + "Image"
                if let path = defaults.string(forKey: fallbackKey),
                   let image = NSImage(contentsOfFile: path) {
                    normalizeImageSize(image)
                    imageView.image = image
                    updateImageSize(image.size)
                    return
                }
            }
            // Only fall back to default for normal state
            let defaultImage = createDefaultImage()
            imageView.image = defaultImage
            updateImageSize(defaultImage.size)
        }
        // For hover/pressed, if no image, keep current image
    }

    private func normalizeImageSize(_ image: NSImage) {
        // Set image size to match pixel dimensions, ignoring DPI metadata
        if let rep = image.representations.first {
            let pixelWidth = rep.pixelsWide
            let pixelHeight = rep.pixelsHigh
            if pixelWidth > 0 && pixelHeight > 0 {
                image.size = NSSize(width: pixelWidth, height: pixelHeight)
            }
        }
    }

    private func updateImageSize(_ size: NSSize) {
        // Use pixel dimensions from image representation if available
        var pixelSize = size
        if let image = imageView.image,
           let rep = image.representations.first {
            pixelSize = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }

        imageSize = pixelSize
        imageView.frame = NSRect(origin: .zero, size: pixelSize)
        setContentSize(pixelSize)
        // Re-center on button position
        repositionOnCenter()
    }

    private func repositionOnCenter() {
        guard buttonCenter != .zero else { return }

        let cocoaPoint = convertAXToCocoaCoordinates(buttonCenter)
        let x = cocoaPoint.x - imageSize.width / 2
        let y = cocoaPoint.y - imageSize.height / 2

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

    private func createDefaultImage() -> NSImage {
        let size = NSSize(width: 14, height: 14)
        let image = NSImage(size: size)
        image.lockFocus()

        let color: NSColor
        switch buttonType {
        case .close: color = .systemRed
        case .minimize: color = .systemYellow
        case .zoom: color = .systemGreen
        }

        color.setFill()
        let path = NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: 12, height: 12))
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

        // Convert to Cocoa coordinates and position window centered on button
        let cocoaPoint = convertAXToCocoaCoordinates(buttonCenter)
        let x = cocoaPoint.x - imageSize.width / 2
        let y = cocoaPoint.y - imageSize.height / 2

        let cocoaFrame = NSRect(x: x, y: y, width: imageSize.width, height: imageSize.height)
        setFrame(cocoaFrame, display: true)
        orderFront(nil)
    }

    override func mouseDown(with event: NSEvent) {
        isMouseDown = true
        loadPressedImage()
    }

    override func mouseUp(with event: NSEvent) {
        // Only perform action if mouse is still inside
        if isMouseDown && isMouseInside {
            performButtonAction()
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

    private func performButtonAction() {
        guard let button = targetButton else { return }
        AXUIElementPerformAction(button, kAXPressAction as CFString)
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
