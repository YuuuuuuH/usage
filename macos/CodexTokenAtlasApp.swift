import AppKit
import Darwin
import Foundation
import SwiftUI

private let showInDockDefaultsKey = "showInDockV1"
private let appearanceModeDefaultsKey = "appearanceModeV1"
private let historicalTotalDefaultsKey = "historicalTotalTokensV1"
private let liveRefreshDefaultsKey = "liveTokenRefreshSecondsV2"
private let dashboardRenderScale: CGFloat = 0.9

private enum AppearanceMode: Int, CaseIterable {
    case system, light, dark

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    var appKitAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

private func preferredDockVisibility() -> Bool {
    let defaults = UserDefaults.standard
    guard defaults.object(forKey: showInDockDefaultsKey) != nil else { return true }
    return defaults.bool(forKey: showInDockDefaultsKey)
}

private func preferredAppearanceMode() -> AppearanceMode {
    AppearanceMode(rawValue: UserDefaults.standard.integer(forKey: appearanceModeDefaultsKey)) ?? .system
}

private extension NSToolbarItem.Identifier {
    static let settings = NSToolbarItem.Identifier("local.codex.token-atlas.settings")
    static let refreshReport = NSToolbarItem.Identifier("local.codex.token-atlas.refresh")
    static let reportStatus = NSToolbarItem.Identifier("local.codex.token-atlas.status")
    static let exportReport = NSToolbarItem.Identifier("local.codex.token-atlas.export")
    static let revealExports = NSToolbarItem.Identifier("local.codex.token-atlas.exports")
    static let liveMonitor = NSToolbarItem.Identifier("local.codex.token-atlas.live-monitor")
}

private enum AtlasColor {
    private static func rgb(_ red: Int, _ green: Int, _ blue: Int, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: alpha)
    }

    static func adaptive(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }

    static let canvas = adaptive(light: rgb(238, 245, 242), dark: rgb(18, 24, 23))
    static let surface = adaptive(light: rgb(255, 255, 255), dark: rgb(29, 36, 35))
    static let ink = adaptive(light: rgb(16, 42, 42), dark: rgb(232, 242, 239))
    static let inkSoft = adaptive(light: rgb(62, 92, 89), dark: rgb(188, 204, 199))
    static let muted = adaptive(light: rgb(109, 129, 126), dark: rgb(139, 158, 153))
    static let line = adaptive(light: rgb(207, 220, 216), dark: rgb(51, 64, 61))
    static let lineStrong = adaptive(light: rgb(169, 191, 186), dark: rgb(76, 93, 89))
    static let teal = adaptive(light: rgb(8, 121, 104), dark: rgb(58, 194, 163))
    static let tealDeep = adaptive(light: rgb(4, 78, 71), dark: rgb(106, 224, 194))
    static let coral = adaptive(light: rgb(232, 111, 81), dark: rgb(245, 139, 110))
    static let statusInk = adaptive(light: rgb(133, 64, 46), dark: rgb(244, 157, 132))
    static let amber = adaptive(light: rgb(216, 154, 43), dark: rgb(237, 183, 76))
    static let zero = adaptive(light: rgb(229, 236, 233), dark: rgb(39, 48, 46))
    static let onAccent = adaptive(light: rgb(255, 255, 255), dark: rgb(7, 35, 31))
    static let tooltipSurface = rgb(16, 42, 42)
    static let tooltipText = rgb(255, 255, 255)
    static let heatLow = adaptive(light: rgb(220, 235, 230), dark: rgb(34, 48, 45))
    static let heatMidLow = adaptive(light: rgb(132, 205, 184), dark: rgb(34, 111, 94))
    static let heatMid = adaptive(light: rgb(24, 146, 122), dark: rgb(27, 178, 143))
    static let heatHigh = adaptive(light: rgb(3, 78, 70), dark: rgb(74, 220, 180))
}

private extension View {
    @ViewBuilder
    func atlasGlass<S: Shape>(
        in shape: S,
        tint: Color? = nil,
        clear: Bool = false,
        interactive: Bool = false
    ) -> some View {
        if #available(macOS 26.0, *) {
            let glass = clear ? Glass.clear : Glass.regular
            glassEffect(glass.tint(tint).interactive(interactive), in: shape)
        } else if clear {
            background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(Color(nsColor: AtlasColor.line).opacity(0.55), lineWidth: 1))
        } else {
            background(.regularMaterial, in: shape)
                .overlay(shape.stroke(Color(nsColor: AtlasColor.line).opacity(0.8), lineWidth: 1))
        }
    }
}

private struct Usage: Decodable {
    let input_tokens: Int64
    let cached_input_tokens: Int64
    let cache_write_input_tokens: Int64
    let output_tokens: Int64
    let reasoning_output_tokens: Int64
    let total_tokens: Int64
    let uncached_input_tokens: Int64
    let unclassified_tokens: Int64
    let calls: Int64

    init(
        input_tokens: Int64 = 0,
        cached_input_tokens: Int64 = 0,
        cache_write_input_tokens: Int64 = 0,
        output_tokens: Int64 = 0,
        reasoning_output_tokens: Int64 = 0,
        total_tokens: Int64 = 0,
        uncached_input_tokens: Int64 = 0,
        unclassified_tokens: Int64 = 0,
        calls: Int64 = 0
    ) {
        self.input_tokens = input_tokens
        self.cached_input_tokens = cached_input_tokens
        self.cache_write_input_tokens = cache_write_input_tokens
        self.output_tokens = output_tokens
        self.reasoning_output_tokens = reasoning_output_tokens
        self.total_tokens = total_tokens
        self.uncached_input_tokens = uncached_input_tokens
        self.unclassified_tokens = unclassified_tokens
        self.calls = calls
    }
}

private struct Cost: Decodable {
    let uncached_input_cost_usd: Double
    let cached_input_cost_usd: Double
    let cache_write_input_cost_usd: Double
    let output_cost_usd: Double
    let estimated_cost_usd: Double
    let standard_equivalent_cost_usd: Double
    let service_tier_premium_usd: Double
    let cache_savings_usd: Double
    let priced_tokens: Int64
    let unpriced_tokens: Int64
    let priced_calls: Int64
    let unpriced_calls: Int64
    let long_context_calls: Int64
    let default_tier_calls: Int64
    let priority_tier_calls: Int64
    let other_tier_calls: Int64
    let tier_rate_fallback_calls: Int64

    init(
        uncached_input_cost_usd: Double = 0,
        cached_input_cost_usd: Double = 0,
        cache_write_input_cost_usd: Double = 0,
        output_cost_usd: Double = 0,
        estimated_cost_usd: Double = 0,
        standard_equivalent_cost_usd: Double = 0,
        service_tier_premium_usd: Double = 0,
        cache_savings_usd: Double = 0,
        priced_tokens: Int64 = 0,
        unpriced_tokens: Int64 = 0,
        priced_calls: Int64 = 0,
        unpriced_calls: Int64 = 0,
        long_context_calls: Int64 = 0,
        default_tier_calls: Int64 = 0,
        priority_tier_calls: Int64 = 0,
        other_tier_calls: Int64 = 0,
        tier_rate_fallback_calls: Int64 = 0
    ) {
        self.uncached_input_cost_usd = uncached_input_cost_usd
        self.cached_input_cost_usd = cached_input_cost_usd
        self.cache_write_input_cost_usd = cache_write_input_cost_usd
        self.output_cost_usd = output_cost_usd
        self.estimated_cost_usd = estimated_cost_usd
        self.standard_equivalent_cost_usd = standard_equivalent_cost_usd
        self.service_tier_premium_usd = service_tier_premium_usd
        self.cache_savings_usd = cache_savings_usd
        self.priced_tokens = priced_tokens
        self.unpriced_tokens = unpriced_tokens
        self.priced_calls = priced_calls
        self.unpriced_calls = unpriced_calls
        self.long_context_calls = long_context_calls
        self.default_tier_calls = default_tier_calls
        self.priority_tier_calls = priority_tier_calls
        self.other_tier_calls = other_tier_calls
        self.tier_rate_fallback_calls = tier_rate_fallback_calls
    }
}

private struct RateSet: Decodable {
    let input: Double?
    let cached_input: Double?
    let cache_write_input: Double?
    let output: Double?
}

private struct RouteDay: Decodable {
    let usage: Usage
    let costs: Cost
}

private struct PricingRoute: Decodable {
    let route_provider: String
    let model: String
    let service_tier: String
    let usage: Usage
    let costs: Cost
    let pricing_provider: String?
    let pricing_model: String?
    let rates: RateSet?
    let daily: [String: RouteDay]
}

private struct PricingData: Decodable {
    let as_of: String
    let scopes: [String: Cost]
    let routes: [PricingRoute]
    let hourly: [String: [[Cost]]]
    let daily: [String: [String: Cost]]
    let timeline_hourly: [String: [String: Cost]]
}

private struct DateRange: Decodable {
    let start: String
    let end: String
}

private struct SessionData: Decodable {
    let id: String
    let parent_id: String
    let lineage_depth: Int
    let title: String
    let path: String
    let totals: Usage
    let by_model: [String: Usage]
    let by_provider: [String: Usage]
    let by_service_tier: [String: Usage]
    let by_reasoning_effort: [String: Usage]
    let by_day: [String: Usage]
    let by_day_model: [String: [String: Usage]]
    let costs_by_day: [String: Cost]
    let costs_by_day_model: [String: [String: Cost]]
    let inherited_events: Int
}

private struct AuditData: Decodable {
    let session_files: Int
    let fork_sessions: Int
    let raw_token_events: Int
    let unique_model_calls: Int
    let inherited_events: Int
    let local_duplicate_events: Int
    let null_usage_events: Int
    let fallback_delta_events: Int
    let fallback_model_events: Int
    let fallback_provider_events: Int
    let fallback_service_tier_events: Int
    let configured_service_tier_fallback: String?
    let repaired_total_events: Int
    let missing_timestamp_events: Int
    let pricing_config_errors: Int
}

private struct DashboardData: Decodable {
    let generated_at_label: String
    let timezone: String
    let range: DateRange
    let models: [String]
    let totals: [String: Usage]
    let pricing: PricingData
    let hourly: [String: [[Usage]]]
    let timeline_hourly: [String: [String: Usage]]
    let daily: [String: [String: Usage]]
    let sessions: [SessionData]
    let audit: AuditData
}

private struct ReportEnvelope: Decodable {
    let dashboard: DashboardData
}

private enum PricingMode: Int {
    case simple = 0
    case tiered = 1

    var title: String {
        switch self {
        case .simple: return "简单计价"
        case .tiered: return "区分 Default / Fast"
        }
    }

    func value(_ cost: Cost) -> Double {
        self == .simple ? cost.standard_equivalent_cost_usd : cost.estimated_cost_usd
    }
}

private enum DatePreset: Int {
    case all = 0
    case last7 = 1
    case last30 = 2
    case custom = 3
}

private struct MetricOption {
    let key: String
    let title: String

    static let all = [
        MetricOption(key: "total_tokens", title: "Total tokens"),
        MetricOption(key: "input_tokens", title: "Input tokens"),
        MetricOption(key: "cached_input_tokens", title: "Cached input"),
        MetricOption(key: "cache_write_input_tokens", title: "Cache write input"),
        MetricOption(key: "uncached_input_tokens", title: "Uncached input"),
        MetricOption(key: "output_tokens", title: "Output tokens"),
        MetricOption(key: "reasoning_output_tokens", title: "Reasoning output"),
        MetricOption(key: "unclassified_tokens", title: "Unclassified"),
        MetricOption(key: "calls", title: "Unique calls")
    ]
}

private extension Usage {
    func value(for key: String) -> Int64 {
        switch key {
        case "input_tokens": return input_tokens
        case "cached_input_tokens": return cached_input_tokens
        case "cache_write_input_tokens": return cache_write_input_tokens
        case "uncached_input_tokens": return uncached_input_tokens
        case "output_tokens": return output_tokens
        case "reasoning_output_tokens": return reasoning_output_tokens
        case "unclassified_tokens": return unclassified_tokens
        case "calls": return calls
        default: return total_tokens
        }
    }

    func adding(_ other: Usage) -> Usage {
        Usage(
            input_tokens: input_tokens + other.input_tokens,
            cached_input_tokens: cached_input_tokens + other.cached_input_tokens,
            cache_write_input_tokens: cache_write_input_tokens + other.cache_write_input_tokens,
            output_tokens: output_tokens + other.output_tokens,
            reasoning_output_tokens: reasoning_output_tokens + other.reasoning_output_tokens,
            total_tokens: total_tokens + other.total_tokens,
            uncached_input_tokens: uncached_input_tokens + other.uncached_input_tokens,
            unclassified_tokens: unclassified_tokens + other.unclassified_tokens,
            calls: calls + other.calls
        )
    }
}

private extension Cost {
    func adding(_ other: Cost) -> Cost {
        Cost(
            uncached_input_cost_usd: uncached_input_cost_usd + other.uncached_input_cost_usd,
            cached_input_cost_usd: cached_input_cost_usd + other.cached_input_cost_usd,
            cache_write_input_cost_usd: cache_write_input_cost_usd + other.cache_write_input_cost_usd,
            output_cost_usd: output_cost_usd + other.output_cost_usd,
            estimated_cost_usd: estimated_cost_usd + other.estimated_cost_usd,
            standard_equivalent_cost_usd: standard_equivalent_cost_usd + other.standard_equivalent_cost_usd,
            service_tier_premium_usd: service_tier_premium_usd + other.service_tier_premium_usd,
            cache_savings_usd: cache_savings_usd + other.cache_savings_usd,
            priced_tokens: priced_tokens + other.priced_tokens,
            unpriced_tokens: unpriced_tokens + other.unpriced_tokens,
            priced_calls: priced_calls + other.priced_calls,
            unpriced_calls: unpriced_calls + other.unpriced_calls,
            long_context_calls: long_context_calls + other.long_context_calls,
            default_tier_calls: default_tier_calls + other.default_tier_calls,
            priority_tier_calls: priority_tier_calls + other.priority_tier_calls,
            other_tier_calls: other_tier_calls + other.other_tier_calls,
            tier_rate_fallback_calls: tier_rate_fallback_calls + other.tier_rate_fallback_calls
        )
    }
}

private class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class CanvasView: FlippedView {
    override func draw(_ dirtyRect: NSRect) {
        AtlasColor.canvas.setFill()
        dirtyRect.fill()
    }
}

private final class SurfaceView: FlippedView {
    init(fill: NSColor = AtlasColor.surface, border: NSColor = AtlasColor.line, radius: CGFloat = 4) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = fill.cgColor
        layer?.borderColor = border.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = radius
    }

    required init?(coder: NSCoder) { nil }
}

private final class TooltipToken {
    let text: String
    init(_ text: String) { self.text = text }
}

private func percentile(_ values: [Double], fraction: Double) -> Double {
    let sorted = values.filter { $0 > 0 }.sorted()
    guard !sorted.isEmpty else { return 0 }
    let index = min(sorted.count - 1, max(0, Int(round(Double(sorted.count - 1) * fraction))))
    return sorted[index]
}

private func heatColor(value: Double, cap: Double) -> NSColor {
    guard value > 0, cap > 0 else { return AtlasColor.zero }
    let t = pow(min(value / cap, 1), 0.44)
    let lightStops: [(Double, (Double, Double, Double))] = [
        (0, (0.86, 0.92, 0.90)),
        (0.36, (0.49, 0.79, 0.70)),
        (0.70, (0.09, 0.57, 0.48)),
        (1, (0.01, 0.31, 0.27))
    ]
    let darkStops: [(Double, (Double, Double, Double))] = [
        (0, (0.13, 0.19, 0.17)),
        (0.36, (0.12, 0.39, 0.32)),
        (0.70, (0.08, 0.61, 0.48)),
        (1, (0.29, 0.86, 0.70))
    ]

    func interpolate(_ stops: [(Double, (Double, Double, Double))]) -> NSColor {
        var left = stops[0]
        var right = stops[stops.count - 1]
        for index in 1..<stops.count where t <= stops[index].0 {
            left = stops[index - 1]
            right = stops[index]
            break
        }
        let span = max(0.0001, right.0 - left.0)
        let local = (t - left.0) / span
        return NSColor(
            srgbRed: left.1.0 + (right.1.0 - left.1.0) * local,
            green: left.1.1 + (right.1.1 - left.1.1) * local,
            blue: left.1.2 + (right.1.2 - left.1.2) * local,
            alpha: 1
        )
    }

    return AtlasColor.adaptive(light: interpolate(lightStops), dark: interpolate(darkStops))
}

private final class HourHeatmapView: NSView {
    override var isFlipped: Bool { true }
    var usage: [[Usage]] = [] { didSet { needsDisplay = true; rebuildTooltips() } }
    var costs: [[Cost]] = [] { didSet { rebuildTooltips() } }
    var metricKey = "total_tokens" { didSet { needsDisplay = true; rebuildTooltips() } }
    var pricingMode = PricingMode.simple { didSet { rebuildTooltips() } }
    var modelLabel = "全部模型" { didSet { rebuildTooltips() } }
    private var tooltipTokens: [TooltipToken] = []
    private var lastTooltipSize = NSSize.zero

    override var intrinsicContentSize: NSSize { NSSize(width: 1060, height: 300) }

    override func layout() {
        super.layout()
        if bounds.size != lastTooltipSize {
            lastTooltipSize = bounds.size
            rebuildTooltips()
        }
    }

