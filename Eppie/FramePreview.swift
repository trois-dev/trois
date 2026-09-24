// Renders small previews of a theme's window frame for the theme grid.
import SwiftUI

/// A theme's frame drawn around a small window, and where that window sits.
struct FramePreviewImage {
    let image: CGImage
    // Points, top-left origin.
    let size: CGSize
    let window: CGRect
}

enum FramePreviewRenderer {
    /// Space a preview gets in a card, in points. Art draws at one point per
    /// image pixel, like on screen, so the window inside shrinks as the frame's
    /// edges grow.
    static let canvas = CGSize(width: 168, height: 112)
    // Frames with very thick edges keep at least this much window and are clipped.
    private static let minimumWindow = CGSize(width: 64, height: 32)
    private static let scale: CGFloat = 2
    // Smaller than a real window's, which would round these small windows into pills.
    static let cornerRadius: CGFloat = 8

    private final class Entry {
        let preview: FramePreviewImage?
        init(_ preview: FramePreviewImage?) { self.preview = preview }
    }
    // About 100 KB per preview. Only cards near the visible ones need to stay.
    private static let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 300
        return cache
    }()
    private static let queue = DispatchQueue(label: "Trois.framepreview", qos: .userInitiated, attributes: .concurrent)

    /// Identifies one rendering. The art's and layout's modification dates
    /// are part of it, so a reinstalled or edited frame draws again.
    static func key(directory: URL, title: String, frameButtons: Bool) -> String {
        let modified = ["active.png", "layout.json"].map { name -> TimeInterval in
            let path = directory.appendingPathComponent(name).path
            return (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        }
        return "\(directory.path)|\(modified)|\(title)|\(frameButtons)"
    }

    /// A finished preview, or nil if it hasn't been rendered. The inner nil
    /// means the frame couldn't be read.
    static func cached(_ key: String) -> FramePreviewImage?? {
        cache.object(forKey: key as NSString).map { $0.preview }
    }

    static func render(key: String, directory: URL, title: String, frameButtons: Bool) async -> FramePreviewImage? {
        if let hit = cached(key) { return hit }
        return await withCheckedContinuation { continuation in
            queue.async {
                let preview = draw(directory: directory, title: title, frameButtons: frameButtons)
                cache.setObject(Entry(preview), forKey: key as NSString)
                continuation.resume(returning: preview)
            }
        }
    }

    private static func draw(directory: URL, title: String, frameButtons: Bool) -> FramePreviewImage? {
        guard let frame = WindowFrame(directory: directory) else { return nil }
        let i = frame.insets
        let window = CGSize(width: max(minimumWindow.width, canvas.width - i.left - i.right),
                            height: max(minimumWindow.height, canvas.height - i.top - i.bottom))
        // Same widgets as BorderTarget: all three, in the frame or at the traffic lights.
        let all = Set(WindowFrame.Widget.allCases)
        guard let (image, layout) = frame.render(
            windowSize: window, active: true, widgets: frameButtons ? all : [], hidden: frameButtons ? [] : all,
            title: title, pressedWidget: nil,
            cornerRadius: cornerRadius, scale: scale
        ) else { return nil }
        return FramePreviewImage(image: image, size: layout.size,
                                 window: CGRect(origin: CGPoint(x: i.left, y: i.top), size: window))
    }
}

/// A theme's frame around a small window, with the theme's buttons where the
/// traffic lights go. Renders in the background; the card stays empty until then.
struct FramePreviewView<Buttons: View>: View {
    let directory: URL
    let title: String
    let frameButtons: Bool
    // Traffic-light buttons drawn inside the window.
    let buttons: Buttons
    // Shown when the frame can't be read.
    let fallback: AnyView
    // Tagged with its key, so a stale preview isn't shown after a setting changes.
    @State private var rendered: (key: String, preview: FramePreviewImage?)?

    private var key: String {
        FramePreviewRenderer.key(directory: directory, title: title, frameButtons: frameButtons)
    }

    var body: some View {
        // A cached preview shows at once, so scrolling back doesn't flash empty cards.
        let key = self.key
        let preview = rendered?.key == key ? .some(rendered!.preview) : FramePreviewRenderer.cached(key)
        Group {
            switch preview {
            case .some(.some(let preview)):
                framed(preview)
            case .some(.none):
                fallback
            case .none:
                Color.clear
            }
        }
        .frame(width: FramePreviewRenderer.canvas.width, height: FramePreviewRenderer.canvas.height)
        .clipped()
        .task(id: key) {
            let key = self.key
            let preview = await FramePreviewRenderer.render(key: key, directory: directory, title: title, frameButtons: frameButtons)
            rendered = (key, preview)
        }
    }

    private func framed(_ preview: FramePreviewImage) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: FramePreviewRenderer.cornerRadius)
                .fill(Color(nsColor: .windowBackgroundColor))
                .frame(width: preview.window.width, height: preview.window.height)
                .offset(x: preview.window.minX, y: preview.window.minY)
            Image(decorative: preview.image, scale: 2)
                .interpolation(.none)
            WindowCorners(window: preview.window)
            buttons
                .offset(x: preview.window.minX + 8, y: preview.window.minY + 8)
        }
        .frame(width: preview.size.width, height: preview.size.height, alignment: .topLeading)
    }
}

/// The window's rounded corners, drawn over a frame image. On screen the
/// window sits above the frame and hides the part of the corner fill that
/// reaches under its edge. A preview draws the frame over the window, so this
/// puts the corners back on top. Only the corner squares are drawn, which
/// stay clear of the buttons at the window's top left.
struct WindowCorners: View {
    // Points, top-left origin, in the frame image's space.
    let window: CGRect

    var body: some View {
        let r = min(FramePreviewRenderer.cornerRadius, window.width / 2, window.height / 2)
        let squares = Path { path in
            path.addRects([
                CGRect(x: 0, y: 0, width: r, height: r),
                CGRect(x: window.width - r, y: 0, width: r, height: r),
                CGRect(x: 0, y: window.height - r, width: r, height: r),
                CGRect(x: window.width - r, y: window.height - r, width: r, height: r),
            ])
        }
        RoundedRectangle(cornerRadius: FramePreviewRenderer.cornerRadius)
            .fill(Color(nsColor: .windowBackgroundColor))
            .frame(width: window.width, height: window.height)
            .mask(squares)
            .offset(x: window.minX, y: window.minY)
    }
}
