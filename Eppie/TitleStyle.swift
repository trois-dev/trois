// Title text style a window frame's layout.json can set.
import Cocoa

/// How a frame draws the window title, stored as layout.json's "title"
/// object. Fields left out keep the look the frame picks from its own art.
struct TitleStyle: Equatable {
    enum Weight: String, CaseIterable {
        case regular, medium, semibold, bold, heavy

        var system: NSFont.Weight {
            switch self {
            case .regular: return .regular
            case .medium: return .medium
            case .semibold: return .semibold
            case .bold: return .bold
            case .heavy: return .heavy
            }
        }

        // NSFontManager's 0-15 scale, where 5 is regular and 9 bold.
        var manager: Int {
            switch self {
            case .regular: return 5
            case .medium: return 6
            case .semibold: return 8
            case .bold: return 9
            case .heavy: return 11
            }
        }
    }

    enum Alignment: String, CaseIterable {
        case left, center, right

        var text: NSTextAlignment {
            switch self {
            case .left: return .left
            case .center: return .center
            case .right: return .right
            }
        }
    }

    // Offsets are points, y down.
    struct Shadow: Equatable {
        var color = "#000000"
        var x: CGFloat = 1
        var y: CGFloat = 1
        var blur: CGFloat = 0
    }

    enum ShadowSetting: Equatable {
        // Whatever the frame's art implies: the 1.x emboss, or nothing.
        case auto
        case none
        case custom(Shadow)
    }

    static let defaultSize: CGFloat = 12
    static let defaultWeight = Weight.semibold
    static let sizes: ClosedRange<CGFloat> = 8...24

    // Font family name. Nil is the system font.
    var font: String?
    var size: CGFloat?
    var weight: Weight?
    var alignment: Alignment?
    // "#rrggbb" or "#rrggbbaa". Nil picks one from the art.
    var color: String?
    // Nil takes the one the inactive art holds, or dims a set active color.
    var inactiveColor: String?
    var shadow = ShadowSetting.auto

    init() {}

    init(json: [String: Any]) {
        font = (json["font"] as? String).flatMap { $0.isEmpty || $0 == "system" ? nil : $0 }
        size = (json["size"] as? NSNumber).map { CGFloat(truncating: $0) }
        weight = (json["weight"] as? String).flatMap(Weight.init)
        alignment = (json["align"] as? String).flatMap(Alignment.init)
        color = (json["color"] as? String).flatMap { Self.color($0) != nil ? $0 : nil }
        inactiveColor = (json["inactiveColor"] as? String).flatMap { Self.color($0) != nil ? $0 : nil }
        if json["shadow"] as? Bool == false {
            shadow = .none
        } else if let s = json["shadow"] as? [String: Any], let color = s["color"] as? String, Self.color(color) != nil {
            func number(_ key: String, _ fallback: CGFloat) -> CGFloat {
                (s[key] as? NSNumber).map { CGFloat(truncating: $0) } ?? fallback
            }
            shadow = .custom(Shadow(color: color, x: number("x", 1), y: number("y", 1), blur: max(0, number("blur", 0))))
        }
    }

    var json: [String: Any] {
        var out: [String: Any] = [:]
        out["font"] = font
        out["size"] = size.map { Double($0) }
        out["weight"] = weight?.rawValue
        out["align"] = alignment?.rawValue
        out["color"] = color
        out["inactiveColor"] = inactiveColor
        switch shadow {
        case .auto: break
        case .none: out["shadow"] = false
        case .custom(let s): out["shadow"] = ["color": s.color, "x": Double(s.x), "y": Double(s.y), "blur": Double(s.blur)]
        }
        return out
    }

    var isEmpty: Bool { self == TitleStyle() }

    /// The font titles draw in. A family that isn't installed falls back to
    /// the system font.
    var resolvedFont: NSFont {
        let size = min(max(self.size ?? Self.defaultSize, Self.sizes.lowerBound), Self.sizes.upperBound)
        let weight = self.weight ?? Self.defaultWeight
        if let font, let family = NSFontManager.shared.font(withFamily: font, traits: [], weight: weight.manager, size: size) {
            return family
        }
        return NSFont.systemFont(ofSize: size, weight: weight.system)
    }

    static func isInstalled(_ family: String) -> Bool {
        NSFontManager.shared.availableFontFamilies.contains(family)
    }

    /// Whether a family ships with macOS, so other Macs have it too.
    static func isBuiltIn(_ family: String) -> Bool {
        guard let member = NSFontManager.shared.availableMembers(ofFontFamily: family)?.first,
              let name = member.first as? String, let font = NSFont(name: name, size: 12),
              let url = CTFontCopyAttribute(font, kCTFontURLAttribute) as? URL else { return false }
        return url.path.hasPrefix("/System/Library/Fonts")
    }

    static func color(_ hex: String) -> NSColor? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        guard s.hasPrefix("#") else { return nil }
        s.removeFirst()
        guard s.count == 6 || s.count == 8, let v = UInt32(s, radix: 16) else { return nil }
        let rgba = s.count == 6 ? v << 8 | 0xff : v
        func channel(_ shift: UInt32) -> CGFloat { CGFloat((rgba >> shift) & 0xff) / 255 }
        return NSColor(srgbRed: channel(24), green: channel(16), blue: channel(8), alpha: channel(0))
    }

    static func hex(_ color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? color
        func byte(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        let rgb = String(format: "#%02x%02x%02x", byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent))
        return c.alphaComponent < 1 ? rgb + String(format: "%02x", byte(c.alphaComponent)) : rgb
    }

    /// Settles the style against what the frame picks from its art.
    /// `autoInactive` is nil when inactive titles just dim the active color.
    /// `autoShadow` is the emboss the art holds for this state.
    func resolved(active: Bool, autoColor: NSColor, autoInactive: NSColor?, autoShadow: NSColor?) -> ResolvedTitle {
        let dim = { (c: NSColor) in c.withAlphaComponent(c.alphaComponent * 0.55) }
        let activeColor = color.flatMap(Self.color) ?? autoColor
        let inactive = inactiveColor.flatMap(Self.color)
            ?? (color == nil ? autoInactive : nil)
            ?? dim(activeColor)
        let shadow: ResolvedTitle.Shadow?
        // Room for a custom shadow. The 1.x emboss was never given any.
        var spill: CGFloat = 0
        switch self.shadow {
        case .auto: shadow = autoShadow.map { ResolvedTitle.Shadow(color: $0, offset: CGSize(width: 1, height: 1), blur: 0) }
        case .none: shadow = nil
        case .custom(let s):
            shadow = Self.color(s.color).map { ResolvedTitle.Shadow(color: $0, offset: CGSize(width: s.x, height: s.y), blur: s.blur) }
            spill = abs(s.x) + s.blur
        }
        return ResolvedTitle(attributes: [.font: resolvedFont, .foregroundColor: active ? activeColor : inactive],
                             shadow: shadow, alignment: alignment ?? .center, spill: spill)
    }
}

/// A title style ready to draw.
struct ResolvedTitle {
    struct Shadow {
        let color: NSColor
        // Points, y down.
        let offset: CGSize
        let blur: CGFloat
    }

    let attributes: [NSAttributedString.Key: Any]
    let shadow: Shadow?
    let alignment: TitleStyle.Alignment
    let spill: CGFloat

    /// Width the title needs, shadow included.
    func width(of title: String) -> CGFloat {
        (title as NSString).size(withAttributes: attributes).width + spill
    }
}
