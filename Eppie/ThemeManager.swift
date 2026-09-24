// Manages button themes - loading from folders/zips.
import Cocoa
import UniformTypeIdentifiers

struct Theme: Identifiable, Hashable {
    let id: String
    let name: String
    let path: URL
    var author: String?
    var closeUp: URL?
    var closeDown: URL?
    var closeDisabled: URL?
    var minimizeUp: URL?
    var minimizeDown: URL?
    var minimizeDisabled: URL?
    var maximizeUp: URL?
    var maximizeDown: URL?
    var maximizeDisabled: URL?
    var restoreUp: URL?
    var restoreDown: URL?
    var helpUp: URL?
    var helpDown: URL?

    var hasAnyImage: Bool {
        closeUp != nil || minimizeUp != nil || maximizeUp != nil
    }
}

class ThemeManager: ObservableObject {
    static let shared = ThemeManager()

    @Published var themes: [Theme] = []
    @Published var currentTheme: Theme?

    private let themesDirectory: URL
    private let fileManager = FileManager.default

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

    init() {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        themesDirectory = appSupport.appendingPathComponent("Trois/Themes", isDirectory: true)

        try? fileManager.createDirectory(at: themesDirectory, withIntermediateDirectories: true)

        loadThemes()
        loadCurrentTheme()
    }

    func loadThemes() {
        var foundThemes: [Theme] = []

        // Load bundled themes
        if let bundledPath = Bundle.main.resourceURL?.appendingPathComponent("Themes") {
            foundThemes.append(contentsOf: scanDirectory(bundledPath))
        }

        // Load user themes
        foundThemes.append(contentsOf: scanDirectory(themesDirectory))

        themes = foundThemes.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func scanDirectory(_ directory: URL) -> [Theme] {
        guard let contents = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey]) else {
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

    private func loadTheme(from directory: URL) -> Theme? {
        let name = directory.lastPathComponent
        var theme = Theme(id: directory.path, name: name, path: directory)
        // Try readme first, then fall back to known authors mapping
        theme.author = parseAuthorFromReadme(in: directory) ?? knownAuthors[name]

        guard let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return nil
        }

        let imageExtensions = ["bmp", "png", "jpg", "jpeg", "tiff", "gif"]

        for file in files {
            let ext = file.pathExtension.lowercased()
            guard imageExtensions.contains(ext) else { continue }

            let filename = file.deletingPathExtension().lastPathComponent.lowercased()

            // Match common naming patterns from the Windows gallery
            if matchesPattern(filename, patterns: ["closeup", "close_up", "close up", "close button up", "close window button", "1closeup"]) {
                theme.closeUp = file
            } else if matchesPattern(filename, patterns: ["closedwn", "closedown", "close_down", "close down", "close button down", "close window button down", "close_dw", "1closedn"]) {
                theme.closeDown = file
            } else if matchesPattern(filename, patterns: ["closedis", "close_disable", "close disabled", "close button disabled", "close gray", "close_ds", "1closedis"]) {
                theme.closeDisabled = file
            } else if matchesPattern(filename, patterns: ["minup", "min_up", "min up", "mini_up", "minim_up", "minimize_up", "minimize up", "minimize button up", "1minup"]) {
                theme.minimizeUp = file
            } else if matchesPattern(filename, patterns: ["mindwn", "mindown", "min_down", "min down", "min dwn", "mini_dwn", "minim_dw", "minimize_down", "minimize down", "minimize button down", "1mindn"]) {
                theme.minimizeDown = file
            } else if matchesPattern(filename, patterns: ["mindis", "min_disable", "min disabled", "min gray", "mini_dis", "minim_ds", "minimize_dis", "minimize button disabled", "1mindis"]) {
                theme.minimizeDisabled = file
            } else if matchesPattern(filename, patterns: ["maxup", "max_up", "max up", "maxim_up", "maximize_up", "maximize up", "maximize button up", "1maxup"]) {
                theme.maximizeUp = file
            } else if matchesPattern(filename, patterns: ["maxdwn", "maxdown", "max_down", "max down", "max dwn", "maxim_dw", "maximize_down", "maximize down", "maximize button down", "1maxdn"]) {
                theme.maximizeDown = file
            } else if matchesPattern(filename, patterns: ["maxdis", "max_disable", "max disabled", "max gray", "maxim_ds", "maximize_dis", "maximize button disabled", "1maxdis"]) {
                theme.maximizeDisabled = file
            } else if matchesPattern(filename, patterns: ["resup", "restore up", "restore_up", "restore button up", "rst_up", "1resup"]) {
                theme.restoreUp = file
            } else if matchesPattern(filename, patterns: ["resdwn", "resdown", "restore down", "restore_down", "restore_dw", "rst_dwn", "restore button down", "1resdn"]) {
                theme.restoreDown = file
            } else if matchesPattern(filename, patterns: ["helpup", "help up", "help button up", "1helpup"]) {
                theme.helpUp = file
            } else if matchesPattern(filename, patterns: ["helpdwn", "helpdown", "help down", "help dwn", "help button down", "1helpdn"]) {
                theme.helpDown = file
            }
        }

        return theme.hasAnyImage ? theme : nil
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

    func installTheme(from url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()

        if ext == "zip" {
            return installFromZip(url)
        } else {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return installFromFolder(url)
            }
        }
        return false
    }

    private func installFromZip(_ zipURL: URL) -> Bool {
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)

        do {
            try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)

            // Use ditto to unzip (available on macOS)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-xk", zipURL.path, tempDir.path]
            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else { return false }

