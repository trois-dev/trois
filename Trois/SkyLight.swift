// Private SkyLight bindings for window-server geometry, moves, and events.
import Cocoa
import ApplicationServices

// Maps an AX window to its window-server id.
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ wid: UnsafeMutablePointer<CGWindowID>) -> AXError

// Every symbol is optional. A missing one makes its caller fall back to AppKit or AX.
enum SkyLight {
    static let handle: UnsafeMutableRawPointer? = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

    static func sym<T>(_ name: String) -> T? {
        guard let handle, let symbol = dlsym(handle, name) else { return nil }
        return unsafeBitCast(symbol, to: T.self)
    }

    typealias MainConnectionFn = @convention(c) () -> Int32
    typealias GetWindowBoundsFn = @convention(c) (Int32, UInt32, UnsafeMutablePointer<CGRect>) -> Int32
    typealias TransactionCreateFn = @convention(c) (Int32) -> Unmanaged<CFTypeRef>?
    typealias TransactionCommitFn = @convention(c) (CFTypeRef, Int32) -> Int32
    // (tx, wid, origin). Origin is global top-left, the same space AX uses.
    typealias TransactionMoveFn = @convention(c) (CFTypeRef, UInt32, CGPoint) -> Int32
    typealias NotifyProc = @convention(c) (UInt32, UnsafeMutableRawPointer?, Int, UnsafeMutableRawPointer?) -> Void
    typealias RegisterNotifyProcFn = @convention(c) (NotifyProc, UInt32, UnsafeMutableRawPointer?) -> Int32
    typealias RequestNotificationsFn = @convention(c) (Int32, UnsafeMutablePointer<UInt32>?, Int32) -> Int32

    static let getWindowBounds: GetWindowBoundsFn? = sym("SLSGetWindowBounds")
    static let transactionCreate: TransactionCreateFn? = sym("SLSTransactionCreate")
    static let transactionCommit: TransactionCommitFn? = sym("SLSTransactionCommit")
    static let transactionMove: TransactionMoveFn? = sym("SLSTransactionMoveWindowWithGroup")
    static let registerNotifyProc: RegisterNotifyProcFn? = sym("SLSRegisterNotifyProc")
    // Regions are opaque CGSRegionRef pointers.
    typealias NewRegionWithRectListFn = @convention(c) (UnsafePointer<CGRect>?, Int32, UnsafeMutablePointer<OpaquePointer?>) -> Int32
    typealias DiffRegionFn = @convention(c) (OpaquePointer, OpaquePointer, UnsafeMutablePointer<OpaquePointer?>) -> Int32
    typealias ReleaseRegionFn = @convention(c) (OpaquePointer) -> Int32
    typealias SetWindowEventShapeFn = @convention(c) (Int32, UInt32, OpaquePointer) -> Int32
    static let newRegionWithRectList: NewRegionWithRectListFn? = sym("CGSNewRegionWithRectList")
    static let diffRegion: DiffRegionFn? = sym("CGSDiffRegion")
    static let releaseRegion: ReleaseRegionFn? = sym("CGSReleaseRegion")
    static let setWindowEventShape: SetWindowEventShapeFn? = sym("SLSSetWindowEventShape")
    static let requestNotifications: RequestNotificationsFn? = sym("SLSRequestNotificationsForWindows")

