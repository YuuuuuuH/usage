import AppKit

@main
enum AtlasThemeTests {
    static func main() {
        let name = "token-atlas-theme-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let theme = AtlasTheme(defaults: defaults)
        precondition(theme.accentHex == AtlasTheme.defaultAccentHex)
        precondition(theme.setHex(" ffcc00 ") && theme.accentHex == "#FFCC00")
        precondition(!theme.setHex("bad") && theme.accentHex == "#FFCC00")
        precondition(!theme.setHex("FF#CC00") && !theme.setHex("##FFCC00"))
        precondition(AtlasTheme(defaults: defaults).accentHex == "#FFCC00")
        for hex in [AtlasTheme.defaultAccentHex, "#000000", "#FFFFFF", "#FFFF00", "#FF0000", "#0000FF", "#808080"] {
            precondition(theme.setHex(hex))
            for dark in [false, true] {
                let accent = theme.accent(dark: dark)
                let background = AtlasTheme.color(hex: dark ? "#262A32" : "#F4F5F8")!
                precondition(AtlasTheme.contrast(accent, background) >= 4.5)
                precondition(AtlasTheme.contrast(AtlasTheme.text(on: accent), accent) >= 4.5)
            }
        }
        theme.setColor(AtlasTheme.color(hex: "#258279")!)
        precondition(theme.accentHex == "#258279")
        precondition(AtlasMedal(name: "铜") == .bronze && AtlasMedal(name: "银") == .silver && AtlasMedal(name: "金") == .gold)
        precondition(AtlasMedal(name: "钻石") == .diamond && AtlasMedal.allCases.count == 4)
        precondition(AtlasMedal(name: "待解锁") == nil)
        for dark in [false, true] {
            for background in AtlasMedal.diamondCardColors(dark: dark) {
                precondition(AtlasTheme.contrast(AtlasMedal.diamond.accent(dark: dark), background) >= 4.5)
            }
        }
        for medal in AtlasMedal.allCases {
            for dark in [false, true] {
                let background = AtlasTheme.color(hex: dark ? "#262A32" : "#F4F5F8")!
                precondition(AtlasTheme.contrast(medal.accent(dark: dark), background) >= 4.5)
            }
            for fill in medal.fillColors { precondition(AtlasTheme.contrast(.black, fill) >= 4.5) }
        }
        for (index, medal) in AtlasMedal.allCases.enumerated() {
            for other in AtlasMedal.allCases.dropFirst(index + 1) {
                let a = medal.fillColors.last!.usingColorSpace(.sRGB)!
                let b = other.fillColors.last!.usingColorSpace(.sRGB)!
                let distance = sqrt(pow(a.redComponent - b.redComponent, 2) + pow(a.greenComponent - b.greenComponent, 2) + pow(a.blueComponent - b.blueComponent, 2))
                precondition(distance >= 0.25)
            }
        }
        print("Theme tests passed")
    }
}
