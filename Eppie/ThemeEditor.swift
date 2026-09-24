// Custom tab: a live preview of the draft theme to click, drop images on and edit.
import SwiftUI
import UniformTypeIdentifiers

enum EditorButton: String, CaseIterable, Identifiable {
    case close, minimize, zoom, help

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    // The glyphs the traffic lights show on hover.
    var symbol: String {
        switch self {
        case .close: return "xmark"
        case .minimize: return "minus"
        case .zoom: return "arrow.up.left.and.arrow.down.right"
        case .help: return "questionmark"
        }
    }

    var color: Color {
        switch self {
        case .close: return .red
        case .minimize: return .yellow
        case .zoom: return .green
        case .help: return .purple
        }
    }

    // Kaleidoscope's collapse box stands in for minimize. Frames have no help box.
    var widget: WindowFrame.Widget? {
        switch self {
        case .close: return .close
        case .minimize: return .collapse
        case .zoom: return .zoom
        case .help: return nil
        }
    }

    func key(_ suffix: String) -> String { "\(rawValue)Button\(suffix)Image" }
}

enum EditorPart: Hashable {
    case button(EditorButton)
    case frame
}

enum PreviewState: String, CaseIterable, Identifiable {
    case active = "Active", hover = "Hover", pressed = "Pressed", inactive = "Inactive"

    var id: String { rawValue }

    // Suffix of the button image key this state shows. Inactive windows get
    // the disabled images.
    var buttonSuffix: String {
        switch self {
        case .active: return ""
        case .hover: return "Hover"
        case .pressed: return "Pressed"
        case .inactive: return "Disabled"
        }
    }

    // Frames have no hover art, so hover shows the active image.
    var frameArt: ThemeManager.FrameArt {
        switch self {
        case .active, .hover: return .active
        case .pressed: return .pressed
        case .inactive: return .inactive
        }
    }
}

/// Where the framed window sits in the canvas, in canvas points with a
/// top-left origin. The window is clamped so the whole frame fits.
private struct CanvasGeometry {
    static let minWindow = CGSize(width: 120, height: 48)
    private static let margin: CGFloat = 16

    let bounds: CGSize
    let insets: NSEdgeInsets
    private(set) var window: CGRect
    private(set) var outer: CGRect
    // Where the frame art actually draws. Some art has transparent margins.
    private(set) var visible: CGRect

    init(bounds: CGSize, requested: CGSize, insets: NSEdgeInsets?) {
        let i = insets ?? NSEdgeInsets()
        let horizontal = i.left + i.right, vertical = i.top + i.bottom
        let maxWidth = max(Self.minWindow.width, bounds.width - 2 * Self.margin - horizontal)
        let maxHeight = max(Self.minWindow.height, bounds.height - 2 * Self.margin - vertical)
        let size = CGSize(width: min(max(requested.width, Self.minWindow.width), maxWidth).rounded(),
                          height: min(max(requested.height, Self.minWindow.height), maxHeight).rounded())
        let outerSize = CGSize(width: size.width + horizontal, height: size.height + vertical)
        let origin = CGPoint(x: ((bounds.width - outerSize.width) / 2).rounded(),
                             y: ((bounds.height - outerSize.height) / 2).rounded())
        self.bounds = bounds
        self.insets = i
        outer = CGRect(origin: origin, size: outerSize)
        window = CGRect(x: origin.x + i.left, y: origin.y + i.top, width: size.width, height: size.height)
        visible = outer
    }

