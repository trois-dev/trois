// Draws WindowBlinds window frames from four edge bitmaps and freely placed buttons.
import Cocoa

// A WindowBlinds UIS skin, converted by windowblinds/tools/convert.py into a
// frame/ folder: top/left/right/bottom.png (plus *_inactive.png), button strips
// and a layout.json of {"format": "wb", "edges", "buttons", "text", "title"}.
// Rules and their sources are in windowblinds/docs/rules.md:
// - Left and right borders run the full window height. Top and bottom sit
//   between them. The frame's insets are the edges' thicknesses.
// - Each edge draws a fixed start, a middle that tiles (or stretches when
//   "tile" is false) and a fixed end, along the edge.
// - Buttons are strips of 3 states (normal, pressed, hover) or 6 (then 3 more
//   for inactive windows). Align 0-3 anchors a button to the top-left,
//   top-right, bottom-left or bottom-right corner, and x/y move its left/top
//   edge that far from the corner. Lower-numbered buttons draw first.
// - A button's "when" holds conditions on the window, all of which must hold.
extension WindowFrame {
    struct WBParts {
        struct Edge {
            let active: CGImage
            let inactive: CGImage
            let start: Int
            let end: Int
            let tile: Bool
        }

        struct Button {
            let image: CGImage
            let states: Int
            let align: Int
            let x: CGFloat
            let y: CGFloat
            // Nil for buttons that only show an image.
            let widget: Widget?
            let when: [String: Bool]
            let alpha: CGFloat

            var size: CGSize { CGSize(width: image.width / states, height: image.height) }
        }

        let edges: [Side: Edge]
        let buttons: [Button]
        // Title text: shift from the left border, down from the band's middle,
        // and where clipping starts, from the right edge.
        let textShift: CGFloat
        let textShiftVert: CGFloat
        let textRightClip: CGFloat
        let textOnBottom: Bool

        var insets: NSEdgeInsets {
            NSEdgeInsets(top: CGFloat(edges[.top]?.active.height ?? 0), left: CGFloat(edges[.left]?.active.width ?? 0),
                         bottom: CGFloat(edges[.bottom]?.active.height ?? 0), right: CGFloat(edges[.right]?.active.width ?? 0))
        }
    }

    static func loadWBParts(json: [String: Any], image: (String) -> CGImage?) -> WBParts? {
        var edges: [Side: WBParts.Edge] = [:]
        let edgeJSON = json["edges"] as? [String: [String: Any]] ?? [:]
        for side in Side.allCases {
            guard let active = image("\(side.rawValue).png"), let e = edgeJSON[side.rawValue] else { return nil }
            edges[side] = WBParts.Edge(active: active, inactive: image("\(side.rawValue)_inactive.png") ?? active,
                                       start: e["start"] as? Int ?? 0, end: e["end"] as? Int ?? 0,
                                       tile: e["tile"] as? Bool ?? true)
        }
        var buttons: [WBParts.Button] = []
        for b in json["buttons"] as? [[String: Any]] ?? [] {
            guard let file = b["image"] as? String, let art = image(file),
                  let states = b["states"] as? Int, states > 0, art.width >= states else { continue }
            let widget: Widget?
            switch b["widget"] as? String {
            case "close": widget = .close
            case "zoom", "restore": widget = .zoom
            case "minimize": widget = .collapse
            default: widget = nil
            }
            buttons.append(WBParts.Button(image: art, states: states, align: b["align"] as? Int ?? 0,
                                          x: CGFloat(b["x"] as? Int ?? 0), y: CGFloat(b["y"] as? Int ?? 0),
                                          widget: widget, when: b["when"] as? [String: Bool] ?? [:],
                                          alpha: CGFloat(b["alpha"] as? Int ?? 255) / 255))
        }
        let text = json["text"] as? [String: Any] ?? [:]
        return WBParts(edges: edges, buttons: buttons,
                       textShift: CGFloat(text["shift"] as? Int ?? 0), textShiftVert: CGFloat(text["shiftVert"] as? Int ?? 0),
                       textRightClip: CGFloat(text["rightClip"] as? Int ?? 0), textOnBottom: text["onBottom"] as? Bool ?? false)
    }

    /// Whether a button's conditions hold. `has` are the widgets the window has.
    /// Trois frames are never drawn for maximized windows.
    private func wbShows(_ button: WBParts.Button, active: Bool, has: Set<Widget>, title: String?) -> Bool {
        let facts: [String: Bool] = [
            "active": active, "maximized": false, "title": !(title ?? "").isEmpty,
            "zoom": has.contains(.zoom), "minimize": has.contains(.collapse),
            "either": has.contains(.zoom) || has.contains(.collapse),
        ]
        return button.when.allSatisfy { facts[$0.key] == $0.value }
    }

    private func wbRect(_ button: WBParts.Button, size: CGSize) -> CGRect {
        let s = button.size
        let x = button.align == 1 || button.align == 3 ? size.width - button.x : button.x
        let y = button.align == 2 || button.align == 3 ? size.height - button.y : button.y
        return CGRect(x: x, y: y, width: s.width, height: s.height)
    }

