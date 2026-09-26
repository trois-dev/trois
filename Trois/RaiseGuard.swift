// Lifts a window's frame and buttons just before the window is raised.
import Cocoa

// A raise puts the target at the top of its level, over our raw windows, and
// they only get back in place once the reordered event arrives, a frame or so
// later. Buttons flash off and the frame is cut off meanwhile. A mouse-down on
// a target (or its frame, which raises it) reaches an event tap before the app
// sees it, so the tap moves our windows up one sub-level first. A higher
// sub-level changes nothing on screen by itself, but the raise can't pass it.
// Cmd-Tab raises an app's windows some 15 to 60 ms after the front app
// changes, so the tracker lifts that app's windows on that event too, leaving
// out those another of its windows covers. A Dock click raises them before
// the front app changes, some 40 ms after the mouse-up, so a mouse-down on a
// Dock icon lifts that app's windows from the tracker's per-app snapshot.
// The reordered event for a raise can arrive before the raise is done, so a
// lift doesn't end there: placements keep it until a moment after the
// mouse-up or the switch, and then a reorder puts the windows back at the
// target's sub-level, directly above or below the now frontmost target.
enum RaiseGuard {
    private static var lock = os_unfair_lock()
    // Our raw windows for each target.
    private static var windows: [CGWindowID: [CGWindowID]] = [:]
    // Frame windows back to their target, since clicking a frame raises it too.
    private static var frameTargets: [CGWindowID: CGWindowID] = [:]
    // Lifted windows by target, with the lift's serial.
    private static var lifted: [CGWindowID: (serial: Int, wids: Set<CGWindowID>)] = [:]
    private static var liftSerial = 0
    // The target of the last click lift, while that lift lasts.
    private static var clicked: (target: CGWindowID, serial: Int)?
    // What to lift when an app is brought forward, by app bundle path, and
    // the Dock's pid, both from the tracker.
    private static var appEntries: [String: [CGWindowID: [CGWindowID]]] = [:]
    private static var dockPID: pid_t = 0
    private static var tap: CFMachPort?
    // How long a lift lasts: after the mouse-up for a click, after the lift
    // for an app switch.
    private static let holdAfterUp: TimeInterval = 0.4
    private static let holdForSwitch: TimeInterval = 0.5
    // Called on main when a lift ends, to put that target's windows back.
    static var didEnd: ((CGWindowID) -> Void)?

