// Handles injection of TroisLoader into running apps via privileged helper
import Foundation
import AppKit

class Injector: NSObject {
    static let shared = Injector()

    private let loaderBundleName = "TroisLoader.bundle"
    private let helperName = "com.trois.app.Injector"
    private let installDir = "/Library/PrivilegedHelperTools"

    // Bundled copies. The helper only loads the root-owned installed loader.
    private var bundledLoader: URL?
    private var bundledHelper: URL?

    private var installedHelper: URL { URL(fileURLWithPath: installDir).appendingPathComponent(helperName) }
    private var installedLoader: URL { URL(fileURLWithPath: installDir).appendingPathComponent(loaderBundleName) }

    // Apps launched close together share one admin prompt.
    private var pendingApps: [NSRunningApplication] = []
    private var flushScheduled = false
    private let queue = DispatchQueue(label: "com.trois.app.injector")

    private override init() {
        super.init()
        let resources = Bundle.main.resourceURL?.appendingPathComponent(loaderBundleName)
        if let resources, FileManager.default.fileExists(atPath: resources.appendingPathComponent("Contents/MacOS/TroisLoader").path) {
            bundledLoader = resources
        }
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchServices/\(helperName)")
        if FileManager.default.fileExists(atPath: helper.path) {
            bundledHelper = helper
        }
    }

    // The shellcode and the helper build are arm64 only.
    func canInject() -> Bool {
        #if arch(arm64)
        return SIPDetector.shared.sipDisabled && bundledLoader != nil && bundledHelper != nil
        #else
        return false
        #endif
    }

    // True when the installed helper and loader match the ones in this app.
    private func isInstallCurrent() -> Bool {
        guard let bundledHelper, let bundledLoader else { return false }
        let fm = FileManager.default
        let loaderBinary = "Contents/MacOS/TroisLoader"
        return fm.contentsEqual(atPath: bundledHelper.path, andPath: installedHelper.path)
            && fm.contentsEqual(atPath: bundledLoader.appendingPathComponent(loaderBinary).path,
                                andPath: installedLoader.appendingPathComponent(loaderBinary).path)
    }

    // Quotes text for an AppleScript string literal, then for the shell via quoted form.
    private func shellArg(_ text: String) -> String {
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "(quoted form of \"\(escaped)\")"
    }

    // Runs a shell command as root. parts are joined with spaces; each is already an AppleScript expression.
    private func runAsAdmin(_ parts: [String]) -> Bool {
        let script = "do shell script " + parts.joined(separator: " & \" \" & ") + " with administrator privileges"
        var error: NSDictionary?
        // NSAppleScript is only safe on the main thread.
        let ok = DispatchQueue.main.sync {
            NSAppleScript(source: script)?.executeAndReturnError(&error) != nil
        }
        if let error { print("Trois: Admin command failed: \(error)") }
        return ok
    }

    // Helper and loader are installed root-owned so no user process can swap what root loads.
    private func installCommand() -> [String]? {
        guard let bundledHelper, let bundledLoader else { return nil }
        let script = """
        set -e; d=\(installDir); mkdir -p "$d"; \
        rm -rf "$d/\(loaderBundleName)"; cp -R "$1" "$d/\(loaderBundleName)"; \
        cp "$2" "$d/\(helperName)"; \
        chown -R root:wheel "$d/\(helperName)" "$d/\(loaderBundleName)"; \
        chmod 755 "$d/\(helperName)"; chmod -R go-w "$d/\(loaderBundleName)"
        """
        return ["\"/bin/sh -c \"", shellArg(script), "\"trois-install\"", shellArg(bundledLoader.path), shellArg(bundledHelper.path)]
    }

    // Start time in microseconds, which the helper checks so a reused pid is never injected.
    private func startTime(of pid: pid_t) -> Int64? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Int64(start.tv_sec) * 1_000_000 + Int64(start.tv_usec)
    }

    private func isInjectable(_ app: NSRunningApplication) -> Bool {
        app.activationPolicy == .regular
            && app.bundleIdentifier != nil
            && app.bundleIdentifier != Bundle.main.bundleIdentifier
            && !ExcludedApps.current.contains(app.bundleIdentifier ?? "")
            && app.executableArchitecture == NSBundleExecutableArchitectureARM64
    }

    // Inject into all running GUI apps
    func injectAll() {
        enqueue(NSWorkspace.shared.runningApplications)
    }

    // Inject into a newly launched app
    func inject(into app: NSRunningApplication) {
        enqueue([app])
    }

    private func enqueue(_ apps: [NSRunningApplication]) {
        guard canInject() else { return }
        pendingApps.append(contentsOf: apps.filter(isInjectable))
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.flush()
        }
    }

    private func flush() {
        flushScheduled = false
        let apps = pendingApps.filter { !$0.isTerminated }
        pendingApps.removeAll()
        let targets = apps.compactMap { app in
            startTime(of: app.processIdentifier).map { "\(app.processIdentifier):\($0)" }
        }
        guard !targets.isEmpty, let install = installCommand() else { return }

        queue.async { [self] in
            var parts: [String] = []
            if !isInstallCurrent() {
                parts = install + ["\"&&\""]
            }
            parts += [shellArg(installedHelper.path)] + targets.map { shellArg($0) }
            print("Trois: Injecting into \(targets.count) apps")
            if !runAsAdmin(parts) {
                print("Trois: Some injections failed")
            }
        }
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
}
