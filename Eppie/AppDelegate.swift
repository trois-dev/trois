// Manages app lifecycle and menu bar.
import Cocoa
import SwiftUI
import ApplicationServices

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var multiWindowTracker: MultiWindowTracker?
    private var settingsWindow: NSWindow?
    private var permissionCheckTimer: Timer?
    private var appLaunchObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Buttons on every window unless the user turned it off.
        UserDefaults.standard.register(defaults: ["allWindowsMode": true])

        // Run as menu bar app (no dock icon)
        NSApp.setActivationPolicy(.accessory)

        // Check SIP status
        let sipDetector = SIPDetector.shared
        print("Trois: Running in \(sipDetector.mode) mode")

        setupMenuBar()
        ThemeManager.shared.migrateBundledTheme()

        // Set up mode based on SIP status
        if sipDetector.sipDisabled {
            // Injection mode - no overlays needed
            setupAutoInject()
        } else {
            // Overlay mode - need accessibility permission
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.checkAndRequestPermission()
            }
        }
    }

    // trois://install/<id> from the theme gallery. Only ids in the catalog are
    // installed; ThemeCatalog looks them up there.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme?.lowercased() == "trois" && url.host?.lowercased() == "install" {
            let id = url.lastPathComponent
            guard ThemeCatalog.isValidID(id) else { continue }
            showSettings(tab: .getThemes)
            ThemeCatalog.shared.install(id)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Only terminate if user explicitly quits
        return .terminateNow
    }

    private func checkAndRequestPermission() {
        // Use native prompt - shows system dialog asking to open Settings
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(options) {
            startTracking()
            return
        }

        // Start polling for permission to be granted
        startPermissionPolling()
    }

    private func startPermissionPolling() {
        permissionCheckTimer?.invalidate()
        permissionCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            if AXIsProcessTrusted() {
                self?.permissionCheckTimer?.invalidate()
                self?.permissionCheckTimer = nil
                // Only start overlay tracking in overlay mode
                if !SIPDetector.shared.sipDisabled {
                    self?.startTracking()
                }
                self?.updateMenuState()
            }
        }
    }

    // Template version of the app mark: three discs spaced by their radius, overlaps drawn lighter.
    private static func menuBarImage() -> NSImage {
        let r: CGFloat = 6
        let xs: [CGFloat] = [6, 12, 18]
        func disc(_ x: CGFloat) -> NSBezierPath {
            NSBezierPath(ovalIn: NSRect(x: x - r, y: 0, width: r * 2, height: r * 2))
        }
        let image = NSImage(size: NSSize(width: 24, height: 12), flipped: false) { bounds in
            // Outer discs only touch at one point, so each disc's neighbors never overlap inside it.
            for (i, x) in xs.enumerated() {
                NSGraphicsContext.saveGraphicsState()
                disc(x).addClip()
                let outsideNeighbors = NSBezierPath(rect: bounds)
                outsideNeighbors.windingRule = .evenOdd
                for j in [i - 1, i + 1] where xs.indices.contains(j) {
                    outsideNeighbors.append(disc(xs[j]))
                }
                outsideNeighbors.addClip()
                NSColor.black.setFill()
                bounds.fill()
                NSGraphicsContext.restoreGraphicsState()
            }
            for i in 0..<xs.count - 1 {
                NSGraphicsContext.saveGraphicsState()
                disc(xs[i]).addClip()
                NSColor.black.withAlphaComponent(0.45).setFill()
                disc(xs[i + 1]).fill()
                NSGraphicsContext.restoreGraphicsState()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Trois"
        return image
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = Self.menuBarImage()
        }

        let menu = NSMenu()

        let enabledItem = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "e")
        enabledItem.state = UserDefaults.standard.bool(forKey: "troisEnabled") ? .on : .off
        menu.addItem(enabledItem)

        // All Windows toggle (overlay mode only)
        if !SIPDetector.shared.sipDisabled {
            let allWindowsItem = NSMenuItem(title: "All Windows", action: #selector(toggleAllWindows), keyEquivalent: "")
            allWindowsItem.state = UserDefaults.standard.bool(forKey: "allWindowsMode") ? .on : .off
            allWindowsItem.tag = 200
            menu.addItem(allWindowsItem)
        }

        menu.addItem(NSMenuItem.separator())

        // Show current mode
        let modeItem = NSMenuItem(title: "Mode: \(SIPDetector.shared.sipDisabled ? "Injection" : "Overlay")", action: nil, keyEquivalent: "")
        modeItem.isEnabled = false
        menu.addItem(modeItem)


        menu.addItem(NSMenuItem.separator())

        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ","))

        menu.addItem(NSMenuItem.separator())

        // Show accessibility item if permission not granted
        if !AXIsProcessTrusted() {
            let accessibilityItem = NSMenuItem(title: "Grant Accessibility Access", action: #selector(requestAccessibilityPermission), keyEquivalent: "")
            accessibilityItem.tag = 100  // Tag to find it later
            menu.addItem(accessibilityItem)
            menu.addItem(NSMenuItem.separator())
        }

        menu.addItem(NSMenuItem(title: "Quit Trois", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    private func setupAutoInject() {
        guard Injector.shared.canInject() else {
            print("Trois: Cannot inject - tools not found")
            return
        }

        // Initial injection into all running apps
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            Injector.shared.injectAll()
        }

        // Watch for new app launches
        appLaunchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard self != nil,
                  let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.activationPolicy == .regular,
                  app.bundleIdentifier != Bundle.main.bundleIdentifier else {
                return
            }

            // Delay injection slightly to let app initialize
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let pid = app.processIdentifier
                print("Trois: Auto-injecting into \(app.localizedName ?? "Unknown") (pid \(pid))")
                _ = Injector.shared.inject(into: pid)
            }
        }
    }

    @objc private func toggleAllWindows(_ sender: NSMenuItem) {
        let newState = sender.state != .on
        sender.state = newState ? .on : .off
        UserDefaults.standard.set(newState, forKey: "allWindowsMode")

        // Restart tracking with new mode
        if multiWindowTracker != nil {
            stopTracking()
            startTracking()
        }
    }

    private func startTracking() {
        let allWindowsMode = UserDefaults.standard.bool(forKey: "allWindowsMode")

        // All-windows mode tracks every visible window, otherwise only the focused one
        multiWindowTracker = MultiWindowTracker(allWindows: allWindowsMode)
        multiWindowTracker?.startTracking()

        UserDefaults.standard.set(true, forKey: "troisEnabled")

        // Listen for image reload notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reloadOverlayImages),
            name: Notification.Name("TroisReloadImages"),
            object: nil
        )
    }

    @objc private func reloadOverlayImages() {
        multiWindowTracker?.reloadAllImages()

        // Also notify injected apps
        if SIPDetector.shared.sipDisabled {
            Injector.shared.notifyThemeChanged()
        }
    }

    private func stopTracking() {
        multiWindowTracker?.stopTracking()
        multiWindowTracker = nil

        UserDefaults.standard.set(false, forKey: "troisEnabled")
    }

    @objc private func toggleEnabled(_ sender: NSMenuItem) {
        if sender.state == .on {
            sender.state = .off
            if SIPDetector.shared.sipDisabled {
                // Injection mode - nothing to stop (injected code stays in apps)
                UserDefaults.standard.set(false, forKey: "troisEnabled")
            } else {
                stopTracking()
            }
        } else {
            if SIPDetector.shared.sipDisabled {
                // Injection mode - just mark as enabled, injection happens separately
                sender.state = .on
                UserDefaults.standard.set(true, forKey: "troisEnabled")
            } else {
                // Overlay mode - need accessibility permission
                let trusted = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
                let options = [trusted: true] as CFDictionary
                let accessEnabled = AXIsProcessTrustedWithOptions(options)

                if accessEnabled {
                    sender.state = .on
                    startTracking()
                }
            }
        }
    }

    @objc private func openSettings() {
        showSettings(tab: nil)
    }

    private func showSettings(tab: SettingsTab?) {
        if let tab {
            SettingsNavigation.shared.tab = tab
        }
        if settingsWindow == nil {
            let settingsView = SettingsView()
            settingsWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            // Kept for reuse; closing must not free it under settingsWindow.
            settingsWindow?.isReleasedWhenClosed = false
            settingsWindow?.title = "Trois Settings"
            settingsWindow?.contentView = NSHostingView(rootView: settingsView)
            settingsWindow?.center()
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func requestAccessibilityPermission() {
        if AXIsProcessTrusted() {
            // Only start overlay tracking in overlay mode
            if !SIPDetector.shared.sipDisabled {
                startTracking()
            }
            updateMenuState()
            return
        }

        // Open System Settings to Accessibility pane
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)

        // Start polling (only matters for overlay mode)
        if !SIPDetector.shared.sipDisabled {
            startPermissionPolling()
        }
    }

    private func updateMenuState() {
        guard let menu = statusItem.menu else { return }
        if let enabledItem = menu.item(withTitle: "Enabled") {
            enabledItem.state = (multiWindowTracker != nil) ? .on : .off
        }

        // Remove accessibility item if permission granted
        if AXIsProcessTrusted(), let accessItem = menu.item(withTag: 100) {
            if let index = menu.items.firstIndex(of: accessItem) {
                menu.removeItem(at: index)
                // Remove the separator after it too
                if index < menu.items.count, menu.items[index].isSeparatorItem {
                    menu.removeItem(at: index)
                }
            }
        }
    }
}
