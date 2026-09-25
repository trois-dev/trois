// Settings tab for options that apply to every theme.
import SwiftUI
import ServiceManagement
import UniformTypeIdentifiers

/// Bundle IDs of apps Trois leaves alone, stored as "excludedApps". The
/// injected loader reads the same key.
enum ExcludedApps {
    static let defaultsKey = "excludedApps"

    static var current: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: defaultsKey) ?? [])
    }
}

/// App-wide switches that also live in the menu bar. AppDelegate owns the
/// changes, this only mirrors them.
final class GeneralState: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var allWindows = false
    @Published private(set) var openAtLogin = false
    @Published private(set) var loginNeedsApproval = false
    @Published private(set) var trusted = false

    private var observers: [NSObjectProtocol] = []

    init() {
        refresh()
        // Login items and Accessibility can change in System Settings while Trois is open.
        for name in [Notification.Name.troisStateChanged, NSApplication.didBecomeActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refresh()
            })
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    // Every assignment publishes, so a switch that was refused snaps back.
    func refresh() {
        enabled = UserDefaults.standard.bool(forKey: "troisEnabled")
        allWindows = UserDefaults.standard.bool(forKey: "allWindowsMode")
        openAtLogin = SMAppService.mainApp.status == .enabled
        loginNeedsApproval = SMAppService.mainApp.status == .requiresApproval
        trusted = AXIsProcessTrusted()
    }
}

struct TweaksView: View {
    @AppStorage("windowBorders") private var windowBorders = true
    @AppStorage("frameButtons") private var frameButtons = false
    @AppStorage(ButtonArt.Sizing.defaultsKey) private var buttonSizing = ButtonArt.Sizing.bleed.rawValue
    @AppStorage("hideMenuBarIcon") private var hideMenuBarIcon = false
    @State private var excluded: [String] = UserDefaults.standard.stringArray(forKey: ExcludedApps.defaultsKey) ?? []
    @State private var selectedApp: String?
    @State private var confirmingReset = false

    @StateObject private var general = GeneralState()
    @ObservedObject private var themeManager = ThemeManager.shared

    private var sizing: ButtonArt.Sizing { ButtonArt.Sizing(rawValue: buttonSizing) ?? .bleed }
    private var injects: Bool { SIPDetector.shared.sipDisabled }
    private var app: AppDelegate? { NSApp.delegate as? AppDelegate }

    var body: some View {
        VStack(spacing: 0) {
            preview
            Divider()
            form
        }
        .onChange(of: buttonSizing) { _ in reloadOverlays() }
        .onChange(of: windowBorders) { _ in reloadOverlays() }
        .onChange(of: frameButtons) { _ in reloadOverlays() }
    }

