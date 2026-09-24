// Manages button themes - loading, installing and applying them.
import Cocoa
import UniformTypeIdentifiers

struct Theme: Identifiable, Hashable {
    let id: String
    let name: String
    let path: URL
    var author: String?
    // Tool the theme was made for, e.g. "Kaleidoscope 1.x", and where it was collected.
    var engine: String?
    var source: URL?
    // From theme.json; catalog themes use it to offer updates.
    var version: Int?
    var closeUp: URL?
    var closeHover: URL?
    var closeDown: URL?
    var closeDisabled: URL?
    var minimizeUp: URL?
    var minimizeHover: URL?
    var minimizeDown: URL?
    var minimizeDisabled: URL?
    var maximizeUp: URL?
    var maximizeHover: URL?
    var maximizeDown: URL?
    var maximizeDisabled: URL?
    var restoreUp: URL?
    var restoreDown: URL?
    var helpUp: URL?
    var helpHover: URL?
    var helpDown: URL?
    var helpDisabled: URL?
    // Kaleidoscope window frame folder (frame/layout.json and images).
    var frameDirectory: URL?
    // Catalog id from the marker a gallery install leaves in the folder.
    var catalogID: String?

    // A frame alone is a theme too; the system buttons show over it.
    var hasAnyImage: Bool {
        closeUp != nil || minimizeUp != nil || maximizeUp != nil || frameDirectory != nil
    }
}

/// How an engine name reads under a theme. Kaleidoscope called its themes schemes.
func engineLabel(_ engine: String) -> String {
    engine.hasPrefix("Kaleidoscope") ? "\(engine) scheme" : engine
}

// Optional theme.json in a theme folder. Catalog themes always have one.
struct ThemeManifest: Codable {
    var name: String?
    var author: String?
    var version: Int?
    var engine: String?
    var source: String?
    // Button key to image path relative to the theme folder.
    var buttons: [String: String]?
    // Button keys, and frame.inactive / frame.pressed, that the Editor tab
    // made from another image and remakes when that image changes.
    var generated: [String]?
}

/// One button image: the UserDefaults key the overlays read, its theme.json
/// key and the file name it gets in a saved theme.
struct ButtonSlot {
    let defaultsKey: String
    let manifestKey: String
    let fileBase: String

    static let all: [ButtonSlot] = [
        ButtonSlot(defaultsKey: "closeButtonImage", manifestKey: "close", fileBase: "close_up"),
        ButtonSlot(defaultsKey: "closeButtonHoverImage", manifestKey: "closeHover", fileBase: "close_hover"),
        ButtonSlot(defaultsKey: "closeButtonPressedImage", manifestKey: "closeDown", fileBase: "close_down"),
        ButtonSlot(defaultsKey: "closeButtonDisabledImage", manifestKey: "closeDisabled", fileBase: "close_disabled"),
        ButtonSlot(defaultsKey: "minimizeButtonImage", manifestKey: "minimize", fileBase: "min_up"),
        ButtonSlot(defaultsKey: "minimizeButtonHoverImage", manifestKey: "minimizeHover", fileBase: "min_hover"),
        ButtonSlot(defaultsKey: "minimizeButtonPressedImage", manifestKey: "minimizeDown", fileBase: "min_down"),
        ButtonSlot(defaultsKey: "minimizeButtonDisabledImage", manifestKey: "minimizeDisabled", fileBase: "min_disabled"),
        ButtonSlot(defaultsKey: "zoomButtonImage", manifestKey: "zoom", fileBase: "max_up"),
        ButtonSlot(defaultsKey: "zoomButtonHoverImage", manifestKey: "zoomHover", fileBase: "max_hover"),
        ButtonSlot(defaultsKey: "zoomButtonPressedImage", manifestKey: "zoomDown", fileBase: "max_down"),
        ButtonSlot(defaultsKey: "zoomButtonDisabledImage", manifestKey: "zoomDisabled", fileBase: "max_disabled"),
        ButtonSlot(defaultsKey: "restoreButtonImage", manifestKey: "restore", fileBase: "res_up"),
        ButtonSlot(defaultsKey: "restoreButtonPressedImage", manifestKey: "restoreDown", fileBase: "res_down"),
        ButtonSlot(defaultsKey: "helpButtonImage", manifestKey: "help", fileBase: "help_up"),
        ButtonSlot(defaultsKey: "helpButtonHoverImage", manifestKey: "helpHover", fileBase: "help_hover"),
        ButtonSlot(defaultsKey: "helpButtonPressedImage", manifestKey: "helpDown", fileBase: "help_down"),
        ButtonSlot(defaultsKey: "helpButtonDisabledImage", manifestKey: "helpDisabled", fileBase: "help_disabled")
    ]

