// Editor tab: a live preview of the draft theme to click, drop images on and edit.
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
    // The theme's name, author and other info.
    case theme
    case button(EditorButton)
    case frame
    // The window title's font, colors and shadow.
    case title
    // One edge list of a frame, for editing its runs.
    case edge(WindowFrame.Side)
    // One of a frame's layout boxes: content, a widget or the title.
    case box(WindowFrame.Box)
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

    @State private var selection: EditorPart = .button(.close)
    @State private var state: PreviewState = .active
    @State private var windowSize = CGSize(width: 320, height: 110)
    @State private var dragStart: CGSize?
    @State private var frame: WindowFrame?
    // The frame with an edge edit still being dragged, drawn in its place.
    @State private var previewFrame: WindowFrame?
    @State private var info = DraftInfo()
    // The run picked in the edge inspector, highlighted in the preview.
    @State private var selectedRun = 0
    // Run to select once a click on another side changes the selection.
    @State private var pendingRun: Int?
    @State private var canvasMode = CanvasMode.preview
    // Bumped when the draft changes, so images are read from disk again.
    @State private var revision = 0
    @State private var renderCache = FrameRenderCache()
    @State private var alert: (title: String, message: String)?
    @State private var showingSave = false
    @State private var pendingSave = false
    @State private var checks: [DraftCheck] = []
    @State private var showingChecks = false
    // Edited here first, shown through previewFrame, then written once
    // edits pause, so color wells don't rewrite the layout on every tick.
    @State private var titleStyle = TitleStyle()
    @State private var titleBaseline: TitleStyle?
    @State private var titleWrite: DispatchWorkItem?
    // The draft has edits another theme replaced; asks whether to resume them.
    @State private var askResume = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
                .padding(.horizontal)
                .padding(.vertical, 8)
            Divider()
            // On its own view: a second alert on the view with the other one wouldn't show.
            canvas
                .alert("Unsaved Edits", isPresented: $askResume) {
                    Button("Keep Editing") { themeManager.resumeDraft() }
                    Button("Start Over", role: .destructive) {
                        discardTitleEdit()
                        themeManager.discardDraft()
                        reload()
                    }
                } message: {
                    Text("The editor has changes that weren't saved as a theme. Keep editing them, or start over from the theme that's applied now?")
                }
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
            askResume = themeManager.prepareDraft()
            reload()
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("TroisReloadImages"))) { _ in reload() }
        .sheet(isPresented: $showingSave, onDismiss: {
            if pendingSave {
                pendingSave = false
                save()
            }
        }) {
            SaveThemeSheet(name: $info.name, author: $info.author) { pendingSave = true }
        }
        .onChange(of: info) { themeManager.setDraftInfo($0) }
        .onChange(of: titleStyle) { titleChanged($0) }
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
        previewFrame = nil
        if titleWrite == nil {
            titleStyle = frame?.titleStyle ?? TitleStyle()
        } else if let frame {
            previewFrame = frame.with(titleStyle: titleStyle)
        }
        titleBaseline = themeManager.baselineTitleStyle()
        info = themeManager.draftInfo()
        checks = themeManager.draftChecks()
        revision += 1
        fitSelection()
    }

    // MARK: - Toolbar and footer

    private var toolbar: some View {
        HStack {
            Picker("Part", selection: partBinding) {
                // Icons keep both pickers on one row; the titles stay for
                // tooltips and VoiceOver.
                Label("Theme", systemImage: "info.circle")
                    .labelStyle(.iconOnly)
                    .help("Theme")
                    .tag(EditorPart.theme)
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
                Label("Title", systemImage: "textformat")
                    .labelStyle(.iconOnly)
                    .help("Title")
                    .tag(EditorPart.title)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Spacer()

            SegmentedControl(items: PreviewState.allCases.map { ($0, $0.rawValue) },
                             selection: $state, enabled: Set(availableStates))
                .fixedSize()
        }
        .onChange(of: selection) { _ in
            selectedRun = pendingRun ?? 0
            pendingRun = nil
            fitState()
        }
        .onChange(of: state) { _ in fitState() }
    }

    // An edge or box shows as the Frame segment.
    private var partBinding: Binding<EditorPart> {
        Binding(get: {
            switch selection {
            case .edge, .box: return .frame
            default: return selection
            }
        }, set: { selection = $0 })
    }

    private func select(_ side: WindowFrame.Side, run: Int) {
        if selection == .edge(side) {
            selectedRun = run
        } else {
            pendingRun = run
            selection = .edge(side)
        }
    }

    // States a part has art for. Frames have no hover art, and 1.x frames no
    // pressed strip.
    private func states(for part: EditorPart) -> [PreviewState] {
        switch part {
        case .theme, .button: return PreviewState.allCases
        case .frame, .edge, .box: return frame?.k1 == nil ? [.active, .pressed, .inactive] : [.active, .inactive]
        case .title: return [.active, .inactive]
        }
    }

    private var availableStates: [PreviewState] { states(for: selection) }

    private func fitState() {
        if !availableStates.contains(state) { state = .active }
    }

    // Edges and boxes only exist on frames with a layout.
    private func fitSelection() {
        switch selection {
        case .edge, .box:
            if frame == nil || frame?.k1 != nil { selection = .frame }
        default:
            break
        }
        fitState()
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button("Reset All") {
                discardTitleEdit()
                themeManager.resetDraft()
            }
            // Text fields on the Theme part keep Command-Z for their own typing.
            let shortcuts = selection != .theme
            Button(action: undo) { Image(systemName: "arrow.uturn.backward") }
                .keyboardShortcut(shortcuts ? KeyboardShortcut("z") : nil)
                .disabled(themeManager.draftUndo.isEmpty)
                .help("Undo")
            Button(action: redo) { Image(systemName: "arrow.uturn.forward") }
                .keyboardShortcut(shortcuts ? KeyboardShortcut("z", modifiers: [.command, .shift]) : nil)
                .disabled(themeManager.draftRedo.isEmpty)
                .help("Redo")
            if frame != nil {
                FrameOptionToggles()
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
            .disabled(!hasCustomImages && frame == nil)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    private var hasCustomImages: Bool {
        _ = revision
        return EditorButton.allCases.contains { UserDefaults.standard.string(forKey: $0.key("")) != nil }
    }

    private func save() {
        // The sheet's edits may not have reached the draft yet.
        themeManager.setDraftInfo(info)
        do {
            let folder = try themeManager.saveCustomTheme()
            themeManager.loadThemes()
            alert = ("Theme Saved", "Theme saved to:\n\(folder.path)")
        } catch {
            alert = ("Theme Not Saved", error.localizedDescription)
        }
    }

    private func report(_ problem: String?) {
        if let problem { alert = ("Image Not Used", problem) }
    }

    // MARK: - Canvas

    private var shownFrame: WindowFrame? { windowBorders ? previewFrame ?? frame : nil }
    private var showsFrameButtons: Bool { frameButtons && shownFrame != nil }
    private var title: String { info.name.isEmpty ? "Untitled" : info.name }

    // The button the Pressed state presses.
    private var pressedButton: EditorButton {
        if case .button(let button) = selection { return button }
        return .close
    }

    private enum CanvasMode { case preview, slices }

    // Slices only edits frames with a layout, and only while the frame or
    // one of its edges is selected.
    private var showsSlices: Bool {
        guard canvasMode == .slices, let frame, frame.k1 == nil else { return false }
        switch selection {
        case .frame, .edge, .box: return true
        case .theme, .button, .title: return false
        }
    }

    private var canvasToggleShown: Bool {
        guard let frame, frame.k1 == nil else { return false }
        switch selection {
        case .frame, .edge, .box: return true
        case .theme, .button, .title: return false
        }
    }

    private var canvas: some View {
        ZStack(alignment: .topLeading) {
            if showsSlices, let frame {
                slices(frame)
            } else {
                previewCanvas
            }
            if canvasToggleShown {
                Picker("View", selection: $canvasMode) {
                    Label("Preview", systemImage: "macwindow").labelStyle(.iconOnly).help("Preview").tag(CanvasMode.preview)
                    Label("Slices", systemImage: "square.grid.3x3").labelStyle(.iconOnly).help("Slices: edit how the art is cut").tag(CanvasMode.slices)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .padding(8)
            }
        }
    }

    private func slices(_ frame: WindowFrame) -> some View {
        let shown = previewFrame ?? frame
        let side: WindowFrame.Side? = { if case .edge(let s) = selection { return s }; return nil }()
        let box: WindowFrame.Box? = { if case .box(let b) = selection { return b }; return nil }()
        let size = CanvasGeometry(bounds: CGSize(width: 4000, height: 4000), requested: windowSize, insets: shown.insets).window.size
        return SlicesView(frame: frame, shown: shown, selectedSide: side, selectedRun: selectedRun,
                          inactive: state == .inactive, thumbnail: rendered(shown, windowSize: size),
                          selectedBox: box, selectBox: { selection = .box($0) },
                          select: { select($0, run: $1) }, preview: { previewFrame = $0 },
                          commit: { commit($0, side: $1) }, commitBoxes: commitBoxes,
                          showPreview: { canvasMode = .preview })
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                loadDroppedFile(providers) { url in drop(url, on: selection) }
            }
    }

    private var previewCanvas: some View {
        GeometryReader { geo in
            let unplaced = CanvasGeometry(bounds: geo.size, requested: windowSize, insets: shownFrame?.insets)
            // The render only depends on the window's size, so it can place the window.
            let rendered = rendered(for: unplaced)
            let g = unplaced.centering(rendered?.layout.shape ?? [])
            ZStack(alignment: .topLeading) {
                Color.gray.opacity(0.18)
                windowView(g, rendered: rendered)
                if case .edge(let side) = selection, let rendered {
                    runOverlay(side, g, rendered: rendered)
                }
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
        case .theme:
            break
        case .frame:
            if rendered != nil { rects.append(g.visible.insetBy(dx: -3, dy: -3)) }
        case .title:
            if let rect = rendered?.layout.title {
                rects.append(rect.offsetBy(dx: g.outer.minX, dy: g.outer.minY).insetBy(dx: -2, dy: -2))
            }
        case .edge(let side):
            if rendered != nil { rects.append(band(side, g).insetBy(dx: -1, dy: -1)) }
        case .box:
            // Boxes are image positions, shown in the slices view.
            break
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
        return rendered(frame, windowSize: g.window.size)
    }

    private func rendered(_ frame: WindowFrame, windowSize: CGSize) -> RenderedFrame? {
        let all = Set(WindowFrame.Widget.allCases)
        let widgets: Set<WindowFrame.Widget> = showsFrameButtons ? all : []
        let pressed = state == .pressed ? pressedButton.widget : nil
        let key = "\(frame.identity)|\(windowSize)|\(state)|\(widgets.count)|\(String(describing: pressed))|\(title)"
        if key == renderCache.key { return renderCache.value }
        let value = frame.render(windowSize: windowSize, active: state != .inactive, widgets: widgets,
                                 hidden: all.subtracting(widgets), title: title, pressedWidget: pressed,
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
        // Trimmed and sized like the overlays, to the box all of the button's states share.
        let mode = ButtonArt.Sizing.current
        let suffixes = ["", "Hover", "Pressed", "Disabled"]
        let images = ButtonArt.load(suffixes.map { defaults.string(forKey: button.key($0)) }, trim: mode != .original)
        let image = suffixes.firstIndex(of: suffix).flatMap { images[$0] } ?? images[0]
        return image.map { ButtonArt.sized($0, cover: 14, backing: 2, mode: mode) }
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
        if let rect = rendered?.layout.title, rect.offsetBy(dx: g.outer.minX, dy: g.outer.minY).contains(point) {
            return .title
        }
        if rendered != nil, g.visible.contains(point), !g.window.contains(point) {
            // Top and bottom draw over the sides, so they own the corners.
            guard frame?.k1 == nil else { return .frame }
            if point.y < g.window.minY { return .edge(.top) }
            if point.y >= g.window.maxY { return .edge(.bottom) }
            return .edge(point.x < g.window.minX ? .left : .right)
        }
        return nil
    }

    // Shows how the selected edge's runs drew at this window size: a box
    // per piece, a tick where each tile repeats, and an outline for scaled
    // pieces. Along a side edge everything runs top to bottom.
    private func runOverlay(_ side: WindowFrame.Side, _ g: CanvasGeometry, rendered: RenderedFrame) -> some View {
        let area = band(side, g)
        let pieces = rendered.layout.runs[side] ?? []
        func rect(_ start: CGFloat, _ length: CGFloat) -> CGRect {
            side.horizontal
                ? CGRect(x: g.outer.minX + start, y: area.minY, width: length, height: area.height)
                : CGRect(x: area.minX, y: g.outer.minY + start, width: area.width, height: length)
        }
        return Canvas { context, _ in
            for piece in pieces where piece.length > 0 {
                let r = rect(piece.start, piece.length)
                let selected = piece.run == selectedRun
                let tint = RunMode.tint(piece.code)
                context.fill(Path(r), with: .color(tint.opacity(selected ? 0.35 : 0.15)))
                context.stroke(Path(r), with: .color(selected ? .accentColor : tint.opacity(0.8)),
                               style: StrokeStyle(lineWidth: selected ? 1.5 : 0.5, dash: piece.code == WindowFrame.Part.scale ? [3, 2] : []))
                // Tiles start at the run's start, or at its end for the from-end modes.
                // Ticks for tiles narrower than 3 points would read as a solid fill.
                guard RunMode.tiles(piece.code), piece.sourceLength >= 3 else { continue }
                let step = CGFloat(piece.sourceLength)
                let fromEnd = RunMode.fromEnd(piece.code)
                var offset = step
                var ticks = Path()
                var count = 0
                // One-pixel tiles would draw a tick per point; stop well before.
                while offset < piece.length && count < 400 {
                    count += 1
                    let at = fromEnd ? piece.length - offset : offset
                    let tick = rect(piece.start + at, 0)
                    ticks.move(to: CGPoint(x: tick.minX, y: tick.minY))
                    ticks.addLine(to: CGPoint(x: tick.maxX, y: tick.maxY))
                    offset += step
                }
                context.stroke(ticks, with: .color(tint.opacity(0.9)), lineWidth: 0.5)
            }
        }
        .allowsHitTesting(false)
    }

    // Where a side's band draws in the canvas.
    private func band(_ side: WindowFrame.Side, _ g: CanvasGeometry) -> CGRect {
        let o = g.outer, i = g.insets
        switch side {
        case .top: return CGRect(x: o.minX, y: o.minY, width: o.width, height: i.top)
        case .bottom: return CGRect(x: o.minX, y: g.window.maxY, width: o.width, height: i.bottom)
        case .left: return CGRect(x: o.minX, y: o.minY, width: i.left, height: o.height)
        case .right: return CGRect(x: g.window.maxX, y: o.minY, width: i.right, height: o.height)
        }
    }

    // A drop replaces the image for the part and the state being previewed.
    private func drop(_ url: URL, on part: EditorPart) {
        selection = part
        // The part may not have art for the state being previewed.
        let state = states(for: part).contains(self.state) ? self.state : .active
        switch part {
        case .theme, .title:
            break
        case .button(let button):
            report(themeManager.setDraftImage(url, forKey: button.key(state.buttonSuffix)))
        case .frame, .edge, .box:
            report(themeManager.setDraftFrameArt(url, for: state.frameArt))
        }
    }

    // MARK: - Edge edits

    private func commit(_ runs: [(Int, Int)], side: WindowFrame.Side) {
        guard let frame, !runs.elementsEqual(frame.runs(side), by: ==) else {
            previewFrame = nil
            return
        }
        if let problem = themeManager.setDraftEdgeRuns(runs, for: side) {
            previewFrame = nil
            report(problem)
        }
    }

    // MARK: - Box edits

    private func commitBoxes(_ changes: [WindowFrame.Box: CGRect?]) {
        guard let frame else { return }
        let real = changes.filter { frame.rects[$0.key.rawValue] != $0.value }
        guard !real.isEmpty else {
            previewFrame = nil
            return
        }
        if let problem = themeManager.setDraftBoxes(real) {
            previewFrame = nil
            alert = ("Layout Not Changed", problem)
        }
    }

    // A title edit still waiting to be written is dropped, since undo steps past it.
    private func undo() {
        discardTitleEdit()
        themeManager.undoDraftEdit()
    }

    private func redo() {
        discardTitleEdit()
        themeManager.redoDraftEdit()
    }

    // MARK: - Title edits

    private func titleChanged(_ style: TitleStyle) {
        guard let frame, style != frame.titleStyle else { return }
        previewFrame = frame.with(titleStyle: style)
        titleWrite?.cancel()
        let write = DispatchWorkItem {
            titleWrite = nil
            if let problem = themeManager.setDraftTitleStyle(titleStyle) {
                report(problem)
                reload()
            }
        }
        titleWrite = write
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: write)
    }

    // A title edit still waiting to be written belongs to the frame it was made on.
    private func discardTitleEdit() {
        titleWrite?.cancel()
        titleWrite = nil
    }

    private func useFrame(from directory: URL?) {
        discardTitleEdit()
        report(themeManager.useDraftFrame(from: directory))
    }

    // MARK: - Inspector

    @ViewBuilder private var inspector: some View {
        switch selection {
        case .theme:
            themeInspector
        case .button(let button):
            buttonInspector(button)
        case .frame:
            frameInspector
        case .title:
            if let frame {
                TitleInspector(style: $titleStyle, frame: frame, baseline: titleBaseline)
            } else {
                Text("No window frame, so no title to style.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        case .edge(let side):
            if let frame, frame.k1 == nil {
                EdgeInspector(side: side, frame: previewFrame ?? frame, selected: $selectedRun,
                              selectSide: { selection = .edge($0) },
                              changed: themeManager.draftEdgeRunsChanged(side),
                              revert: { themeManager.revertDraftEdgeRuns(side) },
                              commit: { commit($0, side: side) })
            } else {
                frameInspector
            }
        case .box(let box):
            if let frame, frame.k1 == nil {
                BoxInspector(box: box, frame: previewFrame ?? frame, selectBox: { selection = .box($0) },
                             baseline: themeManager.baselineBoxes(), commit: commitBoxes)
            } else {
                frameInspector
            }
        }
    }

    private var themeInspector: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 10) {
            GridRow {
                Text("Name").gridColumnAlignment(.trailing)
                TextField("Name", text: $info.name, prompt: Text("My Theme")).labelsHidden()
                Text("Author").gridColumnAlignment(.trailing)
                TextField("Author", text: $info.author, prompt: Text("Your name")).labelsHidden()
            }
            GridRow {
                Text("Version")
                Stepper(value: $info.version, in: 1...999) {
                    Text("\(info.version)").monospacedDigit()
                }
                Text("Website")
                TextField("Website", text: $info.source, prompt: Text("https://")).labelsHidden()
            }
            if let engine = info.engine {
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    Text(engineLabel(engine) == engine ? "Made for \(engine)" : engineLabel(engine))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .gridCellColumns(3)
                }
            }
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
                    FrameSourceMenu(picked: useFrame)
                    HStack {
                        if frame?.k1 == nil {
                            Menu("Edit Layout") {
                                Section("Edges") {
                                    ForEach(WindowFrame.Side.allCases, id: \.self) { side in
                                        Button(side.rawValue.capitalized) {
                                            canvasMode = .slices
                                            selection = .edge(side)
                                        }
                                    }
                                }
                                Section("Boxes") {
                                    ForEach(WindowFrame.Box.allCases, id: \.self) { box in
                                        Button(frame?.rect(box) == nil ? "\(box.name) (none)" : box.name) {
                                            canvasMode = .slices
                                            selection = .box(box)
                                        }
                                    }
                                }
                            }
                            .fixedSize()
                            .help("Change how each edge's art is cut, and where the content, buttons and title sit")
                        }
                        Menu("Buttons") {
                            Button("Take Buttons from Frame") { themeManager.takeButtonsFromFrame() }
                            Button("Put Buttons in Frame") { themeManager.putButtonsInFrame() }
                                .disabled(!hasCustomImages)
                            Divider()
                            Button("Remove Frame") { useFrame(from: nil) }
                        }
                        .fixedSize()
                    }
                }
            }
        } else {
            VStack(spacing: 8) {
                Text("No window frame. Take one from another theme.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                FrameSourceMenu(picked: useFrame)
            }
        }
    }
}

// Its own view so the long theme list is only rebuilt when themes change.
private struct FrameSourceMenu: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    let picked: (URL?) -> Void

    var body: some View {
        let framed = themeManager.themes.filter { $0.frameDirectory != nil }
        Menu("Use Frame From") {
            ForEach(framed) { theme in
                Button(theme.name) { picked(theme.frameDirectory) }
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

// MARK: - Edge runs

// Names for wnd# part codes, the way a run is drawn.
private enum RunMode {
    typealias Part = WindowFrame.Part
    typealias Mode = (code: Int, name: String, symbol: String, help: String)
    static let drawing: [Mode] = [
        (Part.endCap, "Cap", "pin", "Drawn once at its own size"),
        (Part.stretch, "Tile", "repeat", "Repeats from its start to fill the space"),
        (Part.stretchEnd, "Tile from End", "repeat", "Repeats from its end to fill the space"),
        (Part.period, "Repeat Whole", "square.split.1x2", "Repeats only whole copies"),
        (Part.periodFill, "Fill", "arrow.right.to.line", "Takes whatever space is left, tiled from its start"),
        (Part.periodFillEnd, "Fill from End", "arrow.left.to.line", "Takes whatever space is left, tiled from its end"),
        (Part.scale, "Scale", "arrow.left.and.right", "Scaled to fill the space"),
        (Part.crumple, "Crumple", "scissors", "Drawn once, dropped when the window is too small"),
        (Part.title, "Title", "textformat", "Holds the title text and grows to fit it, tiled"),
        (Part.titleCap, "Title Cap", "pin", "Drawn once when the window has a title"),
        (Part.edge, "Gap", "circle.dashed", "Not drawn. Keeps its space at the ends of the edge"),
    ]
    static let widgets: [Mode] = [
        (Part.close, "Close Box", "xmark.circle", "Drawn when the window has a close button"),
        (Part.collapse, "Minimize Box", "minus.circle", "Drawn when the window has a minimize button"),
        (Part.zoom, "Zoom Box", "plus.circle", "Drawn when the window has a zoom button"),
        (Part.noClose, "No Close", "xmark.circle.fill", "Drawn when the window has no close button"),
        (Part.noCollapse, "No Minimize", "minus.circle.fill", "Drawn when the window has no minimize button"),
        (Part.noZoom, "No Zoom", "plus.circle.fill", "Drawn when the window has no zoom button"),
    ]

    // How the menu groups the modes.
    static var groups: [(title: String, modes: [Mode])] {
        func pick(_ codes: [Int]) -> [Mode] { codes.compactMap { c in drawing.first { $0.code == c } } }
        return [("Fixed", pick([Part.endCap, Part.titleCap, Part.crumple, Part.edge])),
                ("Grows", pick([Part.stretch, Part.stretchEnd, Part.period, Part.scale])),
                ("Fills What's Left", pick([Part.periodFill, Part.periodFillEnd, Part.title])),
                ("Buttons", widgets)]
    }

    static func name(_ code: Int) -> String {
        (drawing + widgets).first { $0.code == code }?.name ?? "Code \(code)"
    }

    static func symbol(_ code: Int) -> String {
        (drawing + widgets).first { $0.code == code }?.symbol ?? "questionmark"
    }

    // Modes WindowFrame.fill tiles, and those it tiles from the far end.
    static func tiles(_ code: Int) -> Bool {
        (Part.grows.contains(code) || Part.fills.contains(code) || code == Part.title) && code != Part.scale
    }

    static func fromEnd(_ code: Int) -> Bool {
        code == Part.stretchEnd || code == Part.periodFillEnd
    }

    static func help(_ code: Int) -> String {
        (drawing + widgets).first { $0.code == code }?.help ?? "A part code this editor doesn't know. It's kept as is."
    }

    static func tint(_ code: Int) -> Color {
        if Part.grows.contains(code) { return .green }
        if Part.fills.contains(code) { return .orange }
        if code == Part.title { return .purple }
        if code == Part.edge { return .clear }
        if widgets.contains(where: { $0.code == code }) { return .blue }
        return .gray
    }
}

/// Edits on one side's list of (code, cumulative end). Each run starts where
/// the one before it ends, so moving an end also moves the next run's start.
private enum RunEdit {
    typealias Runs = [(Int, Int)]

    static func start(_ runs: Runs, _ i: Int) -> Int { i == 0 ? 0 : runs[i - 1].1 }

    /// How far run i's end can move: from its start to the next run's end.
    static func bounds(_ runs: Runs, _ i: Int, extent: Int) -> ClosedRange<Int> {
        start(runs, i)...(i + 1 < runs.count ? runs[i + 1].1 : extent)
    }

    static func move(_ runs: Runs, _ i: Int, end: Int, extent: Int) -> Runs {
        var new = runs
        let range = bounds(runs, i, extent: extent)
        new[i].1 = min(max(end, range.lowerBound), range.upperBound)
        return new
    }

    static func setCode(_ runs: Runs, _ i: Int, _ code: Int) -> Runs {
        var new = runs
        new[i].0 = code
        return new
    }

    /// Cuts run i in two at pixel `at`, both halves keeping its mode.
    static func split(_ runs: Runs, _ i: Int, at: Int) -> Runs {
        let low = start(runs, i), high = runs[i].1
        guard high - low >= 2 else { return runs }
        var new = runs
        new.insert((runs[i].0, min(max(at, low + 1), high - 1)), at: i)
        return new
    }

    /// Drops run i's end, so the next run takes its pixels.
    static func mergeNext(_ runs: Runs, _ i: Int) -> Runs {
        guard i + 1 < runs.count else { return runs }
        var new = runs
        new.remove(at: i)
        return new
    }

    /// The run before i takes its pixels. Returns the run to select after.
    static func mergePrevious(_ runs: Runs, _ i: Int) -> (runs: Runs, selected: Int) {
        guard runs.count > 1 else { return (runs, i) }
        guard i > 0 else { return (mergeNext(runs, i), 0) }
        var new = runs
        new[i - 1].1 = runs[i].1
        new.remove(at: i)
        return (new, i - 1)
    }
}

/// The mode menu, grouped by how a run behaves as the window grows.
private struct ModePicker: View {
    let code: Int
    let set: (Int) -> Void

    var body: some View {
        let known = (RunMode.drawing + RunMode.widgets).contains { $0.code == code }
        Picker("Mode", selection: Binding(get: { code }, set: set)) {
            ForEach(RunMode.groups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.modes, id: \.code) { Label($0.name, systemImage: $0.symbol).tag($0.code) }
                }
            }
            if !known { Text(RunMode.name(code)).tag(code) }
        }
    }
}

/// The selected edge's name and history controls, and the selected run's
/// mode and range. The runs themselves are edited in the Slices view.
private struct EdgeInspector: View {
    let side: WindowFrame.Side
    // The frame as drawn, a drag or nudge in progress included.
    let frame: WindowFrame
    @Binding var selected: Int
    let selectSide: (WindowFrame.Side) -> Void
    let changed: Bool
    let revert: () -> Void
    let commit: ([(Int, Int)]) -> Void

    private var runs: [(Int, Int)] { frame.runs(side) }
    private var extent: Int { frame.extent(side) }
    private var index: Int { min(selected, max(0, runs.count - 1)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if !runs.isEmpty { runRow }
        }
        .padding(.vertical, 8)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Picker("Edge", selection: Binding(get: { side }, set: selectSide)) {
                ForEach(WindowFrame.Side.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Text("\(runs.count) runs, \(extent) px")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Button("Revert Edge", action: revert)
                .disabled(!changed)
                .help("Put this edge back as it was when the frame came in")
        }
    }

    private var runRow: some View {
        let i = index
        let (code, end) = runs[i]
        let range = RunEdit.bounds(runs, i, extent: extent)
        let lower = range.lowerBound
        let warnings = frame.runWarnings(side)
        let setEnd = { (value: Int) in commit(RunEdit.move(runs, i, end: value, extent: extent)) }
        return HStack(spacing: 12) {
            Text("Run \(i + 1)")
                .font(.caption)
                .foregroundColor(.secondary)
                .monospacedDigit()
            ModePicker(code: code) { commit(RunEdit.setCode(runs, i, $0)) }
                .labelsHidden()
                .fixedSize()
                .help(RunMode.help(code))
            Text("From \(lower)")
                .monospacedDigit()
            HStack(spacing: 4) {
                Text("to")
                TextField("End", value: Binding(get: { end }, set: setEnd), format: .number)
                    .frame(width: 44)
                    .labelsHidden()
                Stepper("End", value: Binding(get: { end }, set: setEnd), in: range)
                    .labelsHidden()
            }
            Text("\(end - lower) px")
                .font(.caption)
                .foregroundColor(.secondary)
                .monospacedDigit()
            if !warnings.isEmpty {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundColor(.yellow)
                    .help(warnings.joined(separator: "\n"))
            }
            Spacer()
            Button("Split") { commit(RunEdit.split(runs, i, at: (lower + end) / 2)) }
                .disabled(end - lower < 2)
                .help("Cut this run in two at its middle")
            Button("Merge Next") { commit(RunEdit.mergeNext(runs, i)) }
                .disabled(i + 1 >= runs.count)
                .help("Join this run into the one after it")
            Button("Delete") {
                let result = RunEdit.mergePrevious(runs, i)
                selected = result.selected
                commit(result.runs)
            }
            .disabled(runs.count < 2)
            .help("Remove this run. The one before it takes its pixels")
        }
        .controlSize(.small)
    }
}

/// Maps between image pixels and canvas points for the Slices view. Zoom is
/// a whole number when the image fits, so each pixel lands on whole points,
/// and 1/n when it doesn't.
private struct SlicesGeometry {
    let image: CGSize
    let zoom: CGFloat
    let origin: CGPoint

    init(bounds: CGSize, image: CGSize, top: CGFloat = 36, margin: CGFloat = 24) {
        self.image = image
        let fit = min((bounds.width - 2 * margin) / max(1, image.width),
                      (bounds.height - top - margin) / max(1, image.height))
        zoom = fit >= 1 ? min(16, fit.rounded(.down)) : 1 / (1 / max(fit, 0.01)).rounded(.up)
        origin = CGPoint(x: ((bounds.width - image.width * zoom) / 2).rounded(),
                         y: (top + (bounds.height - top - margin - image.height * zoom) / 2).rounded())
    }

    func rect(_ r: CGRect) -> CGRect {
        CGRect(x: origin.x + r.minX * zoom, y: origin.y + r.minY * zoom, width: r.width * zoom, height: r.height * zoom)
    }

    /// Image position under a canvas point, fractional.
    func position(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - origin.x) / zoom, y: (point.y - origin.y) / zoom)
    }
}

// Routes key events from the window's monitor to the current view value.
private final class SliceKeys {
    var handle: (NSEvent) -> Bool = { _ in false }
    var monitor: Any?
}

/// The whole frame image, big, with every edge's runs on it: guides at run
/// ends, regions tinted by mode. Click a region to pick a run, drag a guide
/// to move its end, right-click for more.
private struct SlicesView: View {
    // The frame as saved; drags and nudges start from it.
    let frame: WindowFrame
    // The frame as drawn, an edit in progress included.
    let shown: WindowFrame
    let selectedSide: WindowFrame.Side?
    let selectedRun: Int
    let inactive: Bool
    let thumbnail: RenderedFrame?
    let selectedBox: WindowFrame.Box?
    let selectBox: (WindowFrame.Box) -> Void
    let select: (WindowFrame.Side, Int) -> Void
    let preview: (WindowFrame?) -> Void
    let commit: ([(Int, Int)], WindowFrame.Side) -> Void
    let commitBoxes: ([WindowFrame.Box: CGRect?]) -> Void
    let showPreview: () -> Void

    // Which edges of a box a drag moves. Empty moves the whole box.
    private struct Handle: OptionSet, Hashable {
        let rawValue: Int
        static let left = Handle(rawValue: 1), right = Handle(rawValue: 2)
        static let top = Handle(rawValue: 4), bottom = Handle(rawValue: 8)
    }

    private enum Hit {
        // Every run ending at the guide; zero-length runs can share one.
        case guide(WindowFrame.Side, [Int])
        case region(WindowFrame.Side, Int, pixel: Int)
        case box(WindowFrame.Box, Handle)
    }

    private struct BoxDrag {
        let box: WindowFrame.Box
        let handle: Handle
        let start: CGRect
    }

    private struct Drag {
        let side: WindowFrame.Side
        let candidates: [Int]
        var run: Int?
        var startEnd: Int
    }

    @State private var hover: CGPoint?
    @State private var drag: Drag?
    @State private var boxDrag: BoxDrag?
    @State private var cursorPushed = false
    @State private var keys = SliceKeys()
    // The arrow key whose release commits a nudge.
    @State private var nudgeKey: UInt16?

    var body: some View {
        let _ = keys.handle = handleKey
        GeometryReader { geo in
            let g = SlicesGeometry(bounds: geo.size, image: frame.size)
            let hit = hover.flatMap { self.hit($0, g) }
            ZStack(alignment: .topLeading) {
                Color.gray.opacity(0.18)
                Image(decorative: inactive ? shown.inactive : shown.active, scale: 1)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: frame.size.width * g.zoom, height: frame.size.height * g.zoom)
                    .offset(x: g.origin.x, y: g.origin.y)
                Canvas { context, _ in draw(context, g) }
                    .allowsHitTesting(false)
                readout(hit, g)
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .allowsHitTesting(false)
                thumbnailView(geo.size)
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
            .contentShape(Rectangle())
            .gesture(gesture(g))
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hover = point
                case .ended: hover = nil
                }
                updateCursor(hover.flatMap { self.hit($0, g) })
            }
            .contextMenu { contextMenu(hit) }
        }
        .onAppear {
            keys.monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [keys] event in
                keys.handle(event) ? nil : event
            }
        }
        .onDisappear {
            if let monitor = keys.monitor { NSEvent.removeMonitor(monitor) }
            keys.monitor = nil
            if cursorPushed { NSCursor.pop() }
            cursorPushed = false
        }
    }

    // MARK: Hit testing

    // The selected side first, then top and bottom, which draw over the
    // sides in the corners.
    private var order: [WindowFrame.Side] {
        var sides: [WindowFrame.Side] = [.top, .bottom, .left, .right]
        if let selectedSide {
            sides.removeAll { $0 == selectedSide }
            sides.insert(selectedSide, at: 0)
        }
        return sides
    }

    private func hit(_ point: CGPoint, _ g: SlicesGeometry) -> Hit? {
        let p = g.position(point)
        let reach = max(3, g.zoom / 2) / g.zoom
        // A picked box takes the mouse; otherwise runs come first and a box
        // only answers on its border, so the runs under it stay clickable.
        if let selectedBox, let hit = boxHit(selectedBox, p, reach: reach, inside: true) { return hit }
        if let hit = runHit(p, reach: reach) { return hit }
        for box in boxOrder {
            if let hit = boxHit(box, p, reach: reach, inside: false) { return hit }
        }
        return nil
    }

    // Small boxes first, so they win over the content box around them.
    private var boxOrder: [WindowFrame.Box] { [.close, .zoom, .collapse, .title, .content] }

    private func boxHit(_ box: WindowFrame.Box, _ p: CGPoint, reach: CGFloat, inside: Bool) -> Hit? {
        guard let r = shown.rect(box), r.insetBy(dx: -reach, dy: -reach).contains(p) else { return nil }
        var handle: Handle = []
        if abs(p.x - r.minX) <= reach { handle.insert(.left) } else if abs(p.x - r.maxX) <= reach { handle.insert(.right) }
        if abs(p.y - r.minY) <= reach { handle.insert(.top) } else if abs(p.y - r.maxY) <= reach { handle.insert(.bottom) }
        if !handle.isEmpty || inside { return .box(box, handle) }
        return nil
    }

    private func runHit(_ p: CGPoint, reach: CGFloat) -> Hit? {
        for side in order {
            let band = frame.band(side)
            guard band.insetBy(dx: side.horizontal ? -reach : 0, dy: side.horizontal ? 0 : -reach).contains(p) else { continue }
            let along = side.horizontal ? p.x : p.y
            let runs = shown.runs(side)
            let ends = runs.indices.filter { runs[$0].1 > 0 && abs(CGFloat(runs[$0].1) - along) <= reach }
            if let nearest = ends.min(by: { abs(CGFloat(runs[$0].1) - along) < abs(CGFloat(runs[$1].1) - along) }) {
                return .guide(side, ends.filter { runs[$0].1 == runs[nearest].1 })
            }
        }
        for side in order where frame.band(side).contains(p) {
            let pixel = Int((side.horizontal ? p.x : p.y).rounded(.down))
            let runs = shown.runs(side)
            if let i = runs.indices.first(where: { RunEdit.start(runs, $0) <= pixel && pixel < runs[$0].1 }) {
                return .region(side, i, pixel: pixel)
            }
        }
        return nil
    }

    /// `start` with the drag applied, in whole pixels, kept inside the image
    /// and at least a pixel across.
    private func dragged(_ start: CGRect, _ handle: Handle, dx: Int, dy: Int) -> CGRect {
        let width = Int(frame.size.width), height = Int(frame.size.height)
        var minX = Int(start.minX), minY = Int(start.minY), maxX = Int(start.maxX), maxY = Int(start.maxY)
        if handle.isEmpty {
            let x = min(max(dx, -minX), width - maxX), y = min(max(dy, -minY), height - maxY)
            minX += x; maxX += x; minY += y; maxY += y
        } else {
            if handle.contains(.left) { minX = min(max(0, minX + dx), maxX - 1) }
            if handle.contains(.right) { maxX = max(min(width, maxX + dx), minX + 1) }
            if handle.contains(.top) { minY = min(max(0, minY + dy), maxY - 1) }
            if handle.contains(.bottom) { maxY = max(min(height, maxY + dy), minY + 1) }
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    // MARK: Drawing

    private func draw(_ context: GraphicsContext, _ g: SlicesGeometry) {
        let content = g.rect(frame.content)
        context.fill(Path(content), with: .color(.black.opacity(0.45)))
        // Sides first, so top and bottom sit over them in the corners.
        for side in [WindowFrame.Side.left, .right, .top, .bottom] {
            drawRuns(side, context, g)
        }
        if let side = selectedSide {
            drawRuns(side, context, g, emphasized: true)
        }
        drawBoxes(context, g)
    }

    private static func tint(_ box: WindowFrame.Box) -> Color {
        switch box {
        case .content: return .white
        case .close: return .red
        case .zoom: return .green
        case .collapse: return .yellow
        case .title: return .blue
        }
    }

    // Dashed outlines, the picked box solid with its corners marked.
    private func drawBoxes(_ context: GraphicsContext, _ g: SlicesGeometry) {
        for box in boxOrder.reversed() {
            guard let rect = shown.rect(box) else { continue }
            let r = g.rect(rect)
            let picked = box == selectedBox
            let color = picked ? Color.accentColor : Self.tint(box).opacity(0.9)
            context.stroke(Path(r), with: .color(color),
                           style: StrokeStyle(lineWidth: picked ? 2 : 1, dash: picked ? [] : [4, 3]))
            if picked {
                for corner in [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                               CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)] {
                    let knob = CGRect(x: corner.x - 3, y: corner.y - 3, width: 6, height: 6)
                    context.fill(Path(knob), with: .color(.white))
                    context.stroke(Path(knob), with: .color(.accentColor), lineWidth: 1)
                }
            }
        }
    }

    private func span(_ side: WindowFrame.Side, _ start: Int, _ end: Int) -> CGRect {
        let band = frame.band(side)
        return side.horizontal
            ? CGRect(x: CGFloat(start), y: band.minY, width: CGFloat(end - start), height: band.height)
            : CGRect(x: band.minX, y: CGFloat(start), width: band.width, height: CGFloat(end - start))
    }

    private func drawRuns(_ side: WindowFrame.Side, _ context: GraphicsContext, _ g: SlicesGeometry, emphasized: Bool = false) {
        let runs = shown.runs(side)
        let isSelected = side == selectedSide
        let extent = frame.extent(side)
        for i in runs.indices {
            let start = RunEdit.start(runs, i), end = min(runs[i].1, extent)
            guard end > start else { continue }
            let r = g.rect(span(side, start, end))
            let code = runs[i].0
            let picked = isSelected && i == selectedRun
            if !emphasized {
                context.fill(Path(r), with: .color(RunMode.tint(code).opacity(picked ? 0.4 : 0.18)))
                if !side.horizontal { hatchCorners(r, context, g) }
                drawIcon(code, in: r, context)
            }
            if picked {
                context.stroke(Path(r.insetBy(dx: 0.5, dy: 0.5)), with: .color(.accentColor), lineWidth: 1.5)
            }
        }
        if !emphasized, let last = runs.last, last.1 < extent {
            // Past the last run. Never drawn.
            context.fill(Path(g.rect(span(side, max(0, last.1), extent))), with: .color(.black.opacity(0.35)))
        }
        // Guides at run ends, across the band only.
        var guides = Path()
        for (_, end) in runs where end > 0 && end <= extent {
            let line = g.rect(span(side, end, end))
            guides.move(to: CGPoint(x: line.minX, y: line.minY))
            guides.addLine(to: CGPoint(x: side.horizontal ? line.minX : line.maxX, y: side.horizontal ? line.maxY : line.minY))
        }
        if emphasized {
            context.stroke(guides, with: .color(.accentColor), lineWidth: 1.5)
        } else if !isSelected {
            context.stroke(guides, with: .color(.primary.opacity(0.45)), lineWidth: 1)
        }
    }

    // Side runs in the top and bottom rows are drawn over, so they're hatched.
    private func hatchCorners(_ r: CGRect, _ context: GraphicsContext, _ g: SlicesGeometry) {
        let content = g.rect(frame.content)
        let covered = [CGRect(x: r.minX, y: r.minY, width: r.width, height: max(0, content.minY - r.minY)),
                       CGRect(x: r.minX, y: content.maxY, width: r.width, height: max(0, r.maxY - content.maxY))]
            .map { $0.intersection(r) }
            .filter { !$0.isNull && !$0.isEmpty }
        for area in covered {
            var hatch = Path()
            var x = area.minX - area.height
            while x < area.maxX {
                hatch.move(to: CGPoint(x: x, y: area.maxY))
                hatch.addLine(to: CGPoint(x: x + area.height, y: area.minY))
                x += 5
            }
            var clipped = context
            clipped.clip(to: Path(area))
            clipped.fill(Path(area), with: .color(.black.opacity(0.25)))
            clipped.stroke(hatch, with: .color(.white.opacity(0.35)), lineWidth: 0.5)
        }
    }

    private func drawIcon(_ code: Int, in r: CGRect, _ context: GraphicsContext) {
        guard r.width >= 14, r.height >= 14 else { return }
        var layer = context
        layer.translateBy(x: r.midX, y: r.midY)
        // Tile from End shares Tile's icon, mirrored.
        if code == WindowFrame.Part.stretchEnd { layer.scaleBy(x: -1, y: 1) }
        let icon = Text(Image(systemName: RunMode.symbol(code)))
            .font(.system(size: min(12, r.height - 4)))
            .foregroundColor(.white)
        layer.draw(icon, at: .zero)
    }

    // MARK: Overlays

    private func readout(_ hit: Hit?, _ g: SlicesGeometry) -> some View {
        var text = ""
        if let hover {
            let p = g.position(hover)
            let x = Int(p.x.rounded(.down)), y = Int(p.y.rounded(.down))
            if x >= 0, y >= 0, x < Int(frame.size.width), y < Int(frame.size.height) { text = "x \(x), y \(y)" }
        }
        switch hit {
        case .guide(let side, let runs):
            let end = shown.runs(side)[runs[0]].1
            text += "  \(side.rawValue.capitalized) run \(runs[0] + 1) ends at \(end). Drag to move"
        case .region(let side, let i, _):
            let runs = shown.runs(side)
            text += "  \(side.rawValue.capitalized) run \(i + 1): \(RunMode.name(runs[i].0)), \(RunEdit.start(runs, i))-\(runs[i].1)"
        case .box(let box, let handle):
            if let r = shown.rect(box) {
                let action = handle.isEmpty ? "Drag to move" : "Drag to resize"
                text += "  \(box.name) box \(Int(r.minX)), \(Int(r.minY)), \(Int(r.width)) x \(Int(r.height)). \(action)"
            }
        case nil:
            break
        }
        return Text(text.trimmingCharacters(in: .whitespaces))
            .font(.caption.monospacedDigit())
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Capsule().fill(.regularMaterial))
            .opacity(text.isEmpty ? 0 : 1)
    }

    @ViewBuilder private func thumbnailView(_ bounds: CGSize) -> some View {
        if let thumbnail {
            let size = CGSize(width: CGFloat(thumbnail.image.width) / 2, height: CGFloat(thumbnail.image.height) / 2)
            let scale = min(1, bounds.width * 0.3 / size.width, bounds.height * 0.3 / size.height)
            Image(decorative: thumbnail.image, scale: 2)
                .resizable()
                .interpolation(scale < 1 ? .medium : .none)
                .frame(width: size.width * scale, height: size.height * scale)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .windowBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.4), lineWidth: 0.5))
                .onTapGesture(perform: showPreview)
                .help("How it draws. Click for the full preview")
        }
    }

    @ViewBuilder private func contextMenu(_ hit: Hit?) -> some View {
        if case .box(let box, _) = hit, box != .content {
            Button("Remove \(box.name) Box") { commitBoxes([box: nil]) }
        }
        if case .region(let side, let i, let pixel) = hit {
            let runs = frame.runs(side)
            let start = RunEdit.start(runs, i)
            ModePicker(code: runs[i].0) { edit(side, i, RunEdit.setCode(runs, i, $0)) }
            Divider()
            Button("Split at \(pixel)") { edit(side, i, RunEdit.split(runs, i, at: max(pixel, start + 1))) }
                .disabled(runs[i].1 - start < 2)
            Button("Merge with Next") { edit(side, i, RunEdit.mergeNext(runs, i)) }
                .disabled(i + 1 >= runs.count)
            Button("Delete") {
                let result = RunEdit.mergePrevious(runs, i)
                edit(side, result.selected, result.runs)
            }
            .disabled(runs.count < 2)
        }
    }

    private func edit(_ side: WindowFrame.Side, _ i: Int, _ runs: [(Int, Int)]) {
        select(side, i)
        commit(runs, side)
    }

    // MARK: Mouse

    private func gesture(_ g: SlicesGeometry) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if drag == nil && boxDrag == nil, case .box(let box, let handle) = hit(value.startLocation, g),
                   let rect = frame.rect(box) {
                    boxDrag = BoxDrag(box: box, handle: handle, start: rect)
                    if box != selectedBox { selectBox(box) }
                }
                if let b = boxDrag {
                    let dx = Int((value.translation.width / g.zoom).rounded())
                    let dy = Int((value.translation.height / g.zoom).rounded())
                    preview(frame.with([b.box: dragged(b.start, b.handle, dx: dx, dy: dy)]))
                    return
                }
                if drag == nil {
                    guard case .guide(let side, let runs) = hit(value.startLocation, g) else { return }
                    drag = Drag(side: side, candidates: runs, run: runs.count == 1 ? runs[0] : nil,
                                startEnd: frame.runs(side)[runs[0]].1)
                }
                guard var d = drag else { return }
                let moved = d.side.horizontal ? value.translation.width : value.translation.height
                let delta = Int((moved / g.zoom).rounded())
                if d.run == nil {
                    guard delta != 0 else { return }
                    // Runs sharing an end: forward moves the last, backward the first.
                    d.run = delta > 0 ? d.candidates.max() : d.candidates.min()
                    drag = d
                }
                guard let i = d.run else { return }
                let runs = RunEdit.move(frame.runs(d.side), i, end: d.startEnd + delta, extent: frame.extent(d.side))
                preview(frame.with(d.side, runs: runs))
            }
            .onEnded { value in
                if let b = boxDrag {
                    boxDrag = nil
                    commitBoxes([b.box: shown.rect(b.box)])
                    return
                }
                if let d = drag {
                    drag = nil
                    if let i = d.run {
                        select(d.side, i)
                        commit(shown.runs(d.side), d.side)
                    } else {
                        select(d.side, d.candidates[0])
                    }
                    return
                }
                let distance = hypot(value.translation.width, value.translation.height)
                if distance < 3, case .region(let side, let i, _) = hit(value.startLocation, g) {
                    select(side, i)
                }
            }
    }

    private func updateCursor(_ hit: Hit?) {
        var cursor: NSCursor?
        if case .guide(let side, _) = hit { cursor = side.horizontal ? .resizeLeftRight : .resizeUpDown }
        if case .box(_, let handle) = hit {
            // No diagonal resize cursor in AppKit; corners get the crosshair.
            if handle.isEmpty { cursor = .openHand }
            else if handle.isSubset(of: [.left, .right]) { cursor = .resizeLeftRight }
            else if handle.isSubset(of: [.top, .bottom]) { cursor = .resizeUpDown }
            else { cursor = .crosshair }
        }
        if cursorPushed { NSCursor.pop() }
        cursorPushed = cursor != nil
        cursor?.push()
    }

    // MARK: Keys

    // Arrows along the selected edge nudge the run's end, 10 px with Shift,
    // and a held key makes one edit. Arrows across it, and Tab, pick the
    // next or previous run. Delete gives the run to the one before it.
    private func handleKey(_ event: NSEvent) -> Bool {
        if let box = selectedBox { return handleBoxKey(event, box) }
        guard let side = selectedSide, !(event.window?.firstResponder is NSText),
              event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return false }
        let runs = frame.runs(side)
        guard runs.indices.contains(selectedRun) else { return false }
        let i = selectedRun
        let (forward, backward, next, previous): (UInt16, UInt16, UInt16, UInt16) =
            side.horizontal ? (124, 123, 125, 126) : (125, 126, 124, 123)

        if event.type == .keyUp {
            guard event.keyCode == nudgeKey else { return false }
            nudgeKey = nil
            commit(shown.runs(side), side)
            return true
        }
        switch event.keyCode {
        case forward, backward:
            let step = event.modifierFlags.contains(.shift) ? 10 : 1
            let current = shown.runs(side)
            let end = current[i].1 + (event.keyCode == forward ? step : -step)
            nudgeKey = event.keyCode
            preview(frame.with(side, runs: RunEdit.move(current, i, end: end, extent: frame.extent(side))))
        case next, previous, 48:
            let back = event.keyCode == previous || (event.keyCode == 48 && event.modifierFlags.contains(.shift))
            select(side, min(max(0, i + (back ? -1 : 1)), runs.count - 1))
        case 51, 117:
            guard !event.isARepeat else { return true }
            let result = RunEdit.mergePrevious(runs, i)
            edit(side, result.selected, result.runs)
        default:
            return false
        }
        return true
    }

    // Arrows move the picked box, 10 px with Shift, and a held key makes one
    // edit. Delete removes it, except the content box.
    private func handleBoxKey(_ event: NSEvent, _ box: WindowFrame.Box) -> Bool {
        guard !(event.window?.firstResponder is NSText),
              event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
              let rect = shown.rect(box) else { return false }
        if event.type == .keyUp {
            guard event.keyCode == nudgeKey else { return false }
            nudgeKey = nil
            commitBoxes([box: shown.rect(box)])
            return true
        }
        let step = event.modifierFlags.contains(.shift) ? 10 : 1
        let moves: [UInt16: (Int, Int)] = [123: (-step, 0), 124: (step, 0), 125: (0, step), 126: (0, -step)]
        if let (dx, dy) = moves[event.keyCode] {
            nudgeKey = event.keyCode
            preview(frame.with([box: dragged(rect, [], dx: dx, dy: dy)]))
            return true
        }
        if [51, 117].contains(event.keyCode), box != .content {
            if !event.isARepeat { commitBoxes([box: nil]) }
            return true
        }
        return false
    }
}