    // Raw window-server windows, for borders that must sit in another app's window stack.
    typealias NewWindowFn = @convention(c) (Int32, Int32, Float, Float, OpaquePointer, UnsafeMutablePointer<UInt32>) -> Int32
    typealias WindowFn = @convention(c) (Int32, UInt32) -> Int32
    typealias SetWindowTagsFn = @convention(c) (Int32, UInt32, UnsafeMutablePointer<UInt64>, Int32) -> Int32
    typealias SetWindowResolutionFn = @convention(c) (Int32, UInt32, Double) -> Int32
    typealias SetWindowOpacityFn = @convention(c) (Int32, UInt32, Bool) -> Int32
    typealias SetWindowAlphaFn = @convention(c) (Int32, UInt32, Float) -> Int32
    typealias SetWindowShapeFn = @convention(c) (Int32, UInt32, Float, Float, OpaquePointer) -> Int32
    typealias WindowContextCreateFn = @convention(c) (Int32, UInt32, CFDictionary?) -> Unmanaged<CGContext>?
    typealias FlushWindowFn = @convention(c) (Int32, UInt32, UnsafeMutableRawPointer?) -> Int32
    typealias ConnectionFn = @convention(c) (Int32) -> Int32
    typealias FreezeWindowFn = @convention(c) (Int32, UInt32, CFTypeRef?) -> Int32
    typealias SetShadowPropertiesFn = @convention(c) (UInt32, CFDictionary) -> Int32
    // (tx, wid, order, relative wid). Order 1 is above, -1 below, 0 out.
    typealias TransactionOrderFn = @convention(c) (CFTypeRef, UInt32, Int32, UInt32) -> Int32
    typealias TransactionSetLevelFn = @convention(c) (CFTypeRef, UInt32, Int32) -> Int32
    typealias WindowQueryFn = @convention(c) (Int32, CFArray, UInt32) -> Unmanaged<CFTypeRef>?
    typealias QueryResultCopyWindowsFn = @convention(c) (CFTypeRef) -> Unmanaged<CFTypeRef>?
    typealias IteratorAdvanceFn = @convention(c) (CFTypeRef) -> Bool
    typealias IteratorGetLevelFn = @convention(c) (CFTypeRef) -> Int32
    typealias IteratorGetCornerRadiiFn = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
    typealias CopySpacesForWindowsFn = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    typealias MoveWindowsToSpaceFn = @convention(c) (Int32, CFArray, UInt64) -> Int32

    static let newWindow: NewWindowFn? = sym("SLSNewWindow")
    static let releaseWindow: WindowFn? = sym("SLSReleaseWindow")
    static let setWindowTags: SetWindowTagsFn? = sym("SLSSetWindowTags")
    static let setWindowResolution: SetWindowResolutionFn? = sym("SLSSetWindowResolution")
    static let setWindowOpacity: SetWindowOpacityFn? = sym("SLSSetWindowOpacity")
    static let setWindowAlpha: SetWindowAlphaFn? = sym("SLSSetWindowAlpha")
    static let setWindowShape: SetWindowShapeFn? = sym("SLSSetWindowShape")
    static let windowContextCreate: WindowContextCreateFn? = sym("SLWindowContextCreate")
    static let flushWindow: FlushWindowFn? = sym("SLSFlushWindowContentRegion")
    static let disableUpdate: ConnectionFn? = sym("SLSDisableUpdate")
    static let reenableUpdate: ConnectionFn? = sym("SLSReenableUpdate")
    static let freezeWindow: FreezeWindowFn? = sym("SLSWindowFreezeWithOptions")
    static let thawWindow: WindowFn? = sym("SLSWindowThaw")
    static let setShadowProperties: SetShadowPropertiesFn? = sym("SLSWindowSetShadowProperties")
    static let invalidateShadow: WindowFn? = sym("SLSInvalidateWindowShadow")
    static let transactionOrder: TransactionOrderFn? = sym("SLSTransactionOrderWindow")
    static let transactionSetLevel: TransactionSetLevelFn? = sym("SLSTransactionSetWindowLevel")
    // Sub-levels order windows within a level; a higher one stays above
    // windows raised in a lower one.
    static let transactionSetSubLevel: TransactionSetLevelFn? = sym("SLSTransactionSetWindowSubLevel")
    typealias GetWindowSubLevelFn = @convention(c) (Int32, UInt32) -> Int32
    static let getWindowSubLevel: GetWindowSubLevelFn? = sym("SLSGetWindowSubLevel")
    static let windowQuery: WindowQueryFn? = sym("SLSWindowQueryWindows")
    static let queryResultCopyWindows: QueryResultCopyWindowsFn? = sym("SLSWindowQueryResultCopyWindows")
    static let iteratorAdvance: IteratorAdvanceFn? = sym("SLSWindowIteratorAdvance")
    static let iteratorGetLevel: IteratorGetLevelFn? = sym("SLSWindowIteratorGetLevel")
    // macOS 26 and later.
    static let iteratorGetCornerRadii: IteratorGetCornerRadiiFn? = sym("SLSWindowIteratorGetCornerRadii")
    static let copySpacesForWindows: CopySpacesForWindowsFn? = sym("SLSCopySpacesForWindows")
    static let moveWindowsToSpace: MoveWindowsToSpaceFn? = sym("SLSMoveWindowsToManagedSpace")
    // (cid, 0, 1, 0, screen point, out window point, out wid, out owner cid), as yabai calls it.
    typealias FindWindowAndOwnerFn = @convention(c) (Int32, Int32, Int32, Int32, UnsafeMutablePointer<CGPoint>,
                                                    UnsafeMutablePointer<CGPoint>, UnsafeMutablePointer<UInt32>, UnsafeMutablePointer<Int32>) -> Int32
    static let findWindowAndOwner: FindWindowAndOwnerFn? = sym("SLSFindWindowAndOwner")
    // Process serial numbers are passed as 8-byte buffers.
    typealias GetFrontProcessFn = @convention(c) (UnsafeMutableRawPointer) -> Int32
    typealias ConnectionForPSNFn = @convention(c) (Int32, UnsafeRawPointer, UnsafeMutablePointer<Int32>) -> Int32
    typealias ConnectionPIDFn = @convention(c) (Int32, UnsafeMutablePointer<pid_t>) -> Int32
    static let getFrontProcess: GetFrontProcessFn? = sym("_SLPSGetFrontProcess")
    static let connectionForPSN: ConnectionForPSNFn? = sym("SLSGetConnectionIDForPSN")
    static let connectionPID: ConnectionPIDFn? = sym("SLSConnectionGetPID")