    private func cellRect(row: Int, hour: Int) -> NSRect {
        let left: CGFloat = 66
        let top: CGFloat = 38
        let gap: CGFloat = 4
        let available = max(720, bounds.width - left - 12)
        let width = (available - gap * 23) / 24
        let height: CGFloat = 28
        return NSRect(
            x: left + CGFloat(hour) * (width + gap),
            y: top + CGFloat(row) * (height + gap),
            width: width,
            height: height
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        guard usage.count == 7 else { return }
        let values = usage.flatMap { $0 }.map { Double($0.value(for: metricKey)) }
        let cap = percentile(values, fraction: 0.98)
        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium),
            .foregroundColor: AtlasColor.muted
        ]
        let dayAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: AtlasColor.ink
        ]
        let weekdays = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
        for hour in 0..<24 {
            let rect = cellRect(row: 0, hour: hour)
            NSString(format: "%02d", hour).draw(
                in: NSRect(x: rect.minX, y: 12, width: rect.width, height: 14),
                withAttributes: labelAttributes
            )
        }
        for row in 0..<7 {
            let first = cellRect(row: row, hour: 0)
            (weekdays[row] as NSString).draw(
                in: NSRect(x: 12, y: first.midY - 7, width: 46, height: 16),
                withAttributes: dayAttributes
            )
            for hour in 0..<24 {
                let rect = cellRect(row: row, hour: hour)
                heatColor(value: Double(usage[row][hour].value(for: metricKey)), cap: cap).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
            }
        }
        let legendRect = NSRect(x: 66, y: 273, width: min(340, bounds.width - 150), height: 7)
        let gradient = NSGradient(colors: [AtlasColor.zero, NSColor(calibratedRed: 0.49, green: 0.79, blue: 0.70, alpha: 1), AtlasColor.tealDeep])
        gradient?.draw(in: legendRect, angle: 0)
        "0".draw(in: NSRect(x: 44, y: 267, width: 18, height: 15), withAttributes: labelAttributes)
        shortNumber(Int64(cap)).draw(in: NSRect(x: legendRect.maxX + 8, y: 267, width: 70, height: 15), withAttributes: labelAttributes)
    }

    private func rebuildTooltips() {
        guard usage.count == 7, costs.count == 7, bounds.width > 0 else { return }
        removeAllToolTips()
        tooltipTokens.removeAll()
        let weekdays = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
        for row in 0..<7 where usage[row].count == 24 && costs[row].count == 24 {
            for hour in 0..<24 {
                let item = usage[row][hour]
                let cost = pricingMode.value(costs[row][hour])
                let text = "\(weekdays[row]) \(String(format: "%02d", hour)):00 · \(modelLabel)\n\(formatInt(item.value(for: metricKey))) · \(formatInt(item.calls)) calls\n官方 API 等价价值 \(formatUSD(cost))"
                let token = TooltipToken(text)
                tooltipTokens.append(token)
                addToolTip(cellRect(row: row, hour: hour), owner: self, userData: Unmanaged.passUnretained(token).toOpaque())
            }
        }
    }

    @objc func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        guard let data else { return "" }
        return Unmanaged<TooltipToken>.fromOpaque(data).takeUnretainedValue().text
    }
}

private final class CalendarHeatmapView: NSView {
    override var isFlipped: Bool { true }
    var usage: [String: Usage] = [:] { didSet { needsDisplay = true; rebuildTooltips() } }
    var costs: [String: Cost] = [:] { didSet { rebuildTooltips() } }
    var start = ""
    var end = ""
    var metricKey = "total_tokens" { didSet { needsDisplay = true; rebuildTooltips() } }
    var pricingMode = PricingMode.simple { didSet { rebuildTooltips() } }
    var modelLabel = "全部模型" { didSet { rebuildTooltips() } }
    private var tooltipTokens: [TooltipToken] = []
    private var cells: [(String, NSRect)] = []

    override var intrinsicContentSize: NSSize { NSSize(width: 1060, height: 230) }

    private static let parser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private func calculateCells() -> [(String, NSRect)] {
        guard let first = Self.parser.date(from: start), let last = Self.parser.date(from: end) else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let firstWeekday = (calendar.component(.weekday, from: first) + 5) % 7
        let gridStart = calendar.date(byAdding: .day, value: -firstWeekday, to: first)!
        let dayCount = calendar.dateComponents([.day], from: gridStart, to: last).day! + 1
        let weeks = Int(ceil(Double(dayCount) / 7.0))
        let left: CGFloat = 66
        let top: CGFloat = 34
        let gap: CGFloat = 5
        let size = min(CGFloat(27), max(CGFloat(16), (bounds.width - left - 20 - CGFloat(weeks - 1) * gap) / CGFloat(weeks)))
        var result: [(String, NSRect)] = []
        for offset in 0..<(weeks * 7) {
            let date = calendar.date(byAdding: .day, value: offset, to: gridStart)!
            let key = Self.parser.string(from: date)
            let week = offset / 7
            let weekday = offset % 7
            result.append((key, NSRect(x: left + CGFloat(week) * (size + gap), y: top + CGFloat(weekday) * (size + gap), width: size, height: size)))
        }
        return result
    }

    override func draw(_ dirtyRect: NSRect) {
        cells = calculateCells()
        let cap = percentile(usage.values.map { Double($0.value(for: metricKey)) }, fraction: 0.98)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: AtlasColor.muted
        ]
        let weekdays = ["一", "二", "三", "四", "五", "六", "日"]
        for index in 0..<7 {
            (weekdays[index] as NSString).draw(in: NSRect(x: 28, y: 39 + CGFloat(index) * 32, width: 22, height: 14), withAttributes: attributes)
        }
        for (key, rect) in cells {
            let isInside = key >= start && key <= end
            let value = isInside ? Double(usage[key]?.value(for: metricKey) ?? 0) : 0
            (isInside ? heatColor(value: value, cap: cap) : AtlasColor.canvas).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
        }
    }

    private func rebuildTooltips() {
        guard bounds.width > 0 else { return }
        cells = calculateCells()
        removeAllToolTips()
        tooltipTokens.removeAll()
        for (key, rect) in cells where key >= start && key <= end {
            let item = usage[key] ?? Usage()
            let value = item.value(for: metricKey)
            let amount = pricingMode.value(costs[key] ?? Cost())
            let token = TooltipToken("\(key) · \(modelLabel)\n\(formatInt(value)) · \(formatInt(item.calls)) calls\n官方 API 等价价值 \(formatUSD(amount))")
            tooltipTokens.append(token)
            addToolTip(rect, owner: self, userData: Unmanaged.passUnretained(token).toOpaque())
        }
    }

    override func layout() {
        super.layout()
        rebuildTooltips()
    }

    @objc func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        guard let data else { return "" }
        return Unmanaged<TooltipToken>.fromOpaque(data).takeUnretainedValue().text
    }
}

private func formatInt(_ value: Int64) -> String {
    NumberFormatter.integer.string(from: NSNumber(value: value)) ?? "0"
}

private func shortNumber(_ value: Int64) -> String {
    let number = Double(value)
    if number >= 1_000_000_000 { return String(format: "%.2fB", number / 1_000_000_000) }
    if number >= 1_000_000 { return String(format: "%.1fM", number / 1_000_000) }
    if number >= 1_000 { return String(format: "%.1fK", number / 1_000) }
    return formatInt(value)
}

private func formatTokenRate(_ value: Double) -> String {
    if value >= 1_000_000_000 { return String(format: "%.1fB", value / 1_000_000_000) }
    if value >= 1_000_000 { return String(format: "%.1fM", value / 1_000_000) }
    if value >= 1_000 { return String(format: "%.1fK", value / 1_000) }
    if value >= 100 { return String(format: "%.0f", value) }
    if value >= 10 { return String(format: "%.1f", value) }
    return String(format: "%.2f", value)
}

private func formatStatusTokenRate(_ value: Double) -> String {
    if value >= 1_000_000_000 { return String(format: "%.0fB", value / 1_000_000_000) }
    if value >= 100_000_000 { return String(format: "%.0fM", value / 1_000_000) }
    if value >= 1_000_000 { return String(format: "%.1fM", value / 1_000_000) }
    if value >= 100_000 { return String(format: "%.0fK", value / 1_000) }
    if value >= 1_000 { return String(format: "%.1fK", value / 1_000) }
    if value >= 100 { return String(format: "%.0f", value) }
    if value >= 10 { return String(format: "%.1f", value) }
    return String(format: "%.2f", value)
}

private func formatUSD(_ value: Double) -> String {
    NumberFormatter.currency.string(from: NSNumber(value: value)) ?? "$0.00"
}

private func makeLabel(
    _ text: String,
    size: CGFloat = 13,
    weight: NSFont.Weight = .regular,
    color: NSColor = AtlasColor.ink,
    selectable: Bool = false,
    lines: Int = 1,
    monospaced: Bool = false
) -> NSTextField {
    let field = NSTextField(labelWithString: text)
    field.font = monospaced ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
    field.textColor = color
    field.isSelectable = selectable
    field.maximumNumberOfLines = lines
    field.lineBreakMode = lines == 1 ? .byTruncatingTail : .byWordWrapping
    field.cell?.wraps = lines != 1
    return field
}

private func makeMetricCard(title: String, value: String, detail: String, accent: NSColor) -> NSView {
    let card = SurfaceView()
    let accentBar = NSView()
    accentBar.wantsLayer = true
    accentBar.layer?.backgroundColor = accent.cgColor
    accentBar.translatesAutoresizingMaskIntoConstraints = false
    let titleField = makeLabel(title.uppercased(), size: 10, weight: .bold, color: AtlasColor.muted)
    let valueField = makeLabel(value, size: 20, weight: .semibold, color: AtlasColor.ink, selectable: true, monospaced: true)
    let detailField = makeLabel(detail, size: 9, color: AtlasColor.muted, selectable: true)
    let stack = NSStackView(views: [titleField, valueField, detailField])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 6
    stack.translatesAutoresizingMaskIntoConstraints = false
    card.addSubview(accentBar)
    card.addSubview(stack)
    NSLayoutConstraint.activate([
        accentBar.leadingAnchor.constraint(equalTo: card.leadingAnchor),
        accentBar.trailingAnchor.constraint(equalTo: card.trailingAnchor),
        accentBar.topAnchor.constraint(equalTo: card.topAnchor),
        accentBar.heightAnchor.constraint(equalToConstant: 3),
        stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 13),
        stack.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -12),
        stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 13),
        stack.bottomAnchor.constraint(lessThanOrEqualTo: card.bottomAnchor, constant: -11),
        card.heightAnchor.constraint(equalToConstant: 88)
    ])
    return card
}

private func makePanel(title: String, subtitle: String, content: NSView, trailing: String? = nil) -> NSView {
    let panel = FlippedView()
    let separator = NSView()
    separator.wantsLayer = true
    separator.layer?.backgroundColor = AtlasColor.line.cgColor
    separator.translatesAutoresizingMaskIntoConstraints = false
    panel.addSubview(separator)
    let titleField = makeLabel(title, size: 16, weight: .semibold)
    let subtitleField = makeLabel(subtitle, size: 11, color: AtlasColor.muted, lines: 2)
    let titleStack = NSStackView(views: [titleField, subtitleField])
    titleStack.orientation = .vertical
    titleStack.alignment = .leading
    titleStack.spacing = 4
    let head = NSStackView()
    head.orientation = .horizontal
    head.alignment = .top
    head.addArrangedSubview(titleStack)
    if let trailing {
        let trailingField = makeLabel(trailing, size: 10, weight: .semibold, color: AtlasColor.muted, monospaced: true)
        head.addArrangedSubview(trailingField)
    }
    head.distribution = .fill
    let stack = NSStackView(views: [head, content])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 16
    stack.translatesAutoresizingMaskIntoConstraints = false
    content.translatesAutoresizingMaskIntoConstraints = false
    panel.addSubview(stack)
    NSLayoutConstraint.activate([
        separator.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
        separator.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
        separator.topAnchor.constraint(equalTo: panel.topAnchor),
        separator.heightAnchor.constraint(equalToConstant: 1),
        stack.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 4),
        stack.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -4),
        stack.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 16),
        stack.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -12),
        head.widthAnchor.constraint(equalTo: stack.widthAnchor),
        content.widthAnchor.constraint(equalTo: stack.widthAnchor)
    ])
    return panel
}

private func makeTable(headers: [String], rows: [[String]], widths: [CGFloat], maxRows: Int = 30) -> NSView {
    let visibleRows = Array(rows.prefix(maxRows))
    let allRows = [headers] + visibleRows
    let matrix: [[NSView]] = allRows.enumerated().map { rowIndex, row in
        row.enumerated().map { _, value in
            let field = makeLabel(
                value,
                size: rowIndex == 0 ? 10 : 12,
                weight: rowIndex == 0 ? .bold : .regular,
                color: rowIndex == 0 ? AtlasColor.muted : AtlasColor.ink,
                selectable: rowIndex != 0,
                lines: rowIndex == 0 ? 1 : 2
            )
            field.alignment = .left
            return field
        }
    }
    let grid = NSGridView(views: matrix)
    grid.columnSpacing = 14
    grid.rowSpacing = 0
    grid.xPlacement = .fill
    grid.yPlacement = .center
    for index in widths.indices { grid.column(at: index).width = widths[index] }
    for index in allRows.indices { grid.row(at: index).height = index == 0 ? 34 : 44 }
    let totalWidth = widths.reduce(0, +) + CGFloat(max(0, widths.count - 1)) * 14
    let totalHeight = CGFloat(34 + visibleRows.count * 44)
    let document = FlippedView(frame: NSRect(x: 0, y: 0, width: totalWidth, height: totalHeight))
    grid.translatesAutoresizingMaskIntoConstraints = false
    document.addSubview(grid)
    NSLayoutConstraint.activate([
        grid.leadingAnchor.constraint(equalTo: document.leadingAnchor),
        grid.trailingAnchor.constraint(equalTo: document.trailingAnchor),
        grid.topAnchor.constraint(equalTo: document.topAnchor),
        grid.bottomAnchor.constraint(equalTo: document.bottomAnchor)
    ])
    let scroll = NSScrollView()
    scroll.drawsBackground = false
    scroll.hasHorizontalScroller = true
    scroll.hasVerticalScroller = false
    scroll.autohidesScrollers = true
    scroll.documentView = document
    scroll.heightAnchor.constraint(equalToConstant: totalHeight + 14).isActive = true
    return scroll
}

private enum ExportFormat: Int, CaseIterable {
    case html, json, daily, hourly, model, route, session, all

    var title: String {
        switch self {
        case .html: return "完整历史 HTML 报表"
        case .json: return "当前筛选 JSON"
        case .daily: return "当前周期每日 CSV"
        case .hourly: return "当前周期每小时 CSV"
        case .model: return "当前周期模型 CSV"
        case .route: return "当前周期路由 CSV"
        case .session: return "当前周期会话 CSV"
        case .all: return "当前筛选全部格式"
        }
    }

    var fileName: String {
        switch self {
        case .html: return "codex_token_heatmap.html"
        case .json: return "codex_token_atlas_selection.json"
        case .daily: return "codex_token_atlas_daily.csv"
        case .hourly: return "codex_token_atlas_hourly.csv"
        case .model: return "codex_token_atlas_models.csv"
        case .route: return "codex_token_atlas_routes.csv"
        case .session: return "codex_token_atlas_sessions.csv"
        case .all: return ""
        }
    }
}

private let reportDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
}()

private final class LiveMonitorPresentation: ObservableObject {
    @Published var snapshot = LiveTokenSnapshot.zero
    @Published var refreshSeconds = 2
    @Published var panelPinned = false
    @Published var historicalTotalTokens: Int64 = 0
}

private final class LiveMonitorPanel: NSPanel, NSWindowDelegate {
    var pinnedChanged: ((Bool) -> Void)?
    private(set) var isPinned = false
    private var isPositioning = false
    private var transientOrigin: NSPoint?
    override var canBecomeKey: Bool { true }