    /// Records `ours`, the raw windows placed around `target`, and `frame`,
    /// the one of them a click on raises the target.
    static func set(_ ours: [CGWindowID], frame: CGWindowID?, for target: CGWindowID) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        frameTargets = frameTargets.filter { $0.value != target }
        if ours.isEmpty {
            windows[target] = nil
            lifted[target] = nil
        } else {
            windows[target] = ours
            if let frame { frameTargets[frame] = target }
        }
    }

    static func remove(_ target: CGWindowID) {
        set([], frame: nil, for: target)
    }

    /// Sub-levels above its target's that our window `wid` sits at now.
    static func lift(of wid: CGWindowID) -> Int32 {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return lifted.values.contains { $0.wids.contains(wid) } ? 1 : 0
    }

    /// Records what to lift for each app, by bundle path, should its Dock
    /// icon be clicked. Call when the window stack changes.
    static func setAppEntries(_ entries: [String: [CGWindowID: [CGWindowID]]], dock: pid_t) {
        os_unfair_lock_lock(&lock)
        appEntries = entries
        dockPID = dock
        os_unfair_lock_unlock(&lock)
    }

    /// The window a click is raising, if a click lift is on.
    static var clickedTarget: CGWindowID? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard let clicked, lifted[clicked.target]?.serial == clicked.serial else { return nil }
        return clicked.target
    }

    /// Lifts some of our windows per target, for an app switch about to raise
    /// the targets. Windows already lifted stay lifted.
    static func lift(_ entries: [CGWindowID: [CGWindowID]]) {
        let made = liftWindows(entries)
        scheduleEnds(made, after: holdForSwitch)
    }

    /// Installs the tap on its own thread, so a busy main thread never holds
    /// up clicks. Does nothing without Accessibility.
    static func start() {
        guard tap == nil, SkyLight.transactionSetSubLevel != nil else { return }
        let mask = CGEventMask(1 << CGEventType.leftMouseDown.rawValue | 1 << CGEventType.leftMouseUp.rawValue)
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                           options: .defaultTap, eventsOfInterest: mask,
                                           callback: callback, userInfo: nil) else { return }
        tap = port
        let thread = Thread {
            let source = CFMachPortCreateRunLoopSource(nil, port, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            CFRunLoopRun()
        }
        thread.name = "RaiseGuard"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    // Returns the event untouched; the tap only has to run before delivery.
    private static let callback: CGEventTapCallBack = { _, type, event, _ in
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .leftMouseDown:
            liftTarget(at: event.location)
        case .leftMouseUp:
            os_unfair_lock_lock(&lock)
            let current = lifted.mapValues(\.serial)
            os_unfair_lock_unlock(&lock)
            scheduleEnds(current, after: holdAfterUp)
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    private static func liftTarget(at point: CGPoint) {
        guard let (hit, owner) = WindowServer.windowAndOwner(at: point) else { return }
        os_unfair_lock_lock(&lock)
        let target = windows[hit] != nil ? hit : frameTargets[hit]
        let ours = target.flatMap { windows[$0] }
        let dock = dockPID
        os_unfair_lock_unlock(&lock)
        if target == nil, owner != 0, owner == dock {
            liftDockApp(at: point, dock: dock)
            return
        }
        if let target, let ours, let serial = liftWindows([target: ours])[target] {
            os_unfair_lock_lock(&lock)
            clicked = (target, serial)
            os_unfair_lock_unlock(&lock)
        }
    }

    // Lifts the windows of the app whose Dock icon is under `point`. The Dock
    // brings an app's windows forward before it becomes the front app.
    private static func liftDockApp(at point: CGPoint, dock: pid_t) {
        let app = AXUIElementCreateApplication(dock)
        // The mouse-down waits on this, so the Dock gets little time.
        AXUIElementSetMessagingTimeout(app, 0.05)
        var element: AXUIElement?
        var value: CFTypeRef?
        guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &element) == .success,
              let element,
              AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == CFURLGetTypeID() else { return }
        let path = (value as! URL).standardizedFileURL.path
        os_unfair_lock_lock(&lock)
        let entries = appEntries[path] ?? [:]
        os_unfair_lock_unlock(&lock)
        _ = liftWindows(entries)
    }

    // Moves the given windows up one sub-level in one commit. Returns the
    // lifts made, by target and serial.
    private static func liftWindows(_ entries: [CGWindowID: [CGWindowID]]) -> [CGWindowID: Int] {
        var made: [CGWindowID: Int] = [:]
        var ours: [(target: CGWindowID, wids: [CGWindowID])] = []
        os_unfair_lock_lock(&lock)
        for (target, wids) in entries where !wids.isEmpty && windows[target] != nil {
            liftSerial += 1
            // A click lift and the app switch it causes add up.
            let all = Set(wids).union(lifted[target]?.wids ?? [])
            lifted[target] = (liftSerial, all)
            made[target] = liftSerial
            ours.append((target, wids))
            if clicked?.target == target { clicked?.serial = liftSerial }
        }
        os_unfair_lock_unlock(&lock)
        guard !ours.isEmpty,
              let create = SkyLight.transactionCreate, let commit = SkyLight.transactionCommit,
              let setSubLevel = SkyLight.transactionSetSubLevel,
              let tx = create(SkyLight.cid)?.takeRetainedValue() else { return made }
        for entry in ours {
            let subLevel = WindowServer.subLevel(of: entry.target) + 1
            for wid in entry.wids {
                _ = setSubLevel(tx, wid, subLevel)
            }
        }
        _ = commit(tx, 0)
        return made
    }

    // Ends the given lifts after `delay` unless they already ended or a later
    // lift replaced them.
    private static func scheduleEnds(_ lifts: [CGWindowID: Int], after delay: TimeInterval) {
        guard !lifts.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            for (target, serial) in lifts {
                os_unfair_lock_lock(&lock)
                let ended = lifted[target]?.serial == serial
                if ended { lifted[target] = nil }
                os_unfair_lock_unlock(&lock)
                if ended { didEnd?(target) }
            }
        }
    }
}
