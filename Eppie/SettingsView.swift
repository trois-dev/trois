// Settings UI for themes and button customization.
import SwiftUI

struct SettingsView: View {
    @StateObject private var themeManager = ThemeManager.shared
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            ThemePickerView()
                .tabItem { Label("Themes", systemImage: "paintpalette") }
                .tag(0)

            ManualSettingsView()
                .tabItem { Label("Custom", systemImage: "slider.horizontal.3") }
                .tag(1)

            AboutView()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(2)
        }
        .frame(width: 500, height: 400)
    }
}

struct ThemePickerView: View {
    @ObservedObject var themeManager = ThemeManager.shared
    @State private var showingInstallSheet = false
    @State private var dragOver = false

    var body: some View {
        VStack(spacing: 0) {
            // Theme grid
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))], spacing: 16) {
                    // Default (no theme)
                    ThemeCard(
                        name: "Default",
                        isSelected: themeManager.currentTheme == nil,
                        preview: defaultPreview
                    ) {
                        themeManager.clearTheme()
                    }

                    ForEach(themeManager.themes) { theme in
                        ThemeCard(
                            name: theme.name,
                            author: theme.author,
                            isSelected: themeManager.currentTheme?.id == theme.id,
                            preview: themePreview(theme)
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
                _ = url.startAccessingSecurityScopedResource()
                _ = themeManager.installTheme(from: url)
                url.stopAccessingSecurityScopedResource()
            }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
            if let data = item as? Data,
               let url = URL(dataRepresentation: data, relativeTo: nil) {
                DispatchQueue.main.async {
                    _ = themeManager.installTheme(from: url)
                }
            }
        }
        return true
    }

    private var defaultPreview: some View {
        HStack(spacing: 4) {
            Circle().fill(Color.red).frame(width: 12, height: 12)
            Circle().fill(Color.yellow).frame(width: 12, height: 12)
            Circle().fill(Color.green).frame(width: 12, height: 12)
        }
    }

    private func themePreview(_ theme: Theme) -> some View {
        HStack(spacing: 4) {
            if let closeURL = theme.closeUp, let image = NSImage(contentsOf: closeURL) {
                Image(nsImage: normalizedImage(image))
                    .interpolation(.none)
            } else {
                Circle().fill(Color.red).frame(width: 12, height: 12)
            }

            if let minURL = theme.minimizeUp, let image = NSImage(contentsOf: minURL) {
                Image(nsImage: normalizedImage(image))
                    .interpolation(.none)
            } else {
                Circle().fill(Color.yellow).frame(width: 12, height: 12)
            }

            if let maxURL = theme.maximizeUp, let image = NSImage(contentsOf: maxURL) {
                Image(nsImage: normalizedImage(image))
                    .interpolation(.none)
            } else {
                Circle().fill(Color.green).frame(width: 12, height: 12)
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
    let isSelected: Bool
    let preview: Preview
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .frame(height: 60)
                    .overlay(preview)
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
            }
        }
        .buttonStyle(.plain)
        .frame(width: 120)
    }
}

