// Manages app lifecycle and menu bar.
import Cocoa
import SwiftUI
import ApplicationServices
import ServiceManagement

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var multiWindowTracker: MultiWindowTracker?
    private var settingsWindow: NSWindow?
    private var permissionCheckTimer: Timer?
    private var appLaunchObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Buttons on every window unless the user turned it off.
        UserDefaults.standard.register(defaults: ["allWindowsMode": true, "troisEnabled": true])
        setupMainMenu()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reloadOverlayImages),
            name: Notification.Name("TroisReloadImages"),
            object: nil
        )

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
            offerLoginItemOnce()
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
            showSettings(tab: .themes)
            // The install error alert lives on the Gallery tab.
            ThemeCatalog.shared.install(id) { result in
                if case .failure = result { SettingsNavigation.shared.tab = .getThemes }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    // Opening Trois again while it runs, e.g. from Finder, is the way back when the menu bar icon is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings(tab: nil)
        return false
    }

    func setMenuBarIconHidden(_ hidden: Bool) {
        UserDefaults.standard.set(hidden, forKey: "hideMenuBarIcon")
        statusItem.isVisible = !hidden
    }

    // Never shown, since Trois has no Dock icon, but its key equivalents make
    // copy, paste and close work in the Settings window.
    private func setupMainMenu() {
        let mainMenu = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = menu
            mainMenu.addItem(item)
        }
        submenu("Trois", [NSMenuItem(title: "Quit Trois", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")])
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        submenu("Edit", [
            NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"),
            redo,
            .separator(),
            NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"),
            NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"),
            NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"),
            NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        ])
        submenu("Window", [NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")])
        NSApp.mainMenu = mainMenu
    }

    private var isEnabled: Bool { UserDefaults.standard.bool(forKey: "troisEnabled") }

    private func checkAndRequestPermission() {
        // Use native prompt - shows system dialog asking to open Settings
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(options) {
            if isEnabled { startTracking() }
            updateMenuState()
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
                if !SIPDetector.shared.sipDisabled, self?.isEnabled == true {
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
        statusItem.isVisible = !UserDefaults.standard.bool(forKey: "hideMenuBarIcon")

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

        let loginItem = NSMenuItem(title: "Open at Login", action: #selector(toggleLoginItem), keyEquivalent: "")
        loginItem.tag = 300
        menu.addItem(loginItem)

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

        menu.delegate = self
        statusItem.menu = menu
    }

    // The login item can be removed in System Settings, so its state is read each time the menu opens.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.item(withTag: 300)?.state = SMAppService.mainApp.status == .enabled ? .on : .off
        // Settings can change this too.
        menu.item(withTag: 200)?.state = UserDefaults.standard.bool(forKey: "allWindowsMode") ? .on : .off
    }

    @objc private func toggleLoginItem(_ sender: NSMenuItem) {
        setOpenAtLogin(SMAppService.mainApp.status != .enabled)
    }

    func setOpenAtLogin(_ on: Bool) {
        if on, SMAppService.mainApp.status == .requiresApproval {
            // Registered but switched off in System Settings, which is the only place to switch it back on.
            SMAppService.openSystemSettingsLoginItems()
        } else {
            setLoginItem(on)
        }
        NotificationCenter.default.post(name: .troisStateChanged, object: nil)
    }

    private func setLoginItem(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = enabled ? "Trois Can't Open at Login" : "Trois Still Opens at Login"
            alert.informativeText = "\(error.localizedDescription) You can change it in System Settings > General > Login Items."
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    // Asks once, after Trois is working, so it doesn't stack on the Accessibility prompt.
    private func offerLoginItemOnce() {
        let key = "offeredLoginItem"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        guard SMAppService.mainApp.status != .enabled else { return }

        DispatchQueue.main.async { [weak self] in
            let alert = NSAlert()
            alert.messageText = "Open Trois at login?"
            alert.informativeText = "Trois can start when you log in so your theme is always on. You can change this later from the menu bar."
            alert.addButton(withTitle: "Open at Login")
            alert.addButton(withTitle: "Not Now")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                self?.setLoginItem(true)
            }
        }
    }

    private func setupAutoInject() {
        guard Injector.shared.canInject() else {
            print("Trois: Cannot inject - tools not found")
            return
        }

        Injector.shared.injectAll()

        appLaunchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Injector.shared.inject(into: app)
        }
    }

    @objc private func toggleAllWindows(_ sender: NSMenuItem) {
        setAllWindows(sender.state != .on)
    }

    func setAllWindows(_ on: Bool) {
        statusItem.menu?.item(withTag: 200)?.state = on ? .on : .off
        UserDefaults.standard.set(on, forKey: "allWindowsMode")

        // Restart tracking with new mode
        if multiWindowTracker != nil {
            stopTracking()
            startTracking()
        }
        NotificationCenter.default.post(name: .troisStateChanged, object: nil)
    }

    private func startTracking() {
        multiWindowTracker?.stopTracking()
        let allWindowsMode = UserDefaults.standard.bool(forKey: "allWindowsMode")

        // All-windows mode tracks every visible window, otherwise only the focused one
        multiWindowTracker = MultiWindowTracker(allWindows: allWindowsMode)
        multiWindowTracker?.startTracking()

        UserDefaults.standard.set(true, forKey: "troisEnabled")
        offerLoginItemOnce()
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
        setEnabled(sender.state != .on)
    }

    func setEnabled(_ on: Bool) {
        if !on {
            if SIPDetector.shared.sipDisabled {
                // Injected loaders check the flag on every draw.
                UserDefaults.standard.set(false, forKey: "troisEnabled")
                Injector.shared.notifyThemeChanged()
            } else {
                stopTracking()
            }
        } else {
            if SIPDetector.shared.sipDisabled {
                UserDefaults.standard.set(true, forKey: "troisEnabled")
                Injector.shared.notifyThemeChanged()
            } else {
                // Overlay mode - need accessibility permission
                let trusted = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
                let options = [trusted: true] as CFDictionary
                let accessEnabled = AXIsProcessTrustedWithOptions(options)

                if accessEnabled {
                    startTracking()
                }
            }
        }
        updateMenuState()
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

    @objc func requestAccessibilityPermission() {
        if AXIsProcessTrusted() {
            // Only start overlay tracking in overlay mode
            if !SIPDetector.shared.sipDisabled, isEnabled {
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
        NotificationCenter.default.post(name: .troisStateChanged, object: nil)
        guard let menu = statusItem.menu else { return }
        if let enabledItem = menu.item(withTitle: "Enabled") {
            let on = SIPDetector.shared.sipDisabled ? isEnabled : multiWindowTracker != nil
            enabledItem.state = on ? .on : .off
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

extension Notification.Name {
    /// Posted when Enabled, All Windows, Open at Login or permissions change.
    static let troisStateChanged = Notification.Name("TroisStateChanged")
}
