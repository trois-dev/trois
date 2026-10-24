// Checks how frame folders are read and how layouts are validated.
import XCTest
@testable import Trois

final class WindowFrameTests: XCTestCase {
    // MARK: - Kaleidoscope 2

    func testKaleidoscopeRectsAreTopLeftBottomRightGridLines() throws {
        let frame = try kaleidoscope(size: 40, rects: [[0, [10, 5, 30, 35]], [1, [2, 6, 8, 12]]])
        XCTAssertEqual(frame.content, CGRect(x: 5, y: 10, width: 30, height: 20))
        XCTAssertEqual(frame.rect(.close), CGRect(x: 6, y: 2, width: 6, height: 6))
        let insets = frame.insets
        XCTAssertEqual([insets.top, insets.left, insets.bottom, insets.right], [10, 5, 10, 5])
        XCTAssertFalse(frame.fixedLayout)
    }

    func testKaleidoscopeEmptyRectCountsAsMissing() throws {
        let frame = try kaleidoscope(size: 40, rects: [[0, [10, 5, 30, 35]], [2, [0, 0, 0, 0]]])
        XCTAssertNil(frame.rect(.zoom))
    }

    func testKaleidoscopeRejectsContentPastTheImage() throws {
        XCTAssertNil(try kaleidoscopeOrNil(size: 40, rects: [[0, [10, 5, 30, 45]]]))
    }

    func testKaleidoscopeRejectsMissingContent() throws {
        XCTAssertNil(try kaleidoscopeOrNil(size: 40, rects: [[1, [2, 6, 8, 12]]]))
    }

    func testKaleidoscopeRejectsMissingLayout() throws {
        let scratch = try Scratch(self)
        let folder = try scratch.folder("frame")
        try Fixtures.png(40, 40, at: folder.appendingPathComponent("active.png"))
        try Fixtures.json([String: Any](), at: folder.appendingPathComponent("layout.json"))
        XCTAssertNil(WindowFrame(directory: folder))
    }

    // MARK: - Kaleidoscope 1.x

    func testK1NeedsASixteenPixelIcon() throws {
        let scratch = try Scratch(self)
        let good = try scratch.folder("good/frame")
        try Fixtures.png(16, 16, at: good.appendingPathComponent("active.png"))
        try Fixtures.json(["format": "k1"], at: good.appendingPathComponent("layout.json"))
        let frame = try XCTUnwrap(WindowFrame(directory: good))
        XCTAssertNotNil(frame.k1)
        XCTAssertTrue(frame.fixedLayout)
        let insets = frame.insets
        XCTAssertEqual([insets.top, insets.left, insets.bottom, insets.right], [22, 6, 6, 6])

        let bad = try scratch.folder("bad/frame")
        try Fixtures.png(20, 20, at: bad.appendingPathComponent("active.png"))
        try Fixtures.json(["format": "k1"], at: bad.appendingPathComponent("layout.json"))
        XCTAssertNil(WindowFrame(directory: bad))
    }

    func testK1InactiveIconOfTheWrongSizeFallsBackToActive() throws {
        let scratch = try Scratch(self)
        let folder = try scratch.folder("theme/frame")
        try Fixtures.png(16, 16, at: folder.appendingPathComponent("active.png"))
        try Fixtures.png(20, 20, at: folder.appendingPathComponent("inactive.png"))
        try Fixtures.json(["format": "k1"], at: folder.appendingPathComponent("layout.json"))
        let frame = try XCTUnwrap(WindowFrame(directory: folder))
        XCTAssertEqual(frame.inactive.width, 16)
    }

    func testK1WidgetsComeFromTheThemeFolder() throws {
        let scratch = try Scratch(self)
        let theme = try scratch.folder("theme")
        let folder = try scratch.folder("theme/frame")
        try Fixtures.png(16, 16, at: folder.appendingPathComponent("active.png"))
        try Fixtures.json(["format": "k1"], at: folder.appendingPathComponent("layout.json"))
        try Fixtures.png(16, 16, at: theme.appendingPathComponent("close_up.png"))
        try Fixtures.png(16, 16, at: theme.appendingPathComponent("close_down.png"))
        try Fixtures.png(16, 16, at: theme.appendingPathComponent("min_up.png"))

        let parts = try XCTUnwrap(WindowFrame(directory: folder)?.k1)
        XCTAssertNotNil(parts.widgets[.close]?.down)
        XCTAssertNotNil(parts.widgets[.collapse])
        XCTAssertNil(parts.widgets[.collapse]?.down)
        XCTAssertNil(parts.widgets[.zoom])
    }

    // MARK: - WindowBlinds

    func testWindowBlindsInsetsAreTheEdgeThicknesses() throws {
        let frame = try XCTUnwrap(try windowBlinds(buttons: []))
        let insets = frame.insets
        XCTAssertEqual([insets.top, insets.left, insets.bottom, insets.right], [30, 4, 6, 5])
        let top = try XCTUnwrap(frame.wb?.edges[.top])
        XCTAssertEqual([top.start, top.end], [12, 20])
        XCTAssertFalse(top.tile)
        XCTAssertTrue(try XCTUnwrap(frame.wb?.edges[.left]).tile)
    }

    func testWindowBlindsNeedsAllFourEdges() throws {
        XCTAssertNil(try windowBlinds(buttons: [], skip: "bottom"))
    }