// Where one layout box sits in the frame image, with Add, Remove and Revert.
private struct BoxInspector: View {
    let box: WindowFrame.Box
    // The frame as drawn, a drag or nudge in progress included.
    let frame: WindowFrame
    let selectBox: (WindowFrame.Box) -> Void
    // Boxes as they came with the frame, when they've changed since.
    let baseline: [WindowFrame.Box: CGRect?]?
    let commit: ([WindowFrame.Box: CGRect?]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Picker("Box", selection: Binding(get: { box }, set: selectBox)) {
                    ForEach(WindowFrame.Box.allCases, id: \.self) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Text("\(Int(frame.size.width)) x \(Int(frame.size.height)) px image")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button("Revert Boxes") { if let baseline { commit(baseline) } }
                    .disabled(baseline == nil)
                    .help("Put every box back as it was when the frame came in")
            }
            if let rect = frame.rect(box) {
                HStack(spacing: 12) {
                    field("X", rect.minX) { commit([box: CGRect(x: $0, y: rect.minY, width: rect.width, height: rect.height)]) }
                    field("Y", rect.minY) { commit([box: CGRect(x: rect.minX, y: $0, width: rect.width, height: rect.height)]) }
                    field("W", rect.width) { commit([box: CGRect(x: rect.minX, y: rect.minY, width: $0, height: rect.height)]) }
                    field("H", rect.height) { commit([box: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: $0)]) }
                    Spacer()
                    if box != .content {
                        Button("Remove Box") { commit([box: nil]) }
                            .help("Take the \(box.name.lowercased()) box out of the layout")
                    }
                }
            } else {
                HStack(spacing: 12) {
                    Text(frame.missingBoxes.contains(box)
                         ? "No \(box.name.lowercased()) box, but an edge has runs for one."
                         : "This frame has no \(box.name.lowercased()) box.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    let start = frame.startingRect(for: box)
                    Button("Add Box") { if let start { commit([box: start]) } }
                        .disabled(start == nil)
                        .help(start == nil ? "There's no room above the content. Make the top band taller first"
                                           : "Add one in the top band, then drag it into place")
                }
            }
        }
        .padding(.vertical, 8)
    }

    private func field(_ label: String, _ value: CGFloat, _ set: @escaping (CGFloat) -> Void) -> some View {
        HStack(spacing: 4) {
            Text(label)
            TextField(label, value: Binding(get: { Int(value) }, set: { set(CGFloat($0)) }), format: .number)
                .labelsHidden()
                .frame(width: 48)
                .monospacedDigit()
        }
    }
}

