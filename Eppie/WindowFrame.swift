// Lays out and draws Kaleidoscope window frames around windows of any size.
import Cocoa

/// A Kaleidoscope 2 document window: the active, inactive and pressed-widget
/// images plus the wnd# layout that says how to stretch them. Read from a
/// theme's `frame/` folder (see kaleidoscope/tools/convert.py). A layout.json
/// of {"format": "k1"} marks a 1.x scheme instead, drawn by WindowFrameK1.swift.
///
/// All coordinates are image pixels with a top-left origin. One pixel draws as
/// one point, the size these were made for.
struct WindowFrame {
    enum Widget: Int, CaseIterable {
        case close = 1, zoom = 2, collapse = 3
    }

    // The four edge lists. Raw values are the layout.json keys.
    enum Side: String, CaseIterable {
        case top, bottom, left, right
        var horizontal: Bool { self == .top || self == .bottom }
    }

    let directory: URL
    // Tells apart two reads of the same folder, whose files may have changed.
    private(set) var identity = UUID()
    let active: CGImage
    let inactive: CGImage
    let pressed: CGImage?
    let size: CGSize
    // Rectangle codes to rects: 0 content, 1 close, 2 zoom, 3 collapse, 4 title text.
    let rects: [Int: CGRect]
    // Edge lists as (part code, cumulative end offset).
    private(set) var top: [(Int, Int)]
    private(set) var bottom: [(Int, Int)]
    private(set) var left: [(Int, Int)]
    private(set) var right: [(Int, Int)]
    // Set for 1.x schemes, which follow fixed rules instead of a layout.
    let k1: K1Parts?
    // layout.json's "title" object.
    private(set) var titleStyle = TitleStyle()

    var content: CGRect { rects[0] ?? CGRect(origin: .zero, size: size) }

    /// Space the frame adds around a window, in points.
    var insets: NSEdgeInsets {
        if k1 != nil { return Self.k1Insets }
        return NSEdgeInsets(top: content.minY, left: content.minX,
                     bottom: size.height - content.maxY, right: size.width - content.maxX)
    }