    func fileName(extension ext: String) -> String {
        ext.isEmpty ? fileBase : "\(fileBase).\(ext.lowercased())"
    }
}

class ThemeManager: ObservableObject {
    static let shared = ThemeManager()

    @Published var themes: [Theme] = []
    @Published var currentTheme: Theme?
    // The Editor tab's undo and redo history, as copies of the draft folder.
    @Published var draftUndo: [URL] = []
    @Published var draftRedo: [URL] = []

    let themesDirectory: URL
    let fileManager = FileManager.default
    private let installQueue = DispatchQueue(label: "Trois.themeinstall", qos: .userInitiated)

    // Author mapping from VirtualPlastic.net gallery
    private let knownAuthors: [String: String] = [
        "hifiki": "kepplah",
        "spyder": "Spyder",
        "beaker": "beaker",
        "plastic": "plastic",
        "plastic_old": "plastic",
        "simple": "Andrew Foltz",
        "jonx": "jonx",
        "dots": "Johnny",
        "k": "k'",
        "tinker": "tinker",
        "nr1": "Scott A. Munro",
        "kmr": "kmr",
        "kmr2": "kmr",
        "wincontrol": "Rob Timmers",
        "kde": "jonx",
        "redmac": "BigRedPimp",
        "wid": "wid",
        "dark": "schminimalischt",
        "advanced": "schminimalischt",
        "adv2": "schminimalischt",
        "winxp": "EHF",
        "java": "Rafael Laguna",
        "redblue": "Spyder",
        "blackmeld": "cuttheredwire",
        "nikkie": "Nikkie",
        "nikkie2": "Nikkie",
        "nikkie3": "Nikkie",
        "nikkie4": "Nikkie",
        "nikkie5": "Nikkie",
        "RedLetterEdition": "Elwin",
        "eppiexp": "buvysoft",
        "drops": "buvysoft",
        "silver": "Decell",
        "exegone": "kmr",
        "platinum": "maxonico"
    ]

    static let imageExtensions: Set<String> = ["bmp", "png", "jpg", "jpeg", "gif", "tif", "tiff"]

    // File name patterns from the Windows gallery. Down and disabled come first because
    // some up patterns are substrings of them. import_theme.py in trois-themes mirrors this.
    private static let nameGuesses: [(slot: WritableKeyPath<Theme, URL?>, patterns: [String])] = [
        (\.closeDown, ["closedwn", "closedown", "close_down", "close down", "close button down", "close window button down", "close_dw", "1closedn"]),
        (\.closeDisabled, ["closedis", "close_disable", "close disabled", "close button disabled", "close gray", "close_ds", "1closedis"]),
        (\.closeUp, ["closeup", "close_up", "close up", "close button up", "close window button", "1closeup"]),
        (\.minimizeDown, ["mindwn", "mindown", "min_down", "min down", "min dwn", "mini_dwn", "minim_dw", "minimize_down", "minimize down", "minimize button down", "1mindn"]),
        (\.minimizeDisabled, ["mindis", "min_disable", "min disabled", "min gray", "mini_dis", "minim_ds", "minimize_dis", "minimize button disabled", "1mindis"]),
        (\.minimizeUp, ["minup", "min_up", "min up", "mini_up", "minim_up", "minimize_up", "minimize up", "minimize button up", "1minup"]),
        (\.maximizeDown, ["maxdwn", "maxdown", "max_down", "max down", "max dwn", "maxim_dw", "maximize_down", "maximize down", "maximize button down", "1maxdn"]),
        (\.maximizeDisabled, ["maxdis", "max_disable", "max disabled", "max gray", "maxim_ds", "maximize_dis", "maximize button disabled", "1maxdis"]),
        (\.maximizeUp, ["maxup", "max_up", "max up", "maxim_up", "maximize_up", "maximize up", "maximize button up", "1maxup"]),
        (\.restoreDown, ["resdwn", "resdown", "restore down", "restore_down", "restore_dw", "rst_dwn", "restore button down", "1resdn"]),
        (\.restoreUp, ["resup", "restore up", "restore_up", "restore button up", "rst_up", "1resup"]),
        (\.helpDown, ["helpdwn", "helpdown", "help down", "help dwn", "help button down", "1helpdn"]),
        (\.helpUp, ["helpup", "help up", "help button up", "1helpup"])
    ]

