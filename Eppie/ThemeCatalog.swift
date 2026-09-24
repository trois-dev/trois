// Installs themes from the online catalog and from zips or folders.
import Foundation
import CryptoKit

enum ThemeInstallError: LocalizedError {
    case notInCatalog
    case catalogUnavailable(String)
    case download(String)
    case checksumMismatch
    case tooLarge
    case unsafeArchive(String)
    case noButtons
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notInCatalog: return "That theme isn't in the Trois catalog."
        case .catalogUnavailable(let reason): return "Couldn't load the theme catalog. \(reason)"
        case .download(let reason): return "Couldn't download the theme. \(reason)"
        case .checksumMismatch: return "The downloaded theme didn't match the catalog, so it wasn't installed."
        case .tooLarge: return "The theme is too large."
        case .unsafeArchive(let reason): return "The theme wasn't installed: \(reason)"
        case .noButtons: return "No close, minimize or zoom images were found."
        case .failed(let reason): return "The theme couldn't be installed. \(reason)"
        }
    }
}

/// Unpacks and checks a theme before it reaches the themes folder. Blocking;
/// call off the main thread.
enum ThemeInstaller {
    static let maxArchiveBytes = 2_000_000
    static let maxExtractedBytes = 10_000_000
    static let maxFiles = 200
    // Images, readmes and the files Windows themes came with. Kept in step
    // with scripts/build.py in the catalog repo.
    static let allowedExtensions: Set<String> = [
        "bmp", "png", "jpg", "jpeg", "gif", "tif", "tiff", "ico", "txt", "3dc", "ccs", "reg", "json",
    ]

    /// Installs a zip or folder as `directory/name`, replacing a theme there.
    /// Returns the installed folder.
    static func install(from source: URL, as name: String, into directory: URL) throws -> URL {
        let fileManager = FileManager.default
        let staging = fileManager.temporaryDirectory.appendingPathComponent("Trois-\(UUID().uuidString)")
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory) else {
            throw ThemeInstallError.failed("The file is missing.")
        }
        let unpacked = staging.appendingPathComponent("contents")
        if isDirectory.boolValue {
            try fileManager.copyItem(at: source, to: unpacked)
        } else if source.pathExtension.lowercased() == "zip" {
            try checkArchive(source)
            try fileManager.createDirectory(at: unpacked, withIntermediateDirectories: true)
            guard run("/usr/bin/ditto", ["-xk", source.path, unpacked.path]).status == 0 else {
                throw ThemeInstallError.unsafeArchive("the zip couldn't be opened.")
            }
        } else {
            throw ThemeInstallError.failed("Choose a zip or a folder.")
        }

