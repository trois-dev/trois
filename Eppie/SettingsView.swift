// Settings UI for themes and button customization.
import SwiftUI

enum SettingsTab: Hashable {
    case themes, getThemes, custom, about
}

// Lets the app open Settings on a given tab, e.g. for a trois:// link.
final class SettingsNavigation: ObservableObject {
    static let shared = SettingsNavigation()
    @Published var tab: SettingsTab = .themes
}

struct SettingsView: View {
    @StateObject private var themeManager = ThemeManager.shared
    @ObservedObject private var navigation = SettingsNavigation.shared

    var body: some View {
        TabView(selection: $navigation.tab) {
            ThemePickerView()
                .tabItem { Label("Themes", systemImage: "paintpalette") }
                .tag(SettingsTab.themes)

            CatalogView()
                .tabItem { Label("Get Themes", systemImage: "arrow.down.circle") }
                .tag(SettingsTab.getThemes)

            ThemeEditorView()
                .tabItem { Label("Custom", systemImage: "slider.horizontal.3") }
                .tag(SettingsTab.custom)

            AboutView()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(SettingsTab.about)
        }
        // Wide enough for three frame previews across.
        .frame(width: 620, height: 480)
    }
}

struct CatalogView: View {
    @ObservedObject var catalog = ThemeCatalog.shared

    var body: some View {
        VStack(spacing: 0) {
            if catalog.themes.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    if let error = catalog.loadError, !catalog.isLoading {
                        Text(error)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Try Again") { catalog.refresh() }
                    } else {
                        ProgressView()
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .padding()
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))], spacing: 16) {
                        ForEach(catalog.themes) { entry in
                            CatalogCard(entry: entry)
                        }
                    }
                    .padding()
                }
            }

            Divider()

            HStack {
                Text("Themes are the work of their authors.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button(action: { catalog.refresh() }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(catalog.isLoading)
            }
            .padding()
        }
        .onAppear {
            if catalog.themes.isEmpty {
                catalog.refresh()
            }
        }
        .alert("Theme Not Installed", isPresented: Binding(
            get: { catalog.installError != nil },
            set: { if !$0 { catalog.installError = nil } }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(catalog.installError ?? "")
        }
    }
}

struct CatalogCard: View {
    let entry: CatalogTheme
    @ObservedObject var catalog = ThemeCatalog.shared
    @ObservedObject var themeManager = ThemeManager.shared

    private var installed: Theme? {
        themeManager.installedTheme(named: entry.id)
    }

    var body: some View {
        VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .windowBackgroundColor))
                .frame(height: 60)
                .overlay(preview)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )

            Text(entry.name)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
            Text("by \(entry.author)")
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            if let engine = entry.engine {
                Text(engine)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            action
                .controlSize(.small)
                .frame(height: 22)
        }
        .frame(width: 120)
    }

    @ViewBuilder
    private var action: some View {
        if catalog.installing.contains(entry.id) {
            ProgressView()
                .scaleEffect(0.6)
        } else if let installed, (installed.version ?? 0) >= entry.version {
            if themeManager.currentTheme?.id == installed.id {
                Text("Applied")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Button("Apply") { themeManager.applyTheme(installed) }
            }
        } else {
            Button(installed == nil ? "Install" : "Update") { catalog.install(entry.id) }
        }
    }

    // Previews are PNGs at their pixel size, like the theme grid.
    private var preview: some View {
        HStack(spacing: 4) {
            ForEach(["close", "minimize", "zoom"], id: \.self) { key in
                if let path = entry.preview[key], let url = catalog.url(for: path) {
                    AsyncImage(url: url, scale: 1) { image in
                        image.interpolation(.none)
                    } placeholder: {
                        Color.clear.frame(width: 14, height: 14)
                    }
                }
            }
        }
    }
}

private func reloadOverlays() {
    NotificationCenter.default.post(name: .init("TroisReloadImages"), object: nil)
}

struct ThemePickerView: View {
    @ObservedObject var themeManager = ThemeManager.shared
    @AppStorage("windowBorders") private var windowBorders = true
    @AppStorage("frameButtons") private var frameButtons = false
    @State private var showingInstallSheet = false
    @State private var dragOver = false
    @State private var installError: String?