    init?(directory: URL) {
        func image(_ name: String) -> CGImage? {
            guard let source = CGImageSourceCreateWithURL(directory.appendingPathComponent(name) as CFURL, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("layout.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let active = image("active.png") else { return nil }
        self.directory = directory
        titleStyle = TitleStyle(json: json["title"] as? [String: Any] ?? [:])
        if json["format"] as? String == "k1" {
            guard active.width == 16, active.height == 16 else { return nil }
            self.active = active
            let inactive = image("inactive.png")
            self.inactive = inactive?.width == 16 && inactive?.height == 16 ? inactive! : active
            pressed = nil
            size = CGSize(width: 16, height: 16)
            rects = [:]
            top = []; bottom = []; left = []; right = []
            k1 = Self.loadK1Parts(frameDirectory: directory, image: image)
            return
        }
        guard let layout = json["layout"] as? [String: Any] else { return nil }
        k1 = nil
        self.active = active
        self.inactive = image("inactive.png") ?? active
        self.pressed = image("pressed.png")
        size = CGSize(width: active.width, height: active.height)

        var rects: [Int: CGRect] = [:]
        for entry in layout["rects"] as? [[Any]] ?? [] {
            guard entry.count == 2, let part = entry[0] as? Int, let r = entry[1] as? [Int], r.count == 4 else { continue }
            // wnd# rects are (top, left, bottom, right) grid lines.
            rects[part] = CGRect(x: r[1], y: r[0], width: r[3] - r[1], height: r[2] - r[0])
        }
        guard let content = rects[0], content.width > 0, content.height > 0,
              CGRect(origin: .zero, size: size).contains(content) else { return nil }
        self.rects = rects

        func side(_ key: String) -> [(Int, Int)] {
            (layout[key] as? [[Int]] ?? []).compactMap { $0.count == 2 ? ($0[0], $0[1]) : nil }
        }
        top = side("top")
        bottom = side("bottom")
        left = side("left")
        right = side("right")
    }

    /// Size the pressed strip needs to hold every widget.
    var pressedStripSize: CGSize {
        let widgets = Widget.allCases.compactMap { rects[$0.rawValue] }
        return CGSize(width: widgets.reduce(0) { $0 + $1.width }, height: widgets.map(\.height).max() ?? 0)
    }

    /// Art to paint behind a widget whose image is replaced: a piece of a
    /// stretch or tile section on the same edge, on the widget's rows (its
    /// columns on a side edge), clear of the widget itself. Tile it along
    /// the edge, across the rows if `horizontal`.
    func backdrop(for widget: Widget) -> (source: CGRect, horizontal: Bool)? {
        guard let rect = rects[widget.rawValue], !rect.isEmpty else { return nil }
        let list: [(Int, Int)]
        let horizontal: Bool
        if rect.midY < content.minY { list = top; horizontal = true }
        else if rect.midY > content.maxY { list = bottom; horizontal = true }
        else if rect.midX < content.minX { list = left; horizontal = false }
        else if rect.midX > content.maxX { list = right; horizontal = false }
        else { return nil }
        let extent = horizontal ? size.width : size.height
        let low = horizontal ? rect.minX : rect.minY
        let high = horizontal ? rect.maxX : rect.maxY
        let middle = (low + high) / 2
        func distance(_ piece: (CGFloat, CGFloat)) -> CGFloat {
            min(abs(piece.0 - middle), abs(piece.1 - middle))
        }

        var best: (CGFloat, CGFloat)?
        var position = 0
        for (code, border) in list {
            let start = CGFloat(position)
            position = min(max(border, position), Int(extent))
            let end = CGFloat(position)
            guard Part.grows.contains(code) || Part.fills.contains(code) else { continue }
            // A widget can sit inside a stretch section; keep what's outside it.
            for piece in [(start, min(end, low)), (max(start, high), end)] where piece.1 > piece.0 {
                if best.map({ distance(piece) < distance($0) }) ?? true { best = piece }
            }
        }
        guard let best else { return nil }
        // Tiles repeat, so a short piece is enough.
        let length = min(best.1 - best.0, 32)
        let source = horizontal
            ? CGRect(x: best.0, y: rect.minY, width: length, height: rect.height)
            : CGRect(x: rect.minX, y: best.0, width: rect.width, height: length)
        return (source, horizontal)
    }

    // MARK: - Edge runs

    func runs(_ side: Side) -> [(Int, Int)] {
        switch side {
        case .top: return top
        case .bottom: return bottom
        case .left: return left
        case .right: return right
        }
    }

    /// Length of a side's list in image pixels.
    func extent(_ side: Side) -> Int {
        Int(side.horizontal ? size.width : size.height)
    }

    /// The strip of the image a side's runs are cut from, as drawn by
    /// drawHorizontal and drawVertical.
    func band(_ side: Side) -> CGRect {
        let c = content
        switch side {
        case .top: return CGRect(x: 0, y: 0, width: size.width, height: c.minY)
        case .bottom: return CGRect(x: 0, y: c.maxY, width: size.width, height: size.height - c.maxY)
        case .left: return CGRect(x: 0, y: 0, width: c.minX, height: size.height)
        case .right: return CGRect(x: c.maxX, y: 0, width: size.width - c.maxX, height: size.height)
        }
    }

    /// A copy with `side`'s runs replaced, for previewing edits unsaved.
    func with(_ side: Side, runs: [(Int, Int)]) -> WindowFrame {
        var copy = self
        switch side {
        case .top: copy.top = runs
        case .bottom: copy.bottom = runs
        case .left: copy.left = runs
        case .right: copy.right = runs
        }
        copy.identity = UUID()
        return copy
    }

    /// Why `runs` can't be a side's list, if it can't.
    static func runError(_ runs: [(Int, Int)], extent: Int) -> String? {
        if runs.isEmpty { return "An edge needs at least one run." }
        var position = 0
        for (_, end) in runs {
            if end < position { return "Runs must end in order along the edge." }
            position = end
        }
        if position > extent { return "The last run ends past the image (\(extent) px)." }
        return nil
    }

    /// Things in a side's list that likely draw wrong. `runs` stands in for
    /// the side's current list.
    func runWarnings(_ side: Side, runs list: [(Int, Int)]? = nil) -> [String] {
        let list = list ?? runs(side)
        var out: [String] = []
        var position = 0
        var spans: [(code: Int, start: Int, end: Int)] = []
        for (code, end) in list {
            spans.append((code, position, max(end, position)))
            position = max(end, position)
        }
        for widget in Widget.allCases {
            let codes = [Part.with(widget), Part.without(widget)]
            let runs = spans.filter { codes.contains($0.code) && $0.end > $0.start }
            guard !runs.isEmpty else { continue }
            guard let rect = rects[widget.rawValue], !rect.isEmpty else {
                out.append("A \(Self.widgetName(widget)) run has no \(Self.widgetName(widget)) box in the layout.")
                continue
            }
            guard Self.side(of: rect, content: content) == side else { continue }
            let low = Int(side.horizontal ? rect.minX : rect.minY)
            let high = Int(side.horizontal ? rect.maxX : rect.maxY)
            let withRuns = runs.filter { $0.code == Part.with(widget) }
            if !withRuns.isEmpty && !withRuns.contains(where: { $0.start <= low && $0.end >= high }) {
                out.append("The \(Self.widgetName(widget)) run doesn't cover its box (\(low)-\(high) px).")
            }
        }
        if spans.contains(where: { $0.code == Part.title }) && rects[4] == nil {
            out.append("A title run with no title box in the layout.")
        }
        if !spans.contains(where: { (Part.grows.contains($0.code) || Part.fills.contains($0.code)) && $0.end > $0.start }) {
            out.append("Nothing on this edge grows, so bigger windows leave a gap.")
        }
        return out
    }

    /// The side a widget rect sits on, following backdrop(for:).
    static func side(of rect: CGRect, content: CGRect) -> Side? {
        if rect.midY < content.minY { return .top }
        if rect.midY > content.maxY { return .bottom }
        if rect.midX < content.minX { return .left }
        if rect.midX > content.maxX { return .right }
        return nil
    }

    private static func widgetName(_ widget: Widget) -> String {
        switch widget {
        case .close: return "close"
        case .zoom: return "zoom"
        case .collapse: return "minimize"
        }
    }

    /// Replaces one side's list in the layout.json in `directory`. Other keys,
    /// rects and "source" included, are kept as they are.
    static func writeRuns(_ runs: [(Int, Int)], for side: Side, in directory: URL) -> Bool {
        let url = directory.appendingPathComponent("layout.json")
        guard let data = try? Data(contentsOf: url),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["format"] as? String != "k1",
              var layout = json["layout"] as? [String: Any] else { return false }
        layout[side.rawValue] = runs.map { [$0.0, $0.1] }
        json["layout"] = layout
        guard let out = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) else { return false }
        return (try? out.write(to: url, options: .atomic)) != nil
    }

    /// Sets or, when empty, removes layout.json's title style.
    static func writeTitleStyle(_ style: TitleStyle, in directory: URL) -> Bool {
        let url = directory.appendingPathComponent("layout.json")
        guard let data = try? Data(contentsOf: url),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        json["title"] = style.isEmpty ? nil : style.json
        guard let out = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) else { return false }
        return (try? out.write(to: url, options: .atomic)) != nil
    }

    /// This frame with another title style, drawn before it's written.
    func with(titleStyle: TitleStyle) -> WindowFrame {
        var frame = self
        frame.titleStyle = titleStyle
        frame.identity = UUID()
        return frame
    }

    // MARK: - Layout

    /// Where things landed for one window size.
    struct Layout {
        // Full frame size in points; the window sits at `insets` inside it.
        let size: CGSize
        let widgets: [Widget: CGRect]
        let title: CGRect?
        // Where the frame actually draws, as rects in points with a top-left
        // origin. Leaves out the window and transparent parts of the art.
        // Filled in by render().
        var shape: [CGRect] = []
        // Where each side's runs landed, in order along the side.
        var runs: [Side: [PlacedRun]] = [:]
    }

    /// One drawn piece of a run. Positions are points along the side from
    /// the frame's top or left edge.
    struct PlacedRun {
        // Index into the side's list.
        let run: Int
        // How it drew, which can differ from the list: an end gap no other
        // band draws is drawn as a cap.
        let code: Int
        let start: CGFloat
        let length: CGFloat
        // Pixels of art it drew from, the size of one tile.
        let sourceLength: Int
    }

    private struct Segment {
        let code: Int
        let start: Int
        let end: Int
        var length: Int { end - start }
        // Filled in by layout().
        var outStart = 0
        var outLength = 0
    }

    // Part codes. See K2 Intro, chapter 3.
    enum Part {
        static let edge = 0, endCap = 1, close = 2, zoom = 3, collapse = 4
        static let title = 5, titleCap = 6, stretch = 8, crumple = 10, stretchEnd = 11
        static let period = 12, periodFill = 13, periodFillEnd = 14
        static let noClose = 15, noZoom = 16, noCollapse = 17, scale = 18
        // Not in wnd#: a widget cut out of its section, never drawn. Unlike an
        // edge part it still counts as part of the band, so the band doesn't
        // end early when a widget fills the end of it.
        static let cut = -1
        static let grows: Set<Int> = [stretch, stretchEnd, period, scale]
        static let fills: Set<Int> = [periodFill, periodFillEnd]

        static func with(_ widget: Widget) -> Int {
            switch widget {
            case .close: return close
            case .zoom: return zoom
            case .collapse: return collapse
            }
        }

        static func without(_ widget: Widget) -> Int {
            switch widget {
            case .close: return noClose
            case .zoom: return noZoom
            case .collapse: return noCollapse
            }
        }
    }

    /// Splits an edge list into drawn segments and places them along `length`
    /// points. Leading and trailing edge gaps keep their space; interior edge
    /// parts are dropped. `drawsEnd` picks end edge parts, by source range,
    /// that no other band draws, so they draw as fixed pieces instead.
    /// `titleWidth` is the space the title text needs.
    private func layout(_ list: [(Int, Int)], extent: Int, length: Int, widgets: Set<Widget>,
                        titleWidth: Int?, drawsEnd: (Int, Int) -> Bool = { _, _ in false }) -> (segments: [Segment], lead: Int) {
        var all: [Segment] = []
        var position = 0
        for (code, border) in list {
            // Some schemes run past the image; clamp like Kaleidoscope did.
            let end = min(max(border, position), extent)
            all.append(Segment(code: code, start: position, end: end))
            position = end
        }
        if let first = all.firstIndex(where: { $0.code != Part.edge && $0.length > 0 }),
           let last = all.lastIndex(where: { $0.code != Part.edge && $0.length > 0 }) {
            for i in all.indices where all[i].code == Part.edge && (i < first || i > last)
                && drawsEnd(all[i].start, all[i].end) {
                all[i] = Segment(code: Part.endCap, start: all[i].start, end: all[i].end)
            }
        }
        let firstDrawn = all.firstIndex { $0.code != Part.edge && $0.length > 0 }
        let lead = firstDrawn.map { all[$0].start } ?? 0
        let lastEnd = all.last { $0.code != Part.edge && $0.length > 0 }?.end ?? extent
        let trail = max(0, extent - lastEnd)

        var segments = all.filter { segment in
            guard segment.length > 0 else { return false }
            switch segment.code {
            case Part.edge, Part.cut: return false
            case Part.close: return widgets.contains(.close)
            case Part.noClose: return !widgets.contains(.close)
            case Part.zoom: return widgets.contains(.zoom)
            case Part.noZoom: return !widgets.contains(.zoom)
            case Part.collapse: return widgets.contains(.collapse)
            case Part.noCollapse: return !widgets.contains(.collapse)
            case Part.title, Part.titleCap: return titleWidth != nil
            default: return true
            }
        }

        let available = length - lead - trail
        let titleRect = rects[4]
        // The title section grows so the text rect around it fits the text.
        func titleLength(_ segment: Segment) -> Int {
            guard let titleWidth, let titleRect else { return segment.length }
            let spill = Int(titleRect.width) - segment.length
            return max(segment.length, titleWidth - spill)
        }
        func fixedLength(dropCrumples: Bool) -> Int {
            segments.reduce(0) { sum, s in
                if Part.grows.contains(s.code) || Part.fills.contains(s.code) { return sum }
                if s.code == Part.crumple && dropCrumples { return sum }
                return sum + (s.code == Part.title ? titleLength(s) : s.length)
            }
        }
        // Crumple zones all go together when there isn't room for them.
        let dropCrumples = fixedLength(dropCrumples: false) > available
        if dropCrumples {
            segments.removeAll { $0.code == Part.crumple }
        }
        var spare = available - fixedLength(dropCrumples: false)

        for i in segments.indices where segments[i].code == Part.title {
            var want = titleLength(segments[i])
            // Out of room: give back title space down to the drawn section.
            if spare < 0 {
                let give = min(-spare, want - segments[i].length)
                want -= give
                spare += give
            }
            segments[i].outLength = want
        }
        for i in segments.indices where !Part.grows.contains(segments[i].code) && !Part.fills.contains(segments[i].code) && segments[i].code != Part.title {
            segments[i].outLength = segments[i].length
        }

        // Grow regions share what's left equally, the odd points going to the
        // last ones, as Kaleidoscope did. Period repeats only take whole
        // periods; fills and the first stretch take the remainder.
        let grows = segments.indices.filter { Part.grows.contains(segments[$0].code) }
        var leftover = max(0, spare)
        if !grows.isEmpty {
            let share = leftover / grows.count
            let extra = leftover - share * grows.count
            for (n, i) in grows.enumerated() {
                var give = share + (n >= grows.count - extra ? 1 : 0)
                if segments[i].code == Part.period {
                    give = give / segments[i].length * segments[i].length
                }
                segments[i].outLength = give
            }
            leftover -= grows.reduce(0) { $0 + segments[$1].outLength }
        }
        if leftover > 0 {
            let fills = segments.indices.filter { Part.fills.contains(segments[$0].code) }
            if !fills.isEmpty {
                let share = leftover / fills.count
                for i in fills { segments[i].outLength = share }
                segments[fills[0]].outLength += leftover - share * fills.count
            } else if let i = grows.first(where: { segments[$0].code != Part.period }) ?? grows.first {
                segments[i].outLength += leftover
            }
        }

        var out = lead
        for i in segments.indices {
            segments[i].outStart = out
            out += segments[i].outLength
        }
        return (segments, lead)
    }

    /// Places the widgets and title for a window of `windowSize` points.
    /// `hidden` are widgets the window has whose buttons draw elsewhere.
    func layout(windowSize: CGSize, widgets: Set<Widget>, hidden: Set<Widget> = [], titleWidth: CGFloat?) -> Layout {
        let insets = self.insets
        let size = CGSize(width: windowSize.width + insets.left + insets.right,
                          height: windowSize.height + insets.top + insets.bottom)
        let sides = sides(outer: size, widgets: widgets, cut: cutOut(hidden).subtracting(widgets), titleWidth: titleWidth)
        var layout = Layout(size: size,
                            widgets: widgetRects(sides, outer: size, widgets: widgets),
                            title: titleRect(sides.top))
        let width = Int(self.size.width), height = Int(self.size.height)
        layout.runs = [.top: placed(sides.top, top, extent: width), .bottom: placed(sides.bottom, bottom, extent: width),
                       .left: placed(sides.left, left, extent: height), .right: placed(sides.right, right, extent: height)]
        return layout
    }

    /// Matches drawn segments back to the runs they came from. A segment's
    /// source range always lies inside its run, cut out widgets included.
    private func placed(_ segments: [Segment], _ list: [(Int, Int)], extent: Int) -> [PlacedRun] {
        var bounds: [(Int, Int)] = []
        var position = 0
        for (_, border) in list {
            let end = min(max(border, position), extent)
            bounds.append((position, end))
            position = end
        }
        return segments.compactMap { s in
            guard let i = bounds.firstIndex(where: { $0.0 <= s.start && s.start < $0.1 }) else { return nil }
            return PlacedRun(run: i, code: s.code, start: CGFloat(s.outStart), length: CGFloat(s.outLength), sourceLength: s.length)
        }
    }

    /// Hidden widgets whose sections stay with the button cut out of them.
    /// Schemes can hold art for a window without a widget (the no close, no
    /// zoom and no collapse parts); that's used when present. Most schemes
    /// leave some out, since Mac OS 8 document windows always had all three,
    /// and dropping the whole section can cut away the frame's structure,
    /// like the end of a title tab. Widgets drawn by a part that's always
    /// drawn, like an end cap, have no section to drop and stay as they are.
    private func cutOut(_ hidden: Set<Widget>) -> Set<Widget> {
        let codes = Set((top + bottom + left + right).map(\.0))
        return hidden.filter { codes.contains(Part.with($0)) && !codes.contains(Part.without($0)) }
    }

    /// Splits each widget's section in `list` around the widget, grown by a
    /// point for its shadow. Layout drops the widget's span, so the art on
    /// either side closes up.
    private func cutting(_ list: [(Int, Int)], _ cut: Set<Widget>, horizontal: Bool) -> [(Int, Int)] {
        var out: [(Int, Int)] = []
        var position = 0
        for (code, border) in list {
            let end = max(border, position)
            defer { position = end }
            guard let widget = cut.first(where: { Part.with($0) == code }), let rect = rects[widget.rawValue] else {
                out.append((code, border))
                continue
            }
            let low = max(position, Int(horizontal ? rect.minX : rect.minY) - 1)
            let high = min(end, Int(horizontal ? rect.maxX : rect.maxY) + 1)
            guard low < high else {
                out.append((code, border))
                continue
            }
            out += [(code, low), (Part.cut, high), (code, end)]
        }
        return out
    }

    private struct Sides {
        let top: [Segment]
        let bottom: [Segment]
        let left: [Segment]
        let right: [Segment]
    }

    // Top and bottom run the full frame width, left and right the full height.
    //
    // Edge parts at the ends of an edge list are usually drawn by another band,
    // but two kinds are drawn by nothing else: a side's end part beside the
    // content, e.g. a pillar running down to where the bottom band starts, and
    // the bottom band's corners. They draw as fixed pieces. Other end parts,
    // above the content or in the top corners, can hold widget art for windows
    // that have those widgets, so they stay undrawn.
    // `cut` are widgets whose sections draw with the widget cut out.
    private func sides(outer: CGSize, widgets: Set<Widget>, cut: Set<Widget> = [], titleWidth: CGFloat?) -> Sides {
        let width = Int(outer.width), height = Int(outer.height)
        let imageWidth = Int(size.width), imageHeight = Int(size.height)
        let content = self.content
        let besideContent = { (start: Int, end: Int) in start >= Int(content.minY) && end <= Int(content.maxY) }
        let bottomCorner = { (start: Int, end: Int) in end <= Int(content.minX) || start >= Int(content.maxX) }
        // Each widget is cut from the edge it sits on.
        func on(_ edge: (CGRect) -> Bool) -> Set<Widget> {
            cut.filter { rects[$0.rawValue].map(edge) ?? false }
        }
        // A widget's section can show up on more than one edge; elsewhere it
        // drops as it would for a window without the widget.
        let topCut = on { $0.midY < content.minY }
        let bottomCut = on { $0.midY > content.maxY }
        let leftCut = on { $0.midY >= content.minY && $0.midY <= content.maxY && $0.midX < content.minX }
        let rightCut = on { $0.midY >= content.minY && $0.midY <= content.maxY && $0.midX > content.maxX }
        return Sides(
            top: layout(cutting(top, topCut, horizontal: true), extent: imageWidth, length: width,
                        widgets: widgets.union(topCut), titleWidth: titleWidth.map { Int(ceil($0)) }).segments,
            bottom: layout(cutting(bottom, bottomCut, horizontal: true), extent: imageWidth, length: width,
                           widgets: widgets.union(bottomCut), titleWidth: nil, drawsEnd: bottomCorner).segments,
            left: layout(cutting(left, leftCut, horizontal: false), extent: imageHeight, length: height,
                         widgets: widgets.union(leftCut), titleWidth: nil, drawsEnd: besideContent).segments,
            right: layout(cutting(right, rightCut, horizontal: false), extent: imageHeight, length: height,
                          widgets: widgets.union(rightCut), titleWidth: nil, drawsEnd: besideContent).segments
        )
    }

    /// Maps a source position along an edge to where it lands in the frame.
    /// `extent` is the edge's length in the image, `length` in the frame.
    private func map(_ position: CGFloat, along segments: [Segment], extent: CGFloat, length: CGFloat) -> CGFloat? {
        // Leading and trailing gaps keep their size, so they map from their end.
        if let first = segments.first, position < CGFloat(first.start) { return position }
        if let last = segments.last, position > CGFloat(last.end) { return length - (extent - position) }
        guard let s = segments.first(where: { CGFloat($0.start) <= position && position <= CGFloat($0.end) }) else { return nil }
        let offset = position - CGFloat(s.start)
        let outStart = CGFloat(s.outStart), outLength = CGFloat(s.outLength)
        switch s.code {
        case Part.scale:
            return outStart + offset * outLength / CGFloat(max(1, s.length))
        case Part.stretchEnd, Part.periodFillEnd:
            // Tiled from the far end, so the source lines up there.
            return outStart + outLength - (CGFloat(s.length) - offset)
        default:
            return outStart + min(offset, outLength)
        }
    }

    /// Places each widget on the edge it sits on, following its center.
    /// Widgets can live in any part: their own box section, an end cap, a
    /// stretch region, or a side for vertical title bars.
    private func widgetRects(_ sides: Sides, outer: CGSize, widgets: Set<Widget>) -> [Widget: CGRect] {
        var out: [Widget: CGRect] = [:]
        for widget in widgets {
            guard let rect = rects[widget.rawValue] else { continue }
            var placed: CGRect?
            if rect.midY < content.minY {
                placed = map(rect.midX, along: sides.top, extent: size.width, length: outer.width).map { rect.offsetBy(dx: $0 - rect.midX, dy: 0) }
            } else if rect.midY > content.maxY {
                let y = outer.height - (size.height - rect.minY)
                placed = map(rect.midX, along: sides.bottom, extent: size.width, length: outer.width).map { CGRect(x: $0 - rect.width / 2, y: y, width: rect.width, height: rect.height) }
            } else if rect.midX < content.minX {
                placed = map(rect.midY, along: sides.left, extent: size.height, length: outer.height).map { rect.offsetBy(dx: 0, dy: $0 - rect.midY) }
            } else if rect.midX > content.maxX {
                let x = outer.width - (size.width - rect.minX)
                placed = map(rect.midY, along: sides.right, extent: size.height, length: outer.height).map { CGRect(x: x, y: $0 - rect.height / 2, width: rect.width, height: rect.height) }
            }
            out[widget] = placed
        }
        return out
    }

    private func titleRect(_ segments: [Segment]) -> CGRect? {
        guard let rect = rects[4], let s = segments.first(where: { $0.code == Part.title }) else { return nil }
        let before = CGFloat(s.start) - rect.minX
        let after = rect.maxX - CGFloat(s.end)
        return CGRect(x: CGFloat(s.outStart) - before, y: rect.minY,
                      width: CGFloat(s.outLength) + before + after, height: rect.height)
    }

    // MARK: - Drawing

    /// Draws the frame for a window of `windowSize` points into a new image
    /// at `scale` pixels per point. The window's own area stays clear.
    /// `cornerRadius` is the window's own corner rounding; the gaps it leaves
    /// against the frame's square opening are filled in. `hidden` are widgets
    /// the window has whose buttons draw elsewhere, at the traffic lights.
    func render(windowSize: CGSize, active isActive: Bool, widgets: Set<Widget>, hidden: Set<Widget> = [],
                title: String?, pressedWidget: Widget?, cornerRadius: CGFloat, scale: CGFloat) -> (CGImage, Layout)? {
        if let k1 {
            return renderK1(k1, windowSize: windowSize, active: isActive, widgets: widgets, title: title,
                            pressedWidget: pressedWidget, cornerRadius: cornerRadius, scale: scale)
        }
        let titleStyle = resolvedTitle(active: isActive)
        let titleWidth = title.map { titleStyle.width(of: $0) + 8 }
        let layout = layout(windowSize: windowSize, widgets: widgets, hidden: hidden, titleWidth: titleWidth)
        let width = Int(ceil(layout.size.width * scale))
        let height = Int(ceil(layout.size.height * scale))
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Top-left origin, one unit per point.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        context.interpolationQuality = .none

        let image = isActive ? active : inactive
        let outer = layout.size
        let insets = self.insets

        // Sides first, over the full height, then top and bottom over them.
        let sides = sides(outer: outer, widgets: widgets, cut: cutOut(hidden).subtracting(widgets), titleWidth: titleWidth)
        drawVertical(sides.left, from: image, sourceX: 0, width: Int(content.minX), destX: 0, in: context)
        drawVertical(sides.right, from: image, sourceX: Int(content.maxX), width: Int(insets.right),
                     destX: Int(outer.width - insets.right), in: context)
        drawHorizontal(sides.top, from: image, sourceY: 0, height: Int(content.minY), destY: 0, in: context)
        drawHorizontal(sides.bottom, from: image, sourceY: Int(content.maxY), height: Int(insets.bottom),
                       destY: Int(outer.height - insets.bottom), in: context)

        // Sides that overlap the window's own area are cut away.
        let hole = CGRect(x: insets.left, y: insets.top, width: windowSize.width, height: windowSize.height)
        context.clear(hole)
        if cornerRadius > 0, let color = innerEdgeColor(image) {
            fillCorners(of: hole, radius: cornerRadius, color: color, in: context)
        }

        if let pressedWidget, let pressed, let rect = layout.widgets[pressedWidget], let source = pressedSource(pressedWidget) {
            draw(pressed, source: source, in: rect, context: context)
        }
        if let title, let rect = layout.title {
            drawTitle(title, in: rect, style: titleStyle, context: context)
        }

        guard let result = context.makeImage() else { return nil }
        var drawn = layout
        drawn.shape = drawnShape(of: context, scale: scale, size: layout.size, hole: hole)
        return (result, drawn)
    }

    // Past this many rects the shape is merged in bands of rows, trading
    // precision for cheaper clipping and event shapes.
    private static let maxShapeRects = 400

    /// Rects covering every point where the frame drew something, found by
    /// sampling the rendered pixels once per point. Runs on each row merge
    /// with identical runs on the rows below.
    func drawnShape(of context: CGContext, scale: CGFloat, size: CGSize, hole: CGRect) -> [CGRect] {
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return [] }
        let bytesPerRow = context.bytesPerRow
        let width = Int(size.width), height = Int(size.height)
        let pixelWidth = context.width, pixelHeight = context.height
        let holeRows = Int(hole.minY)..<Int(hole.maxY)
        let holeColumns = Int(hole.minX)..<Int(hole.maxX)

        // Alpha at the pixel nearest the center of each point. Row 0 of the
        // bitmap is the top of the image.
        func drawn(_ x: Int, _ y: Int) -> Bool {
            let px = min(pixelWidth - 1, Int((CGFloat(x) + 0.5) * scale))
            let py = min(pixelHeight - 1, Int((CGFloat(y) + 0.5) * scale))
            return data[py * bytesPerRow + px * 4 + 3] > 0
        }
        func runs(_ y: Int) -> [Range<Int>] {
            var out: [Range<Int>] = []
            var start: Int?
            var x = 0
            while x < width {
                // The window's own area never counts, corner fill included.
                if holeRows.contains(y) && holeColumns.contains(x) {
                    if let s = start { out.append(s..<x); start = nil }
                    x = holeColumns.upperBound
                    continue
                }
                if drawn(x, y) {
                    if start == nil { start = x }
                } else if let s = start {
                    out.append(s..<x)
                    start = nil
                }
                x += 1
            }
            if let s = start { out.append(s..<width) }
            return out
        }

        func merge(band: Int) -> [CGRect] {
            var rects: [CGRect] = []
            // Open rects keyed by their run, extended while the run repeats.
            var open: [Range<Int>: CGRect] = [:]
            var y = 0
            while y < height {
                let rows = y..<min(height, y + band)
                var current: [Range<Int>] = []
                if band == 1 {
                    current = runs(y)
                } else {
                    // A band's runs are the union of its rows' runs.
                    let all = rows.flatMap { runs($0) }.sorted { $0.lowerBound < $1.lowerBound }
                    for r in all {
                        if let last = current.last, r.lowerBound <= last.upperBound {
                            current[current.count - 1] = last.lowerBound..<max(last.upperBound, r.upperBound)
                        } else {
                            current.append(r)
                        }
                    }
                }
                var next: [Range<Int>: CGRect] = [:]
                for r in current {
                    if var rect = open.removeValue(forKey: r) {
                        rect.size.height += CGFloat(rows.count)
                        next[r] = rect
                    } else {
                        next[r] = CGRect(x: r.lowerBound, y: y, width: r.count, height: rows.count)
                    }
                }
                rects.append(contentsOf: open.values)
                open = next
                y = rows.upperBound
            }
            rects.append(contentsOf: open.values)
            return rects
        }

        var band = 1
        var rects = merge(band: band)
        while rects.count > Self.maxShapeRects && band < 16 {
            band *= 2
            rects = merge(band: band)
        }
        return rects
    }