    static let cid: Int32 = {
        let fn: MainConnectionFn? = sym("SLSMainConnectionID")
        return fn?() ?? 0
    }()
}

enum WindowServer {
    /// Whether a window is on screen now; false once minimized or hidden.
    static func isOnScreen(_ wid: CGWindowID) -> Bool {
        let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, wid) as? [[String: Any]]
        return info?.first?[kCGWindowIsOnscreen as String] as? Bool ?? false
    }

    static func bounds(of wid: CGWindowID) -> CGRect? {
        guard let fn = SkyLight.getWindowBounds, SkyLight.cid != 0 else { return nil }
        var rect = CGRect.zero
        guard fn(SkyLight.cid, wid, &rect) == 0, !rect.isEmpty else { return nil }
        return rect
    }

    /// Moves our own windows in one transaction, skipping the AppKit round-trip
    /// and keeping the overlays of one window in step with each other. Each
    /// `below` entry orders a window directly under another app's window, and
    /// each `above` entry directly over one, in the same commit, so position
    /// and depth never drift apart.
    /// Returns false when SkyLight is unavailable and nothing was sent.
    // Ordering against another app's window only works for raw window-server
    // windows at that window's level. AppKit windows ignore it, and a window at
    // another level stays in its own band, so button overlays still float.
    static func move(_ moves: [(wid: CGWindowID, origin: CGPoint)],
                     below: [(wid: CGWindowID, target: CGWindowID)] = [],
                     above: [(wid: CGWindowID, target: CGWindowID)] = []) -> Bool {
        guard let create = SkyLight.transactionCreate,
              let move = SkyLight.transactionMove,
              let commit = SkyLight.transactionCommit,
              SkyLight.cid != 0,
              let tx = create(SkyLight.cid)?.takeRetainedValue() else { return false }
        for m in moves {
            _ = move(tx, m.wid, m.origin)
        }
        if let order = SkyLight.transactionOrder {
            for b in below {
                _ = order(tx, b.wid, -1, b.target)
            }
            for a in above {
                _ = order(tx, a.wid, 1, a.target)
            }
        }
        return commit(tx, 0) == 0
    }

    /// Level and corner radius of any window, read from the window server.
    static func info(of wid: CGWindowID) -> (level: Int32, cornerRadius: CGFloat?)? {
        guard let query = SkyLight.windowQuery, let copy = SkyLight.queryResultCopyWindows,
              let advance = SkyLight.iteratorAdvance, let getLevel = SkyLight.iteratorGetLevel,
              SkyLight.cid != 0,
              let result = query(SkyLight.cid, [NSNumber(value: wid)] as CFArray, 0)?.takeRetainedValue(),
              let iterator = copy(result)?.takeRetainedValue(),
              advance(iterator) else { return nil }
        var radius: CGFloat?
        if let radii = SkyLight.iteratorGetCornerRadii?(iterator)?.takeRetainedValue() as? [NSNumber],
           let first = radii.first?.doubleValue, first > 0 {
            radius = first
        }
        return (getLevel(iterator), radius)
    }

    static func subLevel(of wid: CGWindowID) -> Int32 {
        guard let fn = SkyLight.getWindowSubLevel, SkyLight.cid != 0 else { return 0 }
        return fn(SkyLight.cid, wid)
    }

    /// The Space a window is on, or nil if unknown.
    static func space(of wid: CGWindowID) -> UInt64? {
        guard let copy = SkyLight.copySpacesForWindows, SkyLight.cid != 0,
              let spaces = copy(SkyLight.cid, 0x7, [NSNumber(value: wid)] as CFArray)?.takeRetainedValue() as? [NSNumber] else { return nil }
        return spaces.first?.uint64Value
    }

    static func moveToSpace(_ wid: CGWindowID, _ space: UInt64) {
        _ = SkyLight.moveWindowsToSpace?(SkyLight.cid, [NSNumber(value: wid)] as CFArray, space)
    }

    /// The front process as the window server has it, which NSWorkspace can
    /// trail right after a switch.
    static func frontPID() -> pid_t? {
        guard let getFront = SkyLight.getFrontProcess, let forPSN = SkyLight.connectionForPSN,
              let getPID = SkyLight.connectionPID, SkyLight.cid != 0 else {
            return NSWorkspace.shared.frontmostApplication?.processIdentifier
        }
        var psn: UInt64 = 0
        var connection: Int32 = 0
        var pid: pid_t = 0
        guard getFront(&psn) == 0, forPSN(SkyLight.cid, &psn, &connection) == 0,
              getPID(connection, &pid) == 0 else {
            return NSWorkspace.shared.frontmostApplication?.processIdentifier
        }
        return pid
    }

    /// The window a click at a global top-left point would reach, or nil if unknown.
    static func window(at point: CGPoint) -> CGWindowID? {
        windowAndOwner(at: point)?.wid
    }

    /// The window a click at a global top-left point would reach and its
    /// owner's pid, which is 0 if unknown.
    static func windowAndOwner(at point: CGPoint) -> (wid: CGWindowID, pid: pid_t)? {
        guard let find = SkyLight.findWindowAndOwner, SkyLight.cid != 0 else { return nil }
        var screenPoint = point
        var windowPoint = CGPoint.zero
        var wid: UInt32 = 0
        var owner: Int32 = 0
        guard find(SkyLight.cid, 0, 1, 0, &screenPoint, &windowPoint, &wid, &owner) == 0 else { return nil }
        var pid: pid_t = 0
        if let getPID = SkyLight.connectionPID, getPID(owner, &pid) != 0 {
            pid = 0
        }
        return (wid, pid)
    }
}

