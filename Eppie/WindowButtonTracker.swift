// Tracks window button positions via Accessibility API.
import Cocoa
import ApplicationServices
import QuartzCore

struct ButtonFrames: Equatable {
    var close: CGRect?
    var minimize: CGRect?
    var zoom: CGRect?
}

class WindowButtonTracker {
    private var overlayManager: OverlayManager
    private var displayLink: CVDisplayLink?
    private var currentWindow: AXUIElement?
    private var axObserver: AXObserver?
    private var lastFrames: ButtonFrames?
    private var dragEndTimer: Timer?
    private var isDragging = false

    init(overlayManager: OverlayManager) {
        self.overlayManager = overlayManager
    }

    func startTracking() {
        // Use CVDisplayLink for vsync-aligned updates
        setupDisplayLink()

        // App activation notifications
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appChanged),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )

        // Initial update
        updateCurrentWindow()
        setupAXObserver()
    }

    func stopTracking() {
        if let link = displayLink {
            CVDisplayLinkStop(link)
            displayLink = nil
        }
        removeAXObserver()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        overlayManager.removeAllOverlays()
    }

    private func setupDisplayLink() {
        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard let displayLink = link else { return }

        let callback: CVDisplayLinkOutputCallback = { _, _, _, _, _, userInfo -> CVReturn in
            guard let userInfo = userInfo else { return kCVReturnSuccess }
            let tracker = Unmanaged<WindowButtonTracker>.fromOpaque(userInfo).takeUnretainedValue()
            DispatchQueue.main.async {
                tracker.updateCurrentWindow()
            }
            return kCVReturnSuccess
        }

        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        CVDisplayLinkSetOutputCallback(displayLink, callback, userInfo)
        CVDisplayLinkStart(displayLink)
        self.displayLink = displayLink
    }

    @objc private func appChanged(_ notification: Notification) {
        removeAXObserver()
        currentWindow = nil
        lastFrames = nil
        updateCurrentWindow()
        setupAXObserver()
    }

    private func setupAXObserver() {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }
        if frontApp.bundleIdentifier == Bundle.main.bundleIdentifier { return }

        let pid = frontApp.processIdentifier

        var observer: AXObserver?
        let result = AXObserverCreate(pid, axCallback, &observer)
        guard result == .success, let obs = observer else { return }

        axObserver = obs

        let appRef = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement],
              let window = windows.first else { return }

        currentWindow = window

        // Watch for window changes
        let notifications: [String] = [
            kAXMovedNotification as String,
            kAXResizedNotification as String,
            kAXUIElementDestroyedNotification as String,
            kAXLayoutChangedNotification as String,
            kAXValueChangedNotification as String
        ]

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        for notification in notifications {
            AXObserverAddNotification(obs, window, notification as CFString, selfPtr)
        }

        CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(obs), .defaultMode)
    }

    private func removeAXObserver() {
        if let obs = axObserver {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(obs), .defaultMode)
        }
        axObserver = nil
    }

    private func updateCurrentWindow() {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            overlayManager.hideOverlays()
            return
        }

        // Skip our own app to avoid issues with overlay windows
        if frontApp.bundleIdentifier == Bundle.main.bundleIdentifier {
            overlayManager.hideOverlays()
            return
        }

        let pid = frontApp.processIdentifier
        let appRef = AXUIElementCreateApplication(pid)

        var windowsRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &windowsRef)

        guard result == .success, let windows = windowsRef as? [AXUIElement], let window = windows.first else {
            overlayManager.hideOverlays()
            return
        }

        guard let frames = getButtonFrames(for: window) else {
            overlayManager.hideOverlays()
            return
        }

        lastFrames = frames
        // Always update overlays immediately - they follow the window
        overlayManager.updateOverlays(for: window, frames: frames)
    }

    func handleAXNotification(_ notification: String) {
        if notification == kAXMovedNotification as String {
            handleWindowMove()
        } else if notification == kAXResizedNotification as String ||
                  notification == kAXLayoutChangedNotification as String ||
                  notification == kAXValueChangedNotification as String {
            updateCurrentWindow()
        } else if notification == kAXUIElementDestroyedNotification as String {
            overlayManager.hideOverlays()
            currentWindow = nil
        }
    }

    private func handleWindowMove() {
        let hideOnDrag = UserDefaults.standard.bool(forKey: "hideButtonsOnDrag")

        if hideOnDrag {
            // Hide overlays during drag
            if !isDragging {
                isDragging = true
                overlayManager.hideOverlays()
            }

            // Reset timer - will show overlays when drag ends
            dragEndTimer?.invalidate()
            dragEndTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
                self?.isDragging = false
                self?.updateCurrentWindow()
            }
        } else {
            // Normal behavior - update position during drag
            updateCurrentWindow()
        }
    }

    private func getButtonFrames(for window: AXUIElement) -> ButtonFrames? {
        var frames = ButtonFrames()

        frames.close = getButtonFrame(for: window, attribute: kAXCloseButtonAttribute as CFString)
        frames.minimize = getButtonFrame(for: window, attribute: kAXMinimizeButtonAttribute as CFString)
        frames.zoom = getButtonFrame(for: window, attribute: kAXZoomButtonAttribute as CFString)

        if frames.close != nil || frames.minimize != nil || frames.zoom != nil {
            return frames
        }
        return nil
    }

    private func getButtonFrame(for window: AXUIElement, attribute: CFString) -> CGRect? {
        var buttonRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, attribute, &buttonRef) == .success,
              let button = buttonRef else { return nil }

        let axButton = button as! AXUIElement

        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?

        guard AXUIElementCopyAttributeValue(axButton, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(axButton, kAXSizeAttribute as CFString, &sizeRef) == .success else {
            return nil
        }

        var position = CGPoint.zero
        var size = CGSize.zero

        AXValueGetValue(positionRef as! AXValue, .cgPoint, &position)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)

        return CGRect(origin: position, size: size)
    }
}

// AX callback - must be a C function
private func axCallback(
    observer: AXObserver,
    element: AXUIElement,
    notification: CFString,
    refcon: UnsafeMutableRawPointer?
) {
    guard let refcon = refcon else { return }
    let tracker = Unmanaged<WindowButtonTracker>.fromOpaque(refcon).takeUnretainedValue()
    DispatchQueue.main.async {
        tracker.handleAXNotification(notification as String)
    }
}
