// Checks that unsafe or unusable themes are rejected before anything is installed.
import XCTest
@testable import Trois

// Every case here fails before install reaches ThemeManager.shared, which
// would read and write the app's real settings.
final class ThemeInstallerTests: XCTestCase {
    private var scratch: Scratch!
    private var destination: URL!

    override func setUpWithError() throws {
        scratch = try Scratch(self)
        destination = try scratch.folder("Themes")
    }

    func testMissingSource() throws {
        assertRejected(scratch.url.appendingPathComponent("gone.zip")) {
            guard case .failed = $0 else { return false }
            return true
        }
    }

    func testNeitherZipNorFolder() throws {
        let file = scratch.url.appendingPathComponent("theme.rar")
        try Data([0]).write(to: file)
        assertRejected(file) {
            guard case .failed = $0 else { return false }
            return true
        }
    }

    func testFolderWithAFileThatIsNotAnImageOrReadme() throws {
        let folder = try scratch.folder("Theme")
        try Fixtures.png(16, 16, at: folder.appendingPathComponent("close_up.png"))
        try Data("echo hi".utf8).write(to: folder.appendingPathComponent("setup.sh"))
        assertUnsafe(folder)
    }

    func testFolderWithASymlink() throws {
        let folder = try scratch.folder("Theme")
        try Fixtures.png(16, 16, at: folder.appendingPathComponent("close_up.png"))
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("min_up.png"),
                                                   withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        assertUnsafe(folder)
    }

    func testZipWithASymlink() throws {
        let folder = try scratch.folder("Theme")
        try Fixtures.png(16, 16, at: folder.appendingPathComponent("close_up.png"))
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("min_up.png"),
                                                   withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        // -y stores the link itself rather than what it points to.
        try Fixtures.run("/usr/bin/zip", ["-qry", "theme.zip", "Theme"], in: scratch.url)
        assertUnsafe(scratch.url.appendingPathComponent("theme.zip"))
    }

    func testZipWithTooManyEntries() throws {
        let folder = try scratch.folder("Theme")
        for i in 0...ThemeInstaller.maxFiles {
            try Data("\(i)".utf8).write(to: folder.appendingPathComponent("\(i).txt"))
        }
        try Fixtures.run("/usr/bin/zip", ["-qr", "theme.zip", "Theme"], in: scratch.url)
        assertUnsafe(scratch.url.appendingPathComponent("theme.zip"))
    }

    func testZipOverTheSizeLimit() throws {
        let folder = try scratch.folder("Theme")
        // Random bytes don't compress, so the zip stays over the limit.
        var bytes = [UInt8](repeating: 0, count: ThemeInstaller.maxArchiveBytes + 100_000)
        XCTAssertEqual(SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes), errSecSuccess)
        try Data(bytes).write(to: folder.appendingPathComponent("close_up.png"))
        try Fixtures.run("/usr/bin/zip", ["-qr", "theme.zip", "Theme"], in: scratch.url)
        assertRejected(scratch.url.appendingPathComponent("theme.zip")) {
            guard case .tooLarge = $0 else { return false }
            return true
        }
    }

    func testUnusedFolderNumbersTakenNames() throws {
        XCTAssertEqual(ThemeInstaller.unusedFolder(named: "Aqua", in: destination).lastPathComponent, "Aqua")
        _ = try scratch.folder("Themes/Aqua")
        XCTAssertEqual(ThemeInstaller.unusedFolder(named: "Aqua", in: destination).lastPathComponent, "Aqua 2")
        _ = try scratch.folder("Themes/Aqua 2")
        XCTAssertEqual(ThemeInstaller.unusedFolder(named: "Aqua", in: destination).lastPathComponent, "Aqua 3")
    }

    // MARK: - Helpers

    private func assertUnsafe(_ source: URL, file: StaticString = #filePath, line: UInt = #line) {
        assertRejected(source, file: file, line: line) {
            guard case .unsafeArchive = $0 else { return false }
            return true
        }
    }

    /// Installs `source`, expecting an error `matches` accepts and nothing installed.
    private func assertRejected(_ source: URL, file: StaticString = #filePath, line: UInt = #line,
                                _ matches: (ThemeInstallError) -> Bool) {
        XCTAssertThrowsError(try ThemeInstaller.install(from: source, as: "Theme", into: destination),
                             file: file, line: line) { error in
            guard let error = error as? ThemeInstallError else {
                return XCTFail("Unexpected error \(error)", file: file, line: line)
            }
            XCTAssertTrue(matches(error), "Unexpected error \(error)", file: file, line: line)
        }
        let installed = (try? FileManager.default.contentsOfDirectory(atPath: destination.path)) ?? []
        XCTAssertEqual(installed, [], file: file, line: line)
    }
}
