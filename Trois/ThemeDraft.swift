// The Editor tab's draft theme: its files, frame sync, derived states and checks.
import Cocoa
import UniformTypeIdentifiers

/// How a missing state is made from the normal image.
enum Derivation {
    case hover, pressed, disabled
}

/// A problem with the draft and the fixes the editor offers for it.
struct DraftCheck: Identifiable {
    enum Fix {
        case generateFrameArt(ThemeManager.FrameArt)
        case takeButtonsFromFrame
        case putButtonsInFrame
        case addBox(WindowFrame.Box)
    }

    let id: String
    let message: String
    let fixes: [(title: String, fix: Fix)]
}

/// The theme.json fields the Editor tab edits.
struct DraftInfo: Equatable {
    var name = ""
    var author = ""
    var version = 1
    // Web page for the theme, saved as "source".
    var source = ""
    // Where the art came from. Shown, not edited.
    var engine: String?
}

extension ThemeManager {
    enum FrameArt: String, CaseIterable {
        case active, inactive, pressed
        var fileName: String { rawValue + ".png" }
        // Entry in theme.json's generated list.
        var generatedKey: String { "frame." + rawValue }
    }

    // Button images that also live in the frame art: normal in active.png,
    // disabled in inactive.png, pressed in the pressed strip.
    private static let frameMirrors: [(key: String, widget: WindowFrame.Widget, art: FrameArt)] = [
        ("close", .close, .active), ("closeDisabled", .close, .inactive), ("closeDown", .close, .pressed),
        ("minimize", .collapse, .active), ("minimizeDisabled", .collapse, .inactive), ("minimizeDown", .collapse, .pressed),
        ("zoom", .zoom, .active), ("zoomDisabled", .zoom, .inactive), ("zoomDown", .zoom, .pressed)
    ]

    // A derived key is its normal key plus one of these.
    private static let derivations: [(suffix: String, kind: Derivation)] = [
        ("Hover", .hover), ("Down", .pressed), ("Disabled", .disabled)
    ]

    /// The normal key a theme.json button key is made from, and how.
    static func derivation(of manifestKey: String) -> (base: String, kind: Derivation)? {
        for (suffix, kind) in derivations where manifestKey.hasSuffix(suffix) {
            let base = String(manifestKey.dropLast(suffix.count))
            if ButtonSlot.all.contains(where: { $0.manifestKey == base }) { return (base, kind) }
        }
        return nil
    }

    // MARK: - Draft

    /// The working copy the Editor tab edits. Hidden from the theme list and
    /// applied like any theme, so edits show on real windows right away.
    var draftDirectory: URL {
        themesDirectory.appendingPathComponent(".draft", isDirectory: true)
    }

    /// The draft's window frame folder, if it has one.
    var draftFrameDirectory: URL? { frameDirectory(in: draftDirectory) }

    private var isDraftApplied: Bool {
        UserDefaults.standard.string(forKey: "currentThemeId") == draftDirectory.path
    }

    // Set by any edit, cleared when the draft is saved as a theme or started over.
    private var draftHasUnsavedEdits: Bool {
        get { UserDefaults.standard.bool(forKey: "draftHasUnsavedEdits") }
        set { UserDefaults.standard.set(newValue, forKey: "draftHasUnsavedEdits") }
    }

    /// Makes the draft match what's live, unless the draft is what's live or
    /// holds unsaved edits. True when it kept edits another theme replaced;
    /// the editor then asks whether to resume or discard them.
    @discardableResult
    func prepareDraft() -> Bool {
        if fileManager.fileExists(atPath: draftDirectory.path) {
            if isDraftApplied { return false }
            if draftHasUnsavedEdits { return true }
        }
        snapshotLiveIntoDraft()
        clearDraftHistory()
        return false
    }

    /// Applies the draft again after another theme replaced it.
    func resumeDraft() {
        applyTheme(draftTheme())
    }

    /// Drops the draft's edits and starts again from what's live.
    func discardDraft() {
        snapshotLiveIntoDraft()
        clearDraftHistory()
    }

    // MARK: - Undo

    var draftHistoryDirectory: URL {
        themesDirectory.appendingPathComponent(".draft-history", isDirectory: true)
    }
    private static let maxDraftHistory = 50

    /// Copies the draft aside before an edit, so the edit can be undone.
    private func recordDraftEdit() {
        guard fileManager.fileExists(atPath: draftDirectory.path), let copy = copyDraft() else { return }
        draftUndo.append(copy)
        if draftUndo.count > Self.maxDraftHistory {
            try? fileManager.removeItem(at: draftUndo.removeFirst())
        }
        draftRedo.forEach { try? fileManager.removeItem(at: $0) }
        draftRedo.removeAll()
    }