    // The frame pixel just left of the content, halfway down.
    // Points the corner fill reaches under the window's edge.
    private static let cornerOverlap: CGFloat = 2

    /// Fills the gaps a window's rounded corners leave against the square
    /// opening. The fill's curve sits inside the window's own, so the window's
    /// antialiased edge blends over solid color; two matching soft edges would
    /// let the desktop show through. Only the corner squares are filled, and
    /// the window covers the overlap where it's opaque.
    func fillCorners(of hole: CGRect, radius: CGFloat, color: CGColor, in context: CGContext) {
        let r = min(radius, hole.width / 2, hole.height / 2)
        let overlap = min(Self.cornerOverlap, r)
        guard r > 0 else { return }
        context.saveGState()
        context.clip(to: [
            CGRect(x: hole.minX, y: hole.minY, width: r, height: r),
            CGRect(x: hole.maxX - r, y: hole.minY, width: r, height: r),
            CGRect(x: hole.minX, y: hole.maxY - r, width: r, height: r),
            CGRect(x: hole.maxX - r, y: hole.maxY - r, width: r, height: r),
        ])
        let corners = CGMutablePath()
        corners.addRect(hole)
        corners.addRoundedRect(in: hole.insetBy(dx: overlap, dy: overlap),
                               cornerWidth: r - overlap, cornerHeight: r - overlap)
        context.addPath(corners)
        context.setFillColor(color)
        context.fillPath(using: .evenOdd)
        context.restoreGState()
    }