    // The applied theme as the Installed tab draws it, next to its buttons enlarged.
    private var preview: some View {
        let theme = themeManager.currentTheme
        let buttons = ThemeButtonsPreview(theme: theme, sizing: sizing)
        return HStack(spacing: 24) {
            Group {
                if windowBorders, let theme, let directory = theme.frameDirectory {
                    FramePreviewView(
                        directory: directory, title: theme.name, frameButtons: frameButtons,
                        buttons: buttons,
                        fallback: AnyView(PlainWindowPreview(previewSize: FramePreviewRenderer.canvas, buttons: buttons))
                    )
                } else {
                    PlainWindowPreview(previewSize: FramePreviewRenderer.canvas, buttons: buttons)
                }
            }
            .frame(width: FramePreviewRenderer.canvas.width, height: FramePreviewRenderer.canvas.height)

            VStack(alignment: .leading, spacing: 8) {
                Text(theme?.name ?? "Default")
                    .font(.headline)
                ThemeButtonsPreview(theme: theme, sizing: sizing, zoom: 3)
                Text("Buttons at 3x. The outline is the button the art covers")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var form: some View {
        Form {
            Section("General") {
                if !injects && !general.trusted {
                    LabeledContent {
                        Button("Grant Access...") { app?.requestAccessibilityPermission() }
                    } label: {
                        Text("Accessibility access needed")
                        Text("Trois reads where each window's buttons are")
                    }
                }
                Toggle(isOn: binding(general.enabled) { app?.setEnabled($0) }) {
                    Text("Enabled")
                    Text("Draw the applied theme")
                }
                if !injects {
                    Toggle(isOn: binding(general.allWindows) { app?.setAllWindows($0) }) {
                        Text("All windows")
                        Text("Theme every window, not just the focused one")
                    }
                }
                Toggle(isOn: Binding(get: { hideMenuBarIcon }, set: { app?.setMenuBarIconHidden($0) })) {
                    Text("Hide menu bar icon")
                    Text("Open Trois again from Finder to get back to Settings")
                }
                Toggle(isOn: binding(general.openAtLogin) { app?.setOpenAtLogin($0) }) {
                    Text("Open at login")
                    if general.loginNeedsApproval {
                        Text("Switched off in System Settings > General > Login Items")
                    }
                }
                LabeledContent {
                    Text(injects ? "Injection" : "Overlay")
                } label: {
                    Text("Mode")
                    Text(injects
                         ? "System Integrity Protection is off, so Trois draws inside each app"
                         : "Trois draws over windows. Turning off System Integrity Protection lets it draw inside each app")
                }
            }

            Section("Buttons") {
                Picker(selection: $buttonSizing) {
                    ForEach(ButtonArt.Sizing.allCases, id: \.rawValue) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                } label: {
                    Text("Button art")
                    Text(sizing.help)
                }
                .pickerStyle(.segmented)
            }

            Section("Frame") {
                Toggle(isOn: $windowBorders) {
                    Text("Show frame")
                    Text("Draw the theme's frame around windows")
                }
                Toggle(isOn: $frameButtons) {
                    Text("Frame buttons")
                    Text("Use the frame's own close, minimize and zoom buttons")
                }
                .disabled(!windowBorders)
            }

            Section {
                if excluded.isEmpty {
                    Text("None")
                        .foregroundColor(.secondary)
                }
                ForEach(excluded, id: \.self) { id in
                    excludedRow(id)
                }
            } header: {
                Text("Excluded apps")
            } footer: {
                HStack {
                    Text(injects
                         ? "Apps already running pick this up when they redraw their buttons."
                         : "Trois leaves these apps' windows as they are.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Add App...", action: addExcludedApp)
                }
            }

            Section {
                HStack {
                    Spacer()
                    Button("Reset Tweaks...") { confirmingReset = true }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Reset tweaks to their defaults?", isPresented: $confirmingReset) {
            Button("Reset", role: .destructive, action: reset)
        } message: {
            Text("Enabled, Open at login and the applied theme are kept.")
        }
    }

    private func excludedRow(_ id: String) -> some View {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
        let name = url.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? id
        return HStack {
            if let url {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .frame(width: 20, height: 20)
            }
            VStack(alignment: .leading) {
                Text(name)
                // Apps that aren't installed are listed by ID alone.
                if url != nil {
                    Text(id)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            Button {
                setExcluded(excluded.filter { $0 != id })
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Stop excluding \(name)")
        }
    }

    private func addExcludedApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Exclude"
        guard panel.runModal() == .OK else { return }
        let ids = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
        setExcluded(excluded + ids.filter { !excluded.contains($0) })
    }

    private func setExcluded(_ ids: [String]) {
        excluded = ids
        UserDefaults.standard.set(ids, forKey: ExcludedApps.defaultsKey)
        // Overlays drop excluded windows on the next scan; injected apps redraw.
        reloadOverlays()
    }

    private func reset() {
        for key in ["windowBorders", "frameButtons", ButtonArt.Sizing.defaultsKey] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        setExcluded([])
        app?.setMenuBarIconHidden(false)
        if !general.allWindows { app?.setAllWindows(true) }
        reloadOverlays()
    }

    // The app decides whether a change happens, e.g. Enabled needs Accessibility.
    private func binding(_ value: Bool, set: @escaping (Bool) -> Void) -> Binding<Bool> {
        Binding(get: { value }, set: { set($0); general.refresh() })
    }
}