    func drawWB(_ parts: WBParts, into context: CGContext, windowSize: CGSize, active isActive: Bool, widgets: Set<Widget>,
                hidden: Set<Widget>, title: String?, pressedWidget: Widget?, cornerRadius: CGFloat) -> Layout {
        let i = parts.insets
        let size = outerSize(windowSize)

        let W = size.width, H = size.height
        for side in [Side.left, .right, .top, .bottom] {
            guard let edge = parts.edges[side] else { continue }
            let art = isActive ? edge.active : edge.inactive
            let box: CGRect
            switch side {
            case .left: box = CGRect(x: 0, y: 0, width: i.left, height: H)
            case .right: box = CGRect(x: W - i.right, y: 0, width: i.right, height: H)
            case .top: box = CGRect(x: i.left, y: 0, width: W - i.left - i.right, height: i.top)
            case .bottom: box = CGRect(x: i.left, y: H - i.bottom, width: W - i.left - i.right, height: i.bottom)
            }
            drawWBEdge(art, edge: edge, in: box, horizontal: side.horizontal, context: context)
        }

        // Edges stay within the insets, so the window's own area is still clear.
        let hole = CGRect(x: i.left, y: i.top, width: windowSize.width, height: windowSize.height)
        if cornerRadius > 0, let left = parts.edges[.left],
           let color = Self.storedColor(isActive ? left.active : left.inactive, x: Int(i.left) - 1, y: left.active.height / 2) {
            fillCorners(of: hole, radius: cornerRadius, color: color.cgColor, in: context)
        }

        // Widget buttons draw only when the frame shows them; the traffic lights show the rest.
        var widgetRects: [Widget: CGRect] = [:]
        let has = widgets.union(hidden)
        for button in parts.buttons where wbShows(button, active: isActive, has: has, title: title) {
            if let widget = button.widget {
                guard widgets.contains(widget), widgetRects[widget] == nil else { continue }
            }
            let rect = wbRect(button, size: size)
            var state = button.widget != nil && button.widget == pressedWidget ? 1 : 0
            if !isActive && button.states == 6 { state += 3 }
            let s = button.size
            context.saveGState()
            context.setAlpha(button.alpha)
            draw(button.image, source: CGRect(x: CGFloat(state) * s.width, y: 0, width: s.width, height: s.height),
                 in: rect, context: context)
            context.restoreGState()
            if let widget = button.widget { widgetRects[widget] = rect }
        }

        let style = wbTitle(active: isActive)
        var titleRect: CGRect?
        if let title, !title.isEmpty {
            let band = parts.textOnBottom ? CGRect(x: 0, y: H - i.bottom, width: W, height: i.bottom)
                                          : CGRect(x: 0, y: 0, width: W, height: i.top)
            let left = i.left + parts.textShift
            let right = W - max(parts.textRightClip, i.right)
            if right > left {
                titleRect = CGRect(x: left, y: band.minY + parts.textShiftVert, width: right - left, height: band.height)
                drawTitle(title, in: titleRect!, style: style, context: context)
            }
        }

        return Layout(size: size, widgets: widgetRects, title: titleRect)
    }

    /// Fixed start, tiled or stretched middle, fixed end, along the edge.
    /// When the edge is shorter than both ends, the end draws over the start.
    private func drawWBEdge(_ art: CGImage, edge: WBParts.Edge, in box: CGRect, horizontal: Bool, context: CGContext) {
        let length = horizontal ? box.width : box.height
        let extent = CGFloat(horizontal ? art.width : art.height)
        let thick = CGFloat(horizontal ? art.height : art.width)
        guard length > 0, extent > 0 else { return }
        let start = min(CGFloat(edge.start), extent)
        let end = min(CGFloat(edge.end), extent - start)
        func source(_ from: CGFloat, _ count: CGFloat) -> CGRect {
            horizontal ? CGRect(x: from, y: 0, width: count, height: thick) : CGRect(x: 0, y: from, width: thick, height: count)
        }
        func dest(_ at: CGFloat, _ count: CGFloat) -> CGRect {
            horizontal ? CGRect(x: box.minX + at, y: box.minY, width: count, height: thick)
                       : CGRect(x: box.minX, y: box.minY + at, width: thick, height: count)
        }
        context.saveGState()
        context.clip(to: box)
        let middle = extent - start - end
        let span = length - start - end
        if middle > 0, span > 0 {
            if edge.tile {
                context.saveGState()
                context.clip(to: dest(start, span))
                drawTiled(art, source: source(start, middle), first: dest(start, middle), context: context)
                context.restoreGState()
            } else {
                draw(art, source: source(start, middle), in: dest(start, span), context: context)
            }
        }
        if start > 0 { draw(art, source: source(0, start), in: dest(0, start), context: context) }
        if end > 0 { draw(art, source: source(extent - end, end), in: dest(length - end, end), context: context) }
        context.restoreGState()
    }

    /// The skin's own title colors and shadow, from layout.json's "title".
    func wbTitle(active: Bool) -> ResolvedTitle {
        titleStyle.resolved(active: active, autoColor: .black, autoInactive: nil, autoShadow: nil)
    }
}