    init(contentSize: NSSize) {
        super.init(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        title = "Token Rate"
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        level = .floating
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        animationBehavior = .utilityWindow
        delegate = self
    }

    func show(relativeTo button: NSStatusBarButton) {
        if !isPinned {
            position(relativeTo: button)
        }
        NSApp.activate(ignoringOtherApps: true)
        orderFrontRegardless()
        makeKey()
    }

    func dismissAndUnpin() {
        orderOut(nil)
        setPinned(false)
    }

    func windowWillMove(_ notification: Notification) {
        if !isPositioning, isVisible { setPinned(true) }
    }

    func windowDidMove(_ notification: Notification) {
        guard !isPositioning, isVisible, let origin = transientOrigin else { return }
        if abs(frame.origin.x - origin.x) > 2 || abs(frame.origin.y - origin.y) > 2 {
            setPinned(true)
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        if !isPinned { orderOut(nil) }
    }

    private func position(relativeTo button: NSStatusBarButton) {
        guard let sourceWindow = button.window else { return }
        let sourceRect = sourceWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let visibleFrame = sourceWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let x = min(max(sourceRect.midX - frame.width / 2, visibleFrame.minX + 8), visibleFrame.maxX - frame.width - 8)
        let top = sourceRect.minY - 5
        isPositioning = true
        setFrameTopLeftPoint(NSPoint(x: x, y: top))
        transientOrigin = frame.origin
        isPositioning = false
    }

    private func setPinned(_ pinned: Bool) {
        guard isPinned != pinned else { return }
        isPinned = pinned
        level = pinned ? .normal : .floating
        collectionBehavior = pinned ? [.moveToActiveSpace] : [.moveToActiveSpace, .fullScreenAuxiliary]
        pinnedChanged?(pinned)
    }
}

private struct ScaledContent<Content: View>: View {
    let scale: CGFloat
    let content: Content

    init(scale: CGFloat, @ViewBuilder content: () -> Content) {
        self.scale = scale
        self.content = content()
    }

    var body: some View {
        GeometryReader { geometry in
            content
                .frame(
                    width: geometry.size.width / scale,
                    height: geometry.size.height / scale,
                    alignment: .topLeading
                )
                .scaleEffect(scale, anchor: .topLeading)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSToolbarDelegate, ObservableObject {
    private var window: NSWindow!
    private var scrollView: NSScrollView!
    private let toolbarSpinner = NSProgressIndicator()
    private let toolbarStatus = NSTextField(labelWithString: "准备中")
    private var refreshToolbarItem: NSToolbarItem?
    private weak var settingsToolbarButton: NSButton?
    private weak var liveToolbarButton: NSButton?
    private weak var liveMenuItem: NSMenuItem?
    private weak var dockMenuItem: NSMenuItem?
    private let settingsMenu = NSMenu(title: "设置")
    private var appearanceMenuItems: [AppearanceMode: NSMenuItem] = [:]
    private var refreshMenuItems: [Int: NSMenuItem] = [:]
    @Published fileprivate var generatorRunning = false
    @Published fileprivate var loadingTitleText = "正在刷新 Token 历史"
    @Published fileprivate var loadingDetailText = "读取本地 Codex 会话并校正 fork 用量…"
    @Published fileprivate var dashboard: DashboardData?
    @Published fileprivate var selectedModel = "all"
    @Published fileprivate var selectedMetric = "total_tokens"
    @Published fileprivate var pricingMode = PricingMode.simple
    @Published fileprivate var datePreset = DatePreset.all
    @Published fileprivate var selectedStartDate: Date?
    @Published fileprivate var selectedEndDate: Date?
    fileprivate let livePresentation = LiveMonitorPresentation()
    fileprivate var liveMonitorEnabled = false

    private var statusItem: NSStatusItem?
    private var lastStatusRateText: String?
    private var livePanel: LiveMonitorPanel!
    private var liveMonitor: LiveTokenMonitor!
    private var latestLiveSnapshot = LiveTokenSnapshot.zero
    private var historicalTotalTokens = (UserDefaults.standard.object(forKey: historicalTotalDefaultsKey) as? NSNumber)?.int64Value ?? 0
    private var historicalDisplayTimer: Timer?
    private var showsInDock = preferredDockVisibility()
    private var appearanceMode = preferredAppearanceMode()

    private let fileManager = FileManager.default
    private lazy var homeURL = fileManager.homeDirectoryForCurrentUser
    private lazy var summaryURL = homeURL.appendingPathComponent("codex_token_usage_summary.json")
    private lazy var logURL = homeURL.appendingPathComponent("Library/Logs/Codex Token Atlas.log")
    private lazy var exportFiles: [(ExportFormat, URL)] = [
        (.html, homeURL.appendingPathComponent("codex_token_heatmap.html")),
        (.json, summaryURL),
        (.daily, homeURL.appendingPathComponent("codex_token_usage_by_day.csv")),
        (.hourly, homeURL.appendingPathComponent("codex_token_usage_by_hour.csv")),
        (.model, homeURL.appendingPathComponent("codex_token_usage_by_model.csv")),
        (.route, homeURL.appendingPathComponent("codex_token_usage_by_route.csv")),
        (.session, homeURL.appendingPathComponent("codex_token_usage_by_session.csv"))
    ]

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = appearanceMode.appKitAppearance
        pricingMode = PricingMode(rawValue: UserDefaults.standard.integer(forKey: "pricingMode")) ?? .simple
        let storedRefresh = UserDefaults.standard.integer(forKey: liveRefreshDefaultsKey)
        livePresentation.refreshSeconds = [1, 2, 5].contains(storedRefresh) ? storedRefresh : 5
        if ![1, 2, 5].contains(storedRefresh) {
            UserDefaults.standard.set(5, forKey: liveRefreshDefaultsKey)
        }
        liveMonitorEnabled = UserDefaults.standard.bool(forKey: "liveTokenMonitorEnabledV2")
        if !showsInDock && !liveMonitorEnabled {
            liveMonitorEnabled = true
            UserDefaults.standard.set(true, forKey: "liveTokenMonitorEnabledV2")
        }
        configureMainMenu()
        configureWindow()
        configureLiveMonitor()
        NSApp.setActivationPolicy(showsInDock ? .regular : .accessory)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        refreshReport(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        publishHistoricalTotal()
        historicalDisplayTimer?.invalidate()
        liveMonitor?.stop()
    }

    private func configureMainMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "Codex Token Atlas")
        appMenu.addItem(withTitle: "关于 Codex Token Atlas", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let liveItem = appMenu.addItem(withTitle: "顶部栏 Token 统计", action: #selector(toggleLiveMonitor(_:)), keyEquivalent: "")
        liveItem.target = self
        liveMenuItem = liveItem
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 Codex Token Atlas", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 Codex Token Atlas", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "文件")
        let refresh = fileMenu.addItem(withTitle: "刷新统计", action: #selector(refreshReport(_:)), keyEquivalent: "r")
        refresh.target = self
        let export = fileMenu.addItem(withTitle: "导出…", action: #selector(exportReport(_:)), keyEquivalent: "e")
        export.keyEquivalentModifierMask = [.command, .shift]
        export.target = self
        let reveal = fileMenu.addItem(withTitle: "显示中间导出文件", action: #selector(revealExportFiles(_:)), keyEquivalent: "")
        reveal.target = self
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        let showWindow = windowMenu.addItem(withTitle: "显示 Token Atlas", action: #selector(showMainWindowAction(_:)), keyEquivalent: "0")
        showWindow.target = self
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = mainMenu
        configureSettingsMenu()
    }

    private func configureSettingsMenu() {
        settingsMenu.removeAllItems()
        appearanceMenuItems.removeAll()
        refreshMenuItems.removeAll()

        let dockItem = settingsMenu.addItem(withTitle: "在程序坞中显示", action: #selector(toggleDockPresence(_:)), keyEquivalent: "")
        dockItem.target = self
        dockItem.state = showsInDock ? .on : .off
        dockMenuItem = dockItem
        settingsMenu.addItem(.separator())

        let appearanceItem = NSMenuItem(title: "外观", action: nil, keyEquivalent: "")
        let appearanceMenu = NSMenu(title: "外观")
        for mode in AppearanceMode.allCases {
            let item = appearanceMenu.addItem(withTitle: mode.title, action: #selector(chooseAppearance(_:)), keyEquivalent: "")
            item.target = self
            item.tag = mode.rawValue
            item.state = mode == appearanceMode ? .on : .off
            appearanceMenuItems[mode] = item
        }
        appearanceItem.submenu = appearanceMenu
        settingsMenu.addItem(appearanceItem)

        let refreshItem = NSMenuItem(title: "实时刷新", action: nil, keyEquivalent: "")
        let refreshMenu = NSMenu(title: "实时刷新")
        for seconds in [1, 2, 5] {
            let item = refreshMenu.addItem(withTitle: "\(seconds) 秒", action: #selector(chooseLiveRefreshMenu(_:)), keyEquivalent: "")
            item.target = self
            item.tag = seconds
            item.state = seconds == livePresentation.refreshSeconds ? .on : .off
            refreshMenuItems[seconds] = item
        }
        refreshItem.submenu = refreshMenu
        settingsMenu.addItem(refreshItem)
    }

    private func configureWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1152, height: 756),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Codex Token Atlas"
        window.minSize = NSSize(width: 990, height: 612)
        window.center()
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.delegate = self
        window.titlebarAppearsTransparent = true
        window.backgroundColor = AtlasColor.canvas
        window.contentView = NSHostingView(
            rootView: ScaledContent(scale: dashboardRenderScale) {
                AtlasDashboardView(controller: self)
            }
        )

        let toolbar = NSToolbar(identifier: "local.codex.token-atlas.toolbar.v3")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        window.toolbar = toolbar
        toolbar.displayMode = .iconOnly
        window.toolbarStyle = .unifiedCompact
    }

    private func configureLiveMonitor() {
        livePresentation.historicalTotalTokens = historicalTotalTokens
        livePanel = LiveMonitorPanel(contentSize: NSSize(width: 292, height: 246))
        livePanel.contentViewController = NSHostingController(
            rootView: LiveTokenPopover(controller: self, presentation: livePresentation)
        )
        livePanel.pinnedChanged = { [weak self] pinned in
            self?.livePresentation.panelPinned = pinned
        }

        let sessionRoot = homeURL.appendingPathComponent(".codex/sessions", isDirectory: true)
        liveMonitor = LiveTokenMonitor(sessionRoot: sessionRoot) { [weak self] snapshot in
            guard let self else { return }
            self.latestLiveSnapshot = snapshot
            if self.livePanel.isVisible {
                self.livePresentation.snapshot = snapshot
            }
            self.historicalTotalTokens += snapshot.intervalUsage.totalTokens
            self.updateStatusItem(rate: snapshot.totalRate)
        }
        setLiveMonitorEnabled(liveMonitorEnabled, persist: false, ensureReachability: false)
        let historyTimer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            self?.publishHistoricalTotal()
        }
        historyTimer.tolerance = 5
        RunLoop.main.add(historyTimer, forMode: .common)
        historicalDisplayTimer = historyTimer
    }

    private func installStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        guard let button = item.button else { return }
        button.image = nil
        button.imagePosition = .noImage
        button.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        button.target = self
        button.action = #selector(toggleLivePopover(_:))
        button.sendAction(on: [.leftMouseUp])
        button.toolTip = "60 秒平均 Token 速率"
        updateStatusItem(rate: latestLiveSnapshot.totalRate)
    }

    private func updateStatusItem(rate: Double) {
        guard let button = statusItem?.button else { return }
        let value = formatStatusTokenRate(rate)
        guard value != lastStatusRateText else { return }
        lastStatusRateText = value
        button.title = value
        button.setAccessibilityLabel("Token rate \(formatTokenRate(rate)) tokens per second")
    }

    @objc private func toggleLiveMonitor(_ sender: Any?) {
        let enabled = (sender as? NSButton).map { $0.state == .on } ?? !liveMonitorEnabled
        setLiveMonitorEnabled(enabled, persist: true)
    }

    private func setLiveMonitorEnabled(_ enabled: Bool, persist: Bool, ensureReachability: Bool = true) {
        if ensureReachability && !enabled && !showsInDock {
            applyDockPresence(true, persist: true)
        }
        liveMonitorEnabled = enabled
        if persist { UserDefaults.standard.set(enabled, forKey: "liveTokenMonitorEnabledV2") }
        liveToolbarButton?.state = enabled ? .on : .off
        liveToolbarButton?.contentTintColor = enabled ? AtlasColor.teal : .secondaryLabelColor
        liveMenuItem?.state = enabled ? .on : .off
        if enabled {
            installStatusItem()
            liveMonitor.start(interval: TimeInterval(livePresentation.refreshSeconds))
        } else {
            livePanel.dismissAndUnpin()
            liveMonitor.stop()
            latestLiveSnapshot = .zero
            livePresentation.snapshot = .zero
            if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
            statusItem = nil
            lastStatusRateText = nil
        }
    }

    @objc private func toggleLivePopover(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        if livePanel.isVisible, !livePanel.isPinned {
            livePanel.orderOut(nil)
        } else {
            livePresentation.snapshot = latestLiveSnapshot
            livePanel.show(relativeTo: button)
        }
    }

    @objc private func showMainWindowAction(_ sender: Any?) {
        showMainWindow()
    }

    @objc private func toggleDockPresence(_ sender: Any?) {
        applyDockPresence(!showsInDock, persist: true)
    }

    private func applyDockPresence(_ visible: Bool, persist: Bool) {
        if !visible && !liveMonitorEnabled {
            setLiveMonitorEnabled(true, persist: true)
        }
        showsInDock = visible
        dockMenuItem?.state = visible ? .on : .off
        if persist { UserDefaults.standard.set(visible, forKey: showInDockDefaultsKey) }
        NSApp.setActivationPolicy(visible ? .regular : .accessory)
        if visible, window.isVisible {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @objc private func chooseAppearance(_ sender: NSMenuItem) {
        guard let mode = AppearanceMode(rawValue: sender.tag) else { return }
        appearanceMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: appearanceModeDefaultsKey)
        NSApp.appearance = mode.appKitAppearance
        for (candidate, item) in appearanceMenuItems {
            item.state = candidate == mode ? .on : .off
        }
        window.contentView?.needsDisplay = true
        livePanel.contentView?.needsDisplay = true
    }

    @objc private func chooseLiveRefreshMenu(_ sender: NSMenuItem) {
        chooseLiveRefresh(sender.tag)
    }

    @objc private func showSettingsMenu(_ sender: Any?) {
        guard let button = settingsToolbarButton else { return }
        settingsMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: button)
    }

    fileprivate func showMainWindow() {
        if !livePanel.isPinned { livePanel.orderOut(nil) }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func chooseLiveRefresh(_ seconds: Int) {
        guard [1, 2, 5].contains(seconds) else { return }
        livePresentation.refreshSeconds = seconds
        UserDefaults.standard.set(seconds, forKey: liveRefreshDefaultsKey)
        for (candidate, item) in refreshMenuItems {
            item.state = candidate == seconds ? .on : .off
        }
        liveMonitor.setInterval(TimeInterval(seconds))
    }

    private func publishHistoricalTotal() {
        livePresentation.historicalTotalTokens = historicalTotalTokens
        UserDefaults.standard.set(NSNumber(value: historicalTotalTokens), forKey: historicalTotalDefaultsKey)
    }

    fileprivate func closeLivePanel() {
        livePanel.dismissAndUnpin()
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.settings, .refreshReport, .reportStatus, .liveMonitor, .flexibleSpace, .space, .exportReport, .revealExports]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.settings, .refreshReport, .liveMonitor, .flexibleSpace, .exportReport, .revealExports]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch identifier {
        case .settings:
            let image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "设置")
            let button = NSButton(image: image ?? NSImage(), target: self, action: #selector(showSettingsMenu(_:)))
            button.bezelStyle = .toolbar
            button.controlSize = .regular
            button.imagePosition = .imageOnly
            button.toolTip = "设置"
            button.setAccessibilityLabel("设置")
            button.widthAnchor.constraint(equalToConstant: 34).isActive = true
            button.heightAnchor.constraint(equalToConstant: 28).isActive = true
            settingsToolbarButton = button
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = ""
            item.paletteLabel = "设置"
            item.toolTip = "设置"
            item.view = button
            return item
        case .refreshReport:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = ""
            item.paletteLabel = "刷新"
            item.toolTip = "重新扫描本地 Codex 会话 (⌘R)"
            item.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "刷新统计")
            item.target = self
            item.action = #selector(refreshReport(_:))
            refreshToolbarItem = item
            return item
        case .exportReport:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = ""
            item.paletteLabel = "导出"
            item.toolTip = "选择格式和保存位置"
            item.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "导出")
            item.target = self
            item.action = #selector(exportReport(_:))
            return item
        case .liveMonitor:
            let image = NSImage(systemSymbolName: "gauge.with.dots.needle.33percent", accessibilityDescription: "顶部栏 Token 统计")
            let button = NSButton(image: image ?? NSImage(), target: self, action: #selector(toggleLiveMonitor(_:)))
            button.setButtonType(.toggle)
            button.bezelStyle = .toolbar
            button.controlSize = .regular
            button.imagePosition = .imageOnly
            button.state = liveMonitorEnabled ? .on : .off
            button.contentTintColor = liveMonitorEnabled ? AtlasColor.teal : .secondaryLabelColor
            button.toolTip = "显示或隐藏顶部栏 Token 统计"
            button.setAccessibilityLabel("顶部栏 Token 统计")
            button.widthAnchor.constraint(equalToConstant: 34).isActive = true
            button.heightAnchor.constraint(equalToConstant: 28).isActive = true
            liveToolbarButton = button
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = ""
            item.paletteLabel = "顶部栏 Token 统计"
            item.toolTip = "状态栏显示 60 秒实时速率；展开后同时显示历史累计 Token"
            item.view = button
            return item
        case .revealExports:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = ""
            item.paletteLabel = "文件"
            item.toolTip = "显示生成器的中间文件"
            item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "显示文件")
            item.target = self
            item.action = #selector(revealExportFiles(_:))
            return item
        case .reportStatus:
            toolbarSpinner.style = .spinning
            toolbarSpinner.controlSize = .small
            toolbarSpinner.isDisplayedWhenStopped = false
            toolbarStatus.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
            toolbarStatus.textColor = .secondaryLabelColor
            let stack = NSStackView(views: [toolbarSpinner, toolbarStatus])
            stack.orientation = .horizontal
            stack.alignment = .centerY
            stack.spacing = 7
            stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.view = stack
            item.label = ""
            item.paletteLabel = "状态"
            return item
        default:
            return nil
        }
    }

    @objc private func refreshReport(_ sender: Any?) {
        guard !generatorRunning else { return }
        guard let generatorURL = Bundle.main.resourceURL?.appendingPathComponent("codex_token_heatmap.py") else {
            presentError("应用内的统计生成器缺失。")
            return
        }
        guard let pythonURL = locatePython() else {
            presentError("需要 Python 3.9 或更高版本。")
            return
        }

        generatorRunning = true
        setLoading(true, title: "正在刷新 Token 历史", detail: "读取本地 Codex 会话并校正 fork 用量…")
        appendLog("\n[\(timestampLabel())] Native app refresh\nPython: \(pythonURL.path)\n")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let process = Process()
            process.executableURL = pythonURL
            process.arguments = [generatorURL.path]
            process.environment = ProcessInfo.processInfo.environment.merging(["HOME": self.homeURL.path]) { _, new in new }
            let logHandle = self.openLogHandle()
            process.standardOutput = logHandle
            process.standardError = logHandle
            do {
                try process.run()
                process.waitUntilExit()
                logHandle?.closeFile()
                DispatchQueue.main.async {
                    if process.terminationStatus == 0 {
                        self.loadGeneratedReport()
                    } else {
                        self.generatorRunning = false
                        self.setLoading(false, title: "", detail: "")
                        self.presentError("生成报表失败，退出状态为 \(process.terminationStatus)。")
                    }
                }
            } catch {
                logHandle?.closeFile()
                DispatchQueue.main.async {
                    self.generatorRunning = false
                    self.setLoading(false, title: "", detail: "")
                    self.presentError("无法启动统计生成器：\(error.localizedDescription)")
                }
            }
        }
    }

    private func loadGeneratedReport() {
        do {
            let data = try Data(contentsOf: summaryURL)
            let loadedDashboard = try JSONDecoder().decode(ReportEnvelope.self, from: data).dashboard
            dashboard = loadedDashboard
            historicalTotalTokens = max(historicalTotalTokens, loadedDashboard.totals["all"]?.total_tokens ?? 0)
            publishHistoricalTotal()
            synchronizeDateSelection(with: loadedDashboard)
            generatorRunning = false
            setLoading(false, title: "", detail: "")
            toolbarStatus.stringValue = "已更新 \(DateFormatter.shortTime.string(from: Date()))"
            if ProcessInfo.processInfo.environment["TOKEN_ATLAS_SMOKE_TEST"] == "1" {
                do {
                    try runSmokeChecks(loadedDashboard)
                    try Data("ok\n".utf8).write(to: URL(fileURLWithPath: "/tmp/token-atlas-native-smoke-ok"))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
                } catch {
                    try? Data("\(error)\n".utf8).write(to: URL(fileURLWithPath: "/tmp/token-atlas-native-smoke-failed"))
                    appendLog("SMOKE TEST FAILED: \(error)\n")
                    Darwin.exit(2)
                }
            }
        } catch {
            generatorRunning = false
            setLoading(false, title: "", detail: "")
            presentError("原生仪表盘数据载入失败：\(error.localizedDescription)")
        }
    }

    private func runSmokeChecks(_ data: DashboardData) throws {
        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() {
                throw NSError(domain: "CodexTokenAtlasSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
        let savedModel = selectedModel
        let savedMetric = selectedMetric
        let savedPricing = pricingMode
        let savedPreset = datePreset
        let savedStart = selectedStartDate
        let savedEnd = selectedEndDate
        defer {
            selectedModel = savedModel
            selectedMetric = savedMetric
            pricingMode = savedPricing
            datePreset = savedPreset
            selectedStartDate = savedStart
            selectedEndDate = savedEnd
        }

        selectedModel = "all"
        selectedMetric = "total_tokens"
        datePreset = .all
        selectedStartDate = reportDateFormatter.date(from: data.range.start)
        selectedEndDate = selectedStartDate
        synchronizeDateSelection(with: data)
        try require(activeRange(data).end == data.range.end, "all-time preset did not advance to the latest report date")
        let fullUsage = filteredUsage(scope: "all", data: data)
        let expected = data.totals["all"] ?? Usage()
        try require(fullUsage.total_tokens == expected.total_tokens, "full-range daily total differs from report total")
        try require(fullUsage.calls == expected.calls, "full-range daily calls differ from report calls")

        let hourly = filteredHourly(data).0.flatMap { $0 }.reduce(Usage()) { $0.adding($1) }
        try require(hourly.total_tokens == fullUsage.total_tokens, "filtered hourly total differs from daily total")
        try require(hourly.calls == fullUsage.calls, "filtered hourly calls differ from daily calls")

        let routeUsage = data.pricing.routes.map { filteredRoute($0, data: data).0 }.reduce(Usage()) { $0.adding($1) }
        try require(routeUsage.total_tokens == fullUsage.total_tokens, "route total differs from overall total")
        let sessionUsage = data.sessions.map { filteredSessionUsage($0, data: data) }.reduce(Usage()) { $0.adding($1) }
        try require(sessionUsage.total_tokens == fullUsage.total_tokens, "session total differs from overall total")

        let fullCost = filteredCost(scope: "all", data: data)
        let sessionCost = data.sessions.map { filteredSessionCost($0, data: data) }.reduce(Cost()) { $0.adding($1) }
        try require(abs(sessionCost.standard_equivalent_cost_usd - fullCost.standard_equivalent_cost_usd) < 0.000001, "session Standard value differs from overall value")
        try require(abs(sessionCost.estimated_cost_usd - fullCost.estimated_cost_usd) < 0.000001, "session tiered value differs from overall value")
        pricingMode = .simple
        try require(pricingMode.value(fullCost) == fullCost.standard_equivalent_cost_usd, "simple pricing is not Standard")
        pricingMode = .tiered
        try require(pricingMode.value(fullCost) == fullCost.estimated_cost_usd, "tiered pricing is not service-tier value")

        guard let last = reportDateFormatter.date(from: data.range.end), let first = reportDateFormatter.date(from: data.range.start) else {
            throw NSError(domain: "CodexTokenAtlasSmoke", code: 2, userInfo: [NSLocalizedDescriptionKey: "invalid report date range"])
        }
        selectedEndDate = last
        selectedStartDate = max(first, Calendar.current.date(byAdding: .day, value: -6, to: last) ?? first)
        datePreset = .last7
        let last7 = filteredUsage(scope: "all", data: data)
        try require(last7.total_tokens > 0 && last7.total_tokens <= fullUsage.total_tokens, "last-7-days filter is invalid")
        selectedStartDate = last
        let lastDay = filteredUsage(scope: "all", data: data)
        try require(lastDay.total_tokens <= last7.total_tokens, "single-day filter exceeds last 7 days")

        let exportDirectory = URL(fileURLWithPath: "/tmp/token-atlas-native-export-smoke", isDirectory: true)
        try? fileManager.removeItem(at: exportDirectory)
        try fileManager.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
        for format in ExportFormat.allCases where format != .all {
            let destination = exportDirectory.appendingPathComponent(format.fileName)
            try performExport(format, to: destination)
            let attributes = try fileManager.attributesOfItem(atPath: destination.path)
            try require((attributes[.size] as? NSNumber)?.intValue ?? 0 > 0, "empty \(format.title) export")
        }
        let sessionExport = try String(contentsOf: exportDirectory.appendingPathComponent(ExportFormat.session.fileName), encoding: .utf8)
        try require(sessionExport.contains("standard_value_usd") && sessionExport.contains("tiered_value_usd"), "session export lacks official values")
        let jsonData = try Data(contentsOf: exportDirectory.appendingPathComponent(ExportFormat.json.fileName))
        let json = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
        try require(json?["date_range"] != nil, "selection JSON lacks date range")
        try? fileManager.removeItem(at: exportDirectory)

        let liveLine = Data(#"{"timestamp":"2026-07-30T00:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":900,"cached_input_tokens":500,"output_tokens":100,"total_tokens":1000},"last_token_usage":{"input_tokens":90,"cached_input_tokens":50,"output_tokens":10,"total_tokens":100},"model_context_window":258400}}}"#.utf8)
        let liveEvent = LiveTokenMonitor.parseTokenCountLine(liveLine)
        try require(liveEvent?.usage == LiveTokenUsage(inputTokens: 90, cachedInputTokens: 50, outputTokens: 10, totalTokens: 100), "live token parser rejected valid last usage")
        try require(LiveTokenMonitor.parseTokenCountLine(Data(#"{"type":"event_msg","payload":{"type":"agent_message"}}"#.utf8)) == nil, "live token parser accepted a non-token event")

        guard let contentView = window.contentView else {
            throw NSError(domain: "CodexTokenAtlasSmoke", code: 2, userInfo: [NSLocalizedDescriptionKey: "window has no content view"])
        }
        let contentViewClass = String(describing: type(of: contentView))
        try require(contentViewClass.contains("NSHostingView"), "window is not backed by native SwiftUI")
    }

    fileprivate func activeRange(_ data: DashboardData) -> (start: String, end: String) {
        let start = selectedStartDate.map { reportDateFormatter.string(from: $0) } ?? data.range.start
        let end = selectedEndDate.map { reportDateFormatter.string(from: $0) } ?? data.range.end
        return (max(data.range.start, min(start, end)), min(data.range.end, max(start, end)))
    }

    fileprivate func isIncluded(_ day: String, in data: DashboardData) -> Bool {
        let range = activeRange(data)
        return day >= range.start && day <= range.end
    }

    fileprivate func filteredUsage(scope: String, data: DashboardData) -> Usage {
        (data.daily[scope] ?? [:]).reduce(Usage()) { result, entry in
            isIncluded(entry.key, in: data) ? result.adding(entry.value) : result
        }
    }

    fileprivate func filteredCost(scope: String, data: DashboardData) -> Cost {
        (data.pricing.daily[scope] ?? [:]).reduce(Cost()) { result, entry in
            isIncluded(entry.key, in: data) ? result.adding(entry.value) : result
        }
    }

    fileprivate func filteredRoute(_ route: PricingRoute, data: DashboardData) -> (Usage, Cost) {
        route.daily.reduce((Usage(), Cost())) { result, entry in
            guard isIncluded(entry.key, in: data) else { return result }
            return (result.0.adding(entry.value.usage), result.1.adding(entry.value.costs))
        }
    }

    fileprivate func filteredSessionUsage(_ session: SessionData, data: DashboardData) -> Usage {
        if selectedModel == "all" {
            return session.by_day.reduce(Usage()) { result, entry in
                isIncluded(entry.key, in: data) ? result.adding(entry.value) : result
            }
        }
        return session.by_day_model.reduce(Usage()) { result, entry in
            guard isIncluded(entry.key, in: data), let usage = entry.value[selectedModel] else { return result }
            return result.adding(usage)
        }
    }

    fileprivate func filteredSessionCost(_ session: SessionData, data: DashboardData) -> Cost {
        if selectedModel == "all" {
            return session.costs_by_day.reduce(Cost()) { result, entry in
                isIncluded(entry.key, in: data) ? result.adding(entry.value) : result
            }
        }
        return session.costs_by_day_model.reduce(Cost()) { result, entry in
            guard isIncluded(entry.key, in: data), let cost = entry.value[selectedModel] else { return result }
            return result.adding(cost)
        }
    }

    fileprivate func filteredHourly(_ data: DashboardData) -> ([[Usage]], [[Cost]]) {
        var usageMatrix = Array(repeating: Array(repeating: Usage(), count: 24), count: 7)
        var costMatrix = Array(repeating: Array(repeating: Cost(), count: 24), count: 7)
        let usageTimeline = data.timeline_hourly[selectedModel] ?? [:]
        let costTimeline = data.pricing.timeline_hourly[selectedModel] ?? [:]
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        for (key, usage) in usageTimeline {
            let day = String(key.prefix(10))
            guard isIncluded(day, in: data), let date = reportDateFormatter.date(from: day), let hour = Int(key.suffix(2)) else { continue }
            let weekday = (calendar.component(.weekday, from: date) + 5) % 7
            usageMatrix[weekday][hour] = usageMatrix[weekday][hour].adding(usage)
            if let cost = costTimeline[key] {
                costMatrix[weekday][hour] = costMatrix[weekday][hour].adding(cost)
            }
        }
        return (usageMatrix, costMatrix)
    }

    private func rebuildDashboard() {
        guard let dashboard else { return }
        let previousOrigin = scrollView.documentView == nil ? NSPoint.zero : scrollView.contentView.bounds.origin
        let document = CanvasView()
        document.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        document.addSubview(stack)
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(greaterThanOrEqualToConstant: 1100),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -28)
        ])

        let views = [
            makeHeader(dashboard),
            makeStats(dashboard),
            makeHourlyPanel(dashboard),
            makeCalendarPanel(dashboard),
            makeModelPanel(dashboard),
            makeSessionPanel(dashboard),
            makePricingPanel(dashboard),
            makeAuditPanel(dashboard),
            makeFooter(dashboard)
        ]
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        scrollView.documentView = document
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let maxY = max(0, document.bounds.height - self.scrollView.contentView.bounds.height)
            self.scrollView.contentView.scroll(to: NSPoint(x: 0, y: min(previousOrigin.y, maxY)))
            self.scrollView.reflectScrolledClipView(self.scrollView.contentView)
        }
    }

    private func makeHeader(_ data: DashboardData) -> NSView {
        let header = SurfaceView(fill: AtlasColor.surface, border: AtlasColor.teal.withAlphaComponent(0.28), radius: 6)
        let eyebrow = makeLabel("LOCAL CODEX TELEMETRY / ASIA SHANGHAI", size: 10, weight: .bold, color: AtlasColor.teal, monospaced: true)
        let title = makeLabel("Token Atlas", size: 48, weight: .bold)
        let range = activeRange(data)
        let metricTitle = MetricOption.all.first(where: { $0.key == selectedMetric })?.title ?? "Total tokens"
        let subtitle = makeLabel("\(range.start) → \(range.end) · \(selectedModel == "all" ? "全部模型" : selectedModel) · \(metricTitle)", size: 13, color: AtlasColor.muted)

        let modelPopup = NSPopUpButton()
        modelPopup.addItem(withTitle: "全部模型")
        data.models.forEach { modelPopup.addItem(withTitle: $0) }
        modelPopup.selectItem(at: selectedModel == "all" ? 0 : (data.models.firstIndex(of: selectedModel).map { $0 + 1 } ?? 0))
        modelPopup.target = self
        modelPopup.action = #selector(modelChanged(_:))
        modelPopup.widthAnchor.constraint(equalToConstant: 210).isActive = true

        let metricPopup = NSPopUpButton()
        MetricOption.all.forEach { metricPopup.addItem(withTitle: $0.title) }
        metricPopup.selectItem(at: MetricOption.all.firstIndex { $0.key == selectedMetric } ?? 0)
        metricPopup.target = self
        metricPopup.action = #selector(metricChanged(_:))
        metricPopup.widthAnchor.constraint(equalToConstant: 190).isActive = true

        let controls = NSStackView(views: [makeControl(label: "模型", control: modelPopup), makeControl(label: "指标", control: metricPopup)])
        controls.orientation = .horizontal
        controls.spacing = 10
        controls.alignment = .centerY

        let stack = NSStackView(views: [eyebrow, title, subtitle, controls])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        header.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: header.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: header.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -24)
        ])
        return header
    }

    private func makeDatePicker(value: Date, identifier: String, data: DashboardData) -> NSDatePicker {
        let picker = NSDatePicker()
        picker.identifier = NSUserInterfaceItemIdentifier(identifier)
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerElements = [.yearMonthDay]
        picker.dateValue = value
        picker.minDate = reportDateFormatter.date(from: data.range.start)
        picker.maxDate = reportDateFormatter.date(from: data.range.end)
        picker.target = self
        picker.action = #selector(dateChanged(_:))
        picker.widthAnchor.constraint(equalToConstant: 126).isActive = true
        return picker
    }

    private func makeControl(label: String, control: NSView) -> NSView {
        let title = makeLabel(label, size: 10, weight: .semibold, color: AtlasColor.muted)
        let stack = NSStackView(views: [title, control])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        let container = SurfaceView(fill: AtlasColor.surface, border: AtlasColor.line, radius: 5)
        control.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
            control.heightAnchor.constraint(greaterThanOrEqualToConstant: 26),
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: 42)
        ])
        return container
    }

    private func makeStats(_ data: DashboardData) -> NSView {
        let usage = filteredUsage(scope: selectedModel, data: data)
        let cacheRatio = usage.input_tokens > 0 ? Double(usage.cached_input_tokens) / Double(usage.input_tokens) * 100 : 0
        let cards = [
            makeMetricCard(title: "Total tokens", value: shortNumber(usage.total_tokens), detail: formatInt(usage.total_tokens), accent: AtlasColor.teal),
            makeMetricCard(title: "Input", value: shortNumber(usage.input_tokens), detail: formatInt(usage.input_tokens), accent: AtlasColor.teal),
            makeMetricCard(title: "Uncached input", value: shortNumber(usage.uncached_input_tokens), detail: "\(shortNumber(usage.cached_input_tokens)) read · \(shortNumber(usage.cache_write_input_tokens)) write", accent: AtlasColor.coral),
            makeMetricCard(title: "Output", value: shortNumber(usage.output_tokens), detail: "\(shortNumber(usage.reasoning_output_tokens)) reasoning", accent: AtlasColor.amber),
            makeMetricCard(title: "Cache ratio", value: String(format: "%.1f%%", cacheRatio), detail: "\(shortNumber(usage.cached_input_tokens)) cached", accent: AtlasColor.teal),
            makeMetricCard(title: "Unique calls", value: shortNumber(usage.calls), detail: "\(shortNumber(usage.unclassified_tokens)) unclassified", accent: AtlasColor.coral)
        ]
        let stack = NSStackView(views: cards)
        stack.orientation = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 10
        return stack
    }

    private func makeHourlyPanel(_ data: DashboardData) -> NSView {
        let heatmap = HourHeatmapView()
        let filtered = filteredHourly(data)
        heatmap.usage = filtered.0
        heatmap.costs = filtered.1
        heatmap.metricKey = selectedMetric
        heatmap.pricingMode = pricingMode
        heatmap.modelLabel = selectedModel == "all" ? "全部模型" : selectedModel
        heatmap.heightAnchor.constraint(equalToConstant: 300).isActive = true
        return makePanel(title: "一周 × 24 小时", subtitle: "按星期与本地小时聚合；悬停显示当前计价模式的金额。", content: heatmap, trailing: "CONTINUOUS POWER SCALE · P98")
    }

    private func makeCalendarPanel(_ data: DashboardData) -> NSView {
        let calendar = CalendarHeatmapView()
        calendar.usage = data.daily[selectedModel] ?? [:]
        calendar.costs = data.pricing.daily[selectedModel] ?? [:]
        let range = activeRange(data)
        calendar.start = range.start
        calendar.end = range.end
        calendar.metricKey = selectedMetric
        calendar.pricingMode = pricingMode
        calendar.modelLabel = selectedModel == "all" ? "全部模型" : selectedModel
        calendar.heightAnchor.constraint(equalToConstant: 230).isActive = true
        return makePanel(title: "每日历史", subtitle: "连续色阶展示每天的历史调用。", content: calendar, trailing: "LOCAL DATE")
    }

    private func makeModelPanel(_ data: DashboardData) -> NSView {
        let overall = max(Int64(1), filteredUsage(scope: "all", data: data).total_tokens)
        let modelRows = data.models.map { model -> [String] in
            let usage = filteredUsage(scope: model, data: data)
            let share = Double(usage.total_tokens) / Double(overall) * 100
            let cache = usage.input_tokens > 0 ? Double(usage.cached_input_tokens) / Double(usage.input_tokens) * 100 : 0
            return [model, shortNumber(usage.total_tokens), String(format: "%.1f%%", share), formatInt(usage.calls), String(format: "%.1f%%", cache)]
        }
        let table = makeTable(headers: ["MODEL", "TOTAL", "SHARE", "CALLS", "CACHE"], rows: modelRows, widths: [250, 170, 120, 130, 120])

        let daily = data.daily[selectedModel] ?? [:]
        let dayRows = daily.map { key, value in (key, value) }
            .filter { isIncluded($0.0, in: data) && $0.1.value(for: selectedMetric) > 0 }
            .sorted { $0.1.value(for: selectedMetric) > $1.1.value(for: selectedMetric) }
            .prefix(10)
            .map { [$0.0, formatInt($0.1.value(for: selectedMetric)), shortNumber($0.1.total_tokens), formatInt($0.1.calls)] }
        let daysTable = makeTable(headers: ["DATE", "METRIC", "TOTAL", "CALLS"], rows: dayRows, widths: [180, 180, 160, 130], maxRows: 10)
        let modelsPanel = makePanel(title: "模型分布", subtitle: "模型按调用发生时的 turn context 归属。", content: table)
        let daysPanel = makePanel(title: "高用量日期", subtitle: "当前模型与指标筛选。", content: daysTable)
        let row = NSStackView(views: [modelsPanel, daysPanel])
        row.orientation = .horizontal
        row.distribution = .fillEqually
        row.spacing = 14
        return row
    }

    private func makeSessionPanel(_ data: DashboardData) -> NSView {
        let rows = data.sessions.compactMap { session -> (SessionData, Usage)? in
            let usage = filteredSessionUsage(session, data: data)
            guard usage.value(for: selectedMetric) > 0 else { return nil }
            return (session, usage)
        }
        .sorted { $0.1.value(for: selectedMetric) > $1.1.value(for: selectedMetric) }
        .prefix(30)
        .map { session, usage -> [String] in
            let models = session.by_model.keys.sorted().joined(separator: " · ")
            let providers = session.by_provider.keys.sorted().joined(separator: " · ")
            let tiers = session.by_service_tier.keys.sorted().map { $0 == "priority" ? "priority / fast" : $0 }.joined(separator: " · ")
            let branch = session.parent_id.isEmpty ? "root" : "fork +\(session.lineage_depth)\n\(session.inherited_events) inherited skipped"
            return ["\(session.title)\n\(session.id)", models, "\(providers)\n\(tiers)", formatInt(usage.value(for: selectedMetric)), formatInt(usage.calls), branch]
        }
        let table = makeTable(headers: ["SESSION", "MODELS", "ROUTING", "METRIC", "CALLS", "BRANCH"], rows: rows, widths: [430, 190, 190, 150, 100, 150])
        return makePanel(title: "会话用量", subtitle: "fork 会话仅显示分叉后新增的独占用量。", content: table, trailing: "TOP 30")
    }

    private func makePricingPanel(_ data: DashboardData) -> NSView {
        let cost = filteredCost(scope: selectedModel, data: data)
        let coverageBase = cost.priced_tokens + cost.unpriced_tokens
        let coverage = coverageBase > 0 ? Double(cost.priced_tokens) / Double(coverageBase) * 100 : 0
        let selectedValue = pricingMode.value(cost)
        let premium = pricingMode == .tiered ? cost.service_tier_premium_usd : 0
        let cards = NSStackView(views: [
            makeMetricCard(title: pricingMode == .simple ? "Simple official value" : "Tiered official value", value: formatUSD(selectedValue), detail: String(format: "%.1f%% categorized tokens priced", coverage), accent: AtlasColor.teal),
            makeMetricCard(title: "Standard baseline", value: formatUSD(cost.standard_equivalent_cost_usd), detail: "\(formatInt(cost.default_tier_calls)) default · \(formatInt(cost.long_context_calls)) long context", accent: AtlasColor.teal),
            makeMetricCard(title: "Tier premium", value: formatUSD(premium), detail: pricingMode == .tiered ? "\(formatInt(cost.priority_tier_calls)) fast / priority calls" : "简单计价不应用 Fast 溢价", accent: AtlasColor.coral),
            makeMetricCard(title: "Cache savings", value: formatUSD(cost.cache_savings_usd), detail: "\(formatUSD(cost.cached_input_cost_usd)) read · \(formatUSD(cost.cache_write_input_cost_usd)) write", accent: AtlasColor.amber)
        ])
        cards.orientation = .horizontal
        cards.distribution = .fillEqually
        cards.spacing = 10

        let pricingControl = NSSegmentedControl(labels: [PricingMode.simple.title, PricingMode.tiered.title], trackingMode: .selectOne, target: self, action: #selector(pricingModeChanged(_:)))
        pricingControl.selectedSegment = pricingMode.rawValue
        pricingControl.segmentStyle = .rounded
        pricingControl.setToolTip("全部调用按官方 Standard 价计算", forSegment: 0)
        pricingControl.setToolTip("Default 使用 Standard；Fast/Priority 使用官方 Priority 价", forSegment: 1)
        pricingControl.widthAnchor.constraint(equalToConstant: 300).isActive = true
        let dateSegments = NSSegmentedControl(labels: ["全部", "近 7 天", "近 30 天", "自定义"], trackingMode: .selectOne, target: self, action: #selector(datePresetChanged(_:)))
        dateSegments.selectedSegment = datePreset.rawValue
        dateSegments.segmentStyle = .rounded
        dateSegments.widthAnchor.constraint(equalToConstant: 270).isActive = true
        let startPicker = makeDatePicker(value: selectedStartDate ?? reportDateFormatter.date(from: data.range.start)!, identifier: "startDate", data: data)
        let endPicker = makeDatePicker(value: selectedEndDate ?? reportDateFormatter.date(from: data.range.end)!, identifier: "endDate", data: data)
        let selectionControls = NSStackView(views: [
            makeControl(label: "计价", control: pricingControl),
            makeControl(label: "周期", control: dateSegments),
            makeControl(label: "起始", control: startPicker),
            makeControl(label: "结束", control: endPicker)
        ])
        selectionControls.orientation = .horizontal
        selectionControls.alignment = .centerY
        selectionControls.spacing = 10

        let routes = data.pricing.routes
            .filter { selectedModel == "all" || $0.model == selectedModel }
            .compactMap { route -> [String]? in
                let filtered = filteredRoute(route, data: data)
                guard filtered.0.calls > 0 else { return nil }
                let tier = route.service_tier == "priority" ? "priority / fast" : route.service_tier
                let pricedAs = route.pricing_model.map { "\(route.pricing_provider ?? "") / \($0)" } ?? "Not priced"
                return [
                    route.route_provider,
                    route.model,
                    tier,
                    pricedAs,
                    formatUSD(pricingMode.value(filtered.1)),
                    route.rates?.input.map(formatUSD) ?? "—",
                    route.rates?.cached_input.map(formatUSD) ?? "—",
                    route.rates?.output.map(formatUSD) ?? "—",
                    formatInt(filtered.0.calls),
                    shortNumber(filtered.1.unpriced_tokens)
                ]
            }
        let table = makeTable(headers: ["PROVIDER", "MODEL", "TIER", "PRICED AS", "VALUE", "INPUT", "CACHE", "OUTPUT", "CALLS", "UNPRICED"], rows: routes, widths: [120, 160, 150, 220, 130, 90, 90, 90, 90, 110])
        let method = makeLabel(
            pricingMode == .simple
                ? "简单计价：所有可分类 token 均按对应模型官方 Standard API 价格估算，不区分日志中的 Default/Fast。"
                : "分层计价：Default 使用官方 Standard；Fast/Priority 使用官方 Priority。无对应 Priority 价格时回退 Standard 并计入审计。",
            size: 11,
            color: AtlasColor.muted,
            selectable: true,
            lines: 3
        )
        let content = NSStackView(views: [selectionControls, cards, table, method])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 14
        selectionControls.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor).isActive = true
        cards.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        table.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        method.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        return makePanel(title: "官方 API 等价价值", subtitle: "只使用官方渠道价格，不计算中转站账单或 ChatGPT 订阅账单。", content: content, trailing: "RATES · \(data.pricing.as_of)")
    }

    private func makeAuditPanel(_ data: DashboardData) -> NSView {
        let audit = data.audit
        let cost = data.pricing.scopes["all"] ?? Cost()
        let entries: [(String, Int64)] = [
            ("Session files", Int64(audit.session_files)), ("Fork sessions", Int64(audit.fork_sessions)), ("Raw events", Int64(audit.raw_token_events)),
            ("Unique calls", Int64(audit.unique_model_calls)), ("Fork history skipped", Int64(audit.inherited_events)), ("Local duplicates", Int64(audit.local_duplicate_events)),
            ("Null usage", Int64(audit.null_usage_events)), ("Delta fallbacks", Int64(audit.fallback_delta_events)), ("Model fallbacks", Int64(audit.fallback_model_events)),
            ("Provider fallbacks", Int64(audit.fallback_provider_events)), ("Tier fallbacks", Int64(audit.fallback_service_tier_events)), ("Priority calls", cost.priority_tier_calls),
            ("Tier price fallbacks", cost.tier_rate_fallback_calls), ("Total repairs", Int64(audit.repaired_total_events)), ("Missing timestamps", Int64(audit.missing_timestamp_events)),
            ("Pricing config errors", Int64(audit.pricing_config_errors)), ("Cache writes", data.totals["all"]?.cache_write_input_tokens ?? 0), ("Unclassified", data.totals["all"]?.unclassified_tokens ?? 0)
        ]
        var rows: [[NSView]] = []
        for row in stride(from: 0, to: entries.count, by: 6) {
            rows.append(entries[row..<min(row + 6, entries.count)].map { makeMetricCard(title: $0.0, value: shortNumber($0.1), detail: formatInt($0.1), accent: AtlasColor.line) })
        }
        let grid = NSGridView(views: rows)
        grid.columnSpacing = 8
        grid.rowSpacing = 8
        grid.xPlacement = .fill
        for column in 0..<6 { grid.column(at: column).width = 170 }
        return makePanel(title: "统计审计", subtitle: "异常、fallback 与去重结果保留在此处。", content: grid)
    }

    private func makeFooter(_ data: DashboardData) -> NSView {
        let left = makeLabel("Generated \(data.generated_at_label) · \(data.timezone)", size: 10, color: AtlasColor.muted, selectable: true, monospaced: true)
        let right = makeLabel("Native AppKit · JSON / HTML / CSV export", size: 10, color: AtlasColor.muted, monospaced: true)
        let stack = NSStackView(views: [left, right])
        stack.orientation = .horizontal
        stack.distribution = .fill
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        return stack
    }

    @objc private func modelChanged(_ sender: NSPopUpButton) {
        selectedModel = sender.indexOfSelectedItem == 0 ? "all" : (sender.titleOfSelectedItem ?? "all")
        rebuildDashboard()
    }

    @objc private func metricChanged(_ sender: NSPopUpButton) {
        selectedMetric = MetricOption.all[sender.indexOfSelectedItem].key
        rebuildDashboard()
    }

    @objc private func pricingModeChanged(_ sender: NSSegmentedControl) {
        choosePricingMode(PricingMode(rawValue: sender.selectedSegment) ?? .simple)
    }

    @objc private func datePresetChanged(_ sender: NSSegmentedControl) {
        applyDatePreset(DatePreset(rawValue: sender.selectedSegment) ?? .all)
    }

    fileprivate func choosePricingMode(_ mode: PricingMode) {
        pricingMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "pricingMode")
    }

    fileprivate func applyDatePreset(_ preset: DatePreset) {
        guard let data = dashboard else { return }
        datePreset = preset
        synchronizeDateSelection(with: data)
    }

    private func synchronizeDateSelection(with data: DashboardData) {
        guard let first = reportDateFormatter.date(from: data.range.start), let last = reportDateFormatter.date(from: data.range.end) else { return }
        switch datePreset {
        case .all:
            selectedStartDate = first
            selectedEndDate = last
        case .last7:
            selectedStartDate = max(first, Calendar.current.date(byAdding: .day, value: -6, to: last) ?? first)
            selectedEndDate = last
        case .last30:
            selectedStartDate = max(first, Calendar.current.date(byAdding: .day, value: -29, to: last) ?? first)
            selectedEndDate = last
        case .custom:
            selectedStartDate = min(max(selectedStartDate ?? first, first), last)
            selectedEndDate = min(max(selectedEndDate ?? last, first), last)
            if let start = selectedStartDate, let end = selectedEndDate, start > end {
                selectedStartDate = end
            }
        }
    }

    @objc private func dateChanged(_ sender: NSDatePicker) {
        updateDate(sender.dateValue, isStart: sender.identifier?.rawValue == "startDate")
    }

    fileprivate func updateDate(_ value: Date, isStart: Bool) {
        datePreset = .custom
        if isStart { selectedStartDate = value }
        else { selectedEndDate = value }
        if let start = selectedStartDate, let end = selectedEndDate, start > end {
            if isStart { selectedEndDate = start }
            else { selectedStartDate = end }
        }
    }

    @objc private func exportReport(_ sender: Any?) {
        guard dashboard != nil else {
            presentError("请先完成一次统计刷新。")
            return
        }
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 28))
        ExportFormat.allCases.forEach { popup.addItem(withTitle: $0.title) }
        let alert = NSAlert()
        alert.messageText = "选择导出形式"
        alert.informativeText = "下一步由系统面板选择文件名和保存目录。"
        alert.accessoryView = popup
        alert.addButton(withTitle: "继续")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self,
                  let format = ExportFormat(rawValue: popup.indexOfSelectedItem) else { return }
            self.chooseExportDestination(for: format)
        }
    }

    private func chooseExportDestination(for format: ExportFormat) {
        if format == .all {
            let panel = NSOpenPanel()
            panel.title = "选择导出目录"
            panel.prompt = "导出到此目录"
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.beginSheetModal(for: window) { [weak self] response in
                guard response == .OK, let directory = panel.url, let self else { return }
                do {
                    for item in ExportFormat.allCases where item != .all {
                        try self.performExport(item, to: directory.appendingPathComponent(item.fileName))
                    }
                    self.toolbarStatus.stringValue = "已导出全部格式"
                    NSWorkspace.shared.activateFileViewerSelecting([directory])
                } catch {
                    self.presentError("导出失败：\(error.localizedDescription)")
                }
            }
            return
        }

        let panel = NSSavePanel()
        panel.title = "导出\(format.title)"
        panel.prompt = "导出"
        panel.nameFieldStringValue = format.fileName
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let destination = panel.url, let self else { return }
            do {
                try self.performExport(format, to: destination)
                self.toolbarStatus.stringValue = "已导出 \(format.title)"
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            } catch {
                self.presentError("导出失败：\(error.localizedDescription)")
            }
        }
    }

    private func performExport(_ format: ExportFormat, to destination: URL) throws {
        guard let data = dashboard else {
            throw NSError(domain: "CodexTokenAtlas", code: 2, userInfo: [NSLocalizedDescriptionKey: "没有可导出的统计数据"])
        }
        if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
        if format == .html {
            guard let source = exportFiles.first(where: { $0.0 == .html })?.1 else { return }
            try fileManager.copyItem(at: source, to: destination)
            return
        }
        switch format {
        case .json:
            let payload = selectedExportPayload(data)
            let output = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try output.write(to: destination)
        case .daily:
            try dailyCSV(data).data(using: .utf8)!.write(to: destination)
        case .hourly:
            try hourlyCSV(data).data(using: .utf8)!.write(to: destination)
        case .model:
            try modelCSV(data).data(using: .utf8)!.write(to: destination)
        case .route:
            try routeCSV(data).data(using: .utf8)!.write(to: destination)
        case .session:
            try sessionCSV(data).data(using: .utf8)!.write(to: destination)
        case .html, .all:
            break
        }
    }

    private func selectedExportPayload(_ data: DashboardData) -> [String: Any] {
        let range = activeRange(data)
        let usage = filteredUsage(scope: selectedModel, data: data)
        let cost = filteredCost(scope: selectedModel, data: data)
        let routes = data.pricing.routes.compactMap { route -> [String: Any]? in
            guard selectedModel == "all" || route.model == selectedModel else { return nil }
            let filtered = filteredRoute(route, data: data)
            guard filtered.0.calls > 0 else { return nil }
            return [
                "route_provider": route.route_provider,
                "model": route.model,
                "service_tier": route.service_tier,
                "usage": usageObject(filtered.0),
                "cost": costObject(filtered.1),
                "selected_value_usd": pricingMode.value(filtered.1)
            ]
        }
        return [
            "generated_at": data.generated_at_label,
            "timezone": data.timezone,
            "date_range": ["start": range.start, "end": range.end],
            "model": selectedModel,
            "metric": selectedMetric,
            "pricing_mode": pricingMode == .simple ? "standard_simple" : "default_fast_tiered",
            "usage": usageObject(usage),
            "cost": costObject(cost),
            "selected_value_usd": pricingMode.value(cost),
            "routes": routes
        ]
    }

    private func usageObject(_ value: Usage) -> [String: Any] {
        [
            "input_tokens": value.input_tokens,
            "cached_input_tokens": value.cached_input_tokens,
            "cache_write_input_tokens": value.cache_write_input_tokens,
            "uncached_input_tokens": value.uncached_input_tokens,
            "output_tokens": value.output_tokens,
            "reasoning_output_tokens": value.reasoning_output_tokens,
            "unclassified_tokens": value.unclassified_tokens,
            "total_tokens": value.total_tokens,
            "calls": value.calls
        ]
    }

    private func costObject(_ value: Cost) -> [String: Any] {
        [
            "estimated_cost_usd": value.estimated_cost_usd,
            "standard_equivalent_cost_usd": value.standard_equivalent_cost_usd,
            "service_tier_premium_usd": value.service_tier_premium_usd,
            "cache_savings_usd": value.cache_savings_usd,
            "priced_tokens": value.priced_tokens,
            "unpriced_tokens": value.unpriced_tokens,
            "default_tier_calls": value.default_tier_calls,
            "priority_tier_calls": value.priority_tier_calls
        ]
    }

    private func csv(_ rows: [[String]]) -> String {
        rows.map { row in
            row.map { value in
                let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
                return "\"\(escaped)\""
            }.joined(separator: ",")
        }.joined(separator: "\n") + "\n"
    }

    private func usageCells(_ value: Usage) -> [String] {
        [value.input_tokens, value.cached_input_tokens, value.cache_write_input_tokens, value.uncached_input_tokens, value.output_tokens, value.reasoning_output_tokens, value.unclassified_tokens, value.total_tokens, value.calls].map(String.init)
    }

    private var usageHeaders: [String] {
        ["input_tokens", "cached_input_tokens", "cache_write_input_tokens", "uncached_input_tokens", "output_tokens", "reasoning_output_tokens", "unclassified_tokens", "total_tokens", "calls"]
    }

    private func costCells(_ value: Cost) -> [String] {
        [value.estimated_cost_usd, value.standard_equivalent_cost_usd, value.service_tier_premium_usd, pricingMode.value(value)].map { String(format: "%.6f", $0) } + [String(value.priced_tokens), String(value.unpriced_tokens)]
    }

    private var costHeaders: [String] {
        ["tiered_value_usd", "standard_value_usd", "tier_premium_usd", "selected_value_usd", "priced_tokens", "unpriced_tokens"]
    }

    private func dailyCSV(_ data: DashboardData) -> String {
        var rows = [["date", "model", "pricing_mode"] + usageHeaders + costHeaders]
        let usageDays = data.daily[selectedModel] ?? [:]
        let costDays = data.pricing.daily[selectedModel] ?? [:]
        for day in usageDays.keys.sorted() where isIncluded(day, in: data) {
            rows.append([day, selectedModel, pricingMode == .simple ? "simple" : "tiered"] + usageCells(usageDays[day] ?? Usage()) + costCells(costDays[day] ?? Cost()))
        }
        return csv(rows)
    }

    private func hourlyCSV(_ data: DashboardData) -> String {
        var rows = [["local_hour", "model", "pricing_mode"] + usageHeaders + costHeaders]
        let timeline = data.timeline_hourly[selectedModel] ?? [:]
        let costTimeline = data.pricing.timeline_hourly[selectedModel] ?? [:]
        for hour in timeline.keys.sorted() where isIncluded(String(hour.prefix(10)), in: data) {
            rows.append([hour, selectedModel, pricingMode == .simple ? "simple" : "tiered"] + usageCells(timeline[hour] ?? Usage()) + costCells(costTimeline[hour] ?? Cost()))
        }
        return csv(rows)
    }

    private func modelCSV(_ data: DashboardData) -> String {
        var rows = [["model", "pricing_mode"] + usageHeaders + costHeaders]
        for model in data.models {
            let usage = filteredUsage(scope: model, data: data)
            guard usage.calls > 0 else { continue }
            rows.append([model, pricingMode == .simple ? "simple" : "tiered"] + usageCells(usage) + costCells(filteredCost(scope: model, data: data)))
        }
        return csv(rows)
    }

    private func routeCSV(_ data: DashboardData) -> String {
        var rows = [["route_provider", "model", "service_tier", "pricing_provider", "pricing_model", "pricing_mode"] + usageHeaders + costHeaders]
        for route in data.pricing.routes where selectedModel == "all" || route.model == selectedModel {
            let filtered = filteredRoute(route, data: data)
            guard filtered.0.calls > 0 else { continue }
            rows.append([route.route_provider, route.model, route.service_tier, route.pricing_provider ?? "", route.pricing_model ?? "", pricingMode == .simple ? "simple" : "tiered"] + usageCells(filtered.0) + costCells(filtered.1))
        }
        return csv(rows)
    }

    private func sessionCSV(_ data: DashboardData) -> String {
        var rows = [["session_id", "title", "branch", "models", "providers", "service_tiers", "pricing_mode"] + usageHeaders + costHeaders]
        for session in data.sessions {
            let usage = filteredSessionUsage(session, data: data)
            guard usage.calls > 0 else { continue }
            let cost = filteredSessionCost(session, data: data)
            rows.append([session.id, session.title, session.parent_id.isEmpty ? "root" : "fork +\(session.lineage_depth)", session.by_model.keys.sorted().joined(separator: ";"), session.by_provider.keys.sorted().joined(separator: ";"), session.by_service_tier.keys.sorted().joined(separator: ";"), pricingMode == .simple ? "simple" : "tiered"] + usageCells(usage) + costCells(cost))
        }
        return csv(rows)
    }

    private func copyExport(from source: URL, to destination: URL) throws {
        guard fileManager.fileExists(atPath: source.path) else {
            throw NSError(domain: "CodexTokenAtlas", code: 1, userInfo: [NSLocalizedDescriptionKey: "找不到 \(source.lastPathComponent)"])
        }
        if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
        try fileManager.copyItem(at: source, to: destination)
    }

    @objc private func revealExportFiles(_ sender: Any?) {
        let existing = exportFiles.map(\.1).filter { fileManager.fileExists(atPath: $0.path) }
        if existing.isEmpty { presentError("当前还没有可显示的中间文件。") }
        else { NSWorkspace.shared.activateFileViewerSelecting(existing) }
    }

    private func setLoading(_ loading: Bool, title: String, detail: String) {
        refreshToolbarItem?.isEnabled = !loading
        generatorRunning = loading
        if loading {
            loadingTitleText = title
            loadingDetailText = detail
            toolbarSpinner.startAnimation(nil)
            toolbarStatus.stringValue = title
        } else {
            toolbarSpinner.stopAnimation(nil)
        }
    }

    private func locatePython() -> URL? {
        ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
            .first(where: { fileManager.isExecutableFile(atPath: $0) })
            .map(URL.init(fileURLWithPath:))
    }

    private func presentError(_ message: String) {
        toolbarStatus.stringValue = "操作失败"
        appendLog("ERROR: \(message)\n")
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Codex Token Atlas"
        alert.informativeText = "\(message)\n\n详细日志：\(logURL.path)"
        alert.addButton(withTitle: "好")
        alert.addButton(withTitle: "显示日志")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertSecondButtonReturn, let self {
                NSWorkspace.shared.activateFileViewerSelecting([self.logURL])
            }
        }
    }

    private func openLogHandle() -> FileHandle? {
        try? fileManager.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: logURL.path) { fileManager.createFile(atPath: logURL.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: logURL) else { return nil }
        handle.seekToEndOfFile()
        return handle
    }

    private func appendLog(_ text: String) {
        guard let data = text.data(using: .utf8), let handle = openLogHandle() else { return }
        handle.write(data)
        handle.closeFile()
    }

    private func timestampLabel() -> String { DateFormatter.logTimestamp.string(from: Date()) }
}

