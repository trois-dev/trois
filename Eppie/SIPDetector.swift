// Detects SIP status and manages injection mode
import Foundation

enum InjectionMode {
    case overlay      // SIP enabled - use overlay windows
    case injection    // SIP disabled - inject into apps
}

class SIPDetector {
    static let shared = SIPDetector()

    private(set) var sipDisabled: Bool = false
    private(set) var mode: InjectionMode = .overlay

    private init() {
        checkSIPStatus()
    }

    private func checkSIPStatus() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/csrutil")
        task.arguments = ["status"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                sipDisabled = output.contains("disabled")
            }
        } catch {
            sipDisabled = false
        }

        mode = sipDisabled ? .injection : .overlay
        print("Trois: SIP \(sipDisabled ? "disabled" : "enabled"), using \(mode) mode")
    }

    func canInject() -> Bool {
        return sipDisabled
    }
}
