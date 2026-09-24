// Draws Kaleidoscope 1.x window frames from their 16x16 miniature window icons.
import Cocoa

// A 1.x scheme has no layout resource. Kaleidoscope drew its windows by fixed
// rules, described in "Creating K1 Schemes" (Kaleidoscope 2.3.1 installer) and
// measured from its own screenshots:
// - The window icon is a miniature window. Its outer 6 pixels on the left,
//   right and bottom are the border; corners are drawn as-is and edges stretch
//   from column/row 6. The small square inside is ignored.
// - The title bar is 22 points: icon rows 0-2, row 3 stretched, rows 4-5.
//   Row 3 also holds the title color (columns 7-8) and the emboss color
//   (column 9, unused when it matches the background in column 6).
// - Active windows stretch the racing stripes icon across rows 4-16, 3 points
//   clear of the widgets and 6 points clear of the title: its left and right
//   halves draw as-is and the middle column stretches between them, like the
//   other stretched icons. Only utility windows tile it. Unmasked stripe
//   pixels show the stripes pattern, if any.
// - Widgets are 16x16 icons: close at (4, 4), windowshade flush right 1 point
//   from the edge, zoom just left of it. Inactive windows show no stripes and
//   no widgets.
extension WindowFrame {
    struct K1Parts {
        let stripes: CGImage?
        let stripesPattern: CGImage?
        // Up and down icons, from the theme's own button images.
        let widgets: [Widget: (up: CGImage, down: CGImage?)]
    }

    static let k1Insets = NSEdgeInsets(top: 22, left: 6, bottom: 6, right: 6)
    private static let k1Border = 6
    private static let k1Widget: CGFloat = 16
    private static let k1StripeTop: CGFloat = 4
    private static let k1WidgetGap: CGFloat = 3
    private static let k1TitleGap: CGFloat = 6

