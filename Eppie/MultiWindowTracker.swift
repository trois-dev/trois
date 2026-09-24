// Tracks traffic-light buttons of visible windows and keeps overlays pinned to them.
import Cocoa
import ApplicationServices

struct ButtonFrames: Equatable {
    var close: CGRect?
    var minimize: CGRect?
    var zoom: CGRect?
}

// Motion comes from window-server move/resize events, so overlays follow at
// window-server latency without AX reads. AX is only read when a window is
// first seen or its size changes, on AXQueue so a slow app can't stall motion.
// A periodic scan picks up new and closed windows and focus changes.
//
// Overlays can't be ordered directly above another app's window, so they stay
// floating and are clipped wherever a window in front of their target covers them.
class MultiWindowTracker {
    // False follows only the focused window of the frontmost app.
    private let allWindows: Bool
    private var overlayManagers: [CGWindowID: OverlayManager] = [:]
    // Windows with no AX match or no buttons, with when they were last tried.
    private var rejected: [CGWindowID: CFAbsoluteTime] = [:]
    private var subscribed: [CGWindowID] = []
    private var draggingWindows: Set<CGWindowID> = []
    private var settleWork: [CGWindowID: DispatchWorkItem] = [:]
    private var refreshWork: [CGWindowID: DispatchWorkItem] = [:]
    private var scanTimer: Timer?
    private var scanQueued = false
    // Normal-level windows of other apps, front to back, and their frames in
    // global top-left coordinates. Used to clip overlays that are covered.
    private var stack: [CGWindowID] = []
    private var frames: [CGWindowID: CGRect] = [:]
    private var mouseMonitor: Any?
    // Windows whose first AX lookup is in flight, and the windows the last scan saw.
    private var lookingUp: Set<CGWindowID> = []
    private var seenWindows: Set<CGWindowID> = []
    // Focused window of the frontmost app, when not following all windows.
    private var focusedWID: CGWindowID?
    private var focusQueryInFlight = false
    // Bumped by stopTracking() so AX results from before it are dropped.
    private var generation = 0

    // Motion is considered over this long after the last move event.
    private static let settleDelay: TimeInterval = 0.1
    private static let rejectRetry: CFAbsoluteTime = 1.0

    init(allWindows: Bool) {
        self.allWindows = allWindows
    }