// Font, colors and shadow of the window title. Leaving a field on its
// default keeps it out of layout.json, so the frame's own look shows through.
private struct TitleInspector: View {
    @Binding var style: TitleStyle
    let frame: WindowFrame
    // The style when the frame came in, once it's been edited.
    let baseline: TitleStyle?

    // Hidden families (a leading dot) are system-only.
    private static let families = NSFontManager.shared.availableFontFamilies.filter { !$0.hasPrefix(".") }.sorted()

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                Text("Font").gridColumnAlignment(.trailing)
                HStack(spacing: 12) {
                    Picker("Font", selection: $style.font) {
                        Text("System").tag(String?.none)
                        Divider()
                        // A family the theme names but this Mac lacks still shows as picked.
                        if let font = style.font, !Self.families.contains(font) {
                            Text("\(font) (missing)").tag(Optional(font))
                        }
                        ForEach(Self.families, id: \.self) { Text($0).tag(Optional($0)) }
                    }
                    .labelsHidden()
                    .frame(width: 160)
                    Picker("Weight", selection: weight) {
                        ForEach(TitleStyle.Weight.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Stepper(value: size, in: TitleStyle.sizes) {
                        Text("\(size.wrappedValue.formatted()) pt").monospacedDigit()
                    }
                    Picker("Alignment", selection: alignment) {
                        Label("Left", systemImage: "text.alignleft").tag(TitleStyle.Alignment.left)
                        Label("Center", systemImage: "text.aligncenter").tag(TitleStyle.Alignment.center)
                        Label("Right", systemImage: "text.alignright").tag(TitleStyle.Alignment.right)
                    }
                    .pickerStyle(.segmented)
                    .labelStyle(.iconOnly)
                    .labelsHidden()
                    .fixedSize()
                    // 2.x titles get a section just wide enough for the text, so only 1.x bars leave room to align in.
                    .disabled(frame.k1 == nil && style.alignment == nil)
                    .help(frame.k1 == nil ? "2.x frames size the title's section to the text, so it stays centered"
                                          : "Where the title sits in its space")
                }
            }
            GridRow {
                Text("Color")
                HStack(spacing: 12) {
                    colorChoice(\.color, active: true, help: "Auto uses the color the frame art holds")
                    Text("Inactive")
                    colorChoice(\.inactiveColor, active: false, help: "Auto uses the inactive art's color, or dims a set active color")
                    Spacer()
                    Button("Revert") { style = baseline ?? frame.titleStyle }
                        .disabled((baseline ?? frame.titleStyle) == style)
                        .help("Put the title back as it came with the frame")
                }
            }
            GridRow {
                Text("Shadow")
                HStack(spacing: 12) {
                    Picker("Shadow", selection: shadowMode) {
                        Text("Auto").tag(0)
                        Text("None").tag(1)
                        Text("Custom").tag(2)
                    }
                    .labelsHidden()
                    .fixedSize()
                    .help("Auto keeps the frame's own emboss, if it has one")
                    if case .custom(let shadow) = style.shadow {
                        ColorPicker("Shadow Color", selection: Binding(
                            get: { Color(nsColor: TitleStyle.color(shadow.color) ?? .black) },
                            set: { color in setShadow { $0.color = TitleStyle.hex(NSColor(color)) } }))
                            .labelsHidden()
                        number("X", shadow.x, -4...4) { v in setShadow { $0.x = v } }
                        number("Y", shadow.y, -4...4) { v in setShadow { $0.y = v } }
                        number("Blur", shadow.blur, 0...6) { v in setShadow { $0.blur = v } }
                    }
                }
            }
        }
    }

    // Size, weight and alignment drop out of the style at their defaults.
    private var size: Binding<CGFloat> {
        Binding(get: { style.size ?? TitleStyle.defaultSize },
                set: { style.size = $0 == TitleStyle.defaultSize ? nil : $0 })
    }

    private var weight: Binding<TitleStyle.Weight> {
        Binding(get: { style.weight ?? TitleStyle.defaultWeight },
                set: { style.weight = $0 == TitleStyle.defaultWeight ? nil : $0 })
    }

    private var alignment: Binding<TitleStyle.Alignment> {
        Binding(get: { style.alignment ?? .center },
                set: { style.alignment = $0 == .center ? nil : $0 })
    }

    // The well shows the color titles draw in, auto or not.
    private func colorChoice(_ key: WritableKeyPath<TitleStyle, String?>, active: Bool, help: String) -> some View {
        let drawn = frame.with(titleStyle: style).title(active: active).attributes[.foregroundColor] as? NSColor ?? .black
        return HStack(spacing: 4) {
            Toggle("Auto", isOn: Binding(
                get: { style[keyPath: key] == nil },
                set: { style[keyPath: key] = $0 ? nil : TitleStyle.hex(drawn) }))
            ColorPicker("Color", selection: Binding(
                get: { Color(nsColor: drawn) },
                set: { style[keyPath: key] = TitleStyle.hex(NSColor($0)) }))
                .labelsHidden()
                .disabled(style[keyPath: key] == nil)
        }
        .help(help)
    }

    private var shadowMode: Binding<Int> {
        Binding(get: {
            switch style.shadow {
            case .auto: return 0
            case .none: return 1
            case .custom: return 2
            }
        }, set: { mode in
            switch mode {
            case 0: style.shadow = .auto
            case 1: style.shadow = .none
            default:
                // Start from the shadow the frame draws now, if any.
                let current = frame.with(titleStyle: style).title(active: true).shadow
                style.shadow = .custom(current.map {
                    TitleStyle.Shadow(color: TitleStyle.hex($0.color), x: $0.offset.width, y: $0.offset.height, blur: $0.blur)
                } ?? TitleStyle.Shadow(color: "#00000080", x: 0, y: 1, blur: 1))
            }
        })
    }

    private func setShadow(_ change: (inout TitleStyle.Shadow) -> Void) {
        guard case .custom(var shadow) = style.shadow else { return }
        change(&shadow)
        style.shadow = .custom(shadow)
    }

    private func number(_ label: String, _ value: CGFloat, _ range: ClosedRange<CGFloat>,
                        _ set: @escaping (CGFloat) -> Void) -> some View {
        Stepper(value: Binding(get: { value }, set: set), in: range) {
            Text("\(label) \(value.formatted())").monospacedDigit()
        }
    }
}

/// A segmented control that can disable single segments, which a segmented
/// Picker ignores on macOS.
private struct SegmentedControl<Value: Hashable>: NSViewRepresentable {
    let items: [(value: Value, title: String)]
    @Binding var selection: Value
    let enabled: Set<Value>

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: items.map(\.title), trackingMode: .selectOne,
                                         target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        control.setContentHuggingPriority(.required, for: .horizontal)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        for (i, item) in items.enumerated() {
            control.setLabel(item.title, forSegment: i)
            control.setEnabled(enabled.contains(item.value), forSegment: i)
        }
        control.selectedSegment = items.firstIndex { $0.value == selection } ?? -1
    }

    final class Coordinator: NSObject {
        var parent: SegmentedControl

        init(_ parent: SegmentedControl) { self.parent = parent }

        @objc func changed(_ sender: NSSegmentedControl) {
            let i = sender.selectedSegment
            guard parent.items.indices.contains(i), parent.enabled.contains(parent.items[i].value) else {
                sender.selectedSegment = parent.items.firstIndex { $0.value == parent.selection } ?? -1
                return
            }
            parent.selection = parent.items[i].value
        }
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