private extension DateFormatter {
    static let shortTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    static let logTimestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss zzz"
        return formatter
    }()
}

private extension NumberFormatter {
    static let integer: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    static let currency: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter
    }()
}

private struct LiveTokenPopover: View {
    let controller: AppDelegate
    @ObservedObject var presentation: LiveMonitorPresentation

    private var snapshot: LiveTokenSnapshot { presentation.snapshot }
    private var isActive: Bool {
        snapshot.lastEventAt.map { Date().timeIntervalSince($0) <= LiveTokenSnapshot.windowSeconds } ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            historySummary
            rateHeader
            LiveRateChart(samples: snapshot.samples)
                .frame(height: 38)
            rateBreakdown
            Divider().opacity(0.55)
            statusLine
        }
        .padding(14)
        .frame(width: 284, height: 238)
        .atlasGlass(
            in: RoundedRectangle(cornerRadius: 18, style: .continuous),
            tint: Color(nsColor: AtlasColor.teal).opacity(0.012),
            clear: true
        )
        .padding(4)
    }

    private var historySummary: some View {
        HStack(alignment: .lastTextBaseline, spacing: 8) {
            Text("累计 Tokens")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color(nsColor: AtlasColor.muted))
            Spacer()
            Text(shortNumber(presentation.historicalTotalTokens))
                .font(.system(size: 18, weight: .bold, design: .monospaced))
                .foregroundStyle(Color(nsColor: AtlasColor.ink))
                .help(formatInt(presentation.historicalTotalTokens))
        }
    }

    private var rateHeader: some View {
        HStack(alignment: .lastTextBaseline, spacing: 8) {
            Text(formatTokenRate(snapshot.totalRate))
                .font(.system(size: 32, weight: .bold, design: .monospaced))
                .foregroundStyle(Color(nsColor: AtlasColor.ink))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text("Tokens")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(nsColor: AtlasColor.teal))
            Spacer(minLength: 4)
            Text(isActive ? "ACTIVE" : "IDLE")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(Color(nsColor: isActive ? AtlasColor.tealDeep : AtlasColor.muted))
            LiveIconButton(symbol: "macwindow", help: "打开 Token Atlas") {
                controller.showMainWindow()
            }
            if presentation.panelPinned {
                LiveIconButton(symbol: "xmark", help: "关闭常驻窗口") {
                    controller.closeLivePanel()
                }
            }
        }
    }

    private var rateBreakdown: some View {
        HStack(spacing: 0) {
            LiveRateMetric(label: "INPUT", value: snapshot.inputRate, accent: AtlasColor.teal)
            Divider().frame(height: 34).opacity(0.55)
            LiveRateMetric(label: "CACHE", value: snapshot.cachedRate, accent: AtlasColor.coral)
            Divider().frame(height: 34).opacity(0.55)
            LiveRateMetric(label: "OUTPUT", value: snapshot.outputRate, accent: AtlasColor.amber)
        }
        .padding(.vertical, 4)
    }

    private var statusLine: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(nsColor: AtlasColor.teal))
            Text("\(snapshot.monitoredFiles) · \(String(format: "%.1fms", snapshot.pollDurationMilliseconds))")
            Spacer()
            Text("60s \(shortNumber(snapshot.windowUsage.totalTokens))")
            Text("·")
            Text(lastEventLabel)
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .foregroundStyle(Color(nsColor: AtlasColor.muted))
        .lineLimit(1)
    }

    private var lastEventLabel: String {
        guard let date = snapshot.lastEventAt else { return "NO EVENT" }
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        return seconds < 60 ? "EVENT \(seconds)s" : "EVENT \(seconds / 60)m"
    }
}