extension WindowServer {
    /// Limits where one of our windows takes clicks to `include` minus
    /// `exclude`, in window coordinates with a top-left origin. Clicks
    /// elsewhere go to the windows below. Returns false when unavailable.
    static func setEventShape(of wid: CGWindowID, include: [CGRect], exclude: [CGRect]) -> Bool {
        guard let newRegion = SkyLight.newRegionWithRectList,
              let diff = SkyLight.diffRegion,
              let release = SkyLight.releaseRegion,
              let setShape = SkyLight.setWindowEventShape,
              SkyLight.cid != 0 else { return false }
        func region(_ rects: [CGRect]) -> OpaquePointer? {
            var out: OpaquePointer?
            let status = rects.withUnsafeBufferPointer { newRegion($0.baseAddress, Int32($0.count), &out) }
            return status == 0 ? out : nil
        }
        guard let included = region(include) else { return false }
        defer { _ = release(included) }
        var shape = included
        var difference: OpaquePointer?
        if !exclude.isEmpty, let excluded = region(exclude) {
            defer { _ = release(excluded) }
            if diff(included, excluded, &difference) == 0, let difference {
                shape = difference
            }
        }
        defer { if let difference { _ = release(difference) } }
        return setShape(SkyLight.cid, wid, shape) == 0
    }
}