    /// `directory` is for tests; the app uses Application Support.
    init(directory: URL? = nil) {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        themesDirectory = directory ?? appSupport.appendingPathComponent("Trois/Themes", isDirectory: true)

        try? fileManager.createDirectory(at: themesDirectory, withIntermediateDirectories: true)
        // Undo history doesn't outlive a launch.
        try? fileManager.removeItem(at: draftHistoryDirectory)

        loadThemes()
        loadCurrentTheme()
    }

    func loadThemes() {
        themes = scanDirectory(themesDirectory).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func scanDirectory(_ directory: URL) -> [Theme] {
        // Hidden folders include the Editor tab's draft.
        guard let contents = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles) else {
            return []
        }

        var themes: [Theme] = []
        for url in contents {
            if let resourceValues = try? url.resourceValues(forKeys: [.isDirectoryKey]),
               resourceValues.isDirectory == true {
                if let theme = loadTheme(from: url) {
                    themes.append(theme)
                }
            }
        }
        return themes
    }

    /// Reads a theme folder. Nil when it has no close, minimize or zoom image and no frame.
    /// Safe to call off the main thread.
    func loadTheme(from directory: URL) -> Theme? {
        var theme = loadThemeContents(from: directory)
        theme?.catalogID = (try? String(contentsOf: directory.appendingPathComponent(ThemeInstaller.catalogMarker), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return theme
    }

    private func loadThemeContents(from directory: URL) -> Theme? {
        let name = directory.lastPathComponent
        var theme = Theme(id: directory.path, name: name, path: directory)

        if let manifest = readManifest(in: directory) {
            theme = Theme(id: directory.path, name: manifest.name ?? name, path: directory)
            theme.author = manifest.author
            theme.version = manifest.version
            theme.engine = manifest.engine
            theme.source = manifest.source.flatMap(URL.init(string:))
            if let buttons = manifest.buttons {
                applyManifestButtons(buttons, in: directory, to: &theme)
                theme.frameDirectory = frameDirectory(in: directory)
                if theme.hasAnyImage {
                    return theme
                }
            }
        }

        // Try readme first, then fall back to known authors mapping
        theme.author = theme.author ?? parseAuthorFromReadme(in: directory) ?? knownAuthors[name]

        guard let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return nil
        }

        for file in files {
            guard Self.imageExtensions.contains(file.pathExtension.lowercased()) else { continue }
            let filename = file.deletingPathExtension().lastPathComponent.lowercased()
            if let guess = Self.nameGuesses.first(where: { matchesPattern(filename, patterns: $0.patterns) }) {
                theme[keyPath: guess.slot] = file
            }
        }

        theme.frameDirectory = frameDirectory(in: directory)
        return theme.hasAnyImage ? theme : nil
    }

    func readManifest(in directory: URL) -> ThemeManifest? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("theme.json")) else { return nil }
        return try? JSONDecoder().decode(ThemeManifest.self, from: data)
    }

    func writeManifest(_ manifest: ThemeManifest, to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: directory.appendingPathComponent("theme.json"), options: .atomic)
    }

    func frameDirectory(in directory: URL) -> URL? {
        let frame = directory.appendingPathComponent("frame", isDirectory: true)
        return fileManager.fileExists(atPath: frame.appendingPathComponent("layout.json").path) ? frame : nil
    }

    func applyManifestButtons(_ buttons: [String: String], in directory: URL, to theme: inout Theme) {
        let root = directory.standardizedFileURL.path + "/"
        func file(_ key: String) -> URL? {
            guard let relative = buttons[key] else { return nil }
            let url = directory.appendingPathComponent(relative).standardizedFileURL
            // Paths must stay inside the theme folder.
            guard url.path.hasPrefix(root), fileManager.fileExists(atPath: url.path) else { return nil }
            return url
        }
        theme.closeUp = file("close")
        theme.closeHover = file("closeHover")
        theme.closeDown = file("closeDown")
        theme.closeDisabled = file("closeDisabled")
        theme.minimizeUp = file("minimize")
        theme.minimizeHover = file("minimizeHover")
        theme.minimizeDown = file("minimizeDown")
        theme.minimizeDisabled = file("minimizeDisabled")
        theme.maximizeUp = file("zoom")
        theme.maximizeHover = file("zoomHover")
        theme.maximizeDown = file("zoomDown")
        theme.maximizeDisabled = file("zoomDisabled")
        theme.restoreUp = file("restore")
        theme.restoreDown = file("restoreDown")
        theme.helpUp = file("help")
        theme.helpHover = file("helpHover")
        theme.helpDown = file("helpDown")
        theme.helpDisabled = file("helpDisabled")
    }

    private func matchesPattern(_ filename: String, patterns: [String]) -> Bool {
        // Normalize whitespace (collapse multiple spaces to single space)
        let normalizedFilename = filename.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)

        for pattern in patterns {
            if normalizedFilename.contains(pattern) || normalizedFilename == pattern {
                return true
            }
        }
        return false
    }

    private func parseAuthorFromReadme(in directory: URL) -> String? {
        guard let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return nil
        }

        // Look for readme/txt files
        let readmeFiles = files.filter { url in
            let name = url.lastPathComponent.lowercased()
            let ext = url.pathExtension.lowercased()
            return ext == "txt" || name.contains("readme") || name.contains("read me")
        }

        for file in readmeFiles {
            guard let content = try? String(contentsOf: file, encoding: .utf8) else {
                // Try other encodings
                guard let content = try? String(contentsOf: file, encoding: .windowsCP1252) else { continue }
                if let author = extractAuthor(from: content) { return author }
                continue
            }
            if let author = extractAuthor(from: content) { return author }
        }

        return nil
    }

    private func extractAuthor(from content: String) -> String? {
        let lines = content.components(separatedBy: .newlines)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Pattern: "Author: name" or "by: name"
            if let range = trimmed.range(of: "author:", options: .caseInsensitive) {
                let author = trimmed[range.upperBound...].trimmingCharacters(in: .whitespaces)
                if !author.isEmpty { return String(author) }
            }
            if let range = trimmed.range(of: "by:", options: .caseInsensitive) {
                let author = trimmed[range.upperBound...].trimmingCharacters(in: .whitespaces)
                if !author.isEmpty { return String(author) }
            }
            if let range = trimmed.range(of: "created by", options: .caseInsensitive) {
                let author = trimmed[range.upperBound...].trimmingCharacters(in: .whitespaces)
                if !author.isEmpty { return String(author) }
            }

            // Pattern: "(c) name year" or "© name"
            if trimmed.lowercased().contains("(c)") || trimmed.contains("©") {
                var cleaned = trimmed
                    .replacingOccurrences(of: "(c)", with: "", options: .caseInsensitive)
                    .replacingOccurrences(of: "©", with: "")
                    .trimmingCharacters(in: .whitespaces)
                // Remove year if present
                cleaned = cleaned.replacingOccurrences(of: "\\d{4}", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
                if !cleaned.isEmpty && cleaned.count < 50 { return cleaned }
            }
        }

        // Look for email as fallback (extract name portion)
        for line in lines {
            if let emailRange = line.range(of: "[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+", options: .regularExpression) {
                let email = String(line[emailRange])
                let namePart = email.components(separatedBy: "@").first ?? ""
                let cleanName = namePart.replacingOccurrences(of: "[._]", with: " ", options: .regularExpression)
                if !cleanName.isEmpty { return cleanName }
            }
        }

        return nil
    }

    /// Installs a zip or folder the user picked, off the main thread, and
    /// reloads the list. Calls completion on main.
    func installTheme(from url: URL, completion: ((Result<Theme, Error>) -> Void)? = nil) {
        let name = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "[^a-zA-Z0-9_\\- ]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        installQueue.async {
            let result = Result { try ThemeInstaller.install(from: url, as: name.isEmpty ? "Theme" : name, into: self.themesDirectory) }
            DispatchQueue.main.async {
                self.loadThemes()
                completion?(result.map { self.installedTheme(at: $0) ?? Theme(id: $0.path, name: name, path: $0) })
            }
        }
    }

    /// The loaded theme in `folder`, if any.
    func installedTheme(at folder: URL) -> Theme? {
        themes.first { $0.path.standardizedFileURL.path == folder.standardizedFileURL.path }
    }

    /// Gallery themes in the themes folder by catalog id. A folder counts when a
    /// gallery install marked it, or, for installs from before the marker, when
    /// its name is the id and its name and author match the catalog's.
    func installedCatalogThemes(_ catalog: [String: CatalogTheme]) -> [String: Theme] {
        let folder = themesDirectory.standardizedFileURL.path
        var result: [String: Theme] = [:]
        for theme in themes where theme.path.standardizedFileURL.deletingLastPathComponent().path == folder {
            let id = theme.path.lastPathComponent
            if let catalogID = theme.catalogID {
                if catalogID == id { result[id] = theme }
            } else if let entry = catalog[id], entry.name == theme.name, entry.author == theme.author {
                result[id] = theme
            }
        }
        return result
    }

    // Themes used to ship inside the app, and an applied one stored image
    // paths into the bundle. Reinstalls it from the catalog under the same id.
    func migrateBundledTheme() {
        guard let themeId = UserDefaults.standard.string(forKey: "currentThemeId"),
              themeId.contains(".app/Contents/Resources/Themes/") else { return }
        let id = URL(fileURLWithPath: themeId).lastPathComponent
        ThemeCatalog.shared.install(id, quiet: true) { result in
            // Offline tries again next launch; the default buttons show meanwhile.
            if case .failure(ThemeInstallError.notInCatalog) = result {
                self.clearTheme()
            }
        }
    }

    func applyTheme(_ theme: Theme) {
        currentTheme = theme
        let defaults = UserDefaults.standard

        // Close button states
        defaults.set(theme.closeUp?.path, forKey: "closeButtonImage")
        defaults.set(theme.closeHover?.path, forKey: "closeButtonHoverImage")
        defaults.set(theme.closeDown?.path, forKey: "closeButtonPressedImage")
        defaults.set(theme.closeDisabled?.path, forKey: "closeButtonDisabledImage")

        // Minimize button states
        defaults.set(theme.minimizeUp?.path, forKey: "minimizeButtonImage")
        defaults.set(theme.minimizeHover?.path, forKey: "minimizeButtonHoverImage")
        defaults.set(theme.minimizeDown?.path, forKey: "minimizeButtonPressedImage")
        defaults.set(theme.minimizeDisabled?.path, forKey: "minimizeButtonDisabledImage")

        // Zoom/Maximize button states
        defaults.set(theme.maximizeUp?.path, forKey: "zoomButtonImage")
        defaults.set(theme.maximizeHover?.path, forKey: "zoomButtonHoverImage")
        defaults.set(theme.maximizeDown?.path, forKey: "zoomButtonPressedImage")
        defaults.set(theme.maximizeDisabled?.path, forKey: "zoomButtonDisabledImage")

        // Restore button states (shown when window is zoomed/fullscreen)
        defaults.set(theme.restoreUp?.path, forKey: "restoreButtonImage")
        defaults.set(theme.restoreDown?.path, forKey: "restoreButtonPressedImage")

        // Help button states
        defaults.set(theme.helpUp?.path, forKey: "helpButtonImage")
        defaults.set(theme.helpHover?.path, forKey: "helpButtonHoverImage")
        defaults.set(theme.helpDown?.path, forKey: "helpButtonPressedImage")
        defaults.set(theme.helpDisabled?.path, forKey: "helpButtonDisabledImage")

        defaults.set(theme.frameDirectory?.path, forKey: "windowFrameDirectory")

        defaults.set(theme.id, forKey: "currentThemeId")

        WindowFrameStore.invalidate()
        NotificationCenter.default.post(name: .init("TroisReloadImages"), object: nil)
    }

    func clearTheme() {
        currentTheme = nil
        let defaults = UserDefaults.standard

        // Clear all button states
        for prefix in ["closeButton", "minimizeButton", "zoomButton", "helpButton", "restoreButton"] {
            for suffix in ["Image", "HoverImage", "PressedImage", "DisabledImage"] {
                defaults.removeObject(forKey: prefix + suffix)
            }
        }
        defaults.removeObject(forKey: "windowFrameDirectory")
        defaults.removeObject(forKey: "currentThemeId")

        WindowFrameStore.invalidate()
        NotificationCenter.default.post(name: .init("TroisReloadImages"), object: nil)
    }

    private func loadCurrentTheme() {
        guard let themeId = UserDefaults.standard.string(forKey: "currentThemeId") else { return }
        currentTheme = themeId == draftDirectory.path ? draftTheme() : themes.first { $0.id == themeId }
        // A frame may have been added to the theme folder since it was applied.
        UserDefaults.standard.set(currentTheme?.frameDirectory?.path, forKey: "windowFrameDirectory")
    }

    func deleteTheme(_ theme: Theme) {
        // Only allow deleting user themes, not bundled
        guard theme.path.path.hasPrefix(themesDirectory.path) else { return }

        try? fileManager.removeItem(at: theme.path)
        if currentTheme?.id == theme.id {
            clearTheme()
        }
        loadThemes()
    }

    func revealThemesFolder() {
        NSWorkspace.shared.open(themesDirectory)
    }
}
