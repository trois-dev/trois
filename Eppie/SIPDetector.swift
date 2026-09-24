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
                sipDisabled = Self.allowsInjection(csrutilStatus: output)
            }
        } catch {
            sipDisabled = false
        }

        mode = sipDisabled ? .injection : .overlay
        print("Trois: SIP \(sipDisabled ? "disabled" : "enabled"), using \(mode) mode")
    }

    // Injection needs task_for_pid, which only Debugging Restrictions block. A custom
    // configuration lists each protection on its own line after the status line.
    static func allowsInjection(csrutilStatus output: String) -> Bool {
        let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        if let debugging = lines.first(where: { $0.hasPrefix("Debugging Restrictions:") }) {
            return debugging.hasSuffix("disabled")
        }
        guard let status = lines.first(where: { $0.hasPrefix("System Integrity Protection status:") }) else { return false }
        return status.hasSuffix("disabled.") || status.hasSuffix("disabled")
    }
}