    /// Moved so the drawn part of the frame is centered. `drawn` is in frame
    /// coordinates, as in WindowFrame.Layout.shape.
    func centering(_ drawn: [CGRect]) -> CanvasGeometry {
        guard let first = drawn.first else { return self }
        let art = drawn.dropFirst().reduce(first) { $0.union($1) }.union(CGRect(origin: CGPoint(x: insets.left, y: insets.top), size: window.size))
        var moved = self
        let dx = (bounds.width / 2 - (outer.minX + art.midX)).rounded()
        let dy = (bounds.height / 2 - (outer.minY + art.midY)).rounded()
        moved.outer = outer.offsetBy(dx: dx, dy: dy)
        moved.window = window.offsetBy(dx: dx, dy: dy)
        moved.visible = art.offsetBy(dx: moved.outer.minX, dy: moved.outer.minY)
        return moved
    }
}

private struct RenderedFrame {
    let image: CGImage
    let layout: WindowFrame.Layout
}

// Keeps the last render, since the body runs on every hover and drag tick.
private final class FrameRenderCache {
    var key = ""
    var value: RenderedFrame?
}

private struct PlacedButton: Identifiable {
    let button: EditorButton
    let image: NSImage?
    // Canvas points.
    let rect: CGRect
    var id: EditorButton { button }
}