struct ManualSettingsView: View {
    @AppStorage("customThemeName") private var themeName = ""
    @AppStorage("customThemeAuthor") private var themeAuthor = ""
    @State private var showingSaveAlert = false
    @State private var saveAlertMessage = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 24) {
                    // Button columns
                    HStack(alignment: .top, spacing: 12) {
                        ButtonColumnView(
                            title: "Close",
                            color: .red,
                            keyPrefix: "close"
                        )
                        ButtonColumnView(
                            title: "Minimize",
                            color: .yellow,
                            keyPrefix: "minimize"
                        )
                        ButtonColumnView(
                            title: "Zoom",
                            color: .green,
                            keyPrefix: "zoom"
                        )
                        ButtonColumnView(
                            title: "Help",
                            color: .purple,
                            keyPrefix: "help"
                        )
                    }
                    .padding(.top, 8)

                    Divider()

                    // Theme info
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Theme Name")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            TextField("My Theme", text: $themeName)
                                .textFieldStyle(.roundedBorder)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Author")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            TextField("Your name", text: $themeAuthor)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                }
                .padding(.vertical)
                .padding(.horizontal, 32)
            }

            Divider()

            HStack {
                Button("Reset All") {
                    ThemeManager.shared.clearTheme()
                    NotificationCenter.default.post(name: .init("TroisReloadImages"), object: nil)
                }

                Spacer()

                Button("Save as Theme...") {
                    saveCustomTheme()
                }
                .disabled(!hasCustomImages())
            }
            .padding(.vertical)
            .padding(.horizontal, 32)
        }
        .alert("Theme Saved", isPresented: $showingSaveAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(saveAlertMessage)
        }
    }

    private func hasCustomImages() -> Bool {
        let defaults = UserDefaults.standard
        return defaults.string(forKey: "closeButtonImage") != nil ||
               defaults.string(forKey: "minimizeButtonImage") != nil ||
               defaults.string(forKey: "zoomButtonImage") != nil ||
               defaults.string(forKey: "helpButtonImage") != nil
    }

    private func saveCustomTheme() {
        let name = themeName.isEmpty ? "Custom Theme" : themeName
        let author = themeAuthor.isEmpty ? nil : themeAuthor

        if let savedPath = ThemeManager.shared.saveCustomTheme(name: name, author: author) {
            saveAlertMessage = "Theme saved to:\n\(savedPath)"
            showingSaveAlert = true
            ThemeManager.shared.loadThemes()
        } else {
            saveAlertMessage = "Failed to save theme. Make sure you have at least one custom image."
            showingSaveAlert = true
        }
    }
}

struct ButtonColumnView: View {
    let title: String
    let color: Color
    let keyPrefix: String

    private let states = [
        ("Normal", ""),
        ("Hover", "Hover"),
        ("Pressed", "Pressed"),
        ("Disabled", "Disabled")
    ]

    var body: some View {
        VStack(spacing: 12) {
            // Button title with colored dot
            HStack(spacing: 6) {
                Circle()
                    .fill(color)
                    .frame(width: 12, height: 12)
                Text(title)
                    .font(.headline)
            }

            // State slots
            VStack(spacing: 8) {
                ForEach(states, id: \.0) { state in
                    ButtonStateSlot(
                        stateName: state.0,
                        userDefaultsKey: "\(keyPrefix)Button\(state.1)Image",
                        fallbackColor: color
                    )
                }
            }
        }
        .frame(width: 100)
    }
}

struct ButtonStateSlot: View {
    let stateName: String
    let userDefaultsKey: String
    let fallbackColor: Color

    @State private var imagePath: String = ""
    @State private var isHovering = false

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
            .onAppear {
                imagePath = UserDefaults.standard.string(forKey: userDefaultsKey) ?? ""
            }
            .contextMenu {
                if !imagePath.isEmpty {
                    Button("Clear") {
                        clearImage()
                    }
                }
                Button("Select Image...") {
                    selectImage()
                }
            }
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
            imagePath = url.path
            UserDefaults.standard.set(imagePath, forKey: userDefaultsKey)
            NotificationCenter.default.post(name: .init("TroisReloadImages"), object: nil)
        }
    }

    private func clearImage() {
        imagePath = ""
        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
        NotificationCenter.default.post(name: .init("TroisReloadImages"), object: nil)
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
    var body: some View {
        VStack(spacing: 16) {
            Text("Trois")
                .font(.system(size: 48, weight: .ultraLight))

            Text("Version 1.0")
                .foregroundColor(.secondary)

            Divider()
                .frame(width: 200)

            VStack(alignment: .leading, spacing: 8) {
                Text("by sryo")
                    .font(.caption)
                Text("Successor to EppieDesktop for Windows")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("Original by Jeff Epstein (1998-1999)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("Theme gallery from VirtualPlastic.net")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Text("Customize your traffic light buttons.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    SettingsView()
}