            // Find the theme folder (might be nested)
            let contents = try fileManager.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: [.isDirectoryKey])

            var sourceDir = tempDir
            // If there's a single folder inside, use that
            if contents.count == 1,
               let first = contents.first,
               (try? first.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                sourceDir = first
            }

            let themeName = zipURL.deletingPathExtension().lastPathComponent
            let destDir = themesDirectory.appendingPathComponent(themeName)

            if fileManager.fileExists(atPath: destDir.path) {
                try fileManager.removeItem(at: destDir)
            }

            try fileManager.copyItem(at: sourceDir, to: destDir)
            try fileManager.removeItem(at: tempDir)

            loadThemes()
            return true
        } catch {
            print("Failed to install theme from zip: \(error)")
            try? fileManager.removeItem(at: tempDir)
            return false
        }
    }

    private func installFromFolder(_ folderURL: URL) -> Bool {
        let themeName = folderURL.lastPathComponent
        let destDir = themesDirectory.appendingPathComponent(themeName)

        do {
            if fileManager.fileExists(atPath: destDir.path) {
                try fileManager.removeItem(at: destDir)
            }
            try fileManager.copyItem(at: folderURL, to: destDir)
            loadThemes()
            return true
        } catch {
            print("Failed to install theme from folder: \(error)")
            return false
        }
    }

    func applyTheme(_ theme: Theme) {
        currentTheme = theme
        let defaults = UserDefaults.standard

        // Close button states
        defaults.set(theme.closeUp?.path, forKey: "closeButtonImage")
        defaults.set(theme.closeDown?.path, forKey: "closeButtonPressedImage")
        defaults.set(theme.closeDisabled?.path, forKey: "closeButtonDisabledImage")

        // Minimize button states
        defaults.set(theme.minimizeUp?.path, forKey: "minimizeButtonImage")
        defaults.set(theme.minimizeDown?.path, forKey: "minimizeButtonPressedImage")
        defaults.set(theme.minimizeDisabled?.path, forKey: "minimizeButtonDisabledImage")

        // Zoom/Maximize button states
        defaults.set(theme.maximizeUp?.path, forKey: "zoomButtonImage")
        defaults.set(theme.maximizeDown?.path, forKey: "zoomButtonPressedImage")
        defaults.set(theme.maximizeDisabled?.path, forKey: "zoomButtonDisabledImage")

        // Restore button states (shown when window is zoomed/fullscreen)
        defaults.set(theme.restoreUp?.path, forKey: "restoreButtonImage")
        defaults.set(theme.restoreDown?.path, forKey: "restoreButtonPressedImage")

        // Help button states
        defaults.set(theme.helpUp?.path, forKey: "helpButtonImage")
        defaults.set(theme.helpDown?.path, forKey: "helpButtonPressedImage")

        defaults.set(theme.id, forKey: "currentThemeId")

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
        defaults.removeObject(forKey: "currentThemeId")

        NotificationCenter.default.post(name: .init("TroisReloadImages"), object: nil)
    }

    private func loadCurrentTheme() {
        guard let themeId = UserDefaults.standard.string(forKey: "currentThemeId") else { return }
        currentTheme = themes.first { $0.id == themeId }
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

    func saveCustomTheme(name: String, author: String?) -> String? {
        let defaults = UserDefaults.standard

        // Gather all custom image paths
        var imagePaths: [(key: String, path: String, destName: String)] = []

        let imageKeys: [(key: String, dest: String)] = [
            ("closeButtonImage", "close_up"),
            ("closeButtonHoverImage", "close_hover"),
            ("closeButtonPressedImage", "close_down"),
            ("closeButtonDisabledImage", "close_disabled"),
            ("minimizeButtonImage", "min_up"),
            ("minimizeButtonHoverImage", "min_hover"),
            ("minimizeButtonPressedImage", "min_down"),
            ("minimizeButtonDisabledImage", "min_disabled"),
            ("zoomButtonImage", "max_up"),
            ("zoomButtonHoverImage", "max_hover"),
            ("zoomButtonPressedImage", "max_down"),
            ("zoomButtonDisabledImage", "max_disabled"),
            ("helpButtonImage", "help_up"),
            ("helpButtonHoverImage", "help_hover"),
            ("helpButtonPressedImage", "help_down"),
            ("helpButtonDisabledImage", "help_disabled")
        ]

        for (key, destBase) in imageKeys {
            if let path = defaults.string(forKey: key),
               fileManager.fileExists(atPath: path) {
                let ext = URL(fileURLWithPath: path).pathExtension
                imagePaths.append((key, path, "\(destBase).\(ext)"))
            }
        }

        guard !imagePaths.isEmpty else { return nil }

        // Create safe folder name
        let safeName = name.replacingOccurrences(of: "[^a-zA-Z0-9_\\- ]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let folderName = safeName.isEmpty ? "Custom Theme" : safeName

        var destDir = themesDirectory.appendingPathComponent(folderName)

        // Add number suffix if exists
        var suffix = 1
        while fileManager.fileExists(atPath: destDir.path) {
            destDir = themesDirectory.appendingPathComponent("\(folderName) \(suffix)")
            suffix += 1
        }

        do {
            try fileManager.createDirectory(at: destDir, withIntermediateDirectories: true)

            // Copy images
            for (_, sourcePath, destName) in imagePaths {
                let destURL = destDir.appendingPathComponent(destName)
                try fileManager.copyItem(atPath: sourcePath, toPath: destURL.path)
            }

            // Create readme with author info
            var readme = "Theme: \(name)\n"
            if let author = author, !author.isEmpty {
                readme += "Author: \(author)\n"
            }
            readme += "\nCreated with Trois\n"

            let readmeURL = destDir.appendingPathComponent("readme.txt")
            try readme.write(to: readmeURL, atomically: true, encoding: .utf8)

            return destDir.path
        } catch {
            print("Failed to save custom theme: \(error)")
            try? fileManager.removeItem(at: destDir)
            return nil
        }
    }
}