struct ThemeEditorView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @AppStorage("windowBorders") private var windowBorders = true
    @AppStorage("frameButtons") private var frameButtons = false
    @AppStorage("customThemeName") private var themeName = ""
    @AppStorage("customThemeAuthor") private var themeAuthor = ""

    @State private var selection: EditorPart = .button(.close)
    @State private var state: PreviewState = .active
    @State private var windowSize = CGSize(width: 320, height: 110)
    @State private var dragStart: CGSize?
    @State private var frame: WindowFrame?
    // Bumped when the draft changes, so images are read from disk again.
    @State private var revision = 0
    @State private var renderCache = FrameRenderCache()
    @State private var alert: (title: String, message: String)?
    @State private var showingSave = false
    @State private var pendingSave = false
    @State private var checks: [DraftCheck] = []
    @State private var showingChecks = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
                .padding(.horizontal)
                .padding(.vertical, 8)
            Divider()
            canvas
            Divider()
            inspector
                .frame(maxWidth: .infinity)
                .frame(height: 104)
                .padding(.horizontal)
            Divider()
            footer
        }
        // Edits go to a draft copy of whatever is applied, frame included.
        .onAppear {
            themeManager.prepareDraft()
            reload()
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("TroisReloadImages"))) { _ in reload() }
        .sheet(isPresented: $showingSave, onDismiss: {
            if pendingSave {
                pendingSave = false
                save()
            }
        }) {
            SaveThemeSheet(name: $themeName, author: $themeAuthor) { pendingSave = true }
        }
        .alert(alert?.title ?? "", isPresented: Binding(
            get: { alert != nil },
            set: { if !$0 { alert = nil } }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(alert?.message ?? "")
        }
    }

    private func reload() {
        frame = themeManager.draftFrameDirectory.flatMap { WindowFrame(directory: $0) }
        checks = themeManager.draftChecks()
        revision += 1
    }

    // MARK: - Toolbar and footer

    private var toolbar: some View {
        HStack {
            Picker("Part", selection: $selection) {
                // Icons keep both pickers on one row; the titles stay for
                // tooltips and VoiceOver.
                ForEach(EditorButton.allCases) { button in
                    Label(button.title, systemImage: button.symbol)
                        .labelStyle(.iconOnly)
                        .help(button.title)
                        .tag(EditorPart.button(button))
                }
                Label("Frame", systemImage: "macwindow")
                    .labelStyle(.iconOnly)
                    .help("Frame")
                    .tag(EditorPart.frame)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Spacer()

            Picker("State", selection: $state) {
                ForEach(PreviewState.allCases) { state in
                    Text(state.rawValue).tag(state)
                        .disabled(!availableStates.contains(state))
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .onChange(of: selection) { _ in fitState() }
        .onChange(of: frame?.identity) { _ in fitState() }
    }

    // States the selected part has art for. Frames have no hover art, and
    // 1.x frames no pressed strip.
    private var availableStates: [PreviewState] {
        switch selection {
        case .button: return PreviewState.allCases
        case .frame: return frame?.k1 == nil ? [.active, .pressed, .inactive] : [.active, .inactive]
        }
    }

    private func fitState() {
        if !availableStates.contains(state) { state = .active }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button("Reset All") {
                themeManager.resetDraft()
            }
            if frame != nil {
                Toggle("Window Borders", isOn: $windowBorders)
                Toggle("Buttons in Frame", isOn: $frameButtons)
                    .disabled(!windowBorders)
                    .help("Put the close, zoom and minimize buttons in the frame instead of at the traffic lights")
            }
            Spacer()
            if !checks.isEmpty {
                Button {
                    showingChecks = true
                } label: {
                    Label("\(checks.count)", systemImage: "exclamationmark.triangle")
                }
                .help("Problems with the frame")
                .popover(isPresented: $showingChecks, arrowEdge: .top) {
                    ChecksView(checks: checks) { fix in
                        themeManager.apply(fix)
                    }
                }
            }
            Button("Save as Theme...") {
                showingSave = true
            }
            .disabled(!hasCustomImages)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .onChange(of: windowBorders) { _ in postReload() }
        .onChange(of: frameButtons) { _ in postReload() }
    }

    private var hasCustomImages: Bool {
        _ = revision
        return EditorButton.allCases.contains { UserDefaults.standard.string(forKey: $0.key("")) != nil }
    }

    private func postReload() {
        NotificationCenter.default.post(name: .init("TroisReloadImages"), object: nil)
    }

    private func save() {
        let name = themeName.isEmpty ? "Custom Theme" : themeName
        let author = themeAuthor.isEmpty ? nil : themeAuthor
        if let path = themeManager.saveCustomTheme(name: name, author: author) {
            themeManager.loadThemes()
            alert = ("Theme Saved", "Theme saved to:\n\(path)")
        } else {
            alert = ("Theme Not Saved", "Make sure you have at least one custom image.")
        }
    }

    private func report(_ problem: String?) {
        if let problem { alert = ("Image Not Used", problem) }
    }

    // MARK: - Canvas

    private var shownFrame: WindowFrame? { windowBorders ? frame : nil }
    private var showsFrameButtons: Bool { frameButtons && shownFrame != nil }
    private var title: String { themeName.isEmpty ? "Untitled" : themeName }

    // The button the Pressed state presses.
    private var pressedButton: EditorButton {
        if case .button(let button) = selection { return button }
        return .close
    }

    private var canvas: some View {
        GeometryReader { geo in
            let unplaced = CanvasGeometry(bounds: geo.size, requested: windowSize, insets: shownFrame?.insets)
            // The render only depends on the window's size, so it can place the window.
            let rendered = rendered(for: unplaced)
            let g = unplaced.centering(rendered?.layout.shape ?? [])
            ZStack(alignment: .topLeading) {
                Color.gray.opacity(0.18)
                windowView(g, rendered: rendered)
                selectionOutline(g, rendered: rendered)
                grip(g)
            }
            .coordinateSpace(name: "canvas")
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { value in
                if let part = part(at: value.location, g, rendered: rendered) {
                    selection = part
                }
            })
            .onDrop(of: [.fileURL], isTargeted: nil) { providers, location in
                guard let part = part(at: location, g, rendered: rendered) else { return false }
                return loadDroppedFile(providers) { url in drop(url, on: part) }
            }
        }
        .clipped()
    }

    private func windowView(_ g: CanvasGeometry, rendered: RenderedFrame?) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: BorderWindow.fallbackCornerRadius)
                .fill(Color(nsColor: .windowBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: BorderWindow.fallbackCornerRadius)
                        .stroke(Color.gray.opacity(rendered == nil ? 0.4 : 0), lineWidth: 0.5)
                )
                .frame(width: g.window.width, height: g.window.height)
                .offset(x: g.window.minX, y: g.window.minY)

            if let rendered {
                Image(decorative: rendered.image, scale: 2)
                    .interpolation(.none)
                    .offset(x: g.outer.minX, y: g.outer.minY)
            }

            ForEach(placedButtons(in: g)) { placed in
                Group {
                    if let image = placed.image {
                        Image(nsImage: image).interpolation(.none)
                    } else {
                        Circle().fill(placed.button.color)
                    }
                }
                .frame(width: placed.rect.width, height: placed.rect.height)
                .offset(x: placed.rect.minX, y: placed.rect.minY)
            }
        }
    }

    private func selectionOutline(_ g: CanvasGeometry, rendered: RenderedFrame?) -> some View {
        var rects: [CGRect] = []
        switch selection {
        case .frame:
            if rendered != nil { rects.append(g.visible.insetBy(dx: -3, dy: -3)) }
        case .button(let button):
            if let placed = placedButtons(in: g).first(where: { $0.button == button }) {
                rects.append(placed.rect.insetBy(dx: -2, dy: -2))
            }
            if showsFrameButtons, let widget = button.widget, let rect = rendered?.layout.widgets[widget] {
                rects.append(rect.offsetBy(dx: g.outer.minX, dy: g.outer.minY).insetBy(dx: -2, dy: -2))
            }
        }
        return ForEach(Array(rects.enumerated()), id: \.offset) { _, rect in
            RoundedRectangle(cornerRadius: 3)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
        }
        .allowsHitTesting(false)
    }

    // Resizes the window from its bottom-right corner. The window stays
    // centered, so it grows by twice the drag to keep the corner under the cursor.
    private func grip(_ g: CanvasGeometry) -> some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 8, weight: .semibold))
            .foregroundColor(.secondary)
            .frame(width: 16, height: 16)
            .background(Circle().fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(Circle().stroke(Color.gray.opacity(0.5), lineWidth: 0.5))
            .offset(x: g.visible.maxX - 6, y: g.visible.maxY - 6)
            .gesture(
                DragGesture(coordinateSpace: .named("canvas"))
                    .onChanged { value in
                        let start = dragStart ?? g.window.size
                        dragStart = start
                        let requested = CGSize(width: start.width + value.translation.width * 2,
                                               height: start.height + value.translation.height * 2)
                        windowSize = CanvasGeometry(bounds: g.bounds, requested: requested, insets: g.insets).window.size
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .help("Drag to resize the window")
    }

    private func rendered(for g: CanvasGeometry) -> RenderedFrame? {
        guard let frame = shownFrame else { return nil }
        let widgets: Set<WindowFrame.Widget> = showsFrameButtons ? Set(WindowFrame.Widget.allCases) : []
        let pressed = state == .pressed ? pressedButton.widget : nil
        let key = "\(frame.identity)|\(g.window.size)|\(state)|\(widgets.count)|\(String(describing: pressed))|\(title)"
        if key == renderCache.key { return renderCache.value }
        let value = frame.render(windowSize: g.window.size, active: state != .inactive, widgets: widgets,
                                 title: title, pressedWidget: pressed,
                                 cornerRadius: BorderWindow.fallbackCornerRadius, scale: 2)
            .map { RenderedFrame(image: $0.0, layout: $0.1) }
        renderCache.key = key
        renderCache.value = value
        return value
    }

    // The overlay buttons in a row at the window's top-left, like the traffic
    // lights. Help only shows once it has an image.
    private func placedButtons(in g: CanvasGeometry) -> [PlacedButton] {
        _ = revision
        let items = EditorButton.allCases.compactMap { button -> (EditorButton, NSImage?)? in
            let image = buttonImage(button)
            if button == .help && image == nil { return nil }
            return (button, image)
        }
        let sizes = items.map { $0.1?.size ?? CGSize(width: 14, height: 14) }
        let height = sizes.map(\.height).max() ?? 14
        let gap: CGFloat = items.contains { $0.1 != nil } ? 4 : 9
        var x = g.window.minX + 8
        var placed: [PlacedButton] = []
        for (item, size) in zip(items, sizes) {
            let y = g.window.minY + 8 + ((height - size.height) / 2).rounded()
            placed.append(PlacedButton(button: item.0, image: item.1, rect: CGRect(origin: CGPoint(x: x, y: y), size: size)))
            x += size.width + gap
        }
        return placed
    }

    private func buttonImage(_ button: EditorButton) -> NSImage? {
        let defaults = UserDefaults.standard
        let suffix = state == .pressed && button != pressedButton ? "" : state.buttonSuffix
        return pixelImage(atPath: defaults.string(forKey: button.key(suffix)))
            ?? pixelImage(atPath: defaults.string(forKey: button.key("")))
    }

    private func part(at point: CGPoint, _ g: CanvasGeometry, rendered: RenderedFrame?) -> EditorPart? {
        for placed in placedButtons(in: g) where placed.rect.insetBy(dx: -2, dy: -2).contains(point) {
            return .button(placed.button)
        }
        if showsFrameButtons, let layout = rendered?.layout {
            for button in EditorButton.allCases {
                guard let widget = button.widget, let rect = layout.widgets[widget] else { continue }
                if rect.offsetBy(dx: g.outer.minX, dy: g.outer.minY).contains(point) { return .button(button) }
            }
        }
        if rendered != nil, g.visible.contains(point), !g.window.contains(point) {
            return .frame
        }
        return nil
    }

    // A drop replaces the image for the part and the state being previewed.
    private func drop(_ url: URL, on part: EditorPart) {
        selection = part
        switch part {
        case .button(let button):
            themeManager.setDraftImage(url, forKey: button.key(state.buttonSuffix))
        case .frame:
            report(themeManager.setDraftFrameArt(url, for: state.frameArt))
        }
    }

    // MARK: - Inspector

    @ViewBuilder private var inspector: some View {
        switch selection {
        case .button(let button):
            buttonInspector(button)
        case .frame:
            frameInspector
        }
    }

    private func buttonInspector(_ button: EditorButton) -> some View {
        var slots = [("Normal", button.key("")), ("Hover", button.key("Hover")),
                     ("Pressed", button.key("Pressed")), ("Disabled", button.key("Disabled"))]
        // Shown in place of zoom while a window is zoomed.
        if button == .zoom {
            slots += [("Restore", "restoreButtonImage"), ("Restore Pressed", "restoreButtonPressedImage")]
        }
        let defaults = UserDefaults.standard
        let missing = slots.map(\.1).filter {
            themeManager.canGenerateDraftImage(forKey: $0) && defaults.string(forKey: $0) == nil
        }
        return HStack(spacing: 16) {
            ForEach(slots, id: \.1) { slot in
                ButtonStateSlot(stateName: slot.0, userDefaultsKey: slot.1, fallbackColor: button.color)
            }
            Spacer()
            Button("Fill Missing") {
                themeManager.generateDraftImages(forKeys: missing)
            }
            .disabled(missing.isEmpty || defaults.string(forKey: button.key("")) == nil)
            .help("Make the empty states from the normal image")
        }
    }

    @ViewBuilder private var frameInspector: some View {
        if let directory = themeManager.draftFrameDirectory {
            HStack(spacing: 16) {
                // 1.x frames have no pressed strip.
                ForEach(ThemeManager.FrameArt.allCases.filter { $0 != .pressed || frame?.k1 == nil }, id: \.self) { art in
                    FrameArtSlot(art: art, url: directory.appendingPathComponent(art.fileName),
                                 isGenerated: themeManager.isFrameArtGenerated(art),
                                 revision: revision, report: report)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 8) {
                    FrameSourceMenu()
                    Menu("Buttons") {
                        Button("Take Buttons from Frame") { themeManager.takeButtonsFromFrame() }
                        Button("Put Buttons in Frame") { themeManager.putButtonsInFrame() }
                        Divider()
                        Button("Remove Frame") { themeManager.useDraftFrame(from: nil) }
                    }
                    .fixedSize()
                }
            }
        } else {
            VStack(spacing: 8) {
                Text("No window frame. Take one from another theme.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                FrameSourceMenu()
            }
        }
    }
}

// Its own view so the long theme list is only rebuilt when themes change.
private struct FrameSourceMenu: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    var body: some View {
        let framed = themeManager.themes.filter { $0.frameDirectory != nil }
        Menu("Use Frame From") {
            ForEach(framed) { theme in
                Button(theme.name) {
                    themeManager.useDraftFrame(from: theme.frameDirectory)
                }
            }
        }
        .disabled(framed.isEmpty)
        .fixedSize()
    }
}

private struct FrameArtSlot: View {
    let art: ThemeManager.FrameArt
    let url: URL
    let isGenerated: Bool
    // Not drawn; a new value makes the image load from disk again.
    let revision: Int
    let report: (String?) -> Void

    var body: some View {
        VStack(spacing: 4) {
            Text(art.rawValue.capitalized)
                .font(.caption2)
                .foregroundColor(.secondary)

            Button(action: pick) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .controlBackgroundColor))
                    if let image = NSImage(contentsOf: url) {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.none)
                            .aspectRatio(contentMode: .fit)
                            .padding(4)
                    } else {
                        Image(systemName: "plus")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
                .frame(width: 96, height: 64)
            }
            .buttonStyle(.plain)
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                loadDroppedFile(providers) { set($0) }
            }
            .contextMenu {
                Button("Replace...") { pick() }
                if art != .active {
                    Button("Clear") { set(nil) }
                    Button(isGenerated ? "Regenerate" : "Generate from Active") {
                        ThemeManager.shared.generateDraftFrameArt(art)
                    }
                }
            }

            Text("auto")
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .opacity(isGenerated ? 1 : 0)
                .help("Made from the active image. Updates when it changes.")
        }
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .bmp, .jpeg, .tiff, .gif]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Select the \(art.rawValue) frame image"
        if panel.runModal() == .OK, let url = panel.url {
            set(url)
        }
    }

    private func set(_ source: URL?) {
        report(ThemeManager.shared.setDraftFrameArt(source, for: art))
    }
}