    private func copyDraft() -> URL? {
        let copy = draftHistoryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try fileManager.createDirectory(at: draftHistoryDirectory, withIntermediateDirectories: true)
            try fileManager.copyItem(at: draftDirectory, to: copy)
            return copy
        } catch {
            return nil
        }
    }

    func undoDraftEdit() {
        guard !draftUndo.isEmpty, let current = copyDraft() else { return }
        draftRedo.append(current)
        restoreDraft(from: draftUndo.removeLast())
    }

    func redoDraftEdit() {
        guard !draftRedo.isEmpty, let current = copyDraft() else { return }
        draftUndo.append(current)
        restoreDraft(from: draftRedo.removeLast())
    }

    private func restoreDraft(from copy: URL) {
        try? fileManager.removeItem(at: draftDirectory)
        try? fileManager.moveItem(at: copy, to: draftDirectory)
        draftHasUnsavedEdits = true
        applyTheme(draftTheme())
    }

    private func clearDraftHistory() {
        try? fileManager.removeItem(at: draftHistoryDirectory)
        draftUndo.removeAll()
        draftRedo.removeAll()
    }

    /// Clears every image and frame, live and in the draft. The theme's
    /// name and other info stay.
    func resetDraft() {
        recordDraftEdit()
        let info = draftInfo()
        clearTheme()
        snapshotLiveIntoDraft()
        setDraftInfo(info)
    }

    func draftInfo() -> DraftInfo {
        let manifest = readManifest(in: draftDirectory)
        return DraftInfo(name: manifest?.name ?? "", author: manifest?.author ?? "", version: manifest?.version ?? 1,
                         source: manifest?.source ?? "", engine: manifest?.engine)
    }

    /// Writes the info to the draft's theme.json. Doesn't reapply the draft,
    /// so typing doesn't reload every overlay.
    func setDraftInfo(_ info: DraftInfo) {
        ensureDraft()
        var manifest = readManifest(in: draftDirectory) ?? ThemeManifest()
        func text(_ s: String) -> String? {
            let trimmed = s.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        }
        let name = text(info.name), author = text(info.author), source = text(info.source)
        guard manifest.name != name || manifest.author != author || manifest.version != info.version
            || manifest.source != source else { return }
        manifest.name = name
        manifest.author = author
        manifest.version = info.version
        manifest.source = source
        try? writeManifest(manifest, to: draftDirectory)
        draftHasUnsavedEdits = true
        if isDraftApplied { currentTheme = draftTheme() }
    }

    /// Puts an image in one draft slot, or clears the slot when `source` is
    /// nil, then applies the draft. Generated states of the same button are
    /// remade from it, and frame widgets are updated to match. Returns why
    /// the image wasn't used.
    @discardableResult
    func setDraftImage(_ source: URL?, forKey defaultsKey: String) -> String? {
        guard let slot = ButtonSlot.all.first(where: { $0.defaultsKey == defaultsKey }) else { return nil }
        ensureDraft()
        // Read first: the source may be the file this slot replaces.
        var data: Data?
        if let source {
            do { data = try Data(contentsOf: source) } catch { return "Couldn't read the image. \(error.localizedDescription)" }
        }

        recordDraftEdit()
        var manifest = readManifest(in: draftDirectory) ?? ThemeManifest()
        if let source, let data {
            // The new file is written before the old one goes, so a failed write loses nothing.
            let name = slot.fileName(extension: source.pathExtension)
            do {
                try data.write(to: draftDirectory.appendingPathComponent(name), options: .atomic)
            } catch {
                return "Couldn't write the image. \(error.localizedDescription)"
            }
            if let old = manifest.buttons?[slot.manifestKey], old != name {
                try? fileManager.removeItem(at: draftDirectory.appendingPathComponent(URL(fileURLWithPath: old).lastPathComponent))
            }
            unmarkGenerated(slot.manifestKey, in: &manifest)
            manifest.buttons = (manifest.buttons ?? [:]).merging([slot.manifestKey: name]) { $1 }
        } else {
            removeButton(slot.manifestKey, from: &manifest)
        }

        var changed = [slot.manifestKey]
        for key in manifest.generated ?? [] where Self.derivation(of: key)?.base == slot.manifestKey {
            if source == nil {
                removeButton(key, from: &manifest)
            } else if regenerate(key, in: &manifest) {
                changed.append(key)
            }
        }
        if source != nil {
            pushToFrame(changed, manifest: &manifest)
        }
        saveDraft(manifest)
        return nil
    }

    /// Makes the given slots from their button's normal image and marks them
    /// generated, so they follow later changes to it.
    func generateDraftImages(forKeys defaultsKeys: [String]) {
        ensureDraft()
        recordDraftEdit()
        var manifest = readManifest(in: draftDirectory) ?? ThemeManifest()
        let keys = defaultsKeys.compactMap { key in ButtonSlot.all.first { $0.defaultsKey == key }?.manifestKey }
        let made = keys.filter { regenerate($0, in: &manifest) }
        pushToFrame(made, manifest: &manifest)
        saveDraft(manifest)
    }

    func canGenerateDraftImage(forKey defaultsKey: String) -> Bool {
        ButtonSlot.all.first { $0.defaultsKey == defaultsKey }.flatMap { Self.derivation(of: $0.manifestKey) } != nil
    }

    func isDraftImageGenerated(forKey defaultsKey: String) -> Bool {
        guard let slot = ButtonSlot.all.first(where: { $0.defaultsKey == defaultsKey }) else { return false }
        return readManifest(in: draftDirectory)?.generated?.contains(slot.manifestKey) == true
    }

    /// Replaces one of the draft frame's images, or clears it when `source`
    /// is nil, then applies the draft. Returns why the image wasn't used.
    @discardableResult
    func setDraftFrameArt(_ source: URL?, for art: FrameArt) -> String? {
        guard let frame = draftFrameDirectory else { return "This theme has no window frame." }
        recordDraftEdit()
        let destination = frame.appendingPathComponent(art.fileName)
        var manifest = readManifest(in: draftDirectory) ?? ThemeManifest()
        unmarkGenerated(art.generatedKey, in: &manifest)

        if let source {
            guard let image = PixelOps.load(source) else { return "That file isn't an image." }
            // layout.json's rects are pixel positions in the active image, so
            // the window art has to keep its size. The pressed strip doesn't.
            if art != .pressed, let current = frameImage(.active),
               (current.width, current.height) != (image.width, image.height) {
                return "The frame layout needs a \(current.width) x \(current.height) image. This one is \(image.width) x \(image.height)."
            }
            guard PixelOps.writePNG(image, to: destination) else { return "Couldn't write the image." }
            // Generated art follows the active image.
            if art == .active {
                for other in [FrameArt.inactive, .pressed] where manifest.generated?.contains(other.generatedKey) == true {
                    makeFrameArt(other, manifest: &manifest)
                }
            }
        } else {
            guard art != .active else { return "A frame needs its active image." }
            try? fileManager.removeItem(at: destination)
        }
        saveDraft(manifest)
        return nil
    }

    /// Makes the inactive image or pressed strip from the active image and
    /// marks it generated.
    func generateDraftFrameArt(_ art: FrameArt) {
        guard art != .active, draftFrameDirectory != nil else { return }
        recordDraftEdit()
        var manifest = readManifest(in: draftDirectory) ?? ThemeManifest()
        makeFrameArt(art, manifest: &manifest)
        saveDraft(manifest)
    }

    func isFrameArtGenerated(_ art: FrameArt) -> Bool {
        readManifest(in: draftDirectory)?.generated?.contains(art.generatedKey) == true
    }

    /// Puts another theme's frame in the draft, or removes the draft's frame
    /// when `directory` is nil, then applies the draft. Returns why the frame
    /// wasn't used.
    @discardableResult
    func useDraftFrame(from directory: URL?) -> String? {
        ensureDraft()
        recordDraftEdit()
        let frame = draftDirectory.appendingPathComponent("frame", isDirectory: true)
        // Copied beside the old frame first, so a failed copy keeps it.
        let incoming = draftDirectory.appendingPathComponent(".frame-new", isDirectory: true)
        if let directory {
            try? fileManager.removeItem(at: incoming)
            do {
                try fileManager.copyItem(at: directory, to: incoming)
            } catch {
                try? fileManager.removeItem(at: incoming)
                return "Couldn't copy the frame. \(error.localizedDescription)"
            }
        }
        try? fileManager.removeItem(at: frame)
        try? fileManager.removeItem(at: layoutBaseline)
        if directory != nil {
            do {
                try fileManager.moveItem(at: incoming, to: frame)
            } catch {
                try? fileManager.removeItem(at: incoming)
                return "Couldn't copy the frame. \(error.localizedDescription)"
            }
        }
        var manifest = readManifest(in: draftDirectory) ?? ThemeManifest()
        for art in FrameArt.allCases { unmarkGenerated(art.generatedKey, in: &manifest) }
        saveDraft(manifest)
        return nil
    }

    /// Cuts the close, minimize and zoom images out of the frame art.
    func takeButtonsFromFrame() {
        guard let directory = draftFrameDirectory, let frame = WindowFrame(directory: directory) else { return }
        recordDraftEdit()
        var manifest = readManifest(in: draftDirectory) ?? ThemeManifest()
        for mirror in Self.frameMirrors {
            guard let art = frameImage(mirror.art), let rect = sourceRect(mirror, in: frame),
                  CGRect(x: 0, y: 0, width: art.width, height: art.height).contains(rect),
                  let image = art.cropping(to: rect) else { continue }
            writeButton(image, key: mirror.key, manifest: &manifest)
            unmarkGenerated(mirror.key, in: &manifest)
        }
        saveDraft(manifest)
    }

    /// Paints the close, minimize and zoom images into the frame art.
    func putButtonsInFrame() {
        recordDraftEdit()
        var manifest = readManifest(in: draftDirectory) ?? ThemeManifest()
        pushToFrame(Self.frameMirrors.map(\.key), manifest: &manifest)
        saveDraft(manifest)
    }

    // The draft frame's layout as it came in, so edge edits can be reverted.
    // Kept beside the frame folder, not in it, and left out of saved themes.
    private var layoutBaseline: URL { draftDirectory.appendingPathComponent(".layout-original.json") }

    /// Replaces one side's runs in the draft frame's layout, then applies the
    /// draft. Returns why the runs weren't used.
    @discardableResult
    func setDraftEdgeRuns(_ runs: [(Int, Int)], for side: WindowFrame.Side) -> String? {
        guard let directory = draftFrameDirectory, let frame = WindowFrame(directory: directory) else {
            return "This theme has no window frame."
        }
        guard frame.k1 == nil else { return "1.x frames have a fixed layout." }
        if let error = WindowFrame.runError(runs, extent: frame.extent(side)) { return error }
        recordDraftEdit()
        saveLayoutBaseline()
        guard WindowFrame.writeRuns(runs, for: side, in: directory) else { return "Couldn't write the layout." }
        saveDraft(readManifest(in: draftDirectory) ?? ThemeManifest())
        return nil
    }

    /// Changes some of the draft frame's boxes, nil removing one, then applies
    /// the draft. The pressed strip follows widget boxes that come, go or
    /// change size. Returns why the boxes weren't used.
    @discardableResult
    func setDraftBoxes(_ changes: [WindowFrame.Box: CGRect?]) -> String? {
        guard let directory = draftFrameDirectory, let old = WindowFrame(directory: directory) else {
            return "This theme has no window frame."
        }
        guard old.k1 == nil else { return "1.x frames have a fixed layout." }
        if changes[.content] == .some(nil) { return "A frame needs a content box." }
        var boxes: [WindowFrame.Box: CGRect] = [:]
        for box in WindowFrame.Box.allCases {
            if let change = changes[box] {
                if let rect = change { boxes[box] = rect.integral }
            } else if let rect = old.rect(box) {
                boxes[box] = rect
            }
        }
        if let error = old.boxError(boxes) { return error }
        recordDraftEdit()
        saveLayoutBaseline()
        guard WindowFrame.writeBoxes(changes.mapValues { $0?.integral }, in: directory) else { return "Couldn't write the layout." }
        var manifest = readManifest(in: draftDirectory) ?? ThemeManifest()
        repackPressed(from: old, manifest: &manifest)
        saveDraft(manifest)
        return nil
    }

    /// The draft frame's boxes as they were when the frame came in, if they've
    /// changed since.
    func baselineBoxes() -> [WindowFrame.Box: CGRect?]? {
        guard let data = try? Data(contentsOf: layoutBaseline),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let layout = json["layout"] as? [String: Any],
              let frame = draftFrameDirectory.flatMap(WindowFrame.init(directory:)) else { return nil }
        var original: [Int: CGRect] = [:]
        for entry in layout["rects"] as? [[Any]] ?? [] {
            guard entry.count == 2, let part = entry[0] as? Int, let r = entry[1] as? [Int], r.count == 4 else { continue }
            original[part] = CGRect(x: r[1], y: r[0], width: r[3] - r[1], height: r[2] - r[0])
        }
        var out: [WindowFrame.Box: CGRect?] = [:]
        for box in WindowFrame.Box.allCases where original[box.rawValue] != frame.rects[box.rawValue] {
            out[box] = original[box.rawValue]
        }
        return out.isEmpty ? nil : out
    }

    /// Rebuilds the pressed strip for the current widget boxes. Slices of
    /// widgets whose size didn't change carry over; the rest are made from the
    /// active art like Generate does, then the draft's pressed buttons are
    /// painted in. A generated strip is simply made again.
    private func repackPressed(from old: WindowFrame, manifest: inout ThemeManifest) {
        guard let directory = draftFrameDirectory, let new = WindowFrame(directory: directory) else { return }
        let changed = WindowFrame.Widget.allCases.filter {
            old.rects[$0.rawValue].map { $0.isEmpty ? .zero : $0.size } != new.rects[$0.rawValue].map { $0.isEmpty ? .zero : $0.size }
        }
        guard !changed.isEmpty, let strip = frameImage(.pressed) else { return }
        if manifest.generated?.contains(FrameArt.pressed.generatedKey) == true {
            makeFrameArt(.pressed, manifest: &manifest)
            return
        }
        let size = new.pressedStripSize
        guard size.width > 0, let context = PixelOps.context(Int(size.width), Int(size.height)) else {
            try? fileManager.removeItem(at: directory.appendingPathComponent(FrameArt.pressed.fileName))
            return
        }
        for widget in WindowFrame.Widget.allCases {
            guard let rect = new.rects[widget.rawValue], !rect.isEmpty, let slice = new.pressedSource(widget) else { continue }
            var piece: CGImage?
            if !changed.contains(widget), let oldSlice = old.pressedSource(widget) {
                piece = strip.cropping(to: oldSlice)
            } else {
                piece = new.active.cropping(to: rect).flatMap { PixelOps.derive($0, .pressed) }
            }
            if let piece { context.draw(piece, in: PixelOps.flip(slice, height: Int(size.height))) }
        }
        guard let image = context.makeImage(),
              PixelOps.writePNG(image, to: directory.appendingPathComponent(FrameArt.pressed.fileName)) else { return }
        let keys = Self.frameMirrors.filter { $0.art == .pressed && changed.contains($0.widget) }.map(\.key)
        pushToFrame(keys, manifest: &manifest)
    }

    /// Puts one side's runs back as they were when the frame came in.
    func revertDraftEdgeRuns(_ side: WindowFrame.Side) {
        guard let original = baselineRuns(side) else { return }
        setDraftEdgeRuns(original, for: side)
    }

    /// Whether a side's runs differ from when the frame came in.
    func draftEdgeRunsChanged(_ side: WindowFrame.Side) -> Bool {
        guard let original = baselineRuns(side), let directory = draftFrameDirectory,
              let frame = WindowFrame(directory: directory) else { return false }
        return !original.elementsEqual(frame.runs(side), by: ==)
    }

    private func baselineRuns(_ side: WindowFrame.Side) -> [(Int, Int)]? {
        guard let data = try? Data(contentsOf: layoutBaseline),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let layout = json["layout"] as? [String: Any] else { return nil }
        return (layout[side.rawValue] as? [[Int]] ?? []).compactMap { $0.count == 2 ? ($0[0], $0[1]) : nil }
    }

    /// Sets the draft frame's title style, then applies the draft. Returns
    /// why the style wasn't saved.
    @discardableResult
    func setDraftTitleStyle(_ style: TitleStyle) -> String? {
        guard let directory = draftFrameDirectory else { return "This theme has no window frame." }
        recordDraftEdit()
        saveLayoutBaseline()
        guard WindowFrame.writeTitleStyle(style, in: directory) else { return "Couldn't write the layout." }
        saveDraft(readManifest(in: draftDirectory) ?? ThemeManifest())
        return nil
    }

    /// The title style as it was when the frame came in.
    func baselineTitleStyle() -> TitleStyle? {
        guard let data = try? Data(contentsOf: layoutBaseline),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return TitleStyle(json: json["title"] as? [String: Any] ?? [:])
    }

    // Copies the frame's layout.json aside, once per frame.
    private func saveLayoutBaseline() {
        guard !fileManager.fileExists(atPath: layoutBaseline.path), let directory = draftFrameDirectory else { return }
        try? fileManager.copyItem(at: directory.appendingPathComponent("layout.json"), to: layoutBaseline)
    }

    /// What's wrong with the draft's frame, if anything.
    func draftChecks() -> [DraftCheck] {
        guard let directory = draftFrameDirectory else { return [] }
        guard let frame = WindowFrame(directory: directory) else {
            return [DraftCheck(id: "layout", message: "The frame's layout doesn't fit its active image, so the frame won't draw.", fixes: [])]
        }
        var checks: [DraftCheck] = []
        if frameImage(.inactive) == nil {
            checks.append(DraftCheck(id: "inactive", message: "No inactive frame image. Inactive windows use the active one.",
                                     fixes: [("Generate", .generateFrameArt(.inactive))]))
        }
        let need = frame.pressedStripSize
        if need.width > 0 {
            if let pressed = frameImage(.pressed) {
                if CGFloat(pressed.width) < need.width || CGFloat(pressed.height) < need.height {
                    checks.append(DraftCheck(
                        id: "pressed-size",
                        message: "The pressed strip is \(pressed.width) x \(pressed.height). The frame's buttons need \(Int(need.width)) x \(Int(need.height)).",
                        fixes: [("Generate", .generateFrameArt(.pressed))]))
                }
            } else {
                checks.append(DraftCheck(id: "pressed", message: "No pressed strip. Buttons in the frame won't look pressed.",
                                         fixes: [("Generate", .generateFrameArt(.pressed))]))
            }
        }

        if frame.k1 == nil {
            for side in WindowFrame.Side.allCases {
                for (n, issue) in frame.runIssues(side).enumerated() {
                    // Only offered when there's room for the box to start in.
                    let fixes: [(title: String, fix: DraftCheck.Fix)] = issue.missing
                        .flatMap { frame.startingRect(for: $0) != nil ? [("Add Box", .addBox($0))] : nil } ?? []
                    checks.append(DraftCheck(id: "runs-\(side.rawValue)-\(n)",
                                             message: "\(side.rawValue.capitalized) edge: \(issue.message)", fixes: fixes))
                }
            }
        }

        if let family = frame.titleStyle.font {
            if !TitleStyle.isInstalled(family) {
                checks.append(DraftCheck(id: "title-font", message: "The title font \(family) isn't installed. Titles use the system font.", fixes: []))
            } else if !TitleStyle.isBuiltIn(family) {
                checks.append(DraftCheck(id: "title-font", message: "The title font \(family) doesn't come with macOS. Macs without it use the system font.", fixes: []))
            }
        }

        let manifest = readManifest(in: draftDirectory) ?? ThemeManifest()
        var names: [String] = []
        for mirror in Self.frameMirrors where !inSync(mirror, frame: frame, manifest: manifest) {
            let name = mirror.widget == .collapse ? "minimize" : mirror.key.hasPrefix("close") ? "close" : "zoom"
            if !names.contains(name) { names.append(name) }
        }
        if !names.isEmpty {
            checks.append(DraftCheck(
                id: "sync",
                message: "Some buttons don't match the frame's art: \(names.joined(separator: ", ")).",
                fixes: [("Use Frame's", .takeButtonsFromFrame), ("Update Frame", .putButtonsInFrame)]))
        }
        return checks
    }

    func apply(_ fix: DraftCheck.Fix) {
        switch fix {
        case .generateFrameArt(let art): generateDraftFrameArt(art)
        case .takeButtonsFromFrame: takeButtonsFromFrame()
        case .putButtonsInFrame: putButtonsInFrame()
        case .addBox(let box):
            guard let frame = draftFrameDirectory.flatMap(WindowFrame.init(directory:)),
                  let rect = frame.startingRect(for: box) else { return }
            setDraftBoxes([box: rect])
        }
    }

    func draftTheme() -> Theme {
        let manifest = readManifest(in: draftDirectory)
        var theme = Theme(id: draftDirectory.path, name: manifest?.name ?? "Custom Theme", path: draftDirectory)
        theme.author = manifest?.author
        theme.version = manifest?.version
        theme.engine = manifest?.engine
        theme.source = manifest?.source.flatMap { URL(string: $0) }
        applyManifestButtons(manifest?.buttons ?? [:], in: draftDirectory, to: &theme)
        theme.frameDirectory = frameDirectory(in: draftDirectory)
        return theme
    }

    /// Copies the draft, frame included, into a new theme folder named after
    /// the draft's name. Returns the folder.
    func saveCustomTheme() throws -> URL {
        ensureDraft()
        guard let manifest = readManifest(in: draftDirectory),
              manifest.buttons?.isEmpty == false || draftFrameDirectory != nil else {
            throw ThemeInstallError.noButtons
        }
        let safeName = (manifest.name ?? "").replacingOccurrences(of: "[^a-zA-Z0-9_\\- ]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let destination = ThemeInstaller.unusedFolder(named: safeName.isEmpty ? "Custom Theme" : safeName, in: themesDirectory)

        do {
            try fileManager.copyItem(at: draftDirectory, to: destination)
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
        try? fileManager.removeItem(at: destination.appendingPathComponent(layoutBaseline.lastPathComponent))
        draftHasUnsavedEdits = false
        return destination
    }

    // MARK: - Files

    private func ensureDraft() {
        if !fileManager.fileExists(atPath: draftDirectory.path) { snapshotLiveIntoDraft() }
    }

    private func saveDraft(_ manifest: ThemeManifest) {
        try? writeManifest(manifest, to: draftDirectory)
        draftHasUnsavedEdits = true
        applyTheme(draftTheme())
    }

    /// Copies the live button images and frame into a fresh draft. Built in a
    /// staging folder first, since the live paths may point into the draft.
    private func snapshotLiveIntoDraft() {
        let defaults = UserDefaults.standard
        let staging = themesDirectory.appendingPathComponent(".draft-new", isDirectory: true)
        try? fileManager.removeItem(at: staging)
        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
            var buttons: [String: String] = [:]
            for slot in ButtonSlot.all {
                guard let path = defaults.string(forKey: slot.defaultsKey), fileManager.fileExists(atPath: path) else { continue }
                let name = slot.fileName(extension: URL(fileURLWithPath: path).pathExtension)
                try fileManager.copyItem(atPath: path, toPath: staging.appendingPathComponent(name).path)
                buttons[slot.manifestKey] = name
            }
            if let frame = defaults.string(forKey: "windowFrameDirectory"), fileManager.fileExists(atPath: frame) {
                try fileManager.copyItem(atPath: frame, toPath: staging.appendingPathComponent("frame").path)
            }
            let manifest = ThemeManifest(name: currentTheme?.name, author: currentTheme?.author, version: currentTheme?.version,
                                         engine: currentTheme?.engine, source: currentTheme?.source?.absoluteString,
                                         buttons: buttons)
            try writeManifest(manifest, to: staging)
            try? fileManager.removeItem(at: draftDirectory)
            try fileManager.moveItem(at: staging, to: draftDirectory)
            draftHasUnsavedEdits = false
        } catch {
            print("Failed to snapshot draft: \(error)")
            try? fileManager.removeItem(at: staging)
        }
        // The draft's files replaced the ones the live paths pointed at.
        if isDraftApplied {
            applyTheme(draftTheme())
        }
    }

    private func buttonImage(_ key: String, in manifest: ThemeManifest) -> CGImage? {
        guard let name = manifest.buttons?[key] else { return nil }
        return PixelOps.load(draftDirectory.appendingPathComponent(URL(fileURLWithPath: name).lastPathComponent))
    }

    private func removeButton(_ key: String, from manifest: inout ThemeManifest) {
        if let old = manifest.buttons?.removeValue(forKey: key) {
            try? fileManager.removeItem(at: draftDirectory.appendingPathComponent(URL(fileURLWithPath: old).lastPathComponent))
        }
        unmarkGenerated(key, in: &manifest)
    }

    private func writeButton(_ image: CGImage, key: String, manifest: inout ThemeManifest) {
        guard let slot = ButtonSlot.all.first(where: { $0.manifestKey == key }) else { return }
        let name = slot.fileName(extension: "png")
        if let old = manifest.buttons?[key], old != name {
            try? fileManager.removeItem(at: draftDirectory.appendingPathComponent(URL(fileURLWithPath: old).lastPathComponent))
        }
        if PixelOps.writePNG(image, to: draftDirectory.appendingPathComponent(name)) {
            manifest.buttons = (manifest.buttons ?? [:]).merging([key: name]) { $1 }
        }
    }

    private func unmarkGenerated(_ key: String, in manifest: inout ThemeManifest) {
        manifest.generated?.removeAll { $0 == key }
        if manifest.generated?.isEmpty == true { manifest.generated = nil }
    }

    private func markGenerated(_ key: String, in manifest: inout ThemeManifest) {
        var generated = manifest.generated ?? []
        if !generated.contains(key) { generated.append(key) }
        manifest.generated = generated
    }

    /// Remakes a derived button image from its normal image. False when
    /// there's nothing to make it from.
    private func regenerate(_ key: String, in manifest: inout ThemeManifest) -> Bool {
        guard let derivation = Self.derivation(of: key),
              let source = buttonImage(derivation.base, in: manifest),
              let image = PixelOps.derive(source, derivation.kind) else { return false }
        writeButton(image, key: key, manifest: &manifest)
        markGenerated(key, in: &manifest)
        return true
    }

    private func frameImage(_ art: FrameArt) -> CGImage? {
        draftFrameDirectory.flatMap { PixelOps.load($0.appendingPathComponent(art.fileName)) }
    }

    // MARK: - Frame art

    /// Makes the inactive image or pressed strip from the active image, then
    /// paints the draft's own disabled or pressed buttons over it.
    private func makeFrameArt(_ art: FrameArt, manifest: inout ThemeManifest) {
        guard let directory = draftFrameDirectory, let frame = WindowFrame(directory: directory),
              let image = derivedFrameArt(art, frame: frame, active: frame.active) else { return }
        guard PixelOps.writePNG(image, to: directory.appendingPathComponent(art.fileName)) else { return }
        markGenerated(art.generatedKey, in: &manifest)
        let keys = Self.frameMirrors.filter { $0.art == art && manifest.buttons?[$0.key] != nil }.map(\.key)
        pushToFrame(keys, manifest: &manifest)
    }

    private func derivedFrameArt(_ art: FrameArt, frame: WindowFrame, active: CGImage) -> CGImage? {
        switch art {
        case .active:
            return nil
        case .inactive:
            return PixelOps.derive(active, .disabled)
        case .pressed:
            let size = frame.pressedStripSize
            guard size.width > 0, let context = PixelOps.context(Int(size.width), Int(size.height)) else { return nil }
            for widget in WindowFrame.Widget.allCases {
                guard let rect = frame.rects[widget.rawValue], !rect.isEmpty, let slice = frame.pressedSource(widget),
                      let piece = active.cropping(to: rect), let pressed = PixelOps.derive(piece, .pressed) else { continue }
                context.draw(pressed, in: PixelOps.flip(slice, height: Int(size.height)))
            }
            return context.makeImage()
        }
    }

    // Where a mirrored button sits in its frame image.
    private func sourceRect(_ mirror: (key: String, widget: WindowFrame.Widget, art: FrameArt), in frame: WindowFrame) -> CGRect? {
        // Some schemes list a widget with an empty rect when they don't have it.
        guard let rect = frame.rects[mirror.widget.rawValue], !rect.isEmpty else { return nil }
        return mirror.art == .pressed ? frame.pressedSource(mirror.widget) : rect
    }

    /// Paints the listed button images into the frame art. Inactive and
    /// pressed art that's missing is generated first.
    private func pushToFrame(_ keys: [String], manifest: inout ThemeManifest) {
        guard let directory = draftFrameDirectory else { return }
        let mirrors = Self.frameMirrors.filter { keys.contains($0.key) && manifest.buttons?[$0.key] != nil }
        guard !mirrors.isEmpty else { return }
        for art in [FrameArt.inactive, .pressed] where frameImage(art) == nil && mirrors.contains(where: { $0.art == art }) {
            makeFrameArt(art, manifest: &manifest)
        }
        guard let frame = WindowFrame(directory: directory) else { return }

        var images: [FrameArt: CGImage] = [:]
        for mirror in mirrors {
            guard let button = buttonImage(mirror.key, in: manifest),
                  let base = images[mirror.art] ?? frameImage(mirror.art),
                  let patched = patch(mirror, button: button, into: base, frame: frame) else { continue }
            images[mirror.art] = patched
        }
        for (art, image) in images {
            _ = PixelOps.writePNG(image, to: directory.appendingPathComponent(art.fileName))
        }
    }

    /// `base` with one button painted in. The frame's own art fills behind
    /// it, so transparent buttons don't leave holes or show the old widget.
    private func patch(_ mirror: (key: String, widget: WindowFrame.Widget, art: FrameArt), button: CGImage,
                       into base: CGImage, frame: WindowFrame) -> CGImage? {
        guard let rect = sourceRect(mirror, in: frame) else { return nil }
        var strip = base
        if mirror.art == .pressed {
            // An old strip may be too small for this frame's widgets.
            guard let grown = PixelOps.grown(base, toAtLeast: frame.pressedStripSize) else { return nil }
            strip = grown
        }
        // The pressed strip has no backdrop of its own; it draws over active art.
        let backdropImage = mirror.art == .pressed ? frame.active : base
        let backdrop = frame.backdrop(for: mirror.widget).map { (image: backdropImage, source: $0.source, horizontal: $0.horizontal) }
        return PixelOps.patch(strip, rect: rect, backdrop: backdrop, button: button)
    }

    private func inSync(_ mirror: (key: String, widget: WindowFrame.Widget, art: FrameArt),
                        frame: WindowFrame, manifest: ThemeManifest) -> Bool {
        guard let button = buttonImage(mirror.key, in: manifest),
              let base = frameImage(mirror.art),
              let rect = sourceRect(mirror, in: frame) else { return true }
        // Missing or short art is its own check.
        guard CGRect(x: 0, y: 0, width: base.width, height: base.height).contains(rect),
              let patched = patch(mirror, button: button, into: base, frame: frame) else { return true }
        return PixelOps.sameRegion(patched, base, rect)
    }
}

