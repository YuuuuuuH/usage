import AppKit
import SwiftUI

enum AtlasMedal: Int, CaseIterable {
    case bronze, silver, gold, diamond

    init?(name: String) {
        switch name {
        case "铜": self = .bronze
        case "银": self = .silver
        case "金": self = .gold
        case "钻石": self = .diamond
        default: return nil
        }
    }

    var fillColors: [NSColor] {
        let colors: [String]
        switch self {
        case .bronze: colors = ["#F6B18C", "#BE6B44"]
        case .silver: colors = ["#F0F5FA", "#9BAFC4"]
        case .gold: colors = ["#FFE58A", "#DDA627"]
        case .diamond: colors = ["#ECF7F4", "#94DFD6", "#B3C7ED", "#D4B3EF", "#ECB6CF", "#E1D49F", "#D3F0E9"]
        }
        return colors.map { AtlasTheme.color(hex: $0)! }
    }

    func accent(dark: Bool) -> NSColor {
        let colors: (String, String)
        switch self {
        case .bronze: colors = ("#934223", "#F5986B")
        case .silver: colors = ("#455D78", "#D0E0F4")
        case .gold: colors = ("#876000", "#F5CD4C")
        case .diamond: colors = ("#62507F", "#D6C7EB")
        }
        return AtlasTheme.color(hex: dark ? colors.1 : colors.0)!
    }

    static func diamondCardColors(dark: Bool) -> [NSColor] {
        (dark ? ["#30363E", "#272E36", "#33313C"] : ["#EEEFEB", "#E6EEF0", "#EFE9EE"]).map { AtlasTheme.color(hex: $0)! }
    }
}

final class AtlasTheme: ObservableObject {
    static let shared = AtlasTheme()
    static let defaultAccentHex = "#4569B4"
    static let defaultsKey = "atlasAccentHexV1"
    static let presets = [("蓝", "#4569B4"), ("紫", "#8665BF"), ("青", "#258279"), ("橙", "#BA702F"), ("玫红", "#B3557C"), ("石墨", "#64748B")]

    @Published private(set) var accentHex: String
    private let defaults: UserDefaults
    private var accentCache: [Bool: NSColor] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        accentHex = Self.normalizedHex(defaults.string(forKey: Self.defaultsKey) ?? "") ?? Self.defaultAccentHex
    }

    var isDefault: Bool { accentHex == Self.defaultAccentHex }
    var color: NSColor { Self.color(hex: accentHex)! }

    @discardableResult
    func setHex(_ raw: String) -> Bool {
        guard let hex = Self.normalizedHex(raw) else { return false }
        guard hex != accentHex else { return true }
        defaults.set(hex, forKey: Self.defaultsKey)
        accentCache.removeAll()
        accentHex = hex
        return true
    }

    func setColor(_ color: NSColor) {
        guard let rgb = color.usingColorSpace(.sRGB) else { return }
        func byte(_ component: CGFloat) -> Int { Int((min(1, max(0, component)) * 255).rounded()) }
        setHex(String(format: "#%02X%02X%02X", byte(rgb.redComponent), byte(rgb.greenComponent), byte(rgb.blueComponent)))
    }

    static func normalizedHex(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, value.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        return "#" + value
    }

    static func color(hex: String) -> NSColor? {
        guard let normalized = normalizedHex(hex), let rgb = UInt32(normalized.dropFirst(), radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }

    static func mix(_ color: NSColor, with other: NSColor, amount: CGFloat) -> NSColor {
        let a = color.usingColorSpace(.sRGB)!, b = other.usingColorSpace(.sRGB)!
        let t = min(1, max(0, amount))
        return NSColor(srgbRed: a.redComponent + (b.redComponent - a.redComponent) * t,
                       green: a.greenComponent + (b.greenComponent - a.greenComponent) * t,
                       blue: a.blueComponent + (b.blueComponent - a.blueComponent) * t, alpha: 1)
    }

    static func luminance(_ color: NSColor) -> CGFloat {
        let rgb = color.usingColorSpace(.sRGB)!
        func linear(_ channel: CGFloat) -> CGFloat {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
    }

    static func contrast(_ first: NSColor, _ second: NSColor) -> CGFloat {
        let a = luminance(first), b = luminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    static func text(on background: NSColor) -> NSColor {
        contrast(.black, background) >= contrast(.white, background) ? .black : .white
    }

    func accent(dark: Bool) -> NSColor {
        if let cached = accentCache[dark] { return cached }
        if isDefault {
            let value = Self.color(hex: dark ? "#8BAAE8" : Self.defaultAccentHex)!
            accentCache[dark] = value
            return value
        }
        let background = Self.color(hex: dark ? "#262A32" : "#F4F5F8")!
        for step in 0...20 {
            let candidate = Self.mix(color, with: dark ? .white : .black, amount: CGFloat(step) / 20)
            if Self.contrast(candidate, background) >= 4.5 {
                accentCache[dark] = candidate
                return candidate
            }
        }
        return dark ? .white : .black
    }
}