// Window-server notifications, registered process-wide like JankyBorders does.
// Moved and resized only fire for windows in the interest list set by subscribe().
// stackd saw reordered go quiet once an interest list is set; here it fired for
// every raise in testing, and the periodic scan covers it if it doesn't.
enum WindowServerEvents {
    static let destroyed: UInt32 = 804
    static let moved: UInt32 = 806
    static let resized: UInt32 = 807
    static let reordered: UInt32 = 808
    // A watched window ordered in or out. Used for the Dock's Mission Control window.
    static let shown: UInt32 = 815
    static let hidden: UInt32 = 816
    // The window server began a window animation, such as the genie into the
    // Dock. Measured about 25 ms into a minimize, where hidden only comes at
    // the end, some 500 ms later. The payload is a counter, not a window id.
    static let animationBegan: UInt32 = 1327
    // The front app changed, as Cmd-Tab or a Dock click does. Measured some
    // 40 ms before the app raises its windows. No payload; wid is 0.
    static let frontChanged: UInt32 = 1508

    // Called on the main thread with (event, wid).
    static var handler: ((UInt32, CGWindowID) -> Void)?

    /// True once moved/resized events can be requested.
    private(set) static var isAvailable = false
    private static var registered = false

    // Registrations can't be removed, so this runs once per process.
    static func start() {
        guard !registered else { return }
        registered = true
        guard let register = SkyLight.registerNotifyProc,
              SkyLight.requestNotifications != nil,
              SkyLight.cid != 0 else { return }
        var ok = true
        for event in [destroyed, moved, resized, reordered, shown, hidden, animationBegan] {
            ok = register(notifyProc, event, nil) == 0 && ok
        }
        isAvailable = ok
        // Optional; without it only clicks are guarded against raise flashes.
        _ = register(notifyProc, frontChanged, nil)
    }

    /// Replaces the interest list with `wids`.
    static func subscribe(_ wids: [CGWindowID]) {
        guard isAvailable, let request = SkyLight.requestNotifications else { return }
        var list = wids.map { UInt32($0) }
        _ = list.withUnsafeMutableBufferPointer { buffer in
            request(SkyLight.cid, buffer.baseAddress, Int32(buffer.count))
        }
    }

    // Payloads start with the uint32 window id, except for frontChanged.
    private static let notifyProc: SkyLight.NotifyProc = { event, data, length, _ in
        var wid: CGWindowID = 0
        if let data, length >= 4 {
            wid = CGWindowID(data.loadUnaligned(as: UInt32.self))
        } else if event != frontChanged {
            return
        }
        if Thread.isMainThread {
            WindowServerEvents.handler?(event, wid)
        } else {
            DispatchQueue.main.async { WindowServerEvents.handler?(event, wid) }
        }
    }
}