/// Pixel work for the draft. Rects are image pixels with a top-left origin.
enum PixelOps {
    static func load(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func writePNG(_ image: CGImage, to url: URL) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }

    static func context(_ width: Int, _ height: Int) -> CGContext? {
        guard width > 0, height > 0 else { return nil }
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.interpolationQuality = .none
        return context
    }

    /// A top-left rect in CoreGraphics' bottom-left space, for a context `height` tall.
    static func flip(_ rect: CGRect, height: Int) -> CGRect {
        CGRect(x: rect.minX, y: CGFloat(height) - rect.maxY, width: rect.width, height: rect.height)
    }

    /// `size` centered in `rect`, scaled down to fit if it's too big.
    static func fit(_ size: CGSize, in rect: CGRect) -> CGRect {
        var fitted = size
        if size.width > rect.width || size.height > rect.height {
            let scale = min(rect.width / size.width, rect.height / size.height)
            fitted = CGSize(width: max(1, floor(size.width * scale)), height: max(1, floor(size.height * scale)))
        }
        return CGRect(x: rect.minX + ((rect.width - fitted.width) / 2).rounded(.down),
                      y: rect.minY + ((rect.height - fitted.height) / 2).rounded(.down),
                      width: fitted.width, height: fitted.height)
    }

    /// `base` with `rect` cleared, filled with tiles of `backdrop`, and
    /// `button` drawn over it.
    static func patch(_ base: CGImage, rect: CGRect,
                      backdrop: (image: CGImage, source: CGRect, horizontal: Bool)?, button: CGImage) -> CGImage? {
        let height = base.height
        guard let context = context(base.width, height) else { return nil }
        context.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: height))
        context.clear(flip(rect, height: height))
        context.saveGState()
        context.clip(to: flip(rect, height: height))
        if let backdrop, let tile = backdrop.image.cropping(to: backdrop.source), tile.width > 0, tile.height > 0 {
            if backdrop.horizontal {
                var x = rect.minX
                while x < rect.maxX {
                    context.draw(tile, in: flip(CGRect(x: x, y: rect.minY, width: CGFloat(tile.width), height: rect.height), height: height))
                    x += CGFloat(tile.width)
                }
            } else {
                var y = rect.minY
                while y < rect.maxY {
                    context.draw(tile, in: flip(CGRect(x: rect.minX, y: y, width: rect.width, height: CGFloat(tile.height)), height: height))
                    y += CGFloat(tile.height)
                }
            }
        }
        let placed = fit(CGSize(width: button.width, height: button.height), in: rect)
        context.draw(button, in: flip(placed, height: height))
        context.restoreGState()
        return context.makeImage()
    }

    /// `image` flipped across its top-left to bottom-right diagonal, so a
    /// side band reads left to right like the top one.
    static func transposed(_ image: CGImage) -> CGImage? {
        let width = image.height, height = image.width
        guard let context = context(width, height) else { return nil }
        // Maps source (x, y) to (y, x), both top-left.
        context.concatenate(CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: CGFloat(width), ty: CGFloat(height)))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    /// `image` on a canvas at least `size`, anchored top-left.
    static func grown(_ image: CGImage, toAtLeast size: CGSize) -> CGImage? {
        let width = max(image.width, Int(size.width)), height = max(image.height, Int(size.height))
        if width == image.width && height == image.height { return image }
        guard let context = context(width, height) else { return nil }
        context.draw(image, in: flip(CGRect(x: 0, y: 0, width: image.width, height: image.height), height: height))
        return context.makeImage()
    }

    /// A hover, pressed or disabled version of `image`. Works on premultiplied
    /// pixels, where blending toward a color means blending toward color * alpha.
    static func derive(_ image: CGImage, _ kind: Derivation) -> CGImage? {
        let width = image.width, height = image.height
        guard let context = context(width, height), let data = context.data else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        for i in stride(from: 0, to: width * height * 4, by: 4) {
            let r = Double(pixels[i]), g = Double(pixels[i + 1]), b = Double(pixels[i + 2]), a = Double(pixels[i + 3])
            var out: (Double, Double, Double)
            switch kind {
            case .hover:
                // 15% toward white.
                out = (r + (a - r) * 0.15, g + (a - g) * 0.15, b + (a - b) * 0.15)
            case .pressed:
                out = (r * 0.72, g * 0.72, b * 0.72)
            case .disabled:
                // Grayscale, then 40% toward light gray.
                let luma = 0.3 * r + 0.59 * g + 0.11 * b
                let gray = luma * 0.6 + 0.8 * a * 0.4
                out = (gray, gray, gray)
            }
            pixels[i] = UInt8(min(a, max(0, out.0.rounded())))
            pixels[i + 1] = UInt8(min(a, max(0, out.1.rounded())))
            pixels[i + 2] = UInt8(min(a, max(0, out.2.rounded())))
        }
        return context.makeImage()
    }

    /// Whether `rect` looks the same in both images. Allows a step or two per
    /// channel, which a PNG round trip of translucent pixels can introduce.
    static func sameRegion(_ a: CGImage, _ b: CGImage, _ rect: CGRect) -> Bool {
        let width = Int(rect.width), height = Int(rect.height)
        guard let first = a.cropping(to: rect), let second = b.cropping(to: rect),
              let one = context(width, height), let two = context(width, height),
              let p = one.data?.bindMemory(to: UInt8.self, capacity: width * height * 4),
              let q = two.data?.bindMemory(to: UInt8.self, capacity: width * height * 4) else { return false }
        one.draw(first, in: CGRect(x: 0, y: 0, width: width, height: height))
        two.draw(second, in: CGRect(x: 0, y: 0, width: width, height: height))
        for i in 0..<(width * height * 4) where abs(Int(p[i]) - Int(q[i])) > 2 {
            return false
        }
        return true
    }
}
