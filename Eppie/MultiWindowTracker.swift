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
// Button overlays can't be ordered directly above another app's window, so they
// stay floating and are clipped wherever a window in front of their target
// covers them. Borders sit in the window stack directly below their target and
// are put back there after raises.
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
    private var resizeFollowUps: [CGWindowID: DispatchWorkItem] = [:]
    private var reorderQueued = false
    // The Dock's full-screen windows, one per display. They come on screen for
    // Mission Control and App Exposé but also when an auto-hidden Dock slides
    // in, so a shown event only prompts a scan that looks for the shield below.
    private var dockWindows: Set<CGWindowID> = []
    private var lastDockEvent: CFAbsoluteTime = 0
    private var scanTimer: Timer?
    private var scanQueued = false
    private var clippingQueued = false
    // CGWindowListCopyWindowInfo can block for hundreds of ms while the window
    // server is busy, so it's read here and applied on main.
    private let windowListQueue = DispatchQueue(label: "Trois.windowlist", qos: .userInteractive)
    private var scanInFlight = false
    private var scanAgain = false
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
    // Bumped by stopTracking() so AX results and window lists from before it are dropped.
    private var generation = 0
    private let buttonWatcher = ButtonWatcher()
    private var windowPIDs: [CGWindowID: pid_t] = [:]
    // Extra reads made because button offsets kept changing, per window.
    private var followUpReads: [CGWindowID: Int] = [:]

    // Motion is considered over this long after the last move event.
    private static let settleDelay: TimeInterval = 0.1
    private static let maxFollowUpReads = 3
    private static let rejectRetry: CFAbsoluteTime = 1.0
    // Resize events can arrive before the window server's final size.
    private static let resizeFollowUpDelay: TimeInterval = 0.032
    // A reorder event can come before the app finishes raising its other windows.
    private static let reorderDelay: TimeInterval = 0.03
    // A scan's window list can predate a Dock event, so it only corrects state after this long.
    private static let dockEventGrace: CFAbsoluteTime = 0.5

    // Bounds are global top-left, the same space as CGDisplayBounds.
    private static func coversDisplay(_ bounds: CGRect) -> Bool {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return false }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return false }
        return displays.prefix(Int(count)).contains { CGDisplayBounds($0) == bounds }
    }

    init(allWindows: Bool) {
        self.allWindows = allWindows
    }

    func startTracking() {
        buttonWatcher.start()
        buttonWatcher.buttonsChanged = { [weak self] wid in
            self?.buttonsChanged(wid)
        }
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

        findDockWindows()
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
        dockWindows = []
        BorderWindow.hiddenForMissionControl = false
        stack = []
        frames = [:]
        generation += 1
        scanInFlight = false
        scanAgain = false
        lookingUp = []
        seenWindows = []
        focusedWID = nil
        focusQueryInFlight = false

        for wid in Array(overlayManagers.keys) {
            removeWindow(wid)
        }
        buttonWatcher.stop()
        rejected.removeAll()

        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func workspaceChanged(_ notification: Notification) {
        if notification.name == NSWorkspace.didLaunchApplicationNotification,
           let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
           app.bundleIdentifier == "com.apple.dock" {
            findDockWindows()
        }
        scan()
    }

    @objc private func screensChanged(_ notification: Notification) {
        // The primary screen height used for AppKit coordinates may have changed.
        for manager in overlayManagers.values {
            manager.refresh()
        }
        findDockWindows()
        scan()
    }

    // Looks through all windows, on screen or not, so it runs off main.
    private func findDockWindows() {
        let generation = self.generation
        windowListQueue.async { [weak self] in
            let dockPIDs = Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").map(\.processIdentifier))
            let infoList = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
            var found: Set<CGWindowID> = []
            for info in infoList {
                guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, dockPIDs.contains(pid),
                      info[kCGWindowLayer as String] as? Int == Int(CGWindowLevelForKey(.dockWindow)),
                      let wid = info[kCGWindowNumber as String] as? CGWindowID else { continue }
                found.insert(wid)
            }
            DispatchQueue.main.async {
                guard let self, generation == self.generation else { return }
                self.dockWindows = found
                self.updateSubscription()
            }
        }
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
        if dockWindows.contains(wid) {
            if event == WindowServerEvents.hidden {
                lastDockEvent = CFAbsoluteTimeGetCurrent()
                BorderWindow.hiddenForMissionControl = false
            } else if event == WindowServerEvents.shown {
                // The shield can come on screen a moment after the Dock window.
                queueScan()
                for delay in [0.05, 0.15] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.scan() }
                }
            }
            return
        }
        // A raise changes which windows cover which. Rebuild the stack from
        // the window list rather than guessing where the window landed.
        // Reorders fire for menus and tooltips too; only normal windows matter.
        if event == WindowServerEvents.reordered {
            if frames[wid] != nil {
                // The raised window's border follows at once; the pass catches
                // the rest of an app's windows raised along with it.
                overlayManagers[wid]?.reorderBorder()
                queueScan()
                queueReorder()
            }
            return
        }
        guard let manager = overlayManagers[wid] else { return }
        switch event {
        case WindowServerEvents.moved:
            windowMoved(wid, manager: manager)
        case WindowServerEvents.resized:
            windowResized(wid, manager: manager)
            scheduleResizeFollowUp(wid)
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

    private func windowResized(_ wid: CGWindowID, manager: OverlayManager) {
        guard let frame = WindowServer.bounds(of: wid) else { return }
        frames[wid] = frame
        if !draggingWindows.contains(wid) {
            manager.resize(targetFrame: frame)
        }
        updateClipping()
    }

    // One more read after the last resize event, for the final size.
    private func scheduleResizeFollowUp(_ wid: CGWindowID) {
        resizeFollowUps[wid]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.resizeFollowUps[wid] = nil
            guard let manager = self.overlayManagers[wid] else { return }
            self.windowResized(wid, manager: manager)
        }
        resizeFollowUps[wid] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.resizeFollowUpDelay, execute: work)
    }

    // Raising a window, or an app raising all of its windows, leaves borders
    // behind. Puts every border back below its window in one pass.
    private func queueReorder() {
        guard !reorderQueued else { return }
        reorderQueued = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.reorderDelay) { [weak self] in
            guard let self else { return }
            self.reorderQueued = false
            for manager in self.overlayManagers.values {
                manager.reorderBorder()
            }
        }
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
        // Buttons can move within a window without a resize, and not every app
        // reports it, so re-read them once motion stops.
        manager.refresh()
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

    private func didRefresh(_ wid: CGWindowID, read: WindowRead, changed: Bool) {
        guard let manager = overlayManagers[wid] else { return }
        switch read {
        case .timedOut:
            scheduleRefresh(wid, after: Self.rejectRetry)
        case .unusable:
            buttonWatcher.unwatch(wid)
        case .window(let snapshot):
            if let pid = windowPIDs[wid] {
                buttonWatcher.watch(wid, pid: pid, elements: snapshot.buttonElements)
            }
        }
        // Buttons read mid-animation land somewhere in between. Read again
        // until they hold still.
        let followUps = followUpReads[wid] ?? 0
        if changed && followUps < Self.maxFollowUpReads {
            followUpReads[wid] = followUps + 1
            scheduleRefresh(wid)
        } else {
            followUpReads[wid] = nil
        }
        // A drag may have started while AX was read.
        if draggingWindows.contains(wid) {
            manager.hideOverlays()
        }
        // A new button image or position needs its clip recomputed.
        updateClipping()
    }

    // The app replaced a window's buttons, e.g. Arc showing or hiding its sidebar.
    private func buttonsChanged(_ wid: CGWindowID) {
        guard overlayManagers[wid] != nil else { return }
        followUpReads[wid] = nil
        scheduleRefresh(wid)
    }

    // MARK: - Scan

    // Requests made while a read is in flight are merged into one more read.
    private func scan() {
        guard !scanInFlight else {
            scanAgain = true
            return
        }
        scanInFlight = true
        queryFocus()
        let generation = self.generation
        windowListQueue.async { [weak self] in
            let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
            let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
            DispatchQueue.main.async {
                guard let self, generation == self.generation else { return }
                self.scanInFlight = false
                if let infoList {
                    self.apply(windowList: infoList)
                }
                if self.scanAgain {
                    self.scanAgain = false
                    self.scan()
                }
            }
        }
    }

    private func apply(windowList infoList: [[String: Any]]) {
        let myPID = ProcessInfo.processInfo.processIdentifier
        let myBundleID = Bundle.main.bundleIdentifier

        var candidates: [(wid: CGWindowID, pid: pid_t, frame: CGRect)] = []
        var newStack: [CGWindowID] = []
        var newFrames: [CGWindowID: CGRect] = [:]
        var missionControlShown = false
        let windowManagerPIDs = Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.WindowManager").map(\.processIdentifier))

        for info in infoList {
            guard let wid = info[kCGWindowNumber as String] as? CGWindowID,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = info[kCGWindowLayer as String] as? Int else {
                continue
            }
            if dockWindows.contains(wid) { continue }
            // Mission Control and App Exposé put a full-screen shield from
            // WindowManager just under the Dock. Window names need Screen
            // Recording, so it's matched by owner, level and size instead.
            if windowManagerPIDs.contains(pid), layer > 0,
               let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
               let bounds = CGRect(dictionaryRepresentation: boundsDict),
               Self.coversDisplay(bounds) {
                missionControlShown = true
                continue
            }
            // Skip system UI (layer != 0). Our overlays float, so this also
            // skips them, but our normal windows such as Settings are kept.
            if layer != 0 { continue }
            // Borders share their window's level but are drawn around it, not over others.
            if BorderWindow.isBorder(wid) { continue }

            guard let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: boundsDict) else {
                continue
            }

            // Any visible normal window can cover buttons, tracked or not,
            // Settings included.
            let alpha = info[kCGWindowAlpha as String] as? Double ?? 1
            if alpha > 0 {
                newStack.append(wid)
                newFrames[wid] = frame
            }

            if pid == myPID { continue }
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
        // A list read before a Dock hidden event may still show the shield.
        if CFAbsoluteTimeGetCurrent() - lastDockEvent > Self.dockEventGrace {
            BorderWindow.hiddenForMissionControl = missionControlShown
        }
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
        updateActive()
        updateClipping()

        for (pid, windows) in lookups {
            lookUp(windows, of: pid)
        }
        verifyActiveWindows()
    }

    // Some apps move their buttons without moving the window or posting any AX
    // notification, e.g. Arc's sidebar sliding in on hover or Cmd-S. Checks the
    // windows such changes come from: the one under the mouse and the frontmost
    // app's front window.
    private func verifyActiveWindows() {
        var wids: [CGWindowID] = []
        if let screen = NSScreen.screens.first {
            let mouse = NSEvent.mouseLocation
            let point = CGPoint(x: mouse.x, y: screen.frame.height - mouse.y)
            if let wid = stack.first(where: { frames[$0]?.contains(point) ?? false }) {
                wids.append(wid)
            }
        }
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           let wid = stack.first(where: { windowPIDs[$0] == pid }), !wids.contains(wid) {
            wids.append(wid)
        }
        for wid in wids {
            guard let manager = overlayManagers[wid],
                  settleWork[wid] == nil, refreshWork[wid] == nil else { continue }
            manager.verify()
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
                self?.didLookUp(reads, pid: pid, generation: generation)
            }
        }
    }

    private func didLookUp(_ reads: [(wid: CGWindowID, read: WindowRead)], pid: pid_t, generation: Int) {
        guard generation == self.generation else { return }
        let now = CFAbsoluteTimeGetCurrent()
        for (wid, read) in reads {
            lookingUp.remove(wid)
            // The window may have closed or lost focus while AX was read.
            guard seenWindows.contains(wid), overlayManagers[wid] == nil else { continue }
            let manager = OverlayManager(targetWID: wid, pid: pid)
            guard manager.apply(read) else {
                manager.removeAllOverlays()
                rejected[wid] = now
                continue
            }
            manager.didRefresh = { [weak self] read, changed in
                self?.didRefresh(wid, read: read, changed: changed)
            }
            manager.didChangeShape = { [weak self] in
                self?.queueClipping()
            }
            rejected[wid] = nil
            overlayManagers[wid] = manager
            windowPIDs[wid] = pid
            if case .window(let snapshot) = read {
                buttonWatcher.watch(wid, pid: pid, elements: snapshot.buttonElements)
            }
        }
        updateSubscription()
        updateActive()
        updateClipping()
    }

    // Coalesces shape changes, e.g. every border redrawing on a focus change,
    // into one clipping pass.
    private func queueClipping() {
        guard !clippingQueued else { return }
        clippingQueued = true
        DispatchQueue.main.async { [weak self] in
            self?.clippingQueued = false
            self?.updateClipping()
        }
    }

    // Clips each window's overlays to the parts not covered by windows in front
    // of it, borders included.
    private func updateClipping() {
        var covers: [CGRect] = []
        for wid in stack {
            let manager = overlayManagers[wid]
            manager?.clip(covering: covers)
            if let frame = frames[wid] {
                covers.append(contentsOf: manager?.coverRects(for: frame) ?? [frame])
            }
        }
    }

    // The focused window of the frontmost app draws the active frame.
    private func updateActive() {
        for (wid, manager) in overlayManagers {
            manager.setActive(wid == focusedWID)
        }
    }

    private func removeWindow(_ wid: CGWindowID) {
        overlayManagers[wid]?.removeAllOverlays()
        overlayManagers[wid] = nil
        settleWork[wid]?.cancel()
        settleWork[wid] = nil
        refreshWork[wid]?.cancel()
        refreshWork[wid] = nil
        resizeFollowUps[wid]?.cancel()
        resizeFollowUps[wid] = nil
        draggingWindows.remove(wid)
        buttonWatcher.unwatch(wid)
        windowPIDs[wid] = nil
        followUpReads[wid] = nil
    }

    private func updateSubscription() {
        let wids = Set(overlayManagers.keys).union(dockWindows).sorted()
        guard wids != subscribed else { return }
        subscribed = wids
        WindowServerEvents.subscribe(wids)
    }

    // MARK: - AX lookup

    // Scans with the last known focus and scans again if the answer differs.
    // Borders need it in all-windows mode too, to draw the focused one active.
    private func queryFocus() {
        guard !focusQueryInFlight else { return }
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

// Watches tracked windows' button elements for AXUIElementDestroyed. Some apps
// rebuild their buttons without moving or resizing the window, which fires no
// window-server event. Arc does it when its sidebar is shown or hidden.
final class ButtonWatcher {
    // Called on main with the window whose buttons went away.
    var buttonsChanged: ((CGWindowID) -> Void)?
    private var observers: [pid_t: AXObserver] = [:]
    private var watched: [CGWindowID: (pid: pid_t, elements: [AXUIElement])] = [:]

    // AX callbacks can't capture, so they reach the live watcher through here.
    private static weak var current: ButtonWatcher?

    // The refcon carries the window id rather than a pointer, so a callback
    // arriving after unwatch() finds nothing to free and at worst triggers a
    // spare refresh.
    private static let callback: AXObserverCallback = { _, _, _, refcon in
        let wid = CGWindowID(UInt(bitPattern: refcon))
        ButtonWatcher.current?.buttonsChanged?(wid)
    }

    func start() {
        Self.current = self
    }

    func stop() {
        for wid in Array(watched.keys) {
            unwatch(wid)
        }
        if Self.current === self {
            Self.current = nil
        }
    }

    /// Watches `elements` in place of whatever was watched for `wid`.
    func watch(_ wid: CGWindowID, pid: pid_t, elements: [AXUIElement]) {
        if let old = watched[wid], old.elements.count == elements.count,
           zip(old.elements, elements).allSatisfy({ CFEqual($0, $1) }) {
            return
        }
        unwatch(wid)
        guard !elements.isEmpty, let observer = observer(for: pid) else { return }
        watched[wid] = (pid, elements)
        let refcon = UnsafeMutableRawPointer(bitPattern: UInt(wid))
        // Adding a notification messages the app, so it can block.
        AXQueue.async {
            for element in elements {
                AXObserverAddNotification(observer, element, kAXUIElementDestroyedNotification as CFString, refcon)
            }
        }
    }

    func unwatch(_ wid: CGWindowID) {
        guard let entry = watched.removeValue(forKey: wid) else { return }
        guard let observer = observers[entry.pid] else { return }
        AXQueue.async {
            for element in entry.elements {
                AXObserverRemoveNotification(observer, element, kAXUIElementDestroyedNotification as CFString)
            }
        }
        if !watched.values.contains(where: { $0.pid == entry.pid }) {
            observers[entry.pid] = nil
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
    }

    private func observer(for pid: pid_t) -> AXObserver? {
        if let observer = observers[pid] {
            return observer
        }
        var observer: AXObserver?
        guard AXObserverCreate(pid, Self.callback, &observer) == .success, let observer else { return nil }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        observers[pid] = observer
        return observer
    }
}