    private func innerEdgeColor(_ image: CGImage) -> CGColor? {
        let x = max(0, Int(content.minX) - 1)
        guard let pixel = image.cropping(to: CGRect(x: x, y: Int(content.midY), width: 1, height: 1)),
              let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let p = context.data?.assumingMemoryBound(to: UInt8.self), p[3] > 0 else { return nil }
        return CGColor(srgbRed: CGFloat(p[0]) / 255, green: CGFloat(p[1]) / 255, blue: CGFloat(p[2]) / 255, alpha: 1)
    }

    // The pressed strip holds close, zoom and collapse left to right at the
    // widths of their rects.
    func pressedSource(_ widget: Widget) -> CGRect? {
        var x: CGFloat = 0
        for w in Widget.allCases {
            guard let rect = rects[w.rawValue] else { continue }
            if w == widget {
                return CGRect(x: x, y: 0, width: rect.width, height: rect.height)
            }
            x += rect.width
        }
        return nil
    }

    /// The title's look for the active or inactive window, style applied.
    func title(active: Bool) -> ResolvedTitle {
        k1 != nil ? k1Title(active ? self.active : inactive, active: active) : resolvedTitle(active: active)
    }

    private func resolvedTitle(active: Bool) -> ResolvedTitle {
        // Light text on dark title bars, dark on light ones.
        let light = titleBackgroundIsDark(active ? self.active : inactive)
        return titleStyle.resolved(active: active, autoColor: light ? .white : .black, autoInactive: nil, autoShadow: nil)
    }

