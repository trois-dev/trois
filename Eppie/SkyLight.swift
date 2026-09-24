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
    static let requestNotifications: RequestNotificationsFn? = sym("SLSRequestNotificationsForWindows")

    static let cid: Int32 = {
        let fn: MainConnectionFn? = sym("SLSMainConnectionID")
        return fn?() ?? 0
    }()
}

enum WindowServer {
    static func bounds(of wid: CGWindowID) -> CGRect? {
        guard let fn = SkyLight.getWindowBounds, SkyLight.cid != 0 else { return nil }
        var rect = CGRect.zero
        guard fn(SkyLight.cid, wid, &rect) == 0, !rect.isEmpty else { return nil }
        return rect
    }

    /// Moves our own windows in one transaction, skipping the AppKit round-trip
    /// and keeping the overlays of one window in step with each other.
    /// Returns false when SkyLight is unavailable and nothing was sent.
    // Ordering relative to another app's window (SLSTransactionOrderWindow,
    // SLSOrderWindow) is accepted but has no effect on macOS 27, so overlays
    // keep a floating level instead of sitting directly above their target.
    static func move(_ moves: [(wid: CGWindowID, origin: CGPoint)]) -> Bool {
        guard let create = SkyLight.transactionCreate,
              let move = SkyLight.transactionMove,
              let commit = SkyLight.transactionCommit,
              SkyLight.cid != 0,
              let tx = create(SkyLight.cid)?.takeRetainedValue() else { return false }
        for m in moves {
            _ = move(tx, m.wid, m.origin)
        }
        return commit(tx, 0) == 0
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
        for event in [destroyed, moved, resized, reordered] {
            ok = register(notifyProc, event, nil) == 0 && ok
        }
        isAvailable = ok
    }

    /// Replaces the interest list with `wids`.
    static func subscribe(_ wids: [CGWindowID]) {
        guard isAvailable, let request = SkyLight.requestNotifications else { return }
        var list = wids.map { UInt32($0) }
        _ = list.withUnsafeMutableBufferPointer { buffer in
            request(SkyLight.cid, buffer.baseAddress, Int32(buffer.count))
        }
    }

    // Payload for all four events starts with the uint32 window id.
    private static let notifyProc: SkyLight.NotifyProc = { event, data, length, _ in
        guard let data, length >= 4 else { return }
        let wid = CGWindowID(data.loadUnaligned(as: UInt32.self))
        if Thread.isMainThread {
            WindowServerEvents.handler?(event, wid)
        } else {
            DispatchQueue.main.async { WindowServerEvents.handler?(event, wid) }
        }
    }
}
