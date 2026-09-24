// Lays out and draws Kaleidoscope 2 window frames around windows of any size.
import Cocoa

/// A Kaleidoscope 2 document window: the active, inactive and pressed-widget
/// images plus the wnd# layout that says how to stretch them. Read from a
/// theme's `frame/` folder (see kaleidoscope/tools/convert.py).
///
/// All coordinates are image pixels with a top-left origin. One pixel draws as
/// one point, the size these were made for.
struct WindowFrame {
    enum Widget: Int, CaseIterable {
        case close = 1, zoom = 2, collapse = 3
    }

    let directory: URL
    let active: CGImage
    let inactive: CGImage
    let pressed: CGImage?
    let size: CGSize
    // Rectangle codes to rects: 0 content, 1 close, 2 zoom, 3 collapse, 4 title text.
    let rects: [Int: CGRect]
    // Edge lists as (part code, cumulative end offset).
    let top: [(Int, Int)]
    let bottom: [(Int, Int)]
    let left: [(Int, Int)]
    let right: [(Int, Int)]

    var content: CGRect { rects[0] ?? CGRect(origin: .zero, size: size) }

    /// Space the frame adds around a window, in points.
    var insets: NSEdgeInsets {
        NSEdgeInsets(top: content.minY, left: content.minX,
                     bottom: size.height - content.maxY, right: size.width - content.maxX)
    }

    init?(directory: URL) {
        func image(_ name: String) -> CGImage? {
            guard let source = CGImageSourceCreateWithURL(directory.appendingPathComponent(name) as CFURL, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("layout.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let layout = json["layout"] as? [String: Any],
              let active = image("active.png") else { return nil }
        self.directory = directory
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
    private enum Part {
        static let edge = 0, endCap = 1, close = 2, zoom = 3, collapse = 4
        static let title = 5, titleCap = 6, stretch = 8, crumple = 10, stretchEnd = 11
        static let period = 12, periodFill = 13, periodFillEnd = 14
        static let noClose = 15, noZoom = 16, noCollapse = 17, scale = 18
        static let grows: Set<Int> = [stretch, stretchEnd, period, scale]
        static let fills: Set<Int> = [periodFill, periodFillEnd]
    }

    /// Splits an edge list into drawn segments and places them along `length`
    /// points. Leading and trailing edge gaps keep their space; interior edge
    /// parts are dropped. `titleWidth` is the space the title text needs.
    private func layout(_ list: [(Int, Int)], extent: Int, length: Int,
                        widgets: Set<Widget>, titleWidth: Int?) -> (segments: [Segment], lead: Int) {
        var all: [Segment] = []
        var position = 0
        for (code, border) in list {
            // Some schemes run past the image; clamp like Kaleidoscope did.
            let end = min(max(border, position), extent)
            all.append(Segment(code: code, start: position, end: end))
            position = end
        }
        let firstDrawn = all.firstIndex { $0.code != Part.edge && $0.length > 0 }
        let lead = firstDrawn.map { all[$0].start } ?? 0
        let lastEnd = all.last { $0.code != Part.edge && $0.length > 0 }?.end ?? extent
        let trail = max(0, extent - lastEnd)

        var segments = all.filter { segment in
            guard segment.length > 0 else { return false }
            switch segment.code {
            case Part.edge: return false
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

        // Grow regions share what's left equally. Period repeats only take
        // whole periods; fills and the first stretch take the remainder.
        let grows = segments.indices.filter { Part.grows.contains(segments[$0].code) }
        var leftover = max(0, spare)
        if !grows.isEmpty {
            let share = leftover / grows.count
            var extra = leftover - share * grows.count
            for i in grows {
                var give = share + (extra > 0 ? 1 : 0)
                extra = max(0, extra - 1)
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
    func layout(windowSize: CGSize, widgets: Set<Widget>, titleWidth: CGFloat?) -> Layout {
        let insets = self.insets
        let size = CGSize(width: windowSize.width + insets.left + insets.right,
                          height: windowSize.height + insets.top + insets.bottom)
        let sides = sides(outer: size, widgets: widgets, titleWidth: titleWidth)
        return Layout(size: size,
                      widgets: widgetRects(sides, outer: size, widgets: widgets),
                      title: titleRect(sides.top))
    }

    private struct Sides {
        let top: [Segment]
        let bottom: [Segment]
        let left: [Segment]
        let right: [Segment]
    }

    // Top and bottom run the full frame width, left and right the full height.
    private func sides(outer: CGSize, widgets: Set<Widget>, titleWidth: CGFloat?) -> Sides {
        let width = Int(outer.width), height = Int(outer.height)
        let imageWidth = Int(size.width), imageHeight = Int(size.height)
        return Sides(
            top: layout(top, extent: imageWidth, length: width, widgets: widgets,
                        titleWidth: titleWidth.map { Int(ceil($0)) }).segments,
            bottom: layout(bottom, extent: imageWidth, length: width, widgets: widgets, titleWidth: nil).segments,
            left: layout(left, extent: imageHeight, length: height, widgets: widgets, titleWidth: nil).segments,
            right: layout(right, extent: imageHeight, length: height, widgets: widgets, titleWidth: nil).segments
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
    /// against the frame's square opening are filled in.
    func render(windowSize: CGSize, active isActive: Bool, widgets: Set<Widget>,
                title: String?, pressedWidget: Widget?, cornerRadius: CGFloat, scale: CGFloat) -> (CGImage, Layout)? {
        let titleAttributes = titleAttributes(active: isActive)
        let titleWidth = title.map { ($0 as NSString).size(withAttributes: titleAttributes).width + 8 }
        let layout = layout(windowSize: windowSize, widgets: widgets, titleWidth: titleWidth)
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
        let sides = sides(outer: outer, widgets: widgets, titleWidth: titleWidth)
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
            let corners = CGMutablePath()
            corners.addRect(hole)
            corners.addRoundedRect(in: hole, cornerWidth: cornerRadius, cornerHeight: cornerRadius)
            context.addPath(corners)
            context.setFillColor(color)
            context.fillPath(using: .evenOdd)
        }

        if let pressedWidget, let pressed, let rect = layout.widgets[pressedWidget], let source = pressedSource(pressedWidget) {
            draw(pressed, source: source, in: rect, context: context)
        }
        if let title, let rect = layout.title {
            drawTitle(title, in: rect, attributes: titleAttributes, context: context)
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
    private func drawnShape(of context: CGContext, scale: CGFloat, size: CGSize, hole: CGRect) -> [CGRect] {
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
    private func pressedSource(_ widget: Widget) -> CGRect? {
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

    private func titleAttributes(active: Bool) -> [NSAttributedString.Key: Any] {
        // Light text on dark title bars, dark on light ones.
        let light = titleBackgroundIsDark(active ? self.active : inactive)
        let color: NSColor = light ? .white : .black
        return [.font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: active ? color : color.withAlphaComponent(0.55)]
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

    private func drawTitle(_ title: String, in rect: CGRect, attributes: [NSAttributedString.Key: Any], context: CGContext) {
        let graphics = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingMiddle
        var attributes = attributes
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
    private func draw(_ image: CGImage, source: CGRect, in dest: CGRect, context: CGContext) {
        guard let crop = image.cropping(to: source) else { return }
        context.saveGState()
        // CGContext.draw expects bottom-up; flip locally around the tile.
        context.translateBy(x: dest.minX, y: dest.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(crop, in: CGRect(origin: .zero, size: dest.size))
        context.restoreGState()
    }
}