    // With borders on, cards show each theme's frame around a small window.
    private var showsFrames: Bool { windowBorders }
    private var previewSize: CGSize {
        showsFrames ? FramePreviewRenderer.canvas : CGSize(width: 120, height: 60)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Theme grid
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: previewSize.width))], spacing: 16) {
                    // Default (no theme)
                    ThemeCard(
                        name: "Default",
                        isSelected: themeManager.currentTheme == nil,
                        previewSize: previewSize,
                        preview: showsFrames ? AnyView(plainWindow(defaultPreview)) : AnyView(defaultPreview)
                    ) {
                        themeManager.clearTheme()
                    }

                    ForEach(themeManager.themes) { theme in
                        ThemeCard(
                            name: theme.name,
                            author: theme.author,
                            engine: theme.engine,
                            isSelected: themeManager.currentTheme?.id == theme.id,
                            previewSize: previewSize,
                            preview: cardPreview(theme)
                        ) {
                            themeManager.applyTheme(theme)
                        }
                        .contextMenu {
                            if theme.path.path.contains("Application Support") {
                                Button("Delete Theme", role: .destructive) {
                                    themeManager.deleteTheme(theme)
                                }
                            }
                            Button("Show in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([theme.path])
                            }
                        }
                    }
                }
                .padding()
            }

            // Kaleidoscope themes carry a window frame.
            if themeManager.currentTheme?.frameDirectory != nil {
                Divider()
                HStack {
                    Toggle("Window Borders", isOn: $windowBorders)
                    Toggle("Buttons in Frame", isOn: $frameButtons)
                        .disabled(!windowBorders)
                        .help("Put the close, zoom and minimize buttons in the frame instead of at the traffic lights")
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .onChange(of: windowBorders) { _ in reloadOverlays() }
                .onChange(of: frameButtons) { _ in reloadOverlays() }
            }

            Divider()

            // Bottom toolbar
            HStack {
                Button(action: { showingInstallSheet = true }) {
                    Label("Install Theme...", systemImage: "plus")
                }

                Button(action: { themeManager.revealThemesFolder() }) {
                    Label("Open Themes Folder", systemImage: "folder")
                }

                Spacer()

                Button(action: { themeManager.loadThemes() }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            .padding()
        }
        .onDrop(of: [.fileURL], isTargeted: $dragOver) { providers in
            handleDrop(providers)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(dragOver ? Color.accentColor : Color.clear, lineWidth: 3)
                .padding(4)
        )
        .fileImporter(
            isPresented: $showingInstallSheet,
            allowedContentTypes: [.folder, .zip],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                let accessing = url.startAccessingSecurityScopedResource()
                install(url) {
                    if accessing { url.stopAccessingSecurityScopedResource() }
                }
            }
        }
        .alert("Theme Not Installed", isPresented: Binding(
            get: { installError != nil },
            set: { if !$0 { installError = nil } }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(installError ?? "")
        }
    }

    private func install(_ url: URL, done: (() -> Void)? = nil) {
        themeManager.installTheme(from: url) { result in
            done?()
            if case .failure(let error) = result {
                installError = error.localizedDescription
            }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
            if let data = item as? Data,
               let url = URL(dataRepresentation: data, relativeTo: nil) {
                DispatchQueue.main.async {
                    install(url)
                }
            }
        }
        return true
    }

    private func cardPreview(_ theme: Theme) -> AnyView {
        guard showsFrames else { return AnyView(themePreview(theme)) }
        guard let directory = theme.frameDirectory else { return AnyView(plainWindow(themePreview(theme))) }
        return AnyView(FramePreviewView(
            directory: directory, title: theme.name, frameButtons: frameButtons,
            buttons: themePreview(theme),
            fallback: AnyView(plainWindow(themePreview(theme)))
        ))
    }

    // A frameless window for themes without a frame, sized like the framed ones.
    private func plainWindow<Buttons: View>(_ buttons: Buttons) -> some View {
        RoundedRectangle(cornerRadius: FramePreviewRenderer.cornerRadius)
            .fill(Color(nsColor: .windowBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: FramePreviewRenderer.cornerRadius)
                    .stroke(Color.gray.opacity(0.4), lineWidth: 0.5)
            )
            .overlay(alignment: .topLeading) {
                buttons.padding(8)
            }
            .frame(width: previewSize.width - 24, height: previewSize.height - 24)
    }

    // Sized and spaced like the macOS 27 buttons.
    private var defaultPreview: some View {
        HStack(spacing: 9) {
            Circle().fill(Color.red).frame(width: 14, height: 14)
            Circle().fill(Color.yellow).frame(width: 14, height: 14)
            Circle().fill(Color.green).frame(width: 14, height: 14)
        }
    }

    private func themePreview(_ theme: Theme) -> some View {
        HStack(spacing: 4) {
            if let closeURL = theme.closeUp, let image = NSImage(contentsOf: closeURL) {
                Image(nsImage: normalizedImage(image))
                    .interpolation(.none)
            } else {
                Circle().fill(Color.red).frame(width: 14, height: 14)
            }

            if let minURL = theme.minimizeUp, let image = NSImage(contentsOf: minURL) {
                Image(nsImage: normalizedImage(image))
                    .interpolation(.none)
            } else {
                Circle().fill(Color.yellow).frame(width: 14, height: 14)
            }

            if let maxURL = theme.maximizeUp, let image = NSImage(contentsOf: maxURL) {
                Image(nsImage: normalizedImage(image))
                    .interpolation(.none)
            } else {
                Circle().fill(Color.green).frame(width: 14, height: 14)
            }
        }
    }

    // Normalize image size to pixel dimensions, ignoring DPI metadata
    private func normalizedImage(_ image: NSImage) -> NSImage {
        if let rep = image.representations.first {
            let pixelWidth = rep.pixelsWide
            let pixelHeight = rep.pixelsHigh
            if pixelWidth > 0 && pixelHeight > 0 {
                image.size = NSSize(width: pixelWidth, height: pixelHeight)
            }
        }
        return image
    }
}