        try checkContents(of: unpacked)
        let root = themeRoot(in: unpacked)
        guard ThemeManager.shared.loadTheme(from: root) != nil else { throw ThemeInstallError.noButtons }

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(name, isDirectory: true)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: root)
        } else {
            try fileManager.moveItem(at: root, to: destination)
        }
        return destination
    }

    // Rejects symlinks and paths that leave the folder before anything is
    // written. ditto keeps ../ entries inside the destination but extracts
    // symlinks as they are.
    private static func checkArchive(_ zip: URL) throws {
        let size = (try? zip.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxArchiveBytes else { throw ThemeInstallError.tooLarge }

        let listing = run("/usr/bin/zipinfo", [zip.path])
        let names = run("/usr/bin/zipinfo", ["-1", zip.path])
        guard listing.status == 0, names.status == 0 else {
            throw ThemeInstallError.unsafeArchive("the zip couldn't be read.")
        }
        // Line 2 is "Zip file size: N bytes, number of entries: N". Entry lines
        // follow, one per entry, each starting with its mode: "lrwxrwxrwx" for
        // a symlink, "-rw-r--r--" or a DOS "-rw-a--" otherwise.
        let lines = listing.output.split(separator: "\n", omittingEmptySubsequences: false)
        let paths = names.output.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count > 2,
              let countRange = lines[1].range(of: #"number of entries: \d+"#, options: .regularExpression),
              let count = Int(lines[1][countRange].split(separator: " ").last ?? ""),
              count == paths.count, count <= maxFiles, lines.count >= 2 + count else {
            throw ThemeInstallError.unsafeArchive("the zip has too many or unreadable entries.")
        }
        if lines[2..<(2 + count)].contains(where: { $0.hasPrefix("l") }) {
            throw ThemeInstallError.unsafeArchive("it contains a symlink.")
        }
        for path in paths {
            let components = path.split(separator: "/")
            if path.hasPrefix("/") || components.contains("..") {
                throw ThemeInstallError.unsafeArchive("it contains a path outside the theme folder.")
            }
        }
        // Summary line: "N files, X bytes uncompressed, Y bytes compressed: Z%".
        if let summary = listing.output.split(separator: "\n").last,
           let match = summary.range(of: #"(\d+) bytes uncompressed"#, options: .regularExpression),
           let bytes = Int(summary[match].split(separator: " ")[0]),
           bytes > maxExtractedBytes {
            throw ThemeInstallError.tooLarge
        }
    }

    // Checks what was unpacked, whatever it came from.
    private static func checkContents(of folder: URL) throws {
        let fileManager = FileManager.default
        // Finder zips carry resource forks here; nothing in them is needed.
        try? fileManager.removeItem(at: folder.appendingPathComponent("__MACOSX"))

        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey]
        guard let enumerator = fileManager.enumerator(at: folder, includingPropertiesForKeys: keys) else {
            throw ThemeInstallError.failed("The theme couldn't be read.")
        }
        var count = 0
        var total = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true {
                throw ThemeInstallError.unsafeArchive("it contains a symlink.")
            }
            guard values.isRegularFile == true else { continue }
            if url.lastPathComponent == ".DS_Store" {
                try? fileManager.removeItem(at: url)
                continue
            }
            guard allowedExtensions.contains(url.pathExtension.lowercased()) else {
                throw ThemeInstallError.unsafeArchive("\(url.lastPathComponent) isn't an image or readme.")
            }
            count += 1
            total += values.fileSize ?? 0
            guard count <= maxFiles, total <= maxExtractedBytes else { throw ThemeInstallError.tooLarge }
        }
    }

    // A zip usually holds one folder with the theme in it.
    private static func themeRoot(in folder: URL) -> URL {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles
        )) ?? []
        if contents.count == 1, let only = contents.first,
           (try? only.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            return only
        }
        return folder
    }

    private static func run(_ tool: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return (-1, "")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

struct CatalogTheme: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let author: String
    let engine: String?
    let source: String?
    let version: Int
    let size: Int
    let sha256: String
    let download: String
    // Button key (close, minimize, zoom) to a PNG path relative to the index.
    let preview: [String: String]
}

private struct CatalogIndex: Decodable {
    let format: Int
    let themes: [CatalogTheme]
}

/// The online theme catalog. Only themes listed in its index can be installed,
/// and each download must match the size and SHA-256 the index gives.
final class ThemeCatalog: ObservableObject {
    static let shared = ThemeCatalog()

    static var indexURL: URL {
        #if DEBUG
        // Points a debug build at a local catalog build, e.g. file:///.../site/index.json.
        if let override = UserDefaults.standard.string(forKey: "themeCatalogURL"), let url = URL(string: override) {
            return url
        }
        #endif
        return URL(string: "https://trois-dev.github.io/trois-themes/index.json")!
    }

    @Published private(set) var themes: [CatalogTheme] = []
    @Published private(set) var isLoading = false
    @Published private(set) var loadError: String?
    @Published private(set) var installing: Set<String> = []
    // Shown by the Get Themes tab.
    @Published var installError: String?

    private var pendingLoads: [(Result<[CatalogTheme], Error>) -> Void] = []