private struct LiveIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(nsColor: AtlasColor.inkSoft))
                .frame(width: 24, height: 24)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .atlasGlass(in: Circle(), interactive: true)
        .help(help)
    }
}

private struct LiveRateMetric: View {
    let label: String
    let value: Double
    let accent: NSColor

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(Color(nsColor: accent))
            Text(formatTokenRate(value))
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color(nsColor: AtlasColor.ink))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
    }
}

private struct LiveRateChart: View {
    let samples: [Double]

    var body: some View {
        Canvas { context, size in
            let values = samples.isEmpty ? [0] : samples
            let maximum = max(1, values.max() ?? 1)
            let step = values.count > 1 ? size.width / CGFloat(values.count - 1) : size.width
            var line = Path()
            for (index, value) in values.enumerated() {
                let x = CGFloat(index) * step
                let y = size.height - CGFloat(value / maximum) * (size.height - 9) - 4
                if index == 0 { line.move(to: CGPoint(x: x, y: y)) }
                else { line.addLine(to: CGPoint(x: x, y: y)) }
            }

            var fill = line
            fill.addLine(to: CGPoint(x: size.width, y: size.height))
            fill.addLine(to: CGPoint(x: 0, y: size.height))
            fill.closeSubpath()
            context.fill(fill, with: .color(Color(nsColor: AtlasColor.teal).opacity(0.10)))
            context.stroke(line, with: .color(Color(nsColor: AtlasColor.teal)), lineWidth: 1.8)

            var guides = Path()
            for fraction in [CGFloat(0), 0.5, 1] {
                let y = fraction * size.height
                guides.move(to: CGPoint(x: 0, y: y))
                guides.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(guides, with: .color(Color(nsColor: AtlasColor.line).opacity(0.7)), style: StrokeStyle(lineWidth: 0.5, dash: [3, 4]))
        }
    }
}

private struct AtlasDashboardView: View {
    @ObservedObject var controller: AppDelegate

