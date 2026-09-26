// Reads Stage Manager state so windows parked in its strip get no overlays.
import Cocoa
import ApplicationServices

enum StageManager {
    private static let domain = "com.apple.WindowManager" as CFString
    private static let bundleID = "com.apple.WindowManager"
    // Preferences are re-read at most this often.
    private static let refreshInterval: CFAbsoluteTime = 1
    private static let lock = NSLock()
    private static var cachedEnabled = false
    private static var lastRead: CFAbsoluteTime = 0

    /// Whether Stage Manager is on. Safe to call from any thread.
    static var isEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastRead >= refreshInterval {
            lastRead = now
            // WindowManager writes the key, so the cached copy must be dropped first.
            CFPreferencesAppSynchronize(domain)
            cachedEnabled = CFPreferencesCopyAppValue("GloballyEnabled" as CFString, domain) as? Bool ?? false
        }
        return cachedEnabled
    }

    /// Windows shown as thumbnails in the strip, on every display. Empty when
    /// Stage Manager is off. Walks WindowManager's AX tree, so call it off main.
    // Tree layout as Rectangle reads it: one AXGroup per display strip, holding
    // an AXList of AXButtons, one per app group. Each button's private
    // AXWindowsIDs attribute lists the window ids in that group.
    static func stripWindowIDs() -> Set<CGWindowID> {
        guard isEnabled,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return [] }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        // WindowManager is a system agent; a stall here should not hold up the scan.
        AXUIElementSetMessagingTimeout(element, 0.25)
        var ids: Set<CGWindowID> = []
        for strip in children(of: element, role: kAXGroupRole) {
            for list in children(of: strip, role: kAXListRole) {
                for button in children(of: list, role: kAXButtonRole) {
                    var value: CFTypeRef?
                    guard AXUIElementCopyAttributeValue(button, "AXWindowsIDs" as CFString, &value) == .success,
                          let numbers = value as? [NSNumber] else { continue }
                    ids.formUnion(numbers.map { CGWindowID($0.uint32Value) })
                }
            }
        }
        return ids
    }

    private static func children(of element: AXUIElement, role: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let children = value as? [AXUIElement] else { return [] }
        return children.filter { child in
            var roleValue: CFTypeRef?
            return AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleValue) == .success
                && roleValue as? String == role
        }
    }
}
