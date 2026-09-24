// Tracks button positions for ALL visible windows across all apps
import Cocoa
import ApplicationServices
import QuartzCore

class MultiWindowTracker {
    private var overlayManagers: [CGWindowID: OverlayManager] = [:]
    private var displayLink: CVDisplayLink?
    private var dragEndTimers: [CGWindowID: Timer] = [:]
    private var draggingWindows: Set<CGWindowID> = []

    // Track which PIDs we've set up observers for
    private var axObservers: [pid_t: AXObserver] = [:]

    func startTracking() {
        setupDisplayLink()

        // Watch for app launches/terminations
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appLaunched),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appTerminated),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )

        // Initial scan
        updateAllWindows()
    }

    func stopTracking() {
        if let link = displayLink {
            CVDisplayLinkStop(link)
            displayLink = nil
        }

        // Clean up all observers
        for (_, observer) in axObservers {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        axObservers.removeAll()

        // Remove all overlays
        for (_, manager) in overlayManagers {
            manager.removeAllOverlays()
        }
        overlayManagers.removeAll()

        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    private func setupDisplayLink() {
        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard let displayLink = link else { return }

        let callback: CVDisplayLinkOutputCallback = { _, _, _, _, _, userInfo -> CVReturn in
            guard let userInfo = userInfo else { return kCVReturnSuccess }
            let tracker = Unmanaged<MultiWindowTracker>.fromOpaque(userInfo).takeUnretainedValue()
            DispatchQueue.main.async {
                tracker.updateAllWindows()
            }
            return kCVReturnSuccess
        }

        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        CVDisplayLinkSetOutputCallback(displayLink, callback, userInfo)
        CVDisplayLinkStart(displayLink)
        self.displayLink = displayLink
    }

    @objc private func appLaunched(_ notification: Notification) {
        // New app launched - will be picked up on next update cycle
        updateAllWindows()
    }

    @objc private func appTerminated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        let pid = app.processIdentifier

        // Remove observer for this app
        if let observer = axObservers[pid] {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
            axObservers.removeValue(forKey: pid)
        }

        // Clean up will happen in updateAllWindows when windows are no longer visible
        updateAllWindows()
    }

    private func updateAllWindows() {
        // Get all on-screen windows
        let windowListOptions: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowInfoList = CGWindowListCopyWindowInfo(windowListOptions, kCGNullWindowID) as? [[String: Any]] else {
            return
        }

        var visibleWindowIDs: Set<CGWindowID> = []
        let myPID = ProcessInfo.processInfo.processIdentifier
        let myBundleID = Bundle.main.bundleIdentifier

        for windowInfo in windowInfoList {
            guard let windowID = windowInfo[kCGWindowNumber as String] as? CGWindowID,
                  let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = windowInfo[kCGWindowLayer as String] as? Int else {
                continue
            }

            // Skip our own windows
            if ownerPID == myPID { continue }

            // Skip if it's a menu bar, dock, or other system UI (layer != 0)
            if layer != 0 { continue }

            // Skip windows without bounds (not real windows)
            guard let boundsDict = windowInfo[kCGWindowBounds as String] as? [String: CGFloat],
                  let width = boundsDict["Width"], let height = boundsDict["Height"],
                  width > 50 && height > 50 else {
                continue
            }

            // Get the app for this PID
            guard let app = NSRunningApplication(processIdentifier: ownerPID),
                  app.activationPolicy == .regular,
                  app.bundleIdentifier != myBundleID else {
                continue
            }

            visibleWindowIDs.insert(windowID)

            // Get or create overlay manager for this window
            if overlayManagers[windowID] == nil {
                overlayManagers[windowID] = OverlayManager()
            }

            // Update overlays for this window
            updateWindow(windowID: windowID, pid: ownerPID)
        }

        // Remove overlays for windows that are no longer visible
        let removedIDs = Set(overlayManagers.keys).subtracting(visibleWindowIDs)
        for windowID in removedIDs {
            overlayManagers[windowID]?.removeAllOverlays()
            overlayManagers.removeValue(forKey: windowID)
            dragEndTimers[windowID]?.invalidate()
            dragEndTimers.removeValue(forKey: windowID)
            draggingWindows.remove(windowID)
        }
    }

    private func updateWindow(windowID: CGWindowID, pid: pid_t) {
        guard let manager = overlayManagers[windowID] else { return }

        // Skip if dragging and hide-on-drag is enabled
        if draggingWindows.contains(windowID) {
            return
        }

        let appRef = AXUIElementCreateApplication(pid)

        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else {
            manager.hideOverlays()
            return
        }

        // Find the AXUIElement that corresponds to this CGWindowID
        // We need to match by position/size since there's no direct mapping
        guard let windowInfo = getWindowInfo(windowID: windowID),
              let boundsDict = windowInfo[kCGWindowBounds as String] as? [String: CGFloat],
              let targetX = boundsDict["X"],
              let targetY = boundsDict["Y"],
              let targetW = boundsDict["Width"],
              let targetH = boundsDict["Height"] else {
            manager.hideOverlays()
            return
        }

        // Find matching AX window by position
        var matchedWindow: AXUIElement?
        for window in windows {
            var posRef: CFTypeRef?
            var sizeRef: CFTypeRef?

            guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
                  AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success else {
                continue
            }

            var pos = CGPoint.zero
            var size = CGSize.zero
            AXValueGetValue(posRef as! AXValue, .cgPoint, &pos)
            AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)

            // Match with some tolerance for frame differences
            if abs(pos.x - targetX) < 5 && abs(pos.y - targetY) < 5 &&
               abs(size.width - targetW) < 5 && abs(size.height - targetH) < 5 {
                matchedWindow = window
                break
            }
        }

        guard let window = matchedWindow else {
            manager.hideOverlays()
            return
        }

        guard let frames = getButtonFrames(for: window) else {
            manager.hideOverlays()
            return
        }

        manager.updateOverlays(for: window, frames: frames)
    }

    private func getWindowInfo(windowID: CGWindowID) -> [String: Any]? {
        guard let windowInfoList = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
              let windowInfo = windowInfoList.first else {
            return nil
        }
        return windowInfo
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

    func hideAllOverlays() {
        for (_, manager) in overlayManagers {
            manager.hideOverlays()
        }
    }

    func showAllOverlays() {
        for (_, manager) in overlayManagers {
            manager.showOverlays()
        }
    }

    func reloadAllImages() {
        for (_, manager) in overlayManagers {
            manager.reloadImages()
        }
    }
}