    func startTracking() {
        WindowServerEvents.start()
        WindowServerEvents.handler = { [weak self] event, wid in
            self?.handle(event: event, wid: wid)
        }

        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.activeSpaceDidChangeNotification] {
            center.addObserver(self, selector: #selector(workspaceChanged), name: name, object: nil)
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        // A click can raise a window or focus another window of the same app,
        // which posts no workspace notification. The app does that after the
        // click, so check a few times shortly after instead of waiting for the
        // next scan.
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            for delay in [0.03, 0.1, 0.25] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self?.scan() }
            }
        }

        // Without window-server events the scan is also what moves overlays.
        let interval: TimeInterval = WindowServerEvents.isAvailable ? 0.1 : 1.0 / 60.0
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.scan()
        }
        RunLoop.main.add(timer, forMode: .common)
        scanTimer = timer

        scan()
    }

    func stopTracking() {
        scanTimer?.invalidate()
        scanTimer = nil
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
        }
        mouseMonitor = nil
        WindowServerEvents.handler = nil
        WindowServerEvents.subscribe([])
        subscribed = []
        stack = []
        frames = [:]
        generation += 1
        lookingUp = []
        seenWindows = []
        focusedWID = nil
        focusQueryInFlight = false

        for wid in Array(overlayManagers.keys) {
            removeWindow(wid)
        }
        rejected.removeAll()

        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func workspaceChanged(_ notification: Notification) {
        scan()
    }

    @objc private func screensChanged(_ notification: Notification) {
        // The primary screen height used for AppKit coordinates may have changed.
        for manager in overlayManagers.values {
            manager.refresh()
        }
        scan()
    }

    // Coalesces bursts of requests into one scan on the next run loop pass.
    private func queueScan() {
        guard !scanQueued else { return }
        scanQueued = true
        DispatchQueue.main.async { [weak self] in
            self?.scanQueued = false
            self?.scan()
        }
    }

    // MARK: - Window-server events

    private func handle(event: UInt32, wid: CGWindowID) {
        // A raise changes which windows cover which. Rebuild the stack from
        // the window list rather than guessing where the window landed.
        // Reorders fire for menus and tooltips too; only normal windows matter.
        if event == WindowServerEvents.reordered {
            if frames[wid] != nil {
                queueScan()
            }
            return
        }
        guard let manager = overlayManagers[wid] else { return }
        switch event {
        case WindowServerEvents.moved:
            windowMoved(wid, manager: manager)
        case WindowServerEvents.resized:
            if let frame = WindowServer.bounds(of: wid) {
                frames[wid] = frame
                if !draggingWindows.contains(wid) {
                    manager.follow(targetFrame: frame)
                }
                updateClipping()
            }
            scheduleRefresh(wid)
        case WindowServerEvents.destroyed:
            removeWindow(wid)
            updateSubscription()
        default:
            break
        }
    }

    private func windowMoved(_ wid: CGWindowID, manager: OverlayManager) {
        let frame = WindowServer.bounds(of: wid)
        if let frame {
            frames[wid] = frame
        }
        if UserDefaults.standard.bool(forKey: "hideButtonsOnDrag") {
            if draggingWindows.insert(wid).inserted {
                manager.hideOverlays()
            }
        } else if let frame {
            manager.follow(targetFrame: frame)
        }
        // The moved window may now cover or uncover buttons of windows behind it.
        updateClipping()
        scheduleSettle(wid)
    }

    private func scheduleSettle(_ wid: CGWindowID) {
        settleWork[wid]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.settle(wid)
        }
        settleWork[wid] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay, execute: work)
    }

    private func settle(_ wid: CGWindowID) {
        settleWork[wid] = nil
        guard let manager = overlayManagers[wid] else { return }
        if draggingWindows.remove(wid) != nil {
            if let frame = WindowServer.bounds(of: wid) {
                manager.follow(targetFrame: frame)
            }
            manager.showOverlays()
            updateClipping()
        }
        manager.syncAppKitFrames()
    }

    // Live resizes fire resized every frame; read AX once they pause.
    private func scheduleRefresh(_ wid: CGWindowID, after delay: TimeInterval = settleDelay) {
        refreshWork[wid]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.refreshWork[wid] = nil
            guard !self.draggingWindows.contains(wid) else { return }
            self.overlayManagers[wid]?.refresh()
        }
        refreshWork[wid] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func didRefresh(_ wid: CGWindowID, read: WindowRead) {
        guard let manager = overlayManagers[wid] else { return }
        if case .timedOut = read {
            scheduleRefresh(wid, after: Self.rejectRetry)
        }
        // A drag may have started while AX was read.
        if draggingWindows.contains(wid) {
            manager.hideOverlays()
        }
        // A new button image or position needs its clip recomputed.
        updateClipping()
    }

    // MARK: - Scan

    private func scan() {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return
        }

        let myPID = ProcessInfo.processInfo.processIdentifier
        let myBundleID = Bundle.main.bundleIdentifier
        queryFocus()

        var candidates: [(wid: CGWindowID, pid: pid_t, frame: CGRect)] = []
        var newStack: [CGWindowID] = []
        var newFrames: [CGWindowID: CGRect] = [:]

        for info in infoList {
            guard let wid = info[kCGWindowNumber as String] as? CGWindowID,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = info[kCGWindowLayer as String] as? Int else {
                continue
            }
            // Skip our own windows and system UI (layer != 0)
            if pid == myPID || layer != 0 { continue }

            guard let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: boundsDict) else {
                continue
            }

            // Any visible normal window can cover buttons, tracked or not.
            let alpha = info[kCGWindowAlpha as String] as? Double ?? 1
            if alpha > 0 {
                newStack.append(wid)
                newFrames[wid] = frame
            }

            if !allWindows && wid != focusedWID { continue }

            // Skip windows without real bounds
            guard frame.width > 50 && frame.height > 50 else {
                continue
            }

            guard let app = NSRunningApplication(processIdentifier: pid),
                  app.activationPolicy == .regular,
                  app.bundleIdentifier != myBundleID else {
                continue
            }

            candidates.append((wid, pid, frame))
        }

        stack = newStack
        frames = newFrames
        // Windows in motion have fresher frames from their events.
        for wid in settleWork.keys {
            if let frame = WindowServer.bounds(of: wid) {
                frames[wid] = frame
            }
        }

        let now = CFAbsoluteTimeGetCurrent()
        var lookups: [pid_t: [(wid: CGWindowID, frame: CGRect)]] = [:]
        var seen: Set<CGWindowID> = []

        for candidate in candidates {
            let wid = candidate.wid
            seen.insert(wid)

            if let manager = overlayManagers[wid] {
                // Windows in motion are driven by their events.
                if settleWork[wid] != nil || refreshWork[wid] != nil || manager.isRefreshing { continue }
                if manager.targetFrame.size != candidate.frame.size {
                    manager.refresh()
                } else if manager.targetFrame.origin != candidate.frame.origin {
                    // Only reached when move events were missed or are unavailable.
                    manager.follow(targetFrame: candidate.frame)
                    scheduleSettle(wid)
                }
                continue
            }

            if let tried = rejected[wid], now - tried < Self.rejectRetry { continue }
            if lookingUp.insert(wid).inserted {
                lookups[candidate.pid, default: []].append((wid, candidate.frame))
            }
        }

        for wid in Set(overlayManagers.keys).subtracting(seen) {
            removeWindow(wid)
        }
        seenWindows = seen
        rejected = rejected.filter { seen.contains($0.key) }
        updateSubscription()
        updateClipping()

        for (pid, windows) in lookups {
            lookUp(windows, of: pid)
        }
    }

    // Finds and reads the AX windows for newly seen windows of one app.
    private func lookUp(_ windows: [(wid: CGWindowID, frame: CGRect)], of pid: pid_t) {
        let generation = self.generation
        AXQueue.async { [weak self] in
            let axWindows = Self.axWindows(of: pid)
            let reads = windows.map { window -> (wid: CGWindowID, read: WindowRead) in
                guard let axWindow = Self.matchAXWindow(wid: window.wid, frame: window.frame, in: axWindows) else {
                    return (window.wid, .unusable(frame: nil))
                }
                return (window.wid, OverlayManager.read(axWindow))
            }
            DispatchQueue.main.async {
                self?.didLookUp(reads, generation: generation)
            }
        }
    }

    private func didLookUp(_ reads: [(wid: CGWindowID, read: WindowRead)], generation: Int) {
        guard generation == self.generation else { return }
        let now = CFAbsoluteTimeGetCurrent()
        for (wid, read) in reads {
            lookingUp.remove(wid)
            // The window may have closed or lost focus while AX was read.
            guard seenWindows.contains(wid), overlayManagers[wid] == nil else { continue }
            let manager = OverlayManager(targetWID: wid)
            guard manager.apply(read) else {
                manager.removeAllOverlays()
                rejected[wid] = now
                continue
            }
            manager.didRefresh = { [weak self] read in
                self?.didRefresh(wid, read: read)
            }
            rejected[wid] = nil
            overlayManagers[wid] = manager
        }
        updateSubscription()
        updateClipping()
    }

    // Clips each window's overlays to the parts not covered by windows in front of it.
    private func updateClipping() {
        var covers: [CGRect] = []
        for wid in stack {
            overlayManagers[wid]?.clip(covering: covers)
            if let frame = frames[wid] {
                covers.append(frame)
            }
        }
    }

    private func removeWindow(_ wid: CGWindowID) {
        overlayManagers[wid]?.removeAllOverlays()
        overlayManagers[wid] = nil
        settleWork[wid]?.cancel()
        settleWork[wid] = nil
        refreshWork[wid]?.cancel()
        refreshWork[wid] = nil
        draggingWindows.remove(wid)
    }

    private func updateSubscription() {
        let wids = overlayManagers.keys.sorted()
        guard wids != subscribed else { return }
        subscribed = wids
        WindowServerEvents.subscribe(wids)
    }

    // MARK: - AX lookup

    // Scans with the last known focus and scans again if the answer differs.
    private func queryFocus() {
        guard !allWindows, !focusQueryInFlight else { return }
        focusQueryInFlight = true
        var pid: pid_t?
        if let frontApp = NSWorkspace.shared.frontmostApplication,
           frontApp.bundleIdentifier != Bundle.main.bundleIdentifier {
            pid = frontApp.processIdentifier
        }
        let generation = self.generation
        AXQueue.async { [weak self] in
            let wid = pid.map(Self.focusedWindowID(of:)) ?? .some(nil)
            DispatchQueue.main.async {
                guard let self, generation == self.generation else { return }
                self.focusQueryInFlight = false
                // Nil when the app didn't answer; keep the last known focus.
                if let wid, wid != self.focusedWID {
                    self.focusedWID = wid
                    self.scan()
                }
            }
        }
    }

    // Outer nil when the app didn't answer in time.
    private static func focusedWindowID(of pid: pid_t) -> CGWindowID?? {
        let appRef = AXUIElementCreateApplication(pid)
        var windowRef: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(appRef, kAXFocusedWindowAttribute as CFString, &windowRef)
        if error == .cannotComplete { return nil }
        guard error == .success, let windowRef else { return .some(nil) }
        var wid: CGWindowID = 0
        guard _AXUIElementGetWindow(windowRef as! AXUIElement, &wid) == .success, wid != 0 else { return .some(nil) }
        return wid
    }

    private static func axWindows(of pid: pid_t) -> [AXUIElement] {
        let appRef = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else { return [] }
        return windows
    }

    // Matches by window id, falling back to frame for windows that don't expose one.
    private static func matchAXWindow(wid: CGWindowID, frame: CGRect, in windows: [AXUIElement]) -> AXUIElement? {
        for window in windows {
            var windowID: CGWindowID = 0
            if _AXUIElementGetWindow(window, &windowID) == .success, windowID == wid {
                return window
            }
        }
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
            if abs(pos.x - frame.minX) < 5 && abs(pos.y - frame.minY) < 5 &&
               abs(size.width - frame.width) < 5 && abs(size.height - frame.height) < 5 {
                return window
            }
        }
        return nil
    }

    // MARK: - Appearance

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