    var body: some View {
        ZStack {
            AtlasGridBackground()
            if let data = controller.dashboard {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        VStack(spacing: 14) {
                            Color.clear
                                .frame(height: 0)
                                .id("dashboard-top")
                            hero(data)
                            stats(data)
                            AtlasPanel(title: "一周 × 24 小时", subtitle: "按星期与本地小时聚合；悬停显示 token、calls 与当前计价金额。", trailing: hourlyScaleNote(data)) {
                                HourlyHeatmap(data: data, controller: controller)
                            }
                            AtlasPanel(title: "每日历史", subtitle: "按本地日期排列；同样使用连续色阶，可随模型、指标与周期筛选。", trailing: dailyScaleNote(data)) {
                                DailyHeatmap(data: data, controller: controller)
                            }
                            HStack(alignment: .top, spacing: 0) {
                                AtlasPanel(title: "模型分布", subtitle: "模型按调用发生时的上下文归属。") {
                                    modelTable(data)
                                }
                                Divider()
                                    .padding(.vertical, 24)
                                AtlasPanel(title: "高用量日期", subtitle: "当前模型、指标与周期筛选。") {
                                    topDaysTable(data)
                                }
                            }
                            sessionPanel(data)
                            pricingPanel(data)
                            auditPanel(data)
                            HStack {
                                Text("Generated \(data.generated_at_label) · \(data.timezone)")
                                Spacer()
                            }
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Color(nsColor: AtlasColor.muted))
                            .padding(.horizontal, 4)
                        }
                        .frame(minWidth: 1040, maxWidth: 1420)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 20)
                        .padding(.top, 24)
                        .padding(.bottom, 50)
                    }
                    .onAppear {
                        DispatchQueue.main.async {
                            proxy.scrollTo("dashboard-top", anchor: .top)
                        }
                    }
                }
                .id(data.generated_at_label)
            }
            if controller.generatorRunning {
                loadingOverlay
            }
        }
        .background(Color(nsColor: AtlasColor.canvas))
    }

    private var loadingOverlay: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            VStack(spacing: 11) {
                ProgressView().controlSize(.regular)
                Text(controller.loadingTitleText).font(.system(size: 18, weight: .semibold))
                Text(controller.loadingDetailText).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .ignoresSafeArea()
    }

    private func hero(_ data: DashboardData) -> some View {
        let range = controller.activeRange(data)
        let metric = MetricOption.all.first(where: { $0.key == controller.selectedMetric })?.title ?? "Total tokens"
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Token Atlas")
                    .font(.custom("Avenir Next", size: 40).weight(.bold))
                    .foregroundStyle(Color(nsColor: AtlasColor.ink))
                Text("\(range.start) → \(range.end) · \(controller.selectedModel == "all" ? "全部模型" : controller.selectedModel) · \(metric)")
                    .font(.system(size: 15))
                    .foregroundStyle(Color(nsColor: AtlasColor.inkSoft))
            }
            HStack(spacing: 10) {
                AtlasControl(label: "模型") {
                    AtlasPopup(
                        options: [("all", "全部模型")] + data.models.map { ($0, $0) },
                        selection: Binding(get: { controller.selectedModel }, set: { controller.selectedModel = $0 })
                    )
                    .frame(width: 180, height: 28)
                }
                AtlasControl(label: "指标") {
                    AtlasPopup(
                        options: MetricOption.all.map { ($0.key, $0.title) },
                        selection: Binding(get: { controller.selectedMetric }, set: { controller.selectedMetric = $0 })
                    )
                    .frame(width: 180, height: 28)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .atlasGlass(
                in: RoundedRectangle(cornerRadius: 14, style: .continuous),
                tint: Color(nsColor: AtlasColor.teal).opacity(0.012),
                clear: true
            )
            .padding(.top, 18)
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 12)
    }

    private func hourlyScaleNote(_ data: DashboardData) -> String {
        let values = controller.filteredHourly(data).0.flatMap { $0 }.map { Double($0.value(for: controller.selectedMetric)) }
        return "CONTINUOUS POWER SCALE · P98 CAP \(shortNumber(Int64(percentile(values, fraction: 0.98))))"
    }

    private func dailyScaleNote(_ data: DashboardData) -> String {
        let values = (data.daily[controller.selectedModel] ?? [:])
            .filter { controller.isIncluded($0.key, in: data) }
            .map { Double($0.value.value(for: controller.selectedMetric)) }
        return "CONTINUOUS POWER SCALE · P98 CAP \(shortNumber(Int64(percentile(values, fraction: 0.98))))"
    }

    private func stats(_ data: DashboardData) -> some View {
        let usage = controller.filteredUsage(scope: controller.selectedModel, data: data)
        let cacheRate = usage.input_tokens > 0 ? Double(usage.cached_input_tokens) / Double(usage.input_tokens) * 100 : 0
        return HStack(spacing: 0) {
            MetricCard(title: "TOTAL TOKENS", value: shortNumber(usage.total_tokens), detail: formatInt(usage.total_tokens), accent: AtlasColor.teal)
            AtlasMetricDivider()
            MetricCard(title: "INPUT", value: shortNumber(usage.input_tokens), detail: formatInt(usage.input_tokens), accent: AtlasColor.teal)
            AtlasMetricDivider()
            MetricCard(title: "UNCACHED INPUT", value: shortNumber(usage.uncached_input_tokens), detail: "\(shortNumber(usage.cached_input_tokens)) read · \(shortNumber(usage.cache_write_input_tokens)) write", accent: AtlasColor.coral)
            AtlasMetricDivider()
            MetricCard(title: "OUTPUT", value: shortNumber(usage.output_tokens), detail: "\(shortNumber(usage.reasoning_output_tokens)) reasoning", accent: AtlasColor.amber)
            AtlasMetricDivider()
            MetricCard(title: "CACHE RATIO", value: String(format: "%.1f%%", cacheRate), detail: "\(shortNumber(usage.cached_input_tokens)) cached", accent: AtlasColor.teal)
            AtlasMetricDivider()
            MetricCard(title: "UNIQUE CALLS", value: shortNumber(usage.calls), detail: "\(shortNumber(usage.unclassified_tokens)) unclassified", accent: AtlasColor.coral)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .atlasGlass(
            in: RoundedRectangle(cornerRadius: 16, style: .continuous),
            tint: Color(nsColor: AtlasColor.teal).opacity(0.01),
            clear: true
        )
    }

    private func modelTable(_ data: DashboardData) -> some View {
        let overall = max(Int64(1), controller.filteredUsage(scope: "all", data: data).total_tokens)
        let rows = data.models.map { model -> [String] in
            let usage = controller.filteredUsage(scope: model, data: data)
            let share = Double(usage.total_tokens) / Double(overall) * 100
            let cache = usage.input_tokens > 0 ? Double(usage.cached_input_tokens) / Double(usage.input_tokens) * 100 : 0
            return [model, shortNumber(usage.total_tokens), String(format: "%.1f%%", share), formatInt(usage.calls), String(format: "%.1f%%", cache)]
        }
        return AtlasTable(
            headers: ["MODEL", "TOTAL", "SHARE", "CALLS", "CACHE"],
            rows: rows,
            widths: [],
            adaptiveWeights: [2.2, 1, 0.8, 0.9, 0.8]
        )
    }

    private func topDaysTable(_ data: DashboardData) -> some View {
        let rows = (data.daily[controller.selectedModel] ?? [:])
            .filter { controller.isIncluded($0.key, in: data) && $0.value.value(for: controller.selectedMetric) > 0 }
            .sorted { $0.value.value(for: controller.selectedMetric) > $1.value.value(for: controller.selectedMetric) }
            .prefix(10)
            .map { [$0.key, formatInt($0.value.value(for: controller.selectedMetric)), shortNumber($0.value.total_tokens), formatInt($0.value.calls)] }
        return AtlasTable(
            headers: ["DATE", "METRIC", "TOTAL", "CALLS"],
            rows: Array(rows),
            widths: [],
            adaptiveWeights: [1.35, 1.45, 1, 0.75]
        )
    }

    private func sessionPanel(_ data: DashboardData) -> some View {
        let rows = data.sessions.compactMap { session -> (SessionData, Usage, Cost)? in
            let usage = controller.filteredSessionUsage(session, data: data)
            let cost = controller.filteredSessionCost(session, data: data)
            return usage.value(for: controller.selectedMetric) > 0 ? (session, usage, cost) : nil
        }
        .sorted { $0.1.value(for: controller.selectedMetric) > $1.1.value(for: controller.selectedMetric) }
        .prefix(30)
        .map { session, usage, cost in
            [session.title, session.by_model.keys.sorted().joined(separator: " · "), session.by_provider.keys.sorted().joined(separator: " · "), formatInt(usage.value(for: controller.selectedMetric)), formatInt(usage.calls), formatUSD(controller.pricingMode.value(cost)), session.parent_id.isEmpty ? "root" : "fork +\(session.lineage_depth)"]
        }
        return AtlasPanel(title: "会话用量", subtitle: "fork 会话仅显示分叉后新增的独占用量；金额使用当前周期与计价模式。", trailing: "TOP 30") {
            AtlasTable(headers: ["SESSION", "MODELS", "ROUTING", "METRIC", "CALLS", "VALUE", "BRANCH"], rows: Array(rows), widths: [360, 165, 78, 115, 68, 100, 58])
        }
    }

    private func pricingPanel(_ data: DashboardData) -> some View {
        let cost = controller.filteredCost(scope: controller.selectedModel, data: data)
        let coverageBase = cost.priced_tokens + cost.unpriced_tokens
        let coverage = coverageBase > 0 ? Double(cost.priced_tokens) / Double(coverageBase) * 100 : 0
        let routes = data.pricing.routes.compactMap { route -> [String]? in
            guard controller.selectedModel == "all" || route.model == controller.selectedModel else { return nil }
            let filtered = controller.filteredRoute(route, data: data)
            guard filtered.0.calls > 0 else { return nil }
            return [route.route_provider, route.model, route.service_tier == "priority" ? "priority / fast" : route.service_tier, route.pricing_model.map { "\(route.pricing_provider ?? "") / \($0)" } ?? "Not priced", formatUSD(controller.pricingMode.value(filtered.1)), route.rates?.input.map(formatUSD) ?? "—", route.rates?.cached_input.map(formatUSD) ?? "—", route.rates?.output.map(formatUSD) ?? "—", formatInt(filtered.0.calls), shortNumber(filtered.1.unpriced_tokens)]
        }
        return AtlasPanel(title: "官方 API 等价价值", subtitle: "计价和周期在这里选择；全页统计同步更新。", trailing: "OFFICIAL RATES · \(data.pricing.as_of)") {
            VStack(alignment: .leading, spacing: 15) {
                pricingControls(data)
                HStack(spacing: 0) {
                    MetricCard(title: controller.pricingMode == .simple ? "SIMPLE OFFICIAL VALUE" : "TIERED OFFICIAL VALUE", value: formatUSD(controller.pricingMode.value(cost)), detail: String(format: "%.1f%% categorized tokens priced", coverage), accent: AtlasColor.teal)
                    AtlasMetricDivider()
                    MetricCard(title: "STANDARD BASELINE", value: formatUSD(cost.standard_equivalent_cost_usd), detail: "\(formatInt(cost.default_tier_calls)) default · \(formatInt(cost.long_context_calls)) long context", accent: AtlasColor.teal)
                    AtlasMetricDivider()
                    MetricCard(title: "TIER PREMIUM", value: formatUSD(controller.pricingMode == .tiered ? cost.service_tier_premium_usd : 0), detail: controller.pricingMode == .tiered ? "\(formatInt(cost.priority_tier_calls)) fast / priority calls" : "简单计价不应用 Fast 溢价", accent: AtlasColor.coral)
                    AtlasMetricDivider()
                    MetricCard(title: "CACHE SAVINGS", value: formatUSD(cost.cache_savings_usd), detail: "\(formatUSD(cost.cached_input_cost_usd)) read · \(formatUSD(cost.cache_write_input_cost_usd)) write", accent: AtlasColor.amber)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .atlasGlass(
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous),
                    tint: Color(nsColor: AtlasColor.teal).opacity(0.01),
                    clear: true
                )
                AtlasTable(headers: ["PROVIDER", "MODEL", "TIER", "PRICED AS", "VALUE", "INPUT", "CACHE", "OUTPUT", "CALLS", "UNPRICED"], rows: routes, widths: [110, 145, 140, 200, 110, 75, 75, 75, 75, 95])
                Text(controller.pricingMode == .simple
                    ? "简单计价：全部调用按对应模型官方 Standard API 价格估算。"
                    : "分层计价：Default 使用 Standard；Fast/Priority 使用官方 Priority，无对应价格时回退 Standard。日志缺失 tier 的 \(formatInt(Int64(data.audit.fallback_service_tier_events))) 次调用按当前 Codex 配置 \(tierLabel(data.audit.configured_service_tier_fallback)) 推断。")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: AtlasColor.muted))
                    .textSelection(.enabled)
            }
        }
    }

    private func pricingControls(_ data: DashboardData) -> some View {
        let minDate = reportDateFormatter.date(from: data.range.start) ?? Date()
        let maxDate = reportDateFormatter.date(from: data.range.end) ?? Date()
        return HStack(spacing: 12) {
            AtlasControl(label: "计价") {
                AtlasSegmentedControl(
                    items: [(.simple, "简单计价"), (.tiered, "区分 Default / Fast")],
                    selection: Binding(get: { controller.pricingMode }, set: { controller.choosePricingMode($0) })
                )
                .frame(width: 276)
            }
            AtlasControl(label: "周期") {
                AtlasSegmentedControl(
                    items: [(.all, "全部"), (.last7, "近 7 天"), (.last30, "近 30 天"), (.custom, "自定义")],
                    selection: Binding(get: { controller.datePreset }, set: { controller.applyDatePreset($0) })
                )
                .frame(width: 248)
            }
            AtlasControl(label: "起始") {
                AtlasDateControl(
                    selection: Binding(get: { controller.selectedStartDate ?? minDate }, set: { controller.updateDate($0, isStart: true) }),
                    range: minDate...maxDate
                )
                .frame(width: 116, height: 30)
            }
            AtlasControl(label: "结束") {
                AtlasDateControl(
                    selection: Binding(get: { controller.selectedEndDate ?? maxDate }, set: { controller.updateDate($0, isStart: false) }),
                    range: minDate...maxDate
                )
                .frame(width: 116, height: 30)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .atlasGlass(
            in: RoundedRectangle(cornerRadius: 14, style: .continuous),
            tint: Color(nsColor: AtlasColor.teal).opacity(0.012),
            clear: true
        )
    }

    private func auditPanel(_ data: DashboardData) -> some View {
        let audit = data.audit
        let cost = controller.filteredCost(scope: "all", data: data)
        let entries: [(String, Int64)] = [
            ("SESSION FILES", Int64(audit.session_files)), ("FORK SESSIONS", Int64(audit.fork_sessions)), ("RAW EVENTS", Int64(audit.raw_token_events)),
            ("UNIQUE CALLS", Int64(audit.unique_model_calls)), ("FORK SKIPPED", Int64(audit.inherited_events)), ("LOCAL DUPLICATES", Int64(audit.local_duplicate_events)),
            ("NULL USAGE", Int64(audit.null_usage_events)), ("DELTA FALLBACKS", Int64(audit.fallback_delta_events)), ("MODEL FALLBACKS", Int64(audit.fallback_model_events)),
            ("PROVIDER FALLBACKS", Int64(audit.fallback_provider_events)), ("TIER FALLBACKS", Int64(audit.fallback_service_tier_events)), ("PRIORITY CALLS", cost.priority_tier_calls),
            ("PRICE FALLBACKS", cost.tier_rate_fallback_calls), ("TOTAL REPAIRS", Int64(audit.repaired_total_events)), ("MISSING TIME", Int64(audit.missing_timestamp_events)),
            ("CONFIG ERRORS", Int64(audit.pricing_config_errors)), ("CACHE WRITES", controller.filteredUsage(scope: "all", data: data).cache_write_input_tokens), ("UNCLASSIFIED", controller.filteredUsage(scope: "all", data: data).unclassified_tokens)
        ]
        return AtlasPanel(title: "统计审计", subtitle: "异常、fallback 与去重结果。") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 8) {
                ForEach(Array(entries.enumerated()), id: \.offset) { _, item in
                    MetricCard(title: item.0, value: shortNumber(item.1), detail: formatInt(item.1), accent: AtlasColor.line)
                }
            }
        }
    }

    private func tierLabel(_ tier: String?) -> String {
        tier == "priority" ? "Fast / Priority" : (tier ?? "Default")
    }
}