    func testWindowBlindsButtons() throws {
        let buttons: [[String: Any]] = [
            ["image": "restore.png", "states": 3, "align": 1, "x": 40, "y": 5, "widget": "restore",
             "when": ["maximized": false], "alpha": 128],
            ["image": "close.png", "states": 6, "widget": "close"],
            // A decoration: no widget.
            ["image": "logo.png", "states": 3, "align": 0, "x": 2, "y": 2],
            // Narrower than its states: skipped. convert.py never writes one.
            ["image": "tiny.png", "states": 6, "widget": "minimize"],
            ["image": "missing.png", "states": 3, "widget": "minimize"],
        ]
        let parts = try XCTUnwrap(try windowBlinds(buttons: buttons)?.wb)
        XCTAssertEqual(parts.buttons.count, 3)

        let restore = parts.buttons[0]
        XCTAssertEqual(restore.widget, .zoom)
        XCTAssertEqual(restore.size, CGSize(width: 16, height: 16))
        XCTAssertEqual(restore.align, 1)
        XCTAssertEqual([restore.x, restore.y], [40, 5])
        XCTAssertEqual(restore.when, ["maximized": false])
        XCTAssertEqual(restore.alpha, 128.0 / 255, accuracy: 0.001)

        XCTAssertEqual(parts.buttons[1].widget, .close)
        XCTAssertEqual(parts.buttons[1].size, CGSize(width: 8, height: 16))
        XCTAssertEqual(parts.buttons[1].alpha, 1)
        XCTAssertNil(parts.buttons[2].widget)
        XCTAssertEqual(parts.buttons[2].size, CGSize(width: 16, height: 16))
    }

    // MARK: - Validation

    func testRunErrors() {
        XCTAssertNotNil(WindowFrame.runError([], extent: 40))
        XCTAssertNotNil(WindowFrame.runError([(1, 20), (2, 10)], extent: 40))
        XCTAssertNotNil(WindowFrame.runError([(1, 20), (2, 41)], extent: 40))
        XCTAssertNil(WindowFrame.runError([(1, 20), (2, 20), (3, 40)], extent: 40))
    }

    func testBoxErrors() throws {
        let frame = try kaleidoscope(size: 40, rects: [[0, [10, 5, 30, 35]]])
        let content = CGRect(x: 5, y: 10, width: 30, height: 20)
        XCTAssertNotNil(frame.boxError([.close: CGRect(x: 6, y: 2, width: 6, height: 6)]))
        XCTAssertNotNil(frame.boxError([.content: content, .close: CGRect(x: 36, y: 2, width: 6, height: 6)]))
        XCTAssertNotNil(frame.boxError([.content: content, .close: CGRect(x: 10, y: 12, width: 6, height: 6)]))
        XCTAssertNotNil(frame.boxError([.content: content, .title: CGRect(x: 10, y: 32, width: 20, height: 6)]))
        XCTAssertNil(frame.boxError([.content: content, .close: CGRect(x: 6, y: 2, width: 6, height: 6),
                                     .title: CGRect(x: 14, y: 2, width: 20, height: 6)]))
    }

    func testSideOfABox() {
        let content = CGRect(x: 5, y: 10, width: 30, height: 20)
        XCTAssertEqual(WindowFrame.side(of: CGRect(x: 6, y: 2, width: 6, height: 6), content: content), .top)
        XCTAssertEqual(WindowFrame.side(of: CGRect(x: 6, y: 32, width: 6, height: 6), content: content), .bottom)
        XCTAssertEqual(WindowFrame.side(of: CGRect(x: 0, y: 15, width: 4, height: 6), content: content), .left)
        XCTAssertEqual(WindowFrame.side(of: CGRect(x: 36, y: 15, width: 4, height: 6), content: content), .right)
        XCTAssertNil(WindowFrame.side(of: CGRect(x: 10, y: 15, width: 6, height: 6), content: content))
    }

    // MARK: - Helpers

    private func kaleidoscope(size: Int, rects: [[Any]]) throws -> WindowFrame {
        try XCTUnwrap(try kaleidoscopeOrNil(size: size, rects: rects))
    }

    private func kaleidoscopeOrNil(size: Int, rects: [[Any]]) throws -> WindowFrame? {
        let scratch = try Scratch(self)
        let folder = try scratch.folder("frame")
        try Fixtures.png(size, size, at: folder.appendingPathComponent("active.png"))
        let layout: [String: Any] = ["rects": rects, "top": [[1, size]], "bottom": [[1, size]],
                                     "left": [[1, size]], "right": [[1, size]]]
        try Fixtures.json(["layout": layout], at: folder.appendingPathComponent("layout.json"))
        return WindowFrame(directory: folder)
    }

    /// A WindowBlinds frame folder as windowblinds/tools/convert.py writes it.
    /// Each button image is 48 x 16 pixels, or 4 x 16 for tiny.png. A 6-state
    /// strip's width covers all six, so close.png's states are 8 wide.
    private func windowBlinds(buttons: [[String: Any]], skip: String? = nil) throws -> WindowFrame? {
        let scratch = try Scratch(self)
        let folder = try scratch.folder("frame")
        let sizes = ["top": (100, 30), "left": (4, 50), "right": (5, 50), "bottom": (100, 6)]
        for (side, size) in sizes where side != skip {
            try Fixtures.png(size.0, size.1, at: folder.appendingPathComponent("\(side).png"))
        }
        for name in ["restore.png", "close.png", "logo.png"] {
            try Fixtures.png(48, 16, at: folder.appendingPathComponent(name))
        }
        try Fixtures.png(4, 16, at: folder.appendingPathComponent("tiny.png"))
        let edges: [String: Any] = [
            "top": ["start": 12, "end": 20, "tile": false], "left": ["start": 5, "end": 5],
            "right": ["start": 5, "end": 5], "bottom": ["start": 3, "end": 3],
        ]
        try Fixtures.json(["format": "wb", "edges": edges, "buttons": buttons, "text": ["shift": 4]],
                          at: folder.appendingPathComponent("layout.json"))
        return WindowFrame(directory: folder)
    }
}
