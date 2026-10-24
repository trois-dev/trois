import Cocoa

let app = NSApplication.shared
// Under XCTest the app only hosts the test bundle: no menu, taps or overlays.
let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    || ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
let delegate = isTestHost ? nil : AppDelegate()
app.delegate = delegate
app.run()