private struct AtlasGridBackground: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(nsColor: AtlasColor.canvas),
                Color(nsColor: AtlasColor.surface).opacity(0.64),
                Color(nsColor: AtlasColor.canvas)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }
}

private struct AtlasControl<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 9) {
            Text(label)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color(nsColor: AtlasColor.muted))
                .fixedSize(horizontal: true, vertical: false)
            content
        }
        .frame(minHeight: 30)
        .padding(.horizontal, 4)
    }
}

private struct AtlasPopup: NSViewRepresentable {
    let options: [(value: String, title: String)]
    @Binding var selection: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.isBordered = false
        button.controlSize = .regular
        button.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        button.contentTintColor = AtlasColor.ink
        button.target = context.coordinator
        button.action = #selector(Coordinator.changed(_:))
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        let titles = options.map(\.title)
        if button.itemTitles != titles {
            button.removeAllItems()
            button.addItems(withTitles: titles)
        }
        button.selectItem(at: options.firstIndex(where: { $0.value == selection }) ?? 0)
    }

    final class Coordinator: NSObject {
        var parent: AtlasPopup

        init(_ parent: AtlasPopup) { self.parent = parent }

        @objc func changed(_ sender: NSPopUpButton) {
            guard sender.indexOfSelectedItem >= 0, sender.indexOfSelectedItem < parent.options.count else { return }
            parent.selection = parent.options[sender.indexOfSelectedItem].value
        }
    }
}

private struct AtlasSegmentedControl<Value: Hashable>: View {
    let items: [(value: Value, title: String)]
    @Binding var selection: Value

    var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                GlassEffectContainer(spacing: 4) {
                    HStack(spacing: 4) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            if selection == item.value {
                                Button {
                                    selection = item.value
                                } label: {
                                    segmentLabel(item.title, selected: true)
                                }
                                .buttonStyle(.glassProminent)
                                .tint(Color(nsColor: AtlasColor.teal))
                                .help(item.title)
                            } else {
                                Button {
                                    selection = item.value
                                } label: {
                                    segmentLabel(item.title, selected: false)
                                }
                                .buttonStyle(.glass)
                                .help(item.title)
                            }
                        }
                    }
                }
            } else {
                HStack(spacing: 3) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        Button {
                            selection = item.value
                        } label: {
                            segmentLabel(item.title, selected: selection == item.value)
                        }
                        .buttonStyle(.plain)
                        .background(
                            selection == item.value ? Color(nsColor: AtlasColor.teal) : Color.clear,
                            in: Capsule()
                        )
                        .help(item.title)
                    }
                }
                .padding(3)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().stroke(Color(nsColor: AtlasColor.line).opacity(0.8), lineWidth: 1))
            }
        }
    }

    private func segmentLabel(_ title: String, selected: Bool) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(selected ? Color(nsColor: AtlasColor.onAccent) : Color(nsColor: AtlasColor.inkSoft))
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: 26)
            .contentShape(Capsule())
    }
}

private struct AtlasDateControl: View {
    @Binding var selection: Date
    let range: ClosedRange<Date>
    @State private var showingCalendar = false