    /// Loads the widget icons from the theme folder above `frameDirectory`.
    static func loadK1Parts(frameDirectory: URL, image: (String) -> CGImage?) -> K1Parts {
        let theme = frameDirectory.deletingLastPathComponent()
        func icon(_ name: String) -> CGImage? {
            guard let source = CGImageSourceCreateWithURL(theme.appendingPathComponent(name) as CFURL, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        var widgets: [Widget: (up: CGImage, down: CGImage?)] = [:]
        for (widget, base) in [(Widget.close, "close"), (.zoom, "max"), (.collapse, "min")] {
            if let up = icon("\(base)_up.png") {
                widgets[widget] = (up, icon("\(base)_down.png"))
            }
        }
        return K1Parts(stripes: image("stripes.png"), stripesPattern: image("stripes_pattern.png"), widgets: widgets)
    }

    /// Widget spots for a frame `width` points wide, left to right.
    private func k1WidgetRects(width: CGFloat, widgets: Set<Widget>) -> [Widget: CGRect] {
        let size = Self.k1Widget
        var out: [Widget: CGRect] = [:]
        if widgets.contains(.close) {
            out[.close] = CGRect(x: 4, y: 4, width: size, height: size)
        }
        var right = width - 1
        for widget in [Widget.collapse, .zoom] where widgets.contains(widget) {
            right -= size
            out[widget] = CGRect(x: right, y: 4, width: size, height: size)
        }
        return out
    }

    func renderK1(_ parts: K1Parts, windowSize: CGSize, active isActive: Bool, widgets: Set<Widget>,
                  title: String?, pressedWidget: Widget?, cornerRadius: CGFloat, scale: CGFloat) -> (CGImage, Layout)? {
        let i = Self.k1Insets
        let size = CGSize(width: windowSize.width + i.left + i.right, height: windowSize.height + i.top + i.bottom)
        let width = Int(ceil(size.width * scale)), height = Int(ceil(size.height * scale))
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        context.interpolationQuality = .none

        let icon = isActive ? active : inactive
        let W = size.width, H = size.height, b = CGFloat(Self.k1Border)

        // Columns: left border, stretched middle, right border.
        func band(sourceY: Int, rows: Int, destY: CGFloat, height: CGFloat) {
            let sy = CGFloat(sourceY), sr = CGFloat(rows)
            draw(icon, source: CGRect(x: 0, y: sy, width: b, height: sr), in: CGRect(x: 0, y: destY, width: b, height: height), context: context)
            draw(icon, source: CGRect(x: 6, y: sy, width: 1, height: sr), in: CGRect(x: b, y: destY, width: W - 2 * b, height: height), context: context)
            draw(icon, source: CGRect(x: 10, y: sy, width: b, height: sr), in: CGRect(x: W - b, y: destY, width: b, height: height), context: context)
        }
        // Title bar: top edge, stretched background, the lines above the content.
        band(sourceY: 0, rows: 3, destY: 0, height: 3)
        band(sourceY: 3, rows: 1, destY: 3, height: i.top - 5)
        band(sourceY: 4, rows: 2, destY: i.top - 2, height: 2)
        // Sides stretch row 7; the middle of the row is the ignored square.
        let sideHeight = H - i.top - i.bottom
        draw(icon, source: CGRect(x: 0, y: 7, width: b, height: 1), in: CGRect(x: 0, y: i.top, width: b, height: sideHeight), context: context)
        draw(icon, source: CGRect(x: 10, y: 7, width: b, height: 1), in: CGRect(x: W - b, y: i.top, width: b, height: sideHeight), context: context)
        // Bottom border: the icon's last six rows.
        band(sourceY: 10, rows: 6, destY: H - b, height: b)

        let hole = CGRect(x: i.left, y: i.top, width: windowSize.width, height: windowSize.height)
        context.clear(hole)
        if cornerRadius > 0, let color = k1Pixel(icon, x: 5, y: 7) {
            fillCorners(of: hole, radius: cornerRadius, color: color, in: context)
        }

        // Inactive windows show neither widgets nor stripes.
        let shown = isActive ? widgets.intersection(Set(parts.widgets.keys)) : []
        let widgetRects = k1WidgetRects(width: W, widgets: shown)

        let attributes = k1TitleAttributes(icon, active: isActive)
        let textWidth = title.map { ceil(($0 as NSString).size(withAttributes: attributes).width) } ?? 0
        let stripeStart = widgetRects[.close].map { $0.minX + 13 + Self.k1WidgetGap } ?? 4 + Self.k1WidgetGap
        let stripeEnd = widgetRects.filter { $0.key != .close }.map { $0.value.minX }.min().map { $0 - Self.k1WidgetGap }
            ?? W - 4 - Self.k1WidgetGap
        var titleRect: CGRect?
        if title != nil {
            let w = min(textWidth, max(0, stripeEnd - stripeStart - 2 * Self.k1TitleGap))
            titleRect = CGRect(x: (W - w) / 2, y: 3, width: w, height: i.top - 6)
        }

        if isActive, let stripes = parts.stripes, stripeEnd > stripeStart {
            let band = CGRect(x: stripeStart, y: Self.k1StripeTop, width: stripeEnd - stripeStart, height: CGFloat(stripes.height))
            var pieces = [band]
            if let titleRect {
                // Stripes stop short of the title on both sides, each piece with its own ends.
                let gap = titleRect.insetBy(dx: -Self.k1TitleGap, dy: 0)
                pieces = [CGRect(x: band.minX, y: band.minY, width: gap.minX - band.minX, height: band.height),
                          CGRect(x: gap.maxX, y: band.minY, width: band.maxX - gap.maxX, height: band.height)]
            }
            for piece in pieces where piece.width > 0 {
                drawK1Stripes(stripes, pattern: parts.stripesPattern, in: piece, context: context)
            }
        }

        for (widget, rect) in widgetRects {
            guard let images = parts.widgets[widget] else { continue }
            let image = widget == pressedWidget ? (images.down ?? images.up) : images.up
            draw(image, source: CGRect(x: 0, y: 0, width: image.width, height: image.height), in: rect, context: context)
        }

        if let title, let titleRect {
            if let emboss = k1EmbossColor(icon) {
                var shadow = attributes
                shadow[.foregroundColor] = emboss
                drawTitle(title, in: titleRect.offsetBy(dx: 1, dy: 1), attributes: shadow, context: context)
            }
            drawTitle(title, in: titleRect, attributes: attributes, context: context)
        }

        guard let result = context.makeImage() else { return nil }
        var layout = Layout(size: size, widgets: widgetRects, title: titleRect)
        layout.shape = drawnShape(of: context, scale: scale, size: size, hole: hole)
        return (result, layout)
    }

    /// Draws the left half of the stripes icon at the start of `rect`, the right
    /// half at its end, and stretches the middle column between them.
    private func drawK1Stripes(_ stripes: CGImage, pattern: CGImage?, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.clip(to: rect)
        if let pattern {
            // The pattern shows through the stripes' unmasked pixels.
            tilePattern(pattern, in: rect, context: context)
        }
        let h = CGFloat(stripes.height)
        let mid = CGFloat(stripes.width / 2), rightW = CGFloat(stripes.width) - mid - 1
        draw(stripes, source: CGRect(x: 0, y: 0, width: mid, height: h),
             in: CGRect(x: rect.minX, y: rect.minY, width: mid, height: h), context: context)
        draw(stripes, source: CGRect(x: mid, y: 0, width: 1, height: h),
             in: CGRect(x: rect.minX + mid, y: rect.minY, width: max(0, rect.width - mid - rightW), height: h), context: context)
        draw(stripes, source: CGRect(x: mid + 1, y: 0, width: rightW, height: h),
             in: CGRect(x: rect.maxX - rightW, y: rect.minY, width: rightW, height: h), context: context)
        context.restoreGState()
    }

    private func tilePattern(_ pattern: CGImage, in rect: CGRect, context: CGContext) {
        let w = CGFloat(pattern.width), h = CGFloat(pattern.height)
        guard w > 0, h > 0 else { return }
        context.saveGState()
        context.clip(to: rect)
        var y = rect.minY
        while y < rect.maxY {
            var x = rect.minX
            while x < rect.maxX {
                draw(pattern, source: CGRect(x: 0, y: 0, width: w, height: h), in: CGRect(x: x, y: y, width: w, height: h), context: context)
                x += w
            }
            y += h
        }
        context.restoreGState()
    }

    private func k1Pixel(_ image: CGImage, x: Int, y: Int) -> CGColor? {
        guard let pixel = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)),
              let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let p = context.data?.assumingMemoryBound(to: UInt8.self), p[3] > 0 else { return nil }
        return CGColor(srgbRed: CGFloat(p[0]) / 255, green: CGFloat(p[1]) / 255, blue: CGFloat(p[2]) / 255, alpha: 1)
    }

    private func k1TitleAttributes(_ icon: CGImage, active: Bool) -> [NSAttributedString.Key: Any] {
        let color = k1Pixel(icon, x: 7, y: 3).flatMap { NSColor(cgColor: $0) } ?? .black
        return [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: color]
    }

    private func k1EmbossColor(_ icon: CGImage) -> NSColor? {
        guard let emboss = k1Pixel(icon, x: 9, y: 3), let background = k1Pixel(icon, x: 6, y: 3),
              emboss != background else { return nil }
        return NSColor(cgColor: emboss)
    }
}