struct ThemeCard<Preview: View>: View {
    let name: String
    var author: String? = nil
    var engine: String? = nil
    let isSelected: Bool
    var previewSize = CGSize(width: 120, height: 60)
    let preview: Preview
    let action: () -> Void

    // Large previews hold a whole window, so they sit on a desktop-like backdrop.
    private var backdrop: Color {
        previewSize.height > 60 ? Color.gray.opacity(0.18) : Color(nsColor: .windowBackgroundColor)
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(backdrop)
                    .frame(width: previewSize.width, height: previewSize.height)
                    .overlay(preview)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(isSelected ? Color.accentColor : Color.gray.opacity(0.3), lineWidth: isSelected ? 2 : 1)
                    )

                Text(name)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if let author = author {
                    Text("by \(author)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if let engine = engine {
                    Text(engine)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .buttonStyle(.plain)
        .frame(width: previewSize.width)
    }
}

struct ButtonStateSlot: View {
    let stateName: String
    let userDefaultsKey: String
    let fallbackColor: Color

    @State private var imagePath: String = ""
    @State private var isHovering = false
    // Made from the normal image; remade when it changes.
    @State private var isGenerated = false

    var body: some View {
        VStack(spacing: 4) {
            Text(stateName)
                .font(.caption2)
                .foregroundColor(.secondary)

            Button(action: selectImage) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .frame(width: 44, height: 44)

                    if let path = imagePath.isEmpty ? nil : imagePath,
                       let image = NSImage(contentsOfFile: path) {
                        Image(nsImage: normalizedImage(image))
                            .interpolation(.none)
                    } else {
                        // Empty slot indicator
                        Circle()
                            .strokeBorder(fallbackColor.opacity(0.5), lineWidth: 1)
                            .frame(width: 28, height: 28)
                            .overlay(
                                Image(systemName: "plus")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            )
                    }

                    // Hover overlay
                    if isHovering && !imagePath.isEmpty {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.black.opacity(0.5))
                            .frame(width: 44, height: 44)
                            .overlay(
                                Image(systemName: "xmark")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(.white)
                            )
                    }
                }
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                isHovering = hovering
            }
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                loadDroppedFile(providers) { ThemeManager.shared.setDraftImage($0, forKey: userDefaultsKey) }
            }
            .onAppear(perform: refresh)
            // Applying or resetting a theme changes the live paths.
            .onReceive(NotificationCenter.default.publisher(for: .init("TroisReloadImages"))) { _ in refresh() }
            .contextMenu {
                if !imagePath.isEmpty {
                    Button("Clear") {
                        clearImage()
                    }
                }
                Button("Select Image...") {
                    selectImage()
                }
                if ThemeManager.shared.canGenerateDraftImage(forKey: userDefaultsKey) {
                    Button(isGenerated ? "Regenerate" : "Generate from Normal") {
                        ThemeManager.shared.generateDraftImages(forKeys: [userDefaultsKey])
                    }
                }
            }

            Text("auto")
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .opacity(isGenerated ? 1 : 0)
                .help("Made from the normal image. Updates when it changes.")
        }
    }

    private func selectImage() {
        // If clicking while hovering on existing image, clear it
        if isHovering && !imagePath.isEmpty {
            clearImage()
            return
        }

        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .bmp, .jpeg, .tiff]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Select \(stateName.lowercased()) state image"

        if panel.runModal() == .OK, let url = panel.url {
            ThemeManager.shared.setDraftImage(url, forKey: userDefaultsKey)
        }
    }

    private func clearImage() {
        ThemeManager.shared.setDraftImage(nil, forKey: userDefaultsKey)
    }

    private func refresh() {
        imagePath = UserDefaults.standard.string(forKey: userDefaultsKey) ?? ""
        isGenerated = ThemeManager.shared.isDraftImageGenerated(forKey: userDefaultsKey)
    }

    // Normalize image size to pixel dimensions, ignoring DPI metadata
    private func normalizedImage(_ image: NSImage) -> NSImage {
        if let rep = image.representations.first {
            let pixelWidth = rep.pixelsWide
            let pixelHeight = rep.pixelsHigh
            if pixelWidth > 0 && pixelHeight > 0 {
                image.size = NSSize(width: pixelWidth, height: pixelHeight)
            }
        }
        return image
    }
}