    var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                dateButton
                    .buttonStyle(.glass)
            } else {
                dateButton
                    .buttonStyle(.plain)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().stroke(Color(nsColor: AtlasColor.line).opacity(0.8), lineWidth: 1))
            }
        }
        .help("选择日期")
        .popover(isPresented: $showingCalendar, arrowEdge: .bottom) {
            DatePicker("", selection: $selection, in: range, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
                .padding(14)
                .onChange(of: selection) { _ in showingCalendar = false }
        }
    }

    private var dateButton: some View {
        Button {
            showingCalendar.toggle()
        } label: {
            HStack(spacing: 7) {
                Text(AtlasDateControl.formatter.string(from: selection))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color(nsColor: AtlasColor.ink))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 2)
                Image(systemName: "calendar")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(nsColor: AtlasColor.teal))
            }
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity, minHeight: 28)
            .contentShape(Capsule())
        }
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy/M/d"
        return formatter
    }()
}

private struct MetricCard: View {
    let title: String
    let value: String
    let detail: String
    let accent: NSColor

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color(nsColor: accent))
                    .frame(width: 5, height: 5)
                Text(title)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color(nsColor: AtlasColor.muted))
                    .lineLimit(1)
            }
            Text(value).font(.system(size: 24, weight: .bold, design: .monospaced)).foregroundStyle(Color(nsColor: AtlasColor.ink)).lineLimit(1).minimumScaleFactor(0.66).textSelection(.enabled)
            Text(detail).font(.system(size: 11)).foregroundStyle(Color(nsColor: AtlasColor.muted)).lineLimit(1).minimumScaleFactor(0.66).textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
        .padding(.vertical, 12)
        .padding(.horizontal, 13)
    }
}

private struct AtlasMetricDivider: View {
    var body: some View {
        Divider()
            .frame(height: 58)
            .opacity(0.55)
    }
}

private struct AtlasPanel<Content: View>: View {
    let title: String
    let subtitle: String
    let trailing: String?
    @ViewBuilder let content: Content

    init(title: String, subtitle: String, trailing: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.system(size: 19, weight: .bold)).foregroundStyle(Color(nsColor: AtlasColor.ink))
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(Color(nsColor: AtlasColor.muted))
                }
                Spacer()
                if let trailing { Text(trailing).font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(Color(nsColor: AtlasColor.muted)) }
            }
            content
        }
        .padding(.vertical, 22)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(nsColor: AtlasColor.line).opacity(0.85))
                .frame(height: 1)
        }
    }
}

private struct AtlasTable: View {
    let headers: [String]
    let rows: [[String]]
    let widths: [CGFloat]
    let adaptiveWeights: [CGFloat]?

    init(headers: [String], rows: [[String]], widths: [CGFloat], adaptiveWeights: [CGFloat]? = nil) {
        self.headers = headers
        self.rows = rows
        self.widths = widths
        self.adaptiveWeights = adaptiveWeights
    }

    var body: some View {
        Group {
            if let adaptiveWeights {
                GeometryReader { geometry in
                    VStack(spacing: 0) {
                        adaptiveRow(headers, header: true, availableWidth: geometry.size.width, weights: adaptiveWeights)
                        Divider()
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, values in
                            adaptiveRow(values, header: false, availableWidth: geometry.size.width, weights: adaptiveWeights)
                            Divider()
                        }
                    }
                }
                .frame(height: CGFloat(31 + rows.count * 39))
            } else {
                ScrollView(.horizontal) {
                    VStack(spacing: 0) {
                        row(headers, header: true)
                        Divider()
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, values in
                            row(values, header: false)
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private func adaptiveRow(_ values: [String], header: Bool, availableWidth: CGFloat, weights: [CGFloat]) -> some View {
        let spacing = CGFloat(10)
        let totalWeight = max(1, weights.prefix(values.count).reduce(0, +))
        let contentWidth = max(0, availableWidth - spacing * CGFloat(max(0, values.count - 1)))
        return HStack(spacing: spacing) {
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                Text(value)
                    .font(.system(size: header ? 9 : 11, weight: header ? .bold : .regular))
                    .foregroundStyle(Color(nsColor: header ? AtlasColor.muted : AtlasColor.ink))
                    .lineLimit(header ? 1 : 2)
                    .minimumScaleFactor(0.75)
                    .frame(width: contentWidth * (index < weights.count ? weights[index] : 1) / totalWeight, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .frame(height: header ? 30 : 38)
    }

    private func row(_ values: [String], header: Bool) -> some View {
        HStack(spacing: 10) {
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                Text(value)
                    .font(.system(size: header ? 9 : 11, weight: header ? .bold : .regular))
                    .foregroundStyle(Color(nsColor: header ? AtlasColor.muted : AtlasColor.ink))
                    .lineLimit(header ? 1 : 2)
                    .frame(width: index < widths.count ? widths[index] : 100, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .frame(height: header ? 30 : 38)
    }
}

private struct HourlyHeatmap: View {
    let data: DashboardData
    @ObservedObject var controller: AppDelegate

    var body: some View {
        let filtered = controller.filteredHourly(data)
        let usage = filtered.0
        let costs = filtered.1
        let values = usage.flatMap { $0 }.map { Double($0.value(for: controller.selectedMetric)) }
        let cap = percentile(values, fraction: 0.98)
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Color.clear.frame(width: 48, height: 14)
                ForEach(0..<24, id: \.self) {
                    Text(String(format: "%02d", $0))
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color(nsColor: AtlasColor.muted))
                        .frame(width: 36)
                }
            }
            ForEach(0..<7, id: \.self) { day in
                HStack(spacing: 4) {
                    Text(["周一", "周二", "周三", "周四", "周五", "周六", "周日"][day])
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color(nsColor: AtlasColor.inkSoft))
                        .frame(width: 48, height: 36, alignment: .leading)
                    ForEach(0..<24, id: \.self) { hour in
                        let item = usage[day][hour]
                        AtlasHeatCell(
                            color: heatColor(value: Double(item.value(for: controller.selectedMetric)), cap: cap),
                            size: 36,
                            tooltip: "\(["周一", "周二", "周三", "周四", "周五", "周六", "周日"][day]) \(String(format: "%02d", hour)):00\n\(formatInt(item.value(for: controller.selectedMetric))) · \(formatInt(item.calls)) calls\n官方 API 等价价值 \(formatUSD(controller.pricingMode.value(costs[day][hour])))"
                        )
                    }
                }
            }
            HStack(spacing: 8) {
                Text("0")
                LinearGradient(colors: [AtlasColor.heatLow, AtlasColor.heatMidLow, AtlasColor.heatMid, AtlasColor.heatHigh].map { Color(nsColor: $0) }, startPoint: .leading, endPoint: .trailing)
                    .frame(width: 180, height: 9)
                    .overlay(Rectangle().stroke(Color(nsColor: AtlasColor.tealDeep).opacity(0.12)))
                Text(shortNumber(Int64(cap)))
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(Color(nsColor: AtlasColor.muted))
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.top, 7)
        }
    }
}

private struct AtlasHeatCell: View {
    let color: NSColor
    let size: CGFloat
    let tooltip: String
    let showsTooltip: Bool
    let selected: Bool
    let hoverChanged: ((Bool) -> Void)?
    @State private var hovered = false

    init(
        color: NSColor,
        size: CGFloat,
        tooltip: String,
        showsTooltip: Bool = true,
        selected: Bool = false,
        hoverChanged: ((Bool) -> Void)? = nil
    ) {
        self.color = color
        self.size = size
        self.tooltip = tooltip
        self.showsTooltip = showsTooltip
        self.selected = selected
        self.hoverChanged = hoverChanged
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(nsColor: color))
                .frame(width: size, height: size)
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color(nsColor: AtlasColor.tealDeep).opacity(0.08)))
                .overlay {
                    if hovered || selected {
                        RoundedRectangle(cornerRadius: 2)
                            .stroke(Color(nsColor: AtlasColor.coral), lineWidth: selected ? 2 : 3)
                            .padding(-3)
                    }
                }
            if hovered && showsTooltip {
                AtlasTooltipBubble(text: tooltip)
                    .offset(
                        x: size <= 24 ? 125 : 0,
                        y: size <= 24 ? 0 : -(size / 2 + 43)
                    )
                    .allowsHitTesting(false)
            }
        }
        .frame(width: size, height: size)
        .zIndex(hovered ? 3 : 0)
        .onHover {
            hovered = $0
            hoverChanged?($0)
        }
    }
}

private struct AtlasTooltipBubble: View {
    let text: String

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(Color(nsColor: AtlasColor.tooltipText))
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: true, vertical: true)
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(Color(nsColor: AtlasColor.tooltipSurface).opacity(0.97), in: shape)
            .overlay(shape.stroke(Color(nsColor: AtlasColor.coral), lineWidth: 1))
            .allowsHitTesting(false)
    }
}

private struct DayGridCell: Identifiable {
    let id: String
    let day: String
    let inside: Bool
}

private struct DailyHoverState {
    let text: String
    let row: Int
    let column: Int
}

private struct DailyHourHoverState {
    let hour: Int
    let row: Int
    let text: String
}

private struct DailyHourlyStrip: View {
    let day: String
    let row: Int
    let data: DashboardData
    @ObservedObject var controller: AppDelegate
    let hoverChanged: (DailyHourHoverState?) -> Void

    var body: some View {
        let timeline = data.timeline_hourly[controller.selectedModel] ?? [:]
        let costTimeline = data.pricing.timeline_hourly[controller.selectedModel] ?? [:]
        let usage = (0..<24).map { timeline["\(day)T\(String(format: "%02d", $0))"] ?? Usage() }
        let costs = (0..<24).map { costTimeline["\(day)T\(String(format: "%02d", $0))"] ?? Cost() }
        let cap = percentile(usage.map { Double($0.value(for: controller.selectedMetric)) }, fraction: 0.98)

        HStack(spacing: 3) {
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Color(nsColor: AtlasColor.coral))
                .frame(width: 8)
            Text("\(String(day.dropFirst(5))) · 24H")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(Color(nsColor: AtlasColor.inkSoft))
                .frame(width: 76, alignment: .leading)
            ForEach(0..<24, id: \.self) { hour in
                let item = usage[hour]
                let tooltip = "\(day) \(String(format: "%02d", hour)):00\n\(formatInt(item.value(for: controller.selectedMetric))) · \(formatInt(item.calls)) calls\n官方 API 等价价值 \(formatUSD(controller.pricingMode.value(costs[hour])))"
                AtlasHeatCell(
                    color: heatColor(value: Double(item.value(for: controller.selectedMetric)), cap: cap),
                    size: 18,
                    tooltip: tooltip,
                    showsTooltip: false,
                    hoverChanged: { hovering in
                        hoverChanged(hovering ? DailyHourHoverState(hour: hour, row: row, text: tooltip) : nil)
                    }
                )
            }
        }
        .frame(height: 22)
        .zIndex(100)
    }
}

private struct DailyHeatmap: View {
    let data: DashboardData
    @ObservedObject var controller: AppDelegate
    @State private var hoveredTooltip: DailyHoverState?
    @State private var hourlyTooltip: DailyHourHoverState?
    @State private var selectedDay: String?

    var body: some View {
        let range = controller.activeRange(data)
        let cells = calendarCells(start: range.start, end: range.end)
        let usage = data.daily[controller.selectedModel] ?? [:]
        let costs = data.pricing.daily[controller.selectedModel] ?? [:]
        let cap = percentile(usage.filter { controller.isIncluded($0.key, in: data) }.map { Double($0.value.value(for: controller.selectedMetric)) }, fraction: 0.98)
        let months = monthLabels(cells)
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Color.clear.frame(width: 20, height: 14)
                HStack(spacing: 5) {
                    ForEach(Array(months.enumerated()), id: \.offset) { _, month in
                        Text(month)
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color(nsColor: AtlasColor.muted))
                            .frame(width: 22, height: 14, alignment: .leading)
                    }
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(spacing: 5) {
                        ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) {
                            Text($0)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Color(nsColor: AtlasColor.muted))
                                .frame(width: 20, height: 22)
                        }
                    }
                    LazyHGrid(rows: Array(repeating: GridItem(.fixed(22), spacing: 5), count: 7), spacing: 5) {
                        ForEach(Array(cells.enumerated()), id: \.element.id) { index, cell in
                            let item = usage[cell.day] ?? Usage()
                            let tooltip = cell.inside ? "\(cell.day)\n\(formatInt(item.value(for: controller.selectedMetric))) · \(formatInt(item.calls)) calls\n官方 API 等价价值 \(formatUSD(controller.pricingMode.value(costs[cell.day] ?? Cost())))" : "不在所选周期内"
                            AtlasHeatCell(
                                color: cell.inside ? heatColor(value: Double(item.value(for: controller.selectedMetric)), cap: cap) : NSColor.gray.withAlphaComponent(0.08),
                                size: 22,
                                tooltip: tooltip,
                                showsTooltip: false,
                                selected: cell.inside && selectedDay == cell.day,
                                hoverChanged: { hovering in
                                    hoveredTooltip = hovering
                                        ? DailyHoverState(text: tooltip, row: index % 7, column: index / 7)
                                        : nil
                                }
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                guard cell.inside else { return }
                                hoveredTooltip = nil
                                hourlyTooltip = nil
                                selectedDay = selectedDay == cell.day ? nil : cell.day
                            }
                        }
                    }
                    if let selectedDay,
                       let index = cells.firstIndex(where: { $0.day == selectedDay }) {
                        DailyHourlyStrip(
                            day: selectedDay,
                            row: index % 7,
                            data: data,
                            controller: controller,
                            hoverChanged: { hourlyTooltip = $0 }
                        )
                        .padding(.top, CGFloat(index % 7) * 27)
                    }
                    Spacer(minLength: 0)
                }
            }
            HStack(spacing: 8) {
                Text("0")
                LinearGradient(colors: [AtlasColor.heatLow, AtlasColor.heatMidLow, AtlasColor.heatMid, AtlasColor.heatHigh].map { Color(nsColor: $0) }, startPoint: .leading, endPoint: .trailing)
                    .frame(width: 180, height: 9)
                    .overlay(Rectangle().stroke(Color(nsColor: AtlasColor.tealDeep).opacity(0.12)))
                Text(shortNumber(Int64(cap)))
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(Color(nsColor: AtlasColor.muted))
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.top, 5)
        }
        .overlay(alignment: .topLeading) {
            GeometryReader { geometry in
                if let hoveredTooltip {
                    let cellX = CGFloat(28 + hoveredTooltip.column * 27)
                    let cellY = CGFloat(21 + hoveredTooltip.row * 27)
                    let tooltipX = min(max(0, cellX), max(0, geometry.size.width - 240))
                    let tooltipY = hoveredTooltip.row < 2 ? cellY + 30 : max(0, cellY - 68)
                    AtlasTooltipBubble(text: hoveredTooltip.text)
                        .offset(x: tooltipX, y: tooltipY)
                        .zIndex(100)
                }
                if let hourlyTooltip {
                    let weekCount = CGFloat(cells.count / 7)
                    let cellX = CGFloat(121 + hourlyTooltip.hour * 21) + weekCount * 27
                    let cellY = CGFloat(21 + hourlyTooltip.row * 27)
                    let tooltipX = min(max(0, cellX), max(0, geometry.size.width - 240))
                    let tooltipY = hourlyTooltip.row < 2 ? cellY + 30 : max(0, cellY - 68)
                    AtlasTooltipBubble(text: hourlyTooltip.text)
                        .offset(x: tooltipX, y: tooltipY)
                        .zIndex(200)
                }
            }
            .allowsHitTesting(false)
        }
    }

    private func monthLabels(_ cells: [DayGridCell]) -> [String] {
        stride(from: 0, to: cells.count, by: 7).enumerated().map { index, offset in
            let week = Array(cells[offset..<min(offset + 7, cells.count)])
            guard let firstInside = week.first(where: { $0.inside }),
                  let date = reportDateFormatter.date(from: firstInside.day) else { return "" }
            let day = Calendar(identifier: .gregorian).component(.day, from: date)
            if index == 0 || day <= 7 {
                return "\(Calendar(identifier: .gregorian).component(.month, from: date))月"
            }
            return ""
        }
    }

    private func calendarCells(start: String, end: String) -> [DayGridCell] {
        guard let first = reportDateFormatter.date(from: start), let last = reportDateFormatter.date(from: end) else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let weekday = (calendar.component(.weekday, from: first) + 5) % 7
        let gridStart = calendar.date(byAdding: .day, value: -weekday, to: first)!
        let lastWeekday = (calendar.component(.weekday, from: last) + 5) % 7
        let gridEnd = calendar.date(byAdding: .day, value: 6 - lastWeekday, to: last)!
        let count = calendar.dateComponents([.day], from: gridStart, to: gridEnd).day! + 1
        return (0..<count).map { offset in
            let date = calendar.date(byAdding: .day, value: offset, to: gridStart)!
            let key = reportDateFormatter.string(from: date)
            return DayGridCell(id: key, day: key, inside: key >= start && key <= end)
        }
    }
}

@main
enum CodexTokenAtlasMain {
    private static let delegate = AppDelegate()

    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(preferredDockVisibility() ? .regular : .accessory)
        application.appearance = preferredAppearanceMode().appKitAppearance
        application.delegate = delegate
        application.run()
    }
}