private struct ChecksView: View {
    let checks: [DraftCheck]
    let fix: (DraftCheck.Fix) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(checks) { check in
                VStack(alignment: .leading, spacing: 6) {
                    Text(check.message)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    if !check.fixes.isEmpty {
                        HStack {
                            ForEach(check.fixes.indices, id: \.self) { i in
                                Button(check.fixes[i].title) { fix(check.fixes[i].fix) }
                            }
                        }
                    }
                }
            }
        }
        .padding()
        .frame(width: 300)
    }
}

private struct SaveThemeSheet: View {
    @Binding var name: String
    @Binding var author: String
    let save: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save as Theme")
                .font(.headline)
            TextField("Theme Name", text: $name, prompt: Text("My Theme"))
            TextField("Author", text: $author, prompt: Text("Your name"))
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    save()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}

// Sized to its pixels, ignoring DPI metadata, like the overlays draw it.
private func pixelImage(atPath path: String?) -> NSImage? {
    guard let path, let image = NSImage(contentsOfFile: path) else { return nil }
    if let rep = image.representations.first, rep.pixelsWide > 0, rep.pixelsHigh > 0 {
        image.size = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
    }
    return image
}

/// Hands the first dropped file URL to `handler` on the main queue.
func loadDroppedFile(_ providers: [NSItemProvider], _ handler: @escaping (URL) -> Void) -> Bool {
    guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
        return false
    }
    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
        guard let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
        DispatchQueue.main.async { handler(url) }
    }
    return true
}