struct ImagePickerRow: View {
    let label: String
    @Binding var path: String
    let key: String

    var body: some View {
        HStack {
            Text(label)
            Spacer()

            if !path.isEmpty {
                if let image = NSImage(contentsOfFile: path) {
                    Image(nsImage: image)
                        .resizable()
                        .frame(width: 14, height: 14)
                }
                Text(URL(fileURLWithPath: path).lastPathComponent)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 100)
            }

            Button("Browse...") {
                selectImage()
            }

            if !path.isEmpty {
                Button(action: clearImage) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func selectImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .bmp, .jpeg, .tiff]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Select an image for the \(label.lowercased())"

        if panel.runModal() == .OK, let url = panel.url {
            path = url.path
            UserDefaults.standard.set(path, forKey: key)
            NotificationCenter.default.post(name: .init("TroisReloadImages"), object: nil)
        }
    }

    private func clearImage() {
        path = ""
        UserDefaults.standard.removeObject(forKey: key)
        NotificationCenter.default.post(name: .init("TroisReloadImages"), object: nil)
    }
}

struct AboutView: View {
    @State private var showsCredits = false

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Trois")
                .font(.system(size: 48, weight: .ultraLight))

            Text("Version \(version)")
                .foregroundColor(.secondary)

            Text("Classic window themes for a modern Mac.")

            Divider()
                .frame(width: 200)

            VStack(alignment: .leading, spacing: 6) {
                feature("Themed buttons", "for close, minimize and zoom")
                feature("Window frames", "drawn from each theme's chrome")
                feature("Get Themes", "to browse and install from the gallery")
                feature("Custom", "to build your own or mix parts from others")
            }
            .font(.callout)

            Spacer()

            Text("Made by sryo. Themes are the work of their authors.")
                .font(.caption)
                .foregroundColor(.secondary)
            Button("Credits") { showsCredits = true }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showsCredits) { CreditsView() }
    }

    private func feature(_ title: String, _ detail: String) -> some View {
        (Text(title).bold() + Text(" \(detail)"))
    }
}

// Tools and archives that themes come from. Add a line when a new engine or source lands.
struct CreditsView: View {
    @Environment(\.dismiss) private var dismiss

    private static let engines: [(name: String, by: String)] = [
        ("EppieDesktop", "Jeff Epstein, 1998-1999"),
        ("Kaleidoscope", "Arlo Rose and Greg Landweber"),
    ]

    private static let archives: [(name: String, url: String)] = [
        ("Virtual Plastic Eppie gallery", "https://www.virtualplastic.net/html/eppie.html"),
        ("kaleidoscope.net scheme archive, via the Internet Archive", "https://web.archive.org/web/2002/http://www.kaleidoscope.net/"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Credits")
                .font(.title2)

            Text("Trois exists because of these tools and the people who made themes for them. It is not affiliated with any of them.")
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            section("Engines") {
                ForEach(Self.engines, id: \.name) { engine in
                    Text(engine.name).bold() + Text(" by \(engine.by)")
                }
            }

            section("Theme archives") {
                ForEach(Self.archives, id: \.name) { archive in
                    if let url = URL(string: archive.url) {
                        Link(archive.name, destination: url)
                    }
                }
            }

            section("Themes") {
                Text("Each theme is the work of the author named on it. If you made one and want it credited differently or removed, open an issue.")
                    .fixedSize(horizontal: false, vertical: true)
                Link("github.com/sryo/trois-themes/issues", destination: URL(string: "https://github.com/sryo/trois-themes/issues")!)
            }

            section("Injection mode") {
                HStack(spacing: 4) {
                    Text("Uses the same approach as")
                    Link("MacForge", destination: URL(string: "https://github.com/MacEnhance/MacForge")!)
                }
            }

            Spacer()

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440, height: 440)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            content()
        }
    }
}

#Preview {
    SettingsView()
}