    private func titleBackgroundIsDark(_ image: CGImage) -> Bool {
        guard let rect = rects[4], let crop = image.cropping(to: rect),
              let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.interpolationQuality = .medium
        context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let p = context.data?.assumingMemoryBound(to: UInt8.self) else { return false }
        let luma = 0.299 * Double(p[0]) + 0.587 * Double(p[1]) + 0.114 * Double(p[2])
        return luma < 128
    }

    func drawTitle(_ title: String, in rect: CGRect, style: ResolvedTitle, context: CGContext) {
        let graphics = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        if let shadow = style.shadow {
            // Shadow offsets and blur are in device pixels, unaffected by the
            // CTM, so scale them by hand. The CTM flips y, which turns the
            // y-down offset into CoreGraphics' y-up one.
            let ctm = context.ctm
            context.setShadow(offset: CGSize(width: shadow.offset.width * ctm.a, height: shadow.offset.height * ctm.d),
                              blur: shadow.blur * abs(ctm.a), color: shadow.color.cgColor)
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = style.alignment.text
        paragraph.lineBreakMode = .byTruncatingMiddle
        var attributes = style.attributes
        attributes[.paragraphStyle] = paragraph
        let text = NSAttributedString(string: title, attributes: attributes)
        let height = text.size().height
        text.draw(in: CGRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height))
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: Segment drawing

    private func drawHorizontal(_ segments: [Segment], from image: CGImage, sourceY: Int, height: Int,
                                destY: Int, in context: CGContext) {
        guard height > 0 else { return }
        for s in segments where s.outLength > 0 {
            let source = CGRect(x: s.start, y: sourceY, width: s.length, height: height)
            let dest = CGRect(x: s.outStart, y: destY, width: s.outLength, height: height)
            fill(dest, from: image, source: source, code: s.code, horizontal: true, context: context)
        }
    }

    private func drawVertical(_ segments: [Segment], from image: CGImage, sourceX: Int, width: Int,
                              destX: Int, in context: CGContext) {
        guard width > 0 else { return }
        for s in segments where s.outLength > 0 {
            let source = CGRect(x: sourceX, y: s.start, width: width, height: s.length)
            let dest = CGRect(x: destX, y: s.outStart, width: width, height: s.outLength)
            fill(dest, from: image, source: source, code: s.code, horizontal: false, context: context)
        }
    }

    /// Fills `dest` from `source` the way part `code` says: scaled, tiled from
    /// either end, or drawn once.
    private func fill(_ dest: CGRect, from image: CGImage, source: CGRect, code: Int, horizontal: Bool, context: CGContext) {
        let step = horizontal ? source.width : source.height
        let span = horizontal ? dest.width : dest.height
        guard step > 0 else { return }
        if code == Part.scale {
            draw(image, source: source, in: dest, context: context)
            return
        }
        let tiles = Part.grows.contains(code) || Part.fills.contains(code) || code == Part.title
        let fromEnd = code == Part.stretchEnd || code == Part.periodFillEnd
        context.saveGState()
        context.clip(to: dest)
        let count = tiles ? Int(ceil(span / step)) : 1
        for i in 0..<count {
            let offset = fromEnd ? span - step * CGFloat(i + 1) : step * CGFloat(i)
            let tile = horizontal
                ? CGRect(x: dest.minX + offset, y: dest.minY, width: source.width, height: source.height)
                : CGRect(x: dest.minX, y: dest.minY + offset, width: source.width, height: source.height)
            draw(image, source: source, in: tile, context: context)
        }
        context.restoreGState()
    }

    /// Draws a top-left-origin `source` rect of `image` into a top-left-origin `dest`.
    func draw(_ image: CGImage, source: CGRect, in dest: CGRect, context: CGContext) {
        guard let crop = image.cropping(to: source) else { return }
        context.saveGState()
        // CGContext.draw expects bottom-up; flip locally around the tile.
        context.translateBy(x: dest.minX, y: dest.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(crop, in: CGRect(origin: .zero, size: dest.size))
        context.restoreGState()
    }
}
