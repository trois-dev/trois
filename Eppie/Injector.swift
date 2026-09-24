// Handles injection of TroisLoader into running apps via privileged helper
import Foundation
import AppKit

class Injector: NSObject {
    static let shared = Injector()

    private let loaderBundleName = "TroisLoader.bundle"
    private let helperName = "com.trois.app.Injector"

    private var loaderPath: String?
    private var helperPath: String?

    private override init() {
        super.init()
        setupPaths()
    }

    private func setupPaths() {
        // Look for loader and helper in app's bundle
        // Use the dylib inside the bundle, not the bundle itself
        if let bundlePath = Bundle.main.resourcePath {
            let loaderBundleURL = URL(fileURLWithPath: bundlePath).appendingPathComponent(loaderBundleName)
            let dylibURL = loaderBundleURL.appendingPathComponent("Contents/MacOS/TroisLoader")
            if FileManager.default.fileExists(atPath: dylibURL.path) {
                loaderPath = dylibURL.path
            }
        }

        // Helper is in Contents/Library/LaunchServices
        if let bundlePath = Bundle.main.bundlePath as String? {
            let helperURL = URL(fileURLWithPath: bundlePath)
                .appendingPathComponent("Contents/Library/LaunchServices")
                .appendingPathComponent(helperName)
            if FileManager.default.fileExists(atPath: helperURL.path) {
                helperPath = helperURL.path
            }
        }

        // Fallback: check system location
        if helperPath == nil {
            let systemHelper = "/Library/PrivilegedHelperTools/\(helperName)"
            if FileManager.default.fileExists(atPath: systemHelper) {
                helperPath = systemHelper
            }
        }

        // Fallback to Application Support for loader
        if loaderPath == nil {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let troisSupport = appSupport.appendingPathComponent("Trois")
            let loaderBundleURL = troisSupport.appendingPathComponent(loaderBundleName)
            let dylibURL = loaderBundleURL.appendingPathComponent("Contents/MacOS/TroisLoader")
            if FileManager.default.fileExists(atPath: dylibURL.path) {
                loaderPath = dylibURL.path
            }
        }

        print("Trois Injector: loader=\(loaderPath ?? "not found"), helper=\(helperPath ?? "not found")")
    }

    func canInject() -> Bool {
        return SIPDetector.shared.sipDisabled && loaderPath != nil && helperPath != nil
    }

    // Check if helper is installed in system location
    func isHelperInstalled() -> Bool {
        return FileManager.default.fileExists(atPath: "/Library/PrivilegedHelperTools/\(helperName)")
    }

    // Install the helper to system location
    func installHelper() -> Bool {
        guard let helper = helperPath else {
            print("Trois: Helper not found in bundle")
            return false
        }

        let script = """
        do shell script "mkdir -p /Library/PrivilegedHelperTools && cp '\(helper)' /Library/PrivilegedHelperTools/\(helperName) && chmod 755 /Library/PrivilegedHelperTools/\(helperName)" with administrator privileges
        """

        var error: NSDictionary?
        if let scriptObject = NSAppleScript(source: script) {
            scriptObject.executeAndReturnError(&error)
            if error != nil {
                print("Trois: Failed to install helper: \(error ?? [:])")
                return false
            }
            print("Trois: Helper installed successfully")
            return true
        }
        return false
    }

    // Inject into all running GUI apps using privileged helper
    func injectAll() {
        guard canInject() else {
            print("Trois: Cannot inject (SIP enabled or tools missing)")
            return
        }

        guard let loader = loaderPath else {
            print("Trois: Loader not found")
            return
        }

        // Install helper if needed
        if !isHelperInstalled() {
            print("Trois: Installing helper...")
            if !installHelper() {
                print("Trois: Failed to install helper")
                return
            }
        }

        let apps = NSWorkspace.shared.runningApplications.filter { app in
            app.activationPolicy == .regular &&
            app.bundleIdentifier != Bundle.main.bundleIdentifier &&
            app.bundleIdentifier != nil
        }

        print("Trois: Injecting into \(apps.count) apps...")

        // Build injection commands for all apps
        var commands: [String] = []
        for app in apps {
            let pid = app.processIdentifier
            let name = app.localizedName ?? "Unknown"
            print("Trois: Will inject into \(name) (pid \(pid))")
            commands.append("/Library/PrivilegedHelperTools/\(helperName) \(pid) '\(loader)'")
        }

        if commands.isEmpty {
            return
        }

        // Run all injections with a single admin prompt
        let combinedCommand = commands.joined(separator: "; ")
        let script = """
        do shell script "\(combinedCommand)" with administrator privileges
        """

        var error: NSDictionary?
        if let scriptObject = NSAppleScript(source: script) {
            scriptObject.executeAndReturnError(&error)
            if let err = error {
                print("Trois: Injection error: \(err)")
            } else {
                print("Trois: Injection complete")
            }
        }
    }

    // Inject into a single process
    func inject(into pid: pid_t) -> Bool {
        guard let loader = loaderPath else {
            print("Trois: Loader not found")
            return false
        }

        if !isHelperInstalled() {
            if !installHelper() {
                return false
            }
        }

        let script = """
        do shell script "/Library/PrivilegedHelperTools/\(helperName) \(pid) '\(loader)'" with administrator privileges
        """

        var error: NSDictionary?
        if let scriptObject = NSAppleScript(source: script) {
            scriptObject.executeAndReturnError(&error)
            if error != nil {
                print("Trois: Injection error: \(error ?? [:])")
                return false
            }
            return true
        }
        return false
    }

    // Notify all injected apps to reload themes
    func notifyThemeChanged() {
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name("TroisThemeChanged"),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    // Get list of running GUI apps
    func getInjectableApps() -> [NSRunningApplication] {
        return NSWorkspace.shared.runningApplications.filter { app in
            app.activationPolicy == .regular &&
            app.bundleIdentifier != Bundle.main.bundleIdentifier
        }
    }
}