    static func isValidID(_ id: String) -> Bool {
        id.range(of: #"^[A-Za-z0-9_-]{1,64}$"#, options: .regularExpression) != nil
    }

    /// Fetches the index. Calls completion on main.
    func refresh(completion: ((Result<[CatalogTheme], Error>) -> Void)? = nil) {
        if let completion {
            pendingLoads.append(completion)
        }
        guard !isLoading else { return }
        isLoading = true
        var request = URLRequest(url: Self.indexURL)
        request.cachePolicy = .reloadRevalidatingCacheData
        URLSession.shared.dataTask(with: request) { data, response, error in
            let result: Result<[CatalogTheme], Error>
            if let error {
                result = .failure(ThemeInstallError.catalogUnavailable(error.localizedDescription))
            } else if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                result = .failure(ThemeInstallError.catalogUnavailable("The server returned \(http.statusCode)."))
            } else if let data, let index = try? JSONDecoder().decode(CatalogIndex.self, from: data), index.format == 1 {
                result = .success(index.themes.filter { Self.isValidID($0.id) })
            } else {
                result = .failure(ThemeInstallError.catalogUnavailable("The catalog couldn't be read."))
            }
            DispatchQueue.main.async {
                self.isLoading = false
                switch result {
                case .success(let themes):
                    self.themes = themes
                    self.loadError = nil
                case .failure(let error):
                    self.loadError = error.localizedDescription
                }
                let callbacks = self.pendingLoads
                self.pendingLoads = []
                callbacks.forEach { $0(result) }
            }
        }.resume()
    }

    /// Downloads, checks, installs and applies a catalog theme. Calls
    /// completion on main. Unless `quiet`, failures also set installError.
    func install(_ id: String, quiet: Bool = false, completion: ((Result<Theme, Error>) -> Void)? = nil) {
        guard Self.isValidID(id), !installing.contains(id) else { return }
        installing.insert(id)
        let done: (Result<Theme, Error>) -> Void = { result in
            self.installing.remove(id)
            if !quiet, case .failure(let error) = result {
                self.installError = error.localizedDescription
            }
            completion?(result)
        }
        refresh { result in
            switch result {
            case .failure(let error):
                done(.failure(error))
            case .success(let themes):
                guard let entry = themes.first(where: { $0.id == id }) else {
                    done(.failure(ThemeInstallError.notInCatalog))
                    return
                }
                self.download(entry, done)
            }
        }
    }

    /// A catalog-relative path as a URL on the catalog's own host.
    func url(for path: String) -> URL? {
        guard let url = URL(string: path, relativeTo: Self.indexURL)?.absoluteURL,
              url.scheme == Self.indexURL.scheme, url.host == Self.indexURL.host else { return nil }
        return url
    }

    private func download(_ entry: CatalogTheme, _ completion: @escaping (Result<Theme, Error>) -> Void) {
        guard entry.size <= ThemeInstaller.maxArchiveBytes else {
            completion(.failure(ThemeInstallError.tooLarge))
            return
        }
        guard let url = url(for: entry.download) else {
            completion(.failure(ThemeInstallError.notInCatalog))
            return
        }
        let themesDirectory = ThemeManager.shared.themesDirectory
        URLSession.shared.downloadTask(with: url) { file, response, error in
            let result = Result<URL, Error> {
                if let error {
                    throw ThemeInstallError.download(error.localizedDescription)
                }
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    throw ThemeInstallError.download("The server returned \(http.statusCode).")
                }
                guard let file else { throw ThemeInstallError.download("No data was received.") }
                let data = try Data(contentsOf: file)
                guard data.count == entry.size else { throw ThemeInstallError.checksumMismatch }
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                guard digest == entry.sha256.lowercased() else { throw ThemeInstallError.checksumMismatch }

                let zip = FileManager.default.temporaryDirectory.appendingPathComponent("Trois-\(UUID().uuidString).zip")
                try data.write(to: zip)
                defer { try? FileManager.default.removeItem(at: zip) }
                return try ThemeInstaller.install(from: zip, as: entry.id, into: themesDirectory)
            }
            DispatchQueue.main.async {
                let themeManager = ThemeManager.shared
                themeManager.loadThemes()
                let installed = result.flatMap { folder -> Result<Theme, Error> in
                    guard let theme = themeManager.installedTheme(at: folder) else {
                        return .failure(ThemeInstallError.noButtons)
                    }
                    themeManager.applyTheme(theme)
                    return .success(theme)
                }
                completion(installed)
            }
        }.resume()
    }
}
