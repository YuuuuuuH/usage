import AppKit
import Darwin
import Foundation
import SwiftUI

private let showInDockDefaultsKey = "showInDockV1"
private let appearanceModeDefaultsKey = "appearanceModeV1"
private let appGlassFrostDefaultsKey = "appGlassFrostAmountV1"
private let liveGlassFrostDefaultsKey = "glassFrostAmountV1"
private let historicalTotalsByDataHomeDefaultsKey = "confirmedHistoricalTotalsByDataHomeV1"
private let liveRefreshDefaultsKey = "liveTokenRefreshSecondsV2"
private let liveMonitorSourceDefaultsKey = "liveTokenMonitorSourceV1"
private let dataHomeDefaultsKey = "tokenAtlasDataHomePathV1"
private let allLiveMonitorSourcesID = "__all_live_sources__"
private let dashboardRenderScale: CGFloat = 1
private let defaultAppGlassFrostAmount = 1.0
private let defaultLiveGlassFrostAmount = 0.58

private func normalizedDataHomeURL(_ candidate: URL) -> URL {
    let normalized = candidate.standardizedFileURL.resolvingSymlinksInPath()
    let nestedSessions = normalized.appendingPathComponent("sessions", isDirectory: true)
    var nestedIsDirectory: ObjCBool = false
    let hasNestedSessions = FileManager.default.fileExists(
        atPath: nestedSessions.path,
        isDirectory: &nestedIsDirectory
    ) && nestedIsDirectory.boolValue
    if normalized.lastPathComponent == "sessions", !hasNestedSessions {
        return normalized.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
    }
    return normalized
}

private func defaultDataHomeURL() -> URL {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex", isDirectory: true)
        .standardizedFileURL
}

private func preferredDataHomePath() -> String {
    guard let stored = UserDefaults.standard.string(forKey: dataHomeDefaultsKey), !stored.isEmpty else {
        return defaultDataHomeURL().path
    }
    return normalizedDataHomeURL(URL(fileURLWithPath: stored, isDirectory: true)).path
}

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

private func preferredAppGlassFrostAmount() -> Double {
    let defaults = UserDefaults.standard
    guard defaults.object(forKey: appGlassFrostDefaultsKey) != nil else {
        return defaultAppGlassFrostAmount
    }
    return min(1, max(0, defaults.double(forKey: appGlassFrostDefaultsKey)))
}

private func preferredLiveGlassFrostAmount() -> Double {
    let defaults = UserDefaults.standard
    guard defaults.object(forKey: liveGlassFrostDefaultsKey) != nil else {
        return defaultLiveGlassFrostAmount
    }
    return min(1, max(0, defaults.double(forKey: liveGlassFrostDefaultsKey)))
}

private struct LiveMonitorSourceOption: Identifiable, Equatable {
    let id: String
    let label: String
}

private struct LiveMonitorSource {
    let id: String
    let label: String
    let dataHome: URL
    let displayPath: String
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

    static let canvas = adaptive(light: rgb(244, 245, 248), dark: rgb(26, 29, 35))
    static let surface = adaptive(light: rgb(255, 255, 255), dark: rgb(38, 42, 50))
    static let ink = adaptive(light: rgb(31, 38, 51), dark: rgb(237, 240, 246))
    static let inkSoft = adaptive(light: rgb(78, 88, 105), dark: rgb(195, 202, 216))
    static let muted = adaptive(light: rgb(102, 113, 132), dark: rgb(162, 172, 189))
    static let line = adaptive(light: rgb(218, 224, 233), dark: rgb(57, 65, 79))
    static let lineStrong = adaptive(light: rgb(174, 187, 207), dark: rgb(91, 106, 132))
    static var teal: NSColor { adaptive(light: AtlasTheme.shared.accent(dark: false), dark: AtlasTheme.shared.accent(dark: true)) }
    static var tealDeep: NSColor { teal }
    static let coral = adaptive(light: rgb(126, 105, 160), dark: rgb(181, 163, 216))
    static let statusInk = adaptive(light: rgb(95, 77, 127), dark: rgb(201, 183, 234))
    static let amber = adaptive(light: rgb(145, 109, 63), dark: rgb(199, 169, 124))
    static let zero = adaptive(light: rgb(233, 236, 242), dark: rgb(42, 47, 57))
    static var onAccent: NSColor { adaptive(light: AtlasTheme.text(on: AtlasTheme.shared.accent(dark: false)), dark: AtlasTheme.text(on: AtlasTheme.shared.accent(dark: true))) }
    private static func heat(_ amount: CGFloat) -> NSColor {
        adaptive(light: AtlasTheme.mix(rgb(244, 245, 248), with: AtlasTheme.shared.accent(dark: false), amount: amount),
                 dark: AtlasTheme.mix(rgb(38, 42, 50), with: AtlasTheme.shared.accent(dark: true), amount: amount))
    }
    static var heatLow: NSColor { AtlasTheme.shared.isDefault ? adaptive(light: rgb(227, 236, 248), dark: rgb(43, 54, 75)) : heat(0.12) }
    static var heatMidLow: NSColor { AtlasTheme.shared.isDefault ? adaptive(light: rgb(183, 205, 235), dark: rgb(56, 81, 117)) : heat(0.35) }
    static var heatMid: NSColor { AtlasTheme.shared.isDefault ? adaptive(light: rgb(111, 148, 201), dark: rgb(85, 129, 177)) : heat(0.65) }
    static var heatHigh: NSColor { AtlasTheme.shared.isDefault ? adaptive(light: rgb(48, 82, 143), dark: rgb(172, 207, 238)) : heat(1) }
}

private struct AtlasGlassFrostKey: EnvironmentKey {
    static let defaultValue = defaultAppGlassFrostAmount
}

private struct AtlasWindowBackdropKey: EnvironmentKey {
    static let defaultValue = false
}

private extension EnvironmentValues {
    var atlasGlassFrostAmount: Double {
        get { self[AtlasGlassFrostKey.self] }
        set { self[AtlasGlassFrostKey.self] = newValue }
    }

    var atlasWindowBackdropActive: Bool {
        get { self[AtlasWindowBackdropKey.self] }
        set { self[AtlasWindowBackdropKey.self] = newValue }
    }
}

private final class AtlasWindowBackdrop {
    private typealias MainConnectionID = @convention(c) () -> UInt32
    private typealias SetBackgroundBlur = @convention(c) (UInt32, UInt32, Int32, Float) -> Int32

    static let shared = AtlasWindowBackdrop()

    private let frameworkHandle: UnsafeMutableRawPointer?
    private let mainConnectionID: MainConnectionID?
    private let setBackgroundBlur: SetBackgroundBlur?

    var isAvailable: Bool {
        frameworkHandle != nil && mainConnectionID != nil && setBackgroundBlur != nil
    }

    private init() {
        let path = "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics"
        guard let handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL),
              let mainSymbol = dlsym(handle, "CGSMainConnectionID"),
              let blurSymbol = dlsym(handle, "CGSSetWindowBackgroundBlurRadiusWithOpacityHint")
        else {
            frameworkHandle = nil
            mainConnectionID = nil
            setBackgroundBlur = nil
            return
        }
        frameworkHandle = handle
        mainConnectionID = unsafeBitCast(mainSymbol, to: MainConnectionID.self)
        setBackgroundBlur = unsafeBitCast(blurSymbol, to: SetBackgroundBlur.self)
    }

    func apply(windowNumber: Int, blurRadius: Int32, opacityHint: Float) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let mainConnectionID,
              let setBackgroundBlur,
              let windowID = UInt32(exactly: windowNumber),
              windowID > 0,
              opacityHint.isFinite
        else { return false }

        let radius = min(64, max(0, blurRadius))
        let opacity = min(1, max(0, opacityHint))
        return setBackgroundBlur(mainConnectionID(), windowID, radius, opacity) == 0
    }
}

private struct AtlasGlassModifier<S: Shape>: ViewModifier {
    @Environment(\.atlasGlassFrostAmount) private var frostAmount
    @Environment(\.atlasWindowBackdropActive) private var windowBackdropActive

    let shape: S
    let tint: Color?
    let prefersClear: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        let amount = min(1, max(0, frostAmount))
        let underlayOpacity = amount * (prefersClear ? 0.18 : 0.25)
        let borderOpacity = 0.38 + amount * 0.34

        if windowBackdropActive {
            content
                .background {
                    shape
                        .fill(Color(nsColor: AtlasColor.surface).opacity(0.12 + amount * 0.16))
                        .overlay(shape.fill(tint ?? Color.clear))
                }
                .overlay(shape.stroke(Color(nsColor: AtlasColor.line).opacity(borderOpacity), lineWidth: 1))
        } else if #available(macOS 26.0, *) {
            let glass: Glass = prefersClear ? .clear : .regular
            content
                .background {
                    shape
                        .fill(Color(nsColor: AtlasColor.surface).opacity(underlayOpacity))
                        .glassEffect(glass.tint(tint), in: shape)
                }
                .overlay(shape.stroke(Color(nsColor: AtlasColor.line).opacity(borderOpacity), lineWidth: 1))
        } else {
            let material: Material = prefersClear ? .ultraThin : .regular
            content
                .background {
                    shape
                        .fill(Color(nsColor: AtlasColor.surface).opacity(underlayOpacity))
                        .background(material, in: shape)
                }
                .overlay(shape.stroke(Color(nsColor: AtlasColor.line).opacity(borderOpacity), lineWidth: 1))
        }
    }
}

private extension View {
    func atlasGlass<S: Shape>(
        in shape: S,
        tint: Color? = nil,
        clear: Bool = false
    ) -> some View {
        modifier(
            AtlasGlassModifier(
                shape: shape,
                tint: tint,
                prefersClear: clear
            )
        )
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
    let standard_cache_savings_usd: Double
    let standard_cached_input_cost_usd: Double
    let standard_cache_write_input_cost_usd: Double
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
        standard_cache_savings_usd: Double = 0,
        standard_cached_input_cost_usd: Double = 0,
        standard_cache_write_input_cost_usd: Double = 0,
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
        self.standard_cache_savings_usd = standard_cache_savings_usd
        self.standard_cached_input_cost_usd = standard_cached_input_cost_usd
        self.standard_cache_write_input_cost_usd = standard_cache_write_input_cost_usd
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
    let pricing_kind: String?
    let rates: RateSet?
    let standard_rates: RateSet?
    let rate_note: String?
    let daily: [String: RouteDay]

    func displayedRates(for mode: PricingMode) -> RateSet? {
        mode == .simple ? standard_rates : rates
    }
}

private struct PricingData: Decodable {
    let as_of: String
    let custom_models: [String]?
    let scopes: [String: Cost]
    let routes: [PricingRoute]
    let hourly: [String: [[Cost]]]
    let daily: [String: [String: Cost]]
    let timeline_hourly: [String: [String: Cost]]

    var customModelCount: Int { custom_models?.count ?? 0 }
    var hasCustomPricing: Bool { customModelCount > 0 }
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
    let rollout_files: Int?
    let internal_thread_count: Int?

    var rolloutFileCount: Int { max(1, rollout_files ?? 1) }
    var internalThreadCount: Int { max(0, internal_thread_count ?? 0) }

    var lineageLabel: String {
        let kind = parent_id.isEmpty ? "conversation" : "user fork +\(lineage_depth)"
        return "\(kind)\n\(rolloutFileCount) files · \(internalThreadCount) internal"
    }
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
    let inferred_reasoning_events: Int?
    let inferred_reasoning_tokens: Int?
    let heuristic_reasoning_events: Int?
    let conversation_sessions: Int?
    let internal_threads: Int?
    let orphan_internal_threads: Int?

    var conversationSessionCount: Int { max(0, conversation_sessions ?? session_files) }
    var internalThreadCount: Int { max(0, internal_threads ?? 0) }
    var orphanInternalThreadCount: Int { max(0, orphan_internal_threads ?? 0) }
    var inferredReasoningEventCount: Int { max(0, inferred_reasoning_events ?? 0) }
    var inferredReasoningTokenCount: Int64 { Int64(max(0, inferred_reasoning_tokens ?? 0)) }
    var heuristicReasoningEventCount: Int { max(0, heuristic_reasoning_events ?? 0) }
}

private struct UsageRecords: Decodable {
    static let categories = [("habit", "使用习惯"), ("exploration", "模型探索"), ("collaboration", "协作足迹"), ("volume", "Token 里程碑")]
    struct Day: Decodable {
        let date: String
        let total_tokens: Int64
        let output_tokens: Int64
        let calls: Int
        let sessions: Int
        let models: Int
    }
    struct ModelSession: Decodable {
        let session_id: String
        let title: String
        let model_count: Int
        let models: [String]
    }
    struct ModelFootprint: Decodable, Identifiable {
        let id: String
        let calls: Int
        let total_tokens: Int64
        let output_tokens: Int64
        let first_used: String?
        let last_used: String?
    }
    struct Insights: Decodable {
        struct TeamSession: Decodable {
            let session_id: String
            let title: String
            let worker_count: Int
        }
        let first_active_day: String?
        let model_count: Int
        let collaborative_sessions: Int
        let worker_count: Int
        let peak_day: Day?
        let peak_output_day: Day?
        let busiest_day: Day?
        let most_models_session: ModelSession?
        let collaborative_days: Int?
        let largest_team_session: TeamSession?
        let models: [ModelFootprint]
    }
    struct Milestone: Identifiable {
        let id: String
        let title: String
        let symbol: String
        let level: String
        let date: String
        let target: String
    }
    struct Window: Decodable {
        let start: String
        let end: String
        let window_seconds: Int
        let total_tokens: Int64
        let output_tokens: Int64
        func rate(output: Bool) -> Double { Double(output ? output_tokens : total_tokens) / Double(max(1, window_seconds)) }
        func rateLabel(output: Bool) -> String {
            let value = rate(output: output)
            return value >= 1000 ? shortNumber(Int64(value.rounded())) : String(format: "%.1f", value)
        }
    }
    struct Activity: Decodable {
        let session_id: String
        let title: String
        let start: String
        let end: String
        let seconds: Int
        let total_tokens: Int64
    }
    struct Conversation: Decodable {
        let session_id: String
        let title: String
        let total_tokens: Int64
    }
    struct Achievement: Decodable, Identifiable {
        struct Level: Decodable {
            let name: String
            let target: Int
            let unlocked_on: String?
            var hidden: Bool? = nil
            var isHidden: Bool { hidden ?? (name == "钻石") }
        }
        let id: String
        let title: String
        let symbol: String
        let detail: String
        let value: Int
        let current_value: Int
        let unit: String
        let levels: [Level]
        let category: String?
        let rule: String?
        var categoryID: String { category ?? "habit" }
        func formatted(_ amount: Int) -> String { unit == "Token" ? shortNumber(Int64(amount)) : formatInt(Int64(amount)) }
        var valueLabel: String { "\(formatted(value)) \(unit)" }
        var visibleLevels: [Level] { levels.filter { !$0.isHidden || value >= $0.target } }
        var completedLabel: String { visibleLevels.last.map { "\($0.name)级已达成" } ?? "已达成" }
        var remainingLabel: String { nextLevel.map { "还差 \(formatted(max(0, $0.target - current_value))) \(unit)" } ?? completedLabel }
        var unlockedLevels: Int { levels.filter { value >= $0.target }.count }
        var currentLevelIndex: Int? { levels.lastIndex { value >= $0.target } }
        var nextLevel: Level? { visibleLevels.first { value < $0.target } }
        var progress: Double { nextLevel.map { min(1, max(0, Double(current_value) / Double(max(1, $0.target)))) } ?? 1 }
        var progressLabel: String {
            guard let next = nextLevel else { return completedLabel }
            if id == "streak" { return "本轮连续 \(current_value)/\(next.target) 天 · 目标\(next.name)级" }
            return "距\(next.name)级还差 \(formatted(max(0, next.target - current_value))) \(unit)"
        }
    }
    let as_of: String
    let active_days: Int
    let current_streak: Int
    let longest_streak: Int
    let longest_streak_start: String?
    let longest_streak_end: String?
    let peak_hour: Window?
    let peak_output_hour: Window?
    let peak_throughput: Window?
    let peak_output_throughput: Window?
    let longest_activity: Activity?
    let largest_session: Conversation?
    let achievements: [Achievement]
    let insights: Insights?
    let excluded_timestamp_sessions: Int
    let excluded_replay_events: Int
    let excluded_provenance_events: Int
    var timingExclusionSummary: String? {
        let events = excluded_replay_events + excluded_provenance_events
        var counts: [String] = []
        if events > 0 { counts.append("\(formatInt(Int64(events))) 条记录") }
        if excluded_timestamp_sessions > 0 { counts.append("\(formatInt(Int64(excluded_timestamp_sessions))) 条会话") }
        return counts.isEmpty ? nil : "已筛除 " + counts.joined(separator: " · ")
    }
    var unlockedCount: Int { achievements.reduce(0) { $0 + $1.unlockedLevels } }
    var levelCount: Int { achievements.reduce(0) { $0 + $1.visibleLevels.count } }
    var nextAchievement: Achievement? {
        let candidates = achievements.filter { $0.nextLevel != nil }
        if candidates.allSatisfy({ $0.progress == 0 }) {
            return candidates.first(where: { $0.id == "sessions" }) ?? candidates.first
        }
        return candidates.sorted {
            $0.progress == $1.progress ? $0.id < $1.id : $0.progress > $1.progress
        }.first
    }
    var milestones: [Milestone] {
        achievements.flatMap { achievement in
            achievement.levels.enumerated().compactMap { index, level -> Milestone? in
                guard achievement.value >= level.target, let date = level.unlocked_on else { return nil }
                return Milestone(id: "\(achievement.id)-\(index)", title: achievement.title, symbol: achievement.symbol,
                    level: level.name, date: date, target: "\(achievement.formatted(level.target)) \(achievement.unit)")
            }
        }.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }
    }
}

private func recordWindowLabel(_ start: String, _ end: String, includeSeconds: Bool = false) -> String {
    guard start.count >= 19, end.count >= 19 else { return "\(start) – \(end)" }
    let startDate = String(start.prefix(10))
    let endDate = String(end.prefix(10))
    let timeLength = includeSeconds ? 8 : 5
    let startTime = start.dropFirst(11).prefix(timeLength)
    let endTime = end.dropFirst(11).prefix(timeLength)
    if startDate == endDate { return "\(startDate) · \(startTime)–\(endTime)" }
    let endLabel = start.prefix(4) == end.prefix(4) ? String(endDate.dropFirst(5)) : endDate
    return "\(startDate) \(startTime) – \(endLabel) \(endTime)"
}

private struct DashboardData: Decodable {
    let source_id: String?
    let source_label: String?
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
    let records: UsageRecords?
}

private struct ReportEnvelope: Decodable {
    let source_id: String?
    let source_label: String?
    let sessions_root: String?
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

    func cacheSavings(_ cost: Cost) -> Double {
        self == .simple ? cost.standard_cache_savings_usd : cost.cache_savings_usd
    }

    func cacheReadCost(_ cost: Cost) -> Double {
        self == .simple ? cost.standard_cached_input_cost_usd : cost.cached_input_cost_usd
    }

    func cacheWriteCost(_ cost: Cost) -> Double {
        self == .simple ? cost.standard_cache_write_input_cost_usd : cost.cache_write_input_cost_usd
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
            standard_cache_savings_usd: standard_cache_savings_usd + other.standard_cache_savings_usd,
            standard_cached_input_cost_usd: standard_cached_input_cost_usd + other.standard_cached_input_cost_usd,
            standard_cache_write_input_cost_usd: standard_cache_write_input_cost_usd + other.standard_cache_write_input_cost_usd,
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


private func percentile(_ values: [Double], fraction: Double) -> Double {
    let sorted = values.filter { $0 > 0 }.sorted()
    guard !sorted.isEmpty else { return 0 }
    let index = min(sorted.count - 1, max(0, Int(round(Double(sorted.count - 1) * fraction))))
    return sorted[index]
}

private func heatColor(value: Double, cap: Double) -> NSColor {
    guard value > 0, cap > 0 else { return AtlasColor.zero }
    let t = pow(min(value / cap, 1), 0.44)
    let stops: [(Double, NSColor)] = [
        (0, AtlasColor.heatLow),
        (0.36, AtlasColor.heatMidLow),
        (0.70, AtlasColor.heatMid),
        (1, AtlasColor.heatHigh)
    ]
    let index = (1..<stops.count).first { t <= stops[$0].0 } ?? stops.count - 1
    let left = stops[index - 1]
    let right = stops[index]
    let fraction = (t - left.0) / (right.0 - left.0)
    return NSColor(name: nil) { appearance in
        var color = right.1
        appearance.performAsCurrentDrawingAppearance {
            if let start = left.1.usingColorSpace(.sRGB),
               let end = right.1.usingColorSpace(.sRGB) {
                color = NSColor(
                    srgbRed: start.redComponent + (end.redComponent - start.redComponent) * fraction,
                    green: start.greenComponent + (end.greenComponent - start.greenComponent) * fraction,
                    blue: start.blueComponent + (end.blueComponent - start.blueComponent) * fraction,
                    alpha: 1
                )
            }
        }
        return color
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

private func formatRate(_ value: Double) -> String {
    NumberFormatter.rate.string(from: NSNumber(value: value)) ?? "$0.00"
}

private func formatCostValue(_ cost: Cost, pricingMode: PricingMode) -> String {
    cost.priced_tokens > 0 ? formatUSD(pricingMode.value(cost)) : "未定价"
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
    @Published var historicalTotalTokens: Int64?
    @Published var sourceLabel = "Codex"
    @Published var sourcePath = "~/.codex"
    @Published var sourceOptions: [LiveMonitorSourceOption] = []
    @Published var selectedSourceID = allLiveMonitorSourcesID
}

private final class LiveMonitorPanel: NSPanel, NSWindowDelegate {
    var pinnedChanged: ((Bool) -> Void)?
    private(set) var isPinned = false
    private var isPositioning = false
    private var transientOrigin: NSPoint?
    private var suppressPinUntil = Date.distantPast
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
        if !isPositioning, isVisible, Date() >= suppressPinUntil { setPinned(true) }
    }

    func windowDidMove(_ notification: Notification) {
        guard !isPositioning,
              isVisible,
              Date() >= suppressPinUntil,
              let origin = transientOrigin
        else { return }
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
        suppressPinUntil = Date().addingTimeInterval(0.35)
        setFrameTopLeftPoint(NSPoint(x: x, y: top))
        transientOrigin = frame.origin
        DispatchQueue.main.async { [weak self] in
            self?.isPositioning = false
        }
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

private final class ModelPricingEditor: NSObject {
    private let configuration: [String: Any]
    private let modelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let inputField = NSTextField(string: "")
    private let cachedInputField = NSTextField(string: "")
    private let cacheWriteField = NSTextField(string: "")
    private let outputField = NSTextField(string: "")
    private var drafts: [String: [String]] = [:]
    private var displayedModel = ""

    let view: NSView

    var selectedModel: String {
        modelPopup.titleOfSelectedItem ?? ""
    }

    init(models: [String], preferredModel: String?, configurationURL: URL) throws {
        if FileManager.default.fileExists(atPath: configurationURL.path) {
            let data = try Data(contentsOf: configurationURL)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw NSError(
                    domain: "CodexTokenAtlasPricing",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "价格配置必须是 JSON 对象"]
                )
            }
            if let configuredModels = object["models"], !(configuredModels is [String: Any]) {
                throw NSError(
                    domain: "CodexTokenAtlasPricing",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "价格配置中的 models 必须是 JSON 对象"]
                )
            }
            configuration = object
        } else {
            configuration = [:]
        }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 4, bottom: 4, right: 4)
        stack.frame = NSRect(x: 0, y: 0, width: 430, height: 230)
        view = stack
        super.init()

        let orderedModels = models.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        modelPopup.addItems(withTitles: orderedModels)
        modelPopup.target = self
        modelPopup.action = #selector(modelChanged(_:))
        modelPopup.widthAnchor.constraint(equalToConstant: 292).isActive = true

        for field in [inputField, cachedInputField, cacheWriteField, outputField] {
            field.widthAnchor.constraint(equalToConstant: 180).isActive = true
            field.alignment = .right
            field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            field.placeholderString = "USD / 1M tokens"
        }

        func row(_ title: String, _ control: NSView) -> NSStackView {
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 12, weight: .medium)
            label.alignment = .right
            label.widthAnchor.constraint(equalToConstant: 112).isActive = true
            let result = NSStackView(views: [label, control])
            result.orientation = .horizontal
            result.alignment = .centerY
            result.spacing = 10
            return result
        }

        stack.addArrangedSubview(row("模型", modelPopup))
        stack.addArrangedSubview(row("未缓存输入", inputField))
        stack.addArrangedSubview(row("缓存读取", cachedInputField))
        stack.addArrangedSubview(row("缓存写入", cacheWriteField))
        stack.addArrangedSubview(row("输出", outputField))

        let hint = NSTextField(wrappingLabelWithString: "价格单位为 USD / 100 万 tokens。输入和输出必填；缓存价格留空时使用输入价格。配置仅作用于当前数据目录。")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.preferredMaxLayoutWidth = 408
        stack.addArrangedSubview(hint)

        if let preferredModel, orderedModels.contains(preferredModel) {
            modelPopup.selectItem(withTitle: preferredModel)
        } else {
            modelPopup.selectItem(at: 0)
        }
        loadSelectedModel()
    }

    @objc private func modelChanged(_ sender: Any?) {
        drafts[displayedModel] = [inputField, cachedInputField, cacheWriteField, outputField].map(\.stringValue)
        loadSelectedModel()
    }

    private func configuredModel() -> [String: Any]? {
        guard let models = configuration["models"] as? [String: Any] else { return nil }
        let target = selectedModel.lowercased()
        for (model, value) in models where model.lowercased() == target {
            return value as? [String: Any]
        }
        return nil
    }

    private func loadSelectedModel() {
        displayedModel = selectedModel
        if let draft = drafts[selectedModel] {
            for (field, value) in zip([inputField, cachedInputField, cacheWriteField, outputField], draft) {
                field.stringValue = value
            }
            return
        }
        let configured = configuredModel()
        inputField.stringValue = rateText(configured?["input"])
        cachedInputField.stringValue = rateText(configured?["cached_input"])
        cacheWriteField.stringValue = rateText(configured?["cache_write_input"])
        outputField.stringValue = rateText(configured?["output"])
    }

    private func rateText(_ value: Any?) -> String {
        guard let number = value as? NSNumber else { return "" }
        return String(format: "%.9g", number.doubleValue)
    }

    private func parsedRate(_ field: NSTextField, name: String, required: Bool) throws -> Double? {
        let raw = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty, !required { return nil }
        let normalized = raw.replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized), value.isFinite, value >= 0 else {
            throw NSError(
                domain: "CodexTokenAtlasPricing",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "\(name)价格需要填写非负数字"]
            )
        }
        return value
    }

    func updatedConfiguration(provider: String, removing: Bool) throws -> [String: Any] {
        var result = configuration
        var models = result["models"] as? [String: Any] ?? [:]
        for key in Array(models.keys) where key.lowercased() == selectedModel.lowercased() {
            models.removeValue(forKey: key)
        }

        if !removing {
            guard let input = try parsedRate(inputField, name: "输入", required: true),
                  let output = try parsedRate(outputField, name: "输出", required: true)
            else {
                throw NSError(
                    domain: "CodexTokenAtlasPricing",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "输入和输出价格为必填项"]
                )
            }
            let cachedInput = try parsedRate(cachedInputField, name: "缓存读取", required: false) ?? input
            let cacheWrite = try parsedRate(cacheWriteField, name: "缓存写入", required: false) ?? input
            models[selectedModel] = [
                "provider": provider,
                "input": input,
                "cached_input": cachedInput,
                "cache_write_input": cacheWrite,
                "output": output
            ]
        }

        if models.isEmpty {
            result.removeValue(forKey: "models")
        } else {
            result["models"] = models
        }
        return result
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSToolbarDelegate, ObservableObject {
    private var window: NSWindow!
    private var personalizationWindow: NSWindow?
    private let toolbarSpinner = NSProgressIndicator()
    private let toolbarStatus = NSTextField(labelWithString: "准备中")
    private var refreshToolbarItem: NSToolbarItem?
    private var exportToolbarItem: NSToolbarItem?
    private var liveToolbarItem: NSToolbarItem?
    private weak var liveMenuItem: NSMenuItem?
    private weak var dockMenuItem: NSMenuItem?
    private weak var modelPricingMenuItem: NSMenuItem?
    private let settingsMenu = NSMenu(title: "设置")
    private var appearanceMenuItems: [AppearanceMode: NSMenuItem] = [:]
    private var refreshMenuItems: [Int: NSMenuItem] = [:]
    private weak var appGlassFrostSlider: NSSlider?
    private weak var appGlassFrostValueLabel: NSTextField?
    private weak var liveGlassFrostSlider: NSSlider?
    private weak var liveGlassFrostValueLabel: NSTextField?
    @Published fileprivate var generatorRunning = false
    @Published fileprivate var loadingTitleText = "正在刷新 Token 历史"
    @Published fileprivate var loadingDetailText = "读取当前数据目录的本地会话并汇总用量…"
    @Published fileprivate var dashboard: DashboardData?
    @Published fileprivate var dataHomePath = preferredDataHomePath()
    @Published fileprivate var selectedModel = "all"
    @Published fileprivate var selectedMetric = "total_tokens"
    @Published fileprivate var pricingMode = PricingMode.simple
    @Published fileprivate var datePreset = DatePreset.all
    @Published fileprivate var selectedStartDate: Date?
    @Published fileprivate var selectedEndDate: Date?
    @Published fileprivate var appGlassFrostAmount = preferredAppGlassFrostAmount()
    @Published fileprivate var liveGlassFrostAmount = preferredLiveGlassFrostAmount()
    @Published fileprivate var usesWindowBackdrop = false
    fileprivate let livePresentation = LiveMonitorPresentation()
    fileprivate var liveMonitorEnabled = false

    private var statusItem: NSStatusItem?
    private var lastStatusRateText: String?
    private var livePanel: LiveMonitorPanel!
    private var liveMonitors: [String: LiveTokenMonitor] = [:]
    private var liveMonitorSources: [LiveMonitorSource] = []
    private var liveSnapshots: [String: LiveTokenSnapshot] = [:]
    private var selectedLiveMonitorSourceID = UserDefaults.standard.string(forKey: liveMonitorSourceDefaultsKey)
        ?? allLiveMonitorSourcesID
    private var liveMonitorGeneration: UInt64 = 0
    private var latestLiveSnapshot = LiveTokenSnapshot.zero
    private var historicalTotalTokens: Int64 = 0
    private var historicalTotalsByDataHome: [String: Int64] = [:]
    private var historicalDisplayTimer: Timer?
    private var appGlassFrostSaveWorkItem: DispatchWorkItem?
    private var windowBackdropUpdateWorkItem: DispatchWorkItem?
    private var liveGlassFrostSaveWorkItem: DispatchWorkItem?
    private var showsInDock = preferredDockVisibility()
    @Published fileprivate var appearanceMode = preferredAppearanceMode()

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

    private var dataHomeURL: URL {
        normalizedDataHomeURL(URL(fileURLWithPath: dataHomePath, isDirectory: true))
    }

    private var pricingConfigurationURL: URL {
        dataHomeURL.appendingPathComponent("token_atlas_pricing.json")
    }

    private var dataHomeHistoryKey: String { dataHomeURL.path }

    private func loadHistoricalTotals() {
        var totals: [String: Int64] = [:]
        if let stored = UserDefaults.standard.dictionary(forKey: historicalTotalsByDataHomeDefaultsKey) {
            for (path, value) in stored {
                guard let number = value as? NSNumber else { continue }
                let key = normalizedDataHomeURL(URL(fileURLWithPath: path, isDirectory: true)).path
                totals[key] = max(totals[key] ?? 0, number.int64Value)
            }
        }

        historicalTotalsByDataHome = totals
        historicalTotalTokens = totals[dataHomeHistoryKey] ?? 0
        persistHistoricalTotals()
    }

    private func persistHistoricalTotals() {
        let stored = historicalTotalsByDataHome.mapValues { NSNumber(value: $0) }
        UserDefaults.standard.set(stored, forKey: historicalTotalsByDataHomeDefaultsKey)
    }

    private var codexDataHomeURL: URL {
        normalizedDataHomeURL(homeURL.appendingPathComponent(".codex", isDirectory: true))
    }

    private var qodexDataHomeURL: URL {
        normalizedDataHomeURL(homeURL.appendingPathComponent(".qodex", isDirectory: true))
    }

    fileprivate var dataHomeDisplayPath: String {
        abbreviatedDataHomePath(dataHomeURL)
    }

    private func abbreviatedDataHomePath(_ dataHome: URL) -> String {
        let path = dataHome.path
        let userHome = homeURL.standardizedFileURL.path
        if path == userHome { return "~" }
        if path.hasPrefix(userHome + "/") {
            return "~" + String(path.dropFirst(userHome.count))
        }
        return path
    }

    fileprivate var currentDataSourceID: String {
        if dataHomeURL.path == codexDataHomeURL.path { return "codex" }
        if dataHomeURL.path == qodexDataHomeURL.path { return "qodex" }
        if let sourceID = dashboard?.source_id?.trimmingCharacters(in: .whitespacesAndNewlines), !sourceID.isEmpty {
            return sourceID
        }
        return "custom"
    }

    fileprivate var currentDataSourceLabel: String {
        if dataHomeURL.path == codexDataHomeURL.path { return "Codex" }
        if dataHomeURL.path == qodexDataHomeURL.path { return "Qodex" }
        if let sourceLabel = dashboard?.source_label?.trimmingCharacters(in: .whitespacesAndNewlines), !sourceLabel.isEmpty {
            return sourceLabel
        }
        let name = dataHomeURL.lastPathComponent
        return name.isEmpty ? "自定义数据源" : name
    }

    fileprivate var codexDataHomeAvailable: Bool { isCompatibleDataHome(codexDataHomeURL) }
    fileprivate var qodexDataHomeAvailable: Bool { isCompatibleDataHome(qodexDataHomeURL) }
    fileprivate var isUsingCodexDataHome: Bool { dataHomeURL.path == codexDataHomeURL.path }
    fileprivate var isUsingQodexDataHome: Bool { dataHomeURL.path == qodexDataHomeURL.path }

    private var dataHomeLoadingDetail: String {
        "检查增量缓存并读取 \(currentDataSourceLabel)（\(dataHomeDisplayPath)）的新日志…"
    }

    private func isCompatibleDataHome(_ candidate: URL) -> Bool {
        let sessions = normalizedDataHomeURL(candidate).appendingPathComponent("sessions", isDirectory: true)
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: sessions.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func normalizeInitialDataHomeSelection() {
        let selected = dataHomeURL
        if isCompatibleDataHome(selected) {
            dataHomePath = selected.path
            UserDefaults.standard.set(selected.path, forKey: dataHomeDefaultsKey)
            return
        }
        if let fallback = [codexDataHomeURL, qodexDataHomeURL]
            .first(where: { isCompatibleDataHome($0) }) {
            dataHomePath = fallback.path
            UserDefaults.standard.set(fallback.path, forKey: dataHomeDefaultsKey)
        }
    }

    fileprivate func activateCodexDataHome() {
        activateDataHome(codexDataHomeURL)
    }

    fileprivate func activateQodexDataHome() {
        activateDataHome(qodexDataHomeURL)
    }

    fileprivate func chooseDataHome() {
        guard !generatorRunning else { return }
        let panel = NSOpenPanel()
        panel.title = "选择会话数据目录"
        panel.message = "请选择包含 sessions 子目录的数据目录；也可以直接选择 sessions 目录。"
        panel.prompt = "使用此目录"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = fileManager.fileExists(atPath: dataHomeURL.path) ? dataHomeURL : homeURL
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let selected = panel.url else { return }
            self?.activateDataHome(selected)
        }
    }

    @objc private func chooseDataHomeFromMenu(_ sender: Any?) {
        chooseDataHome()
    }

    private func activateDataHome(_ candidate: URL) {
        guard !generatorRunning else { return }
        let selected = normalizedDataHomeURL(candidate)
        guard isCompatibleDataHome(selected) else {
            presentError("所选目录不兼容：需要存在 \(selected.path)/sessions。")
            return
        }

        let changed = selected.path != dataHomeURL.path
        if changed, livePanel != nil {
            publishHistoricalTotal()
        }
        dataHomePath = selected.path
        UserDefaults.standard.set(selected.path, forKey: dataHomeDefaultsKey)
        refreshToolbarItem?.toolTip = "重新扫描当前数据目录 \(dataHomeDisplayPath)（⌘R）"
        if changed {
            dashboard = nil
            updateModelPricingMenuItem()
            selectedModel = "all"
            datePreset = .all
            selectedStartDate = nil
            selectedEndDate = nil
            historicalTotalTokens = historicalTotalsByDataHome[dataHomeHistoryKey] ?? 0
            if livePanel != nil {
                rebuildLiveMonitors()
            }
        }
        refreshReport(nil)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        normalizeInitialDataHomeSelection()
        loadHistoricalTotals()
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
        if !generatorRunning {
            enableWindowBackdrop()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        publishHistoricalTotal()
        appGlassFrostSaveWorkItem?.cancel()
        windowBackdropUpdateWorkItem?.cancel()
        liveGlassFrostSaveWorkItem?.cancel()
        UserDefaults.standard.set(appGlassFrostAmount, forKey: appGlassFrostDefaultsKey)
        UserDefaults.standard.set(liveGlassFrostAmount, forKey: liveGlassFrostDefaultsKey)
        historicalDisplayTimer?.invalidate()
        liveMonitorGeneration &+= 1
        liveMonitors.values.forEach { $0.stop() }
    }

    private func configureMainMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "Codex Token Atlas")
        appMenu.addItem(withTitle: "关于 Codex Token Atlas", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        let personalize = appMenu.addItem(withTitle: "个性化…", action: #selector(showPersonalization(_:)), keyEquivalent: ",")
        personalize.target = self
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
        let chooseDataHome = fileMenu.addItem(withTitle: "选择会话数据目录…", action: #selector(chooseDataHomeFromMenu(_:)), keyEquivalent: "")
        chooseDataHome.target = self
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

        let personalize = settingsMenu.addItem(withTitle: "个性化…", action: #selector(showPersonalization(_:)), keyEquivalent: "")
        personalize.target = self
        settingsMenu.addItem(.separator())

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

        let modelPricingItem = settingsMenu.addItem(withTitle: "开源/本地模型价格…", action: #selector(editModelPricing(_:)), keyEquivalent: "")
        modelPricingItem.target = self
        modelPricingMenuItem = modelPricingItem
        updateModelPricingMenuItem()
        settingsMenu.addItem(.separator())

        let glassItem = NSMenuItem(title: "液态玻璃", action: nil, keyEquivalent: "")
        let glassMenu = NSMenu(title: "液态玻璃")
        let appGlassItem = NSMenuItem(title: "主应用", action: nil, keyEquivalent: "")
        let appGlassMenu = NSMenu(title: "主应用")
        let appFrostControlItem = NSMenuItem()
        let appClearLabel = NSTextField(labelWithString: "清透")
        appClearLabel.font = .systemFont(ofSize: 11, weight: .medium)
        appClearLabel.textColor = .secondaryLabelColor
        let appFrostedLabel = NSTextField(labelWithString: "磨砂")
        appFrostedLabel.font = .systemFont(ofSize: 11, weight: .medium)
        appFrostedLabel.textColor = .secondaryLabelColor
        let appSlider = NSSlider(
            value: appGlassFrostAmount,
            minValue: 0,
            maxValue: 1,
            target: self,
            action: #selector(changeAppGlassFrost(_:))
        )
        appSlider.isContinuous = true
        appSlider.numberOfTickMarks = 5
        appSlider.allowsTickMarkValuesOnly = false
        appSlider.setAccessibilityLabel("主应用液态玻璃磨砂程度")
        appSlider.widthAnchor.constraint(equalToConstant: 142).isActive = true
        appGlassFrostSlider = appSlider
        let appValueLabel = NSTextField(labelWithString: glassFrostLabel(appGlassFrostAmount))
        appValueLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        appValueLabel.textColor = .secondaryLabelColor
        appValueLabel.alignment = .center
        appGlassFrostValueLabel = appValueLabel
        let appSliderRow = NSStackView(views: [appClearLabel, appSlider, appFrostedLabel])
        appSliderRow.orientation = .horizontal
        appSliderRow.alignment = .centerY
        appSliderRow.spacing = 8
        let appFrostStack = NSStackView(views: [appSliderRow, appValueLabel])
        appFrostStack.orientation = .vertical
        appFrostStack.alignment = .centerX
        appFrostStack.spacing = 5
        appFrostStack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        appFrostStack.frame = NSRect(x: 0, y: 0, width: 226, height: 54)
        appFrostControlItem.view = appFrostStack
        appGlassMenu.addItem(appFrostControlItem)
        appGlassMenu.addItem(.separator())
        let resetAppGlass = appGlassMenu.addItem(withTitle: "恢复 100%", action: #selector(resetAppGlassFrost(_:)), keyEquivalent: "")
        resetAppGlass.target = self
        appGlassItem.submenu = appGlassMenu
        glassMenu.addItem(appGlassItem)

        let liveGlassItem = NSMenuItem(title: "状态栏卡片", action: nil, keyEquivalent: "")
        let liveGlassMenu = NSMenu(title: "状态栏卡片")
        let liveFrostControlItem = NSMenuItem()
        let liveClearLabel = NSTextField(labelWithString: "清透")
        liveClearLabel.font = .systemFont(ofSize: 11, weight: .medium)
        liveClearLabel.textColor = .secondaryLabelColor
        let liveFrostedLabel = NSTextField(labelWithString: "磨砂")
        liveFrostedLabel.font = .systemFont(ofSize: 11, weight: .medium)
        liveFrostedLabel.textColor = .secondaryLabelColor
        let liveSlider = NSSlider(
            value: liveGlassFrostAmount,
            minValue: 0,
            maxValue: 1,
            target: self,
            action: #selector(changeLiveGlassFrost(_:))
        )
        liveSlider.isContinuous = true
        liveSlider.numberOfTickMarks = 5
        liveSlider.allowsTickMarkValuesOnly = false
        liveSlider.setAccessibilityLabel("状态栏卡片液态玻璃磨砂程度")
        liveSlider.widthAnchor.constraint(equalToConstant: 142).isActive = true
        liveGlassFrostSlider = liveSlider
        let liveValueLabel = NSTextField(labelWithString: glassFrostLabel(liveGlassFrostAmount))
        liveValueLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        liveValueLabel.textColor = .secondaryLabelColor
        liveValueLabel.alignment = .center
        liveGlassFrostValueLabel = liveValueLabel
        let liveSliderRow = NSStackView(views: [liveClearLabel, liveSlider, liveFrostedLabel])
        liveSliderRow.orientation = .horizontal
        liveSliderRow.alignment = .centerY
        liveSliderRow.spacing = 8
        let liveFrostStack = NSStackView(views: [liveSliderRow, liveValueLabel])
        liveFrostStack.orientation = .vertical
        liveFrostStack.alignment = .centerX
        liveFrostStack.spacing = 5
        liveFrostStack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        liveFrostStack.frame = NSRect(x: 0, y: 0, width: 226, height: 54)
        liveFrostControlItem.view = liveFrostStack
        liveGlassMenu.addItem(liveFrostControlItem)
        liveGlassMenu.addItem(.separator())
        let resetLiveGlass = liveGlassMenu.addItem(withTitle: "恢复平衡值", action: #selector(resetLiveGlassFrost(_:)), keyEquivalent: "")
        resetLiveGlass.target = self
        liveGlassItem.submenu = liveGlassMenu
        glassMenu.addItem(liveGlassItem)

        glassItem.submenu = glassMenu
        settingsMenu.addItem(glassItem)

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

    private func updateModelPricingMenuItem() {
        let models = editableModelPricingModels()
        modelPricingMenuItem?.isEnabled = !models.isEmpty && !generatorRunning
        modelPricingMenuItem?.toolTip = models.isEmpty
            ? "当前数据目录中的模型均已使用内置价格"
            : "为未定价的开源或本地模型设置价格"
    }

    private func editableModelPricingModels() -> [String] {
        guard let data = dashboard else { return [] }
        return data.models.filter { model in
            let routes = data.pricing.routes.filter { $0.model == model }
            return routes.isEmpty || routes.contains { $0.pricing_kind != "official" }
        }
    }

    fileprivate var canEditModelPricing: Bool {
        !generatorRunning && !editableModelPricingModels().isEmpty
    }

    @objc fileprivate func editModelPricing(_ sender: Any?) {
        guard !generatorRunning, dashboard != nil else {
            presentError("请先完成当前数据目录的统计刷新。")
            return
        }
        let editableModels = editableModelPricingModels()
        guard !editableModels.isEmpty else {
            presentError("当前数据目录中的模型均已使用内置价格。")
            return
        }

        do {
            let preferredModel = editableModels.contains(selectedModel) ? selectedModel : nil
            let editor = try ModelPricingEditor(
                models: editableModels,
                preferredModel: preferredModel,
                configurationURL: pricingConfigurationURL
            )
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "设置模型价格"
            alert.informativeText = "\(currentDataSourceLabel) · \(dataHomeDisplayPath)"
            alert.accessoryView = editor.view
            alert.addButton(withTitle: "保存当前模型并刷新")
            alert.addButton(withTitle: "移除该模型价格")
            alert.addButton(withTitle: "取消")

            var updated: [String: Any] = [:]
            var removing = false
            while true {
                let response = alert.runModal()
                guard response == .alertFirstButtonReturn || response == .alertSecondButtonReturn else { return }
                removing = response == .alertSecondButtonReturn
                do {
                    updated = try editor.updatedConfiguration(provider: currentDataSourceLabel, removing: removing)
                    break
                } catch {
                    alert.informativeText = "\(currentDataSourceLabel) · \(error.localizedDescription)"
                }
            }
            var encoded = try JSONSerialization.data(
                withJSONObject: updated,
                options: [.prettyPrinted, .sortedKeys]
            )
            encoded.append(0x0A)
            try encoded.write(to: pricingConfigurationURL, options: .atomic)
            try? fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: pricingConfigurationURL.path
            )
            toolbarStatus.stringValue = removing
                ? "已移除 \(editor.selectedModel) 的价格"
                : "已保存 \(editor.selectedModel) 的价格"
            refreshReport(nil)
        } catch {
            presentError("模型价格保存失败：\(error.localizedDescription)")
        }
    }

    private func configureWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 756),
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
        window.titlebarAppearsTransparent = false
        window.isOpaque = true
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
        livePanel = LiveMonitorPanel(contentSize: NSSize(width: 300, height: 288))
        let liveController = NSHostingController(
            rootView: LiveTokenPopover(controller: self, presentation: livePresentation)
        )
        liveController.view.wantsLayer = true
        liveController.view.layer?.cornerRadius = 22
        liveController.view.layer?.masksToBounds = true
        livePanel.contentViewController = liveController
        livePanel.pinnedChanged = { [weak self] pinned in
            self?.livePresentation.panelPinned = pinned
        }

        rebuildLiveMonitors(startIfEnabled: false)
        setLiveMonitorEnabled(liveMonitorEnabled, persist: false, ensureReachability: false)
        let historyTimer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            self?.publishHistoricalTotal()
        }
        historyTimer.tolerance = 5
        RunLoop.main.add(historyTimer, forMode: .common)
        historicalDisplayTimer = historyTimer
    }

    private func availableLiveMonitorSources() -> [LiveMonitorSource] {
        var sources: [LiveMonitorSource] = []
        var seenPaths: Set<String> = []

        func append(_ dataHome: URL, label: String) {
            let normalized = normalizedDataHomeURL(dataHome)
            guard isCompatibleDataHome(normalized), seenPaths.insert(normalized.path).inserted else { return }
            sources.append(LiveMonitorSource(
                id: normalized.path,
                label: label,
                dataHome: normalized,
                displayPath: abbreviatedDataHomePath(normalized)
            ))
        }

        append(codexDataHomeURL, label: "Codex")
        append(qodexDataHomeURL, label: "Qodex")
        append(dataHomeURL, label: currentDataSourceLabel)
        return sources
    }

    private func selectedLiveSources() -> [LiveMonitorSource] {
        if selectedLiveMonitorSourceID == allLiveMonitorSourcesID {
            return liveMonitorSources
        }
        return liveMonitorSources.filter { $0.id == selectedLiveMonitorSourceID }
    }

    private func selectedLiveSnapshot() -> LiveTokenSnapshot {
        LiveTokenSnapshot.combining(selectedLiveSources().compactMap { liveSnapshots[$0.id] })
    }

    private func selectedLiveHistoricalTotal() -> Int64? {
        let sources = selectedLiveSources()
        let totals = sources.compactMap { historicalTotalsByDataHome[$0.dataHome.path] }
        guard !sources.isEmpty, totals.count == sources.count else { return nil }
        return totals.reduce(0, +)
    }

    private func updateLivePresentationSource() {
        var options = liveMonitorSources.map { LiveMonitorSourceOption(id: $0.id, label: $0.label) }
        if liveMonitorSources.count > 1 {
            options.append(LiveMonitorSourceOption(id: allLiveMonitorSourcesID, label: "全部"))
        }
        if !options.contains(where: { $0.id == selectedLiveMonitorSourceID }) {
            selectedLiveMonitorSourceID = liveMonitorSources.count > 1
                ? allLiveMonitorSourcesID
                : liveMonitorSources.first?.id ?? allLiveMonitorSourcesID
        }
        UserDefaults.standard.set(selectedLiveMonitorSourceID, forKey: liveMonitorSourceDefaultsKey)

        let selectedSources = selectedLiveSources()
        livePresentation.sourceOptions = options
        livePresentation.selectedSourceID = selectedLiveMonitorSourceID
        if selectedLiveMonitorSourceID == allLiveMonitorSourcesID {
            livePresentation.sourceLabel = "全部来源"
            livePresentation.sourcePath = selectedSources.map(\.displayPath).joined(separator: " + ")
        } else if let source = selectedSources.first {
            livePresentation.sourceLabel = source.label
            livePresentation.sourcePath = source.displayPath
        }
        livePresentation.historicalTotalTokens = selectedLiveHistoricalTotal()
        latestLiveSnapshot = selectedLiveSnapshot()
        if livePanel?.isVisible == true {
            livePresentation.snapshot = latestLiveSnapshot
        }
        lastStatusRateText = nil
        statusItem?.button?.toolTip = "\(livePresentation.sourceLabel) · 总 Token 流速（60 秒滚动平均）"
        if statusItem != nil {
            updateStatusItem(rate: latestLiveSnapshot.totalRate)
        }
    }

    fileprivate func selectLiveMonitorSource(_ sourceID: String) {
        guard livePresentation.sourceOptions.contains(where: { $0.id == sourceID }),
              sourceID != selectedLiveMonitorSourceID
        else { return }
        selectedLiveMonitorSourceID = sourceID
        UserDefaults.standard.set(sourceID, forKey: liveMonitorSourceDefaultsKey)
        updateLivePresentationSource()
        livePresentation.snapshot = latestLiveSnapshot
    }

    private func rebuildLiveMonitors(startIfEnabled: Bool = true) {
        let sources = availableLiveMonitorSources()
        let newSourceIDs = Set(sources.map(\.id))
        if !liveMonitors.isEmpty, newSourceIDs == Set(liveMonitors.keys) {
            liveMonitorSources = sources
            updateLivePresentationSource()
            return
        }

        liveMonitorGeneration &+= 1
        let generation = liveMonitorGeneration
        liveMonitors.values.forEach { $0.stop() }
        liveMonitors.removeAll()
        liveMonitorSources = sources
        liveSnapshots.removeAll()
        latestLiveSnapshot = .zero
        livePresentation.snapshot = .zero
        updateLivePresentationSource()

        for source in sources {
            let monitor = LiveTokenMonitor(
                sessionRoot: source.dataHome.appendingPathComponent("sessions", isDirectory: true)
            ) { [weak self] snapshot in
                guard let self, generation == self.liveMonitorGeneration else { return }
                self.liveSnapshots[source.id] = snapshot
                self.latestLiveSnapshot = self.selectedLiveSnapshot()
                if self.livePanel.isVisible {
                    self.livePresentation.snapshot = self.latestLiveSnapshot
                }
                self.updateStatusItem(rate: self.latestLiveSnapshot.totalRate)
            }
            liveMonitors[source.id] = monitor
            if startIfEnabled, liveMonitorEnabled {
                monitor.start(interval: TimeInterval(livePresentation.refreshSeconds))
            }
        }
    }

    private func installStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: 30)
        statusItem = item
        guard let button = item.button else { return }
        button.title = ""
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        button.target = self
        button.action = #selector(toggleLivePopover(_:))
        button.sendAction(on: [.leftMouseUp])
        button.toolTip = "\(livePresentation.sourceLabel) · 总 Token 流速（60 秒滚动平均）"
        updateStatusItem(rate: latestLiveSnapshot.totalRate)
    }

    private func updateStatusItem(rate: Double) {
        guard let button = statusItem?.button else { return }
        let value = formatStatusTokenRate(rate)
        guard value != lastStatusRateText else { return }
        lastStatusRateText = value
        let sourceTitle = selectedLiveMonitorSourceID == allLiveMonitorSourcesID
            ? "ALL"
            : String(livePresentation.sourceLabel.prefix(7))

        let size = NSSize(width: 30, height: NSStatusBar.system.thickness)
        let image = NSImage(size: size, flipped: true) { _ in
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byClipping
            let titleAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 6, weight: .medium),
                .foregroundColor: NSColor.black,
                .paragraphStyle: paragraph
            ]
            let valueAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .semibold),
                .foregroundColor: NSColor.black,
                .paragraphStyle: paragraph
            ]
            (sourceTitle as NSString).draw(
                in: NSRect(x: 0, y: 1, width: size.width, height: 8),
                withAttributes: titleAttributes
            )
            (value as NSString).draw(
                in: NSRect(x: 0, y: 8, width: size.width, height: 13),
                withAttributes: valueAttributes
            )
            return true
        }
        image.isTemplate = true
        button.image = image
        button.setAccessibilityLabel("\(livePresentation.sourceLabel) total Token rate \(formatTokenRate(rate)) tokens per second")
    }

    private func liveToolbarImage(enabled: Bool) -> NSImage? {
        let symbol = enabled ? "gauge.with.dots.needle.67percent" : "gauge.with.dots.needle.33percent"
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "顶部栏 Token 统计") else {
            return nil
        }
        guard enabled,
              let configured = image.withSymbolConfiguration(.init(paletteColors: [AtlasColor.teal]))
        else { return image }
        configured.isTemplate = false
        return configured
    }

    @objc private func toggleLiveMonitor(_ sender: Any?) {
        setLiveMonitorEnabled(!liveMonitorEnabled, persist: true)
    }

    private func setLiveMonitorEnabled(_ enabled: Bool, persist: Bool, ensureReachability: Bool = true) {
        if ensureReachability && !enabled && !showsInDock {
            applyDockPresence(true, persist: true)
        }
        liveMonitorEnabled = enabled
        if persist { UserDefaults.standard.set(enabled, forKey: "liveTokenMonitorEnabledV2") }
        liveToolbarItem?.image = liveToolbarImage(enabled: enabled)
        liveMenuItem?.state = enabled ? .on : .off
        if enabled {
            installStatusItem()
            if liveMonitors.isEmpty {
                rebuildLiveMonitors(startIfEnabled: false)
            }
            liveMonitors.values.forEach {
                $0.start(interval: TimeInterval(livePresentation.refreshSeconds))
            }
        } else {
            livePanel.dismissAndUnpin()
            liveMonitorGeneration &+= 1
            liveMonitors.values.forEach { $0.stop() }
            liveMonitors.removeAll()
            liveSnapshots.removeAll()
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
            livePresentation.historicalTotalTokens = selectedLiveHistoricalTotal()
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
        applyAppearanceMode(mode)
    }

    @objc fileprivate func showPersonalization(_ sender: Any?) {
        if personalizationWindow == nil {
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 420), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            panel.title = "个性化"
            panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: AtlasPersonalizationView(controller: self))
            panel.center()
            personalizationWindow = panel
        }
        personalizationWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    fileprivate func closePersonalization() { personalizationWindow?.close() }

    fileprivate func applyAppearanceMode(_ mode: AppearanceMode) {
        appearanceMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: appearanceModeDefaultsKey)
        NSApp.appearance = mode.appKitAppearance
        for (candidate, item) in appearanceMenuItems {
            item.state = candidate == mode ? .on : .off
        }
        window.contentView?.needsDisplay = true
        livePanel.contentView?.needsDisplay = true
    }

    @objc private func changeAppGlassFrost(_ sender: NSSlider) {
        applyAppGlassFrost(sender.doubleValue)
    }

    @objc private func resetAppGlassFrost(_ sender: Any?) {
        applyAppGlassFrost(defaultAppGlassFrostAmount)
    }

    private func applyAppGlassFrost(_ value: Double) {
        let clamped = min(1, max(0, value))
        withAnimation(.linear(duration: 0.10)) {
            appGlassFrostAmount = clamped
        }
        appGlassFrostSlider?.doubleValue = clamped
        appGlassFrostValueLabel?.stringValue = glassFrostLabel(clamped)
        appGlassFrostSaveWorkItem?.cancel()
        let save = DispatchWorkItem {
            UserDefaults.standard.set(clamped, forKey: appGlassFrostDefaultsKey)
        }
        appGlassFrostSaveWorkItem = save
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20, execute: save)

        windowBackdropUpdateWorkItem?.cancel()
        let backdropUpdate = DispatchWorkItem { [weak self] in
            guard let self, !self.generatorRunning else { return }
            self.enableWindowBackdrop()
        }
        windowBackdropUpdateWorkItem = backdropUpdate
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: backdropUpdate)
    }

    @objc private func changeLiveGlassFrost(_ sender: NSSlider) {
        applyLiveGlassFrost(sender.doubleValue)
    }

    @objc private func resetLiveGlassFrost(_ sender: Any?) {
        applyLiveGlassFrost(defaultLiveGlassFrostAmount)
    }

    private func applyLiveGlassFrost(_ value: Double) {
        let clamped = min(1, max(0, value))
        withAnimation(.linear(duration: 0.10)) {
            liveGlassFrostAmount = clamped
        }
        liveGlassFrostSlider?.doubleValue = clamped
        liveGlassFrostValueLabel?.stringValue = glassFrostLabel(clamped)
        liveGlassFrostSaveWorkItem?.cancel()
        let save = DispatchWorkItem {
            UserDefaults.standard.set(clamped, forKey: liveGlassFrostDefaultsKey)
        }
        liveGlassFrostSaveWorkItem = save
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20, execute: save)
    }

    private func glassFrostLabel(_ value: Double) -> String {
        let descriptor: String
        switch value {
        case ..<0.34: descriptor = "清透"
        case 0.72...: descriptor = "磨砂"
        default: descriptor = "平衡"
        }
        return "\(descriptor) · \(Int((value * 100).rounded()))%"
    }

    @objc private func chooseLiveRefreshMenu(_ sender: NSMenuItem) {
        chooseLiveRefresh(sender.tag)
    }

    fileprivate func showMainWindow() {
        if !livePanel.isPinned { livePanel.orderOut(nil) }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if !generatorRunning {
            DispatchQueue.main.async { [weak self] in
                self?.enableWindowBackdrop()
            }
        }
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        guard !generatorRunning else { return }
        enableWindowBackdrop()
    }

    private func chooseLiveRefresh(_ seconds: Int) {
        guard [1, 2, 5].contains(seconds) else { return }
        livePresentation.refreshSeconds = seconds
        UserDefaults.standard.set(seconds, forKey: liveRefreshDefaultsKey)
        for (candidate, item) in refreshMenuItems {
            item.state = candidate == seconds ? .on : .off
        }
        liveMonitors.values.forEach { $0.setInterval(TimeInterval(seconds)) }
    }

    private func publishHistoricalTotal() {
        livePresentation.historicalTotalTokens = selectedLiveHistoricalTotal()
        persistHistoricalTotals()
    }

    private func reconcileHistoricalTotal(_ total: Int64) {
        historicalTotalTokens = max(0, total)
        historicalTotalsByDataHome[dataHomeHistoryKey] = historicalTotalTokens
        publishHistoricalTotal()
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
            let item = NSMenuToolbarItem(itemIdentifier: identifier)
            item.label = ""
            item.paletteLabel = "设置"
            item.toolTip = "设置"
            item.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "设置")
            item.menu = settingsMenu
            item.showsIndicator = false
            return item
        case .refreshReport:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = ""
            item.paletteLabel = "刷新"
            item.toolTip = "重新扫描当前数据目录 \(dataHomeDisplayPath)（⌘R）"
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
            item.isEnabled = dashboard != nil && !generatorRunning
            exportToolbarItem = item
            return item
        case .liveMonitor:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = ""
            item.paletteLabel = "顶部栏 Token 统计"
            item.toolTip = "状态栏显示 60 秒实时速率；展开后同时显示历史累计 Token"
            item.image = liveToolbarImage(enabled: liveMonitorEnabled)
            item.target = self
            item.action = #selector(toggleLiveMonitor(_:))
            liveToolbarItem = item
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
        let selectedDataHome = dataHomeURL
        guard isCompatibleDataHome(selectedDataHome) else {
            presentError("当前数据目录不兼容：需要存在 \(selectedDataHome.path)/sessions。")
            return
        }
        guard let generatorURL = Bundle.main.resourceURL?.appendingPathComponent("codex_token_heatmap.py") else {
            presentError("应用内的统计生成器缺失。")
            return
        }
        guard let pythonURL = locatePython() else {
            presentError("需要 Python 3.9 或更高版本。")
            return
        }

        generatorRunning = true
        updateModelPricingMenuItem()
        setLoading(true, title: "正在刷新 Token 历史", detail: dataHomeLoadingDetail)
        appendLog("\n[\(timestampLabel())] Native app refresh\nData home: \(selectedDataHome.path)\nPython: \(pythonURL.path)\n")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let process = Process()
            process.executableURL = pythonURL
            process.arguments = [generatorURL.path, "--data-home", selectedDataHome.path]
            process.environment = ProcessInfo.processInfo.environment.merging(["HOME": self.homeURL.path]) { _, new in new }
            let logHandle = self.openLogHandle()
            process.standardOutput = logHandle
            process.standardError = logHandle
            do {
                try process.run()
                process.waitUntilExit()
                logHandle?.closeFile()
                if process.terminationStatus == 0 {
                    let data = try Data(contentsOf: self.summaryURL)
                    let envelope = try JSONDecoder().decode(ReportEnvelope.self, from: data)
                    DispatchQueue.main.async {
                        self.loadGeneratedReport(envelope)
                    }
                } else {
                    DispatchQueue.main.async {
                        self.generatorRunning = false
                        self.updateModelPricingMenuItem()
                        self.setLoading(false, title: "", detail: "")
                        self.presentError("生成报表失败，退出状态为 \(process.terminationStatus)。")
                    }
                }
            } catch {
                logHandle?.closeFile()
                DispatchQueue.main.async {
                    self.generatorRunning = false
                    self.updateModelPricingMenuItem()
                    self.setLoading(false, title: "", detail: "")
                    self.presentError("统计刷新失败：\(error.localizedDescription)")
                }
            }
        }
    }

    private func loadGeneratedReport(_ envelope: ReportEnvelope) {
        do {
            guard let sessionsRoot = envelope.sessions_root, !sessionsRoot.isEmpty else {
                throw NSError(
                    domain: "CodexTokenAtlasReport",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "报表缺少会话数据目录信息"]
                )
            }
            let reportedDataHome = normalizedDataHomeURL(
                URL(fileURLWithPath: sessionsRoot, isDirectory: true)
            )
            guard reportedDataHome.path == dataHomeURL.path else {
                throw NSError(
                    domain: "CodexTokenAtlasReport",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "报表来自其他数据目录，请重新刷新"]
                )
            }
            let loadedDashboard = envelope.dashboard
            if let sourceID = envelope.source_id,
               let dashboardSourceID = loadedDashboard.source_id,
               sourceID != dashboardSourceID {
                throw NSError(
                    domain: "CodexTokenAtlasReport",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "报表来源标识不一致"]
                )
            }
            dashboard = loadedDashboard
            if selectedModel != "all", !loadedDashboard.models.contains(selectedModel) {
                selectedModel = "all"
            }
            reconcileHistoricalTotal(loadedDashboard.totals["all"]?.total_tokens ?? 0)
            updateLivePresentationSource()
            lastStatusRateText = nil
            if statusItem != nil {
                updateStatusItem(rate: latestLiveSnapshot.totalRate)
            }
            synchronizeDateSelection(with: loadedDashboard)
            generatorRunning = false
            updateModelPricingMenuItem()
            setLoading(false, title: "", detail: "")
            toolbarStatus.stringValue = "\(currentDataSourceLabel) · 已更新 \(DateFormatter.shortTime.string(from: Date()))"
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
            updateModelPricingMenuItem()
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
        historicalTotalsByDataHome[dataHomeHistoryKey] = expected.total_tokens + 1_000_000
        reconcileHistoricalTotal(expected.total_tokens)
        try require(historicalTotalTokens == expected.total_tokens, "history did not reconcile downward to the report")

        if let model = data.models.first, let modelExpected = data.totals[model] {
            selectedModel = model
            let modelUsage = filteredUsage(scope: model, data: data)
            try require(modelUsage.total_tokens == modelExpected.total_tokens, "model filter total differs from report scope")
            try require(modelUsage.calls == modelExpected.calls, "model filter calls differ from report scope")
            selectedModel = "all"
        }

        let hourly = filteredHourly(data).0.flatMap { $0 }.reduce(Usage()) { $0.adding($1) }
        try require(hourly.total_tokens == fullUsage.total_tokens, "filtered hourly total differs from daily total")
        try require(hourly.calls == fullUsage.calls, "filtered hourly calls differ from daily calls")

        let routeUsage = data.pricing.routes.map { filteredRoute($0, data: data).0 }.reduce(Usage()) { $0.adding($1) }
        try require(routeUsage.total_tokens == fullUsage.total_tokens, "route total differs from overall total")
        let sessionUsage = data.sessions.map { filteredSessionUsage($0, data: data) }.reduce(Usage()) { $0.adding($1) }
        try require(sessionUsage.total_tokens == fullUsage.total_tokens, "session total differs from overall total")
        try require(data.records != nil, "usage records missing from generated report")
        if let records = data.records {
            try require(records.current_streak <= records.longest_streak, "current streak exceeds lifetime record")
            try require(records.longest_streak <= records.active_days, "streak exceeds active days")
            try require((records.peak_hour?.total_tokens ?? 0) <= fullUsage.total_tokens, "peak window exceeds lifetime tokens")
            if let peak = records.peak_hour { try require(peak.window_seconds == 3600, "hourly volume window is invalid") }
            if let peak = records.peak_throughput { try require(peak.window_seconds == 60 && peak.rate(output: false) == Double(peak.total_tokens) / 60, "throughput denominator is invalid") }
            if let peak = records.peak_output_throughput { try require(peak.window_seconds == 60 && peak.rate(output: true) == Double(peak.output_tokens) / 60, "output throughput denominator is invalid") }
            try require(records.achievements.count == 12 && records.achievements.allSatisfy { $0.levels.prefix(3).map(\.name) == ["铜", "银", "金"] }, "tiered achievement wall is incomplete")
            let hiddenFamilies = Set(records.achievements.filter { $0.levels.contains { $0.isHidden } }.map(\.id))
            try require(hiddenFamilies == Set(["days", "sessions", "collaborative_days", "total_tokens", "output_tokens"]), "hidden achievements are not selective")
            let revealedLevels = records.achievements.reduce(0) { total, badge in total + badge.levels.filter { $0.isHidden && badge.value >= $0.target }.count }
            try require(records.levelCount == 36 + revealedLevels, "locked secret tiers leaked into total count")
            try require(Set(records.achievements.map(\.categoryID)) == Set(UsageRecords.categories.map(\.0)), "achievement categories are incomplete")
            try require(records.milestones.count <= records.unlockedCount, "milestone dates exceed earned levels")
            try require(records.nextAchievement?.nextLevel != nil || records.unlockedCount == records.levelCount, "next achievement is invalid")
            for (id, expected) in [("total_tokens", fullUsage.total_tokens), ("output_tokens", fullUsage.output_tokens), ("reasoning_tokens", fullUsage.reasoning_output_tokens), ("cached_tokens", fullUsage.cached_input_tokens)] {
                try require(records.achievements.first(where: { $0.id == id })?.value == Int(expected), "achievement counter differs from confirmed report: \(id)")
            }
            try require(records.insights != nil, "record insights are missing")
            if let insights = records.insights {
                try require(insights.collaborative_sessions <= data.audit.conversationSessionCount, "collaborative conversations exceed user conversations")
                try require(insights.models.reduce(Int64(0)) { $0 + $1.total_tokens } == fullUsage.total_tokens, "model footprints differ from accounting total")
                try require((insights.peak_day?.total_tokens ?? 0) <= fullUsage.total_tokens, "peak day exceeds total usage")
                try require((insights.collaborative_days ?? 0) <= records.active_days, "collaborative days exceed active days")
                try require(records.achievements.first(where: { $0.id == "collaborative_days" })?.value == insights.collaborative_days, "collaborative-day badge differs from confirmed days")
                try require((insights.largest_team_session?.worker_count ?? 0) <= insights.worker_count, "single-conversation worker record exceeds all workers")
            }
            if let streak = records.achievements.first(where: { $0.id == "streak" }) {
                try require(streak.levels.map(\.target) == [3, 7, 14], "streak tiers differ from the intended milestones")
                try require(streak.current_value == records.current_streak, "streak progress uses a past record")
            }
        }

        // Synthetic counters and timestamps exercise rounding and date-label boundaries.
        let rateFixture = UsageRecords.Window(start: "2024-04-15T12:34:05.123000+08:00", end: "2024-04-15T12:35:05.123000+08:00", window_seconds: 60, total_tokens: 8_000_000, output_tokens: 37_000)
        let tierFixtures: [UsageRecords.Achievement.Level] = zip(["铜", "银", "金", "钻石"], [10, 30, 100, 500]).map {
            .init(name: $0.0, target: $0.1, unlocked_on: "2024-04-15", hidden: $0.0 == "钻石")
        }
        func badgeFixture(_ value: Int, levels: [UsageRecords.Achievement.Level]? = nil) -> UsageRecords.Achievement {
            .init(id: "sessions", title: "对话旅程", symbol: "bubble.left.and.bubble.right", detail: "累计会话", value: value, current_value: value,
                  unit: "条", levels: levels ?? tierFixtures, category: "habit", rule: "累计有用量的用户对话。")
        }
        for value in [0, 9, 10, 29, 30, 99, 100, 499, 500, 501] {
            let badge = badgeFixture(value)
            try require(badge.unlockedLevels == tierFixtures.filter { value >= $0.target }.count, "achievement boundary is incorrect")
            try require(badge.nextLevel?.target == tierFixtures.first { !$0.isHidden && value < $0.target }?.target, "next level exposes a hidden tier")
            try require((0...1).contains(badge.progress), "achievement progress is outside its bounds")
            try require(badge.visibleLevels.count == (value >= 500 ? 4 : 3), "secret level slot was exposed early")
            if value < 500 {
                try require(!badge.progressLabel.contains("钻石") && !badge.remainingLabel.contains("500"), "secret goal leaked into progress copy")
            }
        }
        try require(badgeFixture(500).completedLabel == "钻石级已达成" && badgeFixture(500).remainingLabel == "钻石级已达成", "diamond completion label is incorrect")
        try require(badgeFixture(100).nextLevel == nil && badgeFixture(499).progress == 1 && badgeFixture(499).completedLabel == "金级已达成", "gold preview exposes hidden progression")
        try require(badgeFixture(100, levels: Array(tierFixtures.prefix(3))).completedLabel == "金级已达成", "legacy three-tier reports are not supported")
        if ProcessInfo.processInfo.environment["TOKEN_ATLAS_RENDER_ACHIEVEMENTS"] == "1" {
            try renderAchievementPreviews([10, 30, 100, 500].map { badgeFixture($0) })
        }
        try require(rateFixture.rateLabel(output: false) == "133.3K" && rateFixture.rateLabel(output: true) == "616.7", "peak speed formatting is invalid")
        try require(recordWindowLabel(rateFixture.start, rateFixture.end, includeSeconds: true) == "2024-04-15 · 12:34:05–12:35:05", "same-day record range repeats the date")
        try require(recordWindowLabel("2024-04-15T23:45:58+08:00", "2024-04-16T00:45:58+08:00") == "2024-04-15 23:45 – 04-16 00:45", "overnight record range loses its date")
        try require(recordWindowLabel("2025-12-31T23:59:00+08:00", "2026-01-01T00:00:00+08:00") == "2025-12-31 23:59 – 2026-01-01 00:00", "cross-year record range loses its year")
        try require(recordWindowLabel("", "") == " – ", "incomplete record range is unsafe")

        let fullCost = filteredCost(scope: "all", data: data)
        if currentDataSourceID == "qodex", data.pricing.customModelCount == 0 {
            try require(fullCost.priced_tokens == 0, "Qodex local usage was assigned an official price")
            try require(fullCost.unpriced_tokens == fullUsage.total_tokens, "Qodex unpriced total differs from usage")
        }
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
        try require(last7.total_tokens >= 0 && last7.total_tokens <= fullUsage.total_tokens, "last-7-days filter is invalid")
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
        let sameFileExport = exportFiles.first(where: { $0.0 == .html })!.1
        let htmlBeforeCopy = try Data(contentsOf: sameFileExport)
        try performExport(.html, to: sameFileExport)
        let htmlAfterCopy = try Data(contentsOf: sameFileExport)
        try require(htmlBeforeCopy == htmlAfterCopy, "export to the source path changed the report")
        let preservedDestination = exportDirectory.appendingPathComponent("preserved.html")
        try htmlBeforeCopy.write(to: preservedDestination)
        var exportFailed = false
        do {
            try copyExport(from: exportDirectory.appendingPathComponent("missing.html"), to: preservedDestination)
        } catch { exportFailed = true }
        let preservedHTML = try Data(contentsOf: preservedDestination)
        try require(exportFailed && preservedHTML == htmlBeforeCopy, "failed export changed the existing destination")
        if let model = data.models.first {
            selectedModel = model
            try require(modelCSV(data).split(separator: "\n").count <= 2, "model CSV ignored the selected model")
            selectedModel = "all"
        }
        if let route = data.pricing.routes.first(where: { $0.service_tier == "priority" && $0.standard_rates != nil }) {
            try require(route.displayedRates(for: .simple)?.input == route.standard_rates?.input, "simple pricing shows tiered rates")
            try require(route.displayedRates(for: .tiered)?.input == route.rates?.input, "tiered pricing shows standard rates")
        }
        let sessionExport = try String(contentsOf: exportDirectory.appendingPathComponent(ExportFormat.session.fileName), encoding: .utf8)
        try require(sessionExport.contains("standard_value_usd") && sessionExport.contains("tiered_value_usd"), "session export lacks official values")
        try require(sessionExport.contains("source_id") && sessionExport.contains("rollout_files") && sessionExport.contains("internal_threads"), "session export lacks source or logical-session fields")
        let jsonData = try Data(contentsOf: exportDirectory.appendingPathComponent(ExportFormat.json.fileName))
        let json = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
        try require(json?["date_range"] != nil, "selection JSON lacks date range")
        try require(json?["source_id"] as? String == currentDataSourceID, "selection JSON has the wrong data source")
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
        guard !generatorRunning else { return }
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
        if format == .html {
            guard let source = exportFiles.first(where: { $0.0 == .html })?.1 else { return }
            try copyExport(from: source, to: destination)
            return
        }
        switch format {
        case .json:
            let payload = selectedExportPayload(data)
            let output = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try output.write(to: destination, options: .atomic)
        case .daily:
            try Data(dailyCSV(data).utf8).write(to: destination, options: .atomic)
        case .hourly:
            try Data(hourlyCSV(data).utf8).write(to: destination, options: .atomic)
        case .model:
            try Data(modelCSV(data).utf8).write(to: destination, options: .atomic)
        case .route:
            try Data(routeCSV(data).utf8).write(to: destination, options: .atomic)
        case .session:
            try Data(sessionCSV(data).utf8).write(to: destination, options: .atomic)
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
            "source_id": currentDataSourceID,
            "source_label": currentDataSourceLabel,
            "data_home": dataHomeURL.path,
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
            "standard_cache_savings_usd": value.standard_cache_savings_usd,
            "selected_cache_savings_usd": pricingMode.cacheSavings(value),
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

    private var sourceHeaders: [String] { ["source_id", "source_label"] }
    private var sourceCells: [String] { [currentDataSourceID, currentDataSourceLabel] }

    private func dailyCSV(_ data: DashboardData) -> String {
        var rows = [sourceHeaders + ["date", "model", "pricing_mode"] + usageHeaders + costHeaders]
        let usageDays = data.daily[selectedModel] ?? [:]
        let costDays = data.pricing.daily[selectedModel] ?? [:]
        for day in usageDays.keys.sorted() where isIncluded(day, in: data) {
            rows.append(sourceCells + [day, selectedModel, pricingMode == .simple ? "simple" : "tiered"] + usageCells(usageDays[day] ?? Usage()) + costCells(costDays[day] ?? Cost()))
        }
        return csv(rows)
    }

    private func hourlyCSV(_ data: DashboardData) -> String {
        var rows = [sourceHeaders + ["local_hour", "model", "pricing_mode"] + usageHeaders + costHeaders]
        let timeline = data.timeline_hourly[selectedModel] ?? [:]
        let costTimeline = data.pricing.timeline_hourly[selectedModel] ?? [:]
        for hour in timeline.keys.sorted() where isIncluded(String(hour.prefix(10)), in: data) {
            rows.append(sourceCells + [hour, selectedModel, pricingMode == .simple ? "simple" : "tiered"] + usageCells(timeline[hour] ?? Usage()) + costCells(costTimeline[hour] ?? Cost()))
        }
        return csv(rows)
    }

    private func modelCSV(_ data: DashboardData) -> String {
        var rows = [sourceHeaders + ["model", "pricing_mode"] + usageHeaders + costHeaders]
        for model in data.models where selectedModel == "all" || model == selectedModel {
            let usage = filteredUsage(scope: model, data: data)
            guard usage.calls > 0 else { continue }
            rows.append(sourceCells + [model, pricingMode == .simple ? "simple" : "tiered"] + usageCells(usage) + costCells(filteredCost(scope: model, data: data)))
        }
        return csv(rows)
    }

    private func routeCSV(_ data: DashboardData) -> String {
        var rows = [sourceHeaders + ["route_provider", "model", "service_tier", "pricing_provider", "pricing_model", "pricing_mode"] + usageHeaders + costHeaders]
        for route in data.pricing.routes where selectedModel == "all" || route.model == selectedModel {
            let filtered = filteredRoute(route, data: data)
            guard filtered.0.calls > 0 else { continue }
            rows.append(sourceCells + [route.route_provider, route.model, route.service_tier, route.pricing_provider ?? "", route.pricing_model ?? "", pricingMode == .simple ? "simple" : "tiered"] + usageCells(filtered.0) + costCells(filtered.1))
        }
        return csv(rows)
    }

    private func sessionCSV(_ data: DashboardData) -> String {
        var rows = [sourceHeaders + ["session_id", "title", "lineage", "rollout_files", "internal_threads", "models", "providers", "service_tiers", "pricing_mode"] + usageHeaders + costHeaders]
        for session in data.sessions {
            let usage = filteredSessionUsage(session, data: data)
            guard usage.calls > 0 else { continue }
            let cost = filteredSessionCost(session, data: data)
            rows.append(sourceCells + [session.id, session.title, session.parent_id.isEmpty ? "conversation" : "user fork +\(session.lineage_depth)", String(session.rolloutFileCount), String(session.internalThreadCount), session.by_model.keys.sorted().joined(separator: ";"), session.by_provider.keys.sorted().joined(separator: ";"), session.by_service_tier.keys.sorted().joined(separator: ";"), pricingMode == .simple ? "simple" : "tiered"] + usageCells(usage) + costCells(cost))
        }
        return csv(rows)
    }

    private func copyExport(from source: URL, to destination: URL) throws {
        guard fileManager.fileExists(atPath: source.path) else {
            throw NSError(domain: "CodexTokenAtlas", code: 1, userInfo: [NSLocalizedDescriptionKey: "找不到 \(source.lastPathComponent)"])
        }
        guard source.standardizedFileURL.resolvingSymlinksInPath() != destination.standardizedFileURL.resolvingSymlinksInPath() else { return }
        try Data(contentsOf: source).write(to: destination, options: .atomic)
    }

    @objc private func revealExportFiles(_ sender: Any?) {
        let existing = exportFiles.map(\.1).filter { fileManager.fileExists(atPath: $0.path) }
        if existing.isEmpty { presentError("当前还没有可显示的中间文件。") }
        else { NSWorkspace.shared.activateFileViewerSelecting(existing) }
    }

    private func setLoading(_ loading: Bool, title: String, detail: String) {
        refreshToolbarItem?.isEnabled = !loading
        exportToolbarItem?.isEnabled = !loading && dashboard != nil
        generatorRunning = loading
        if loading {
            suspendWindowBackdrop()
            loadingTitleText = title
            loadingDetailText = detail
            toolbarSpinner.startAnimation(nil)
            toolbarStatus.stringValue = title
        } else {
            toolbarSpinner.stopAnimation(nil)
            enableWindowBackdrop()
        }
    }

    private var windowBackdropConfiguration: (radius: Int32, opacity: Float) {
        let amount = min(1, max(0, appGlassFrostAmount))
        return (
            radius: Int32((8 + amount * 24).rounded()),
            opacity: Float(0.78 + amount * 0.12)
        )
    }

    private func enableWindowBackdrop() {
        guard window != nil, window.isVisible, !generatorRunning else { return }
        let configuration = windowBackdropConfiguration
        window.isOpaque = false
        window.backgroundColor = NSColor.clear.withAlphaComponent(0.000_000_1)

        if AtlasWindowBackdrop.shared.apply(
            windowNumber: window.windowNumber,
            blurRadius: configuration.radius,
            opacityHint: configuration.opacity
        ) {
            usesWindowBackdrop = true
            window.contentView?.needsDisplay = true
        } else {
            suspendWindowBackdrop()
        }
    }

    private func suspendWindowBackdrop() {
        usesWindowBackdrop = false
        guard window != nil else { return }
        window.isOpaque = true
        window.backgroundColor = AtlasColor.canvas
        if window.windowNumber > 0, AtlasWindowBackdrop.shared.isAvailable {
            _ = AtlasWindowBackdrop.shared.apply(
                windowNumber: window.windowNumber,
                blurRadius: 0,
                opacityHint: 1
            )
        }
        window.contentView?.needsDisplay = true
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
    static let rate: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 6
        return formatter
    }()
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
    @ObservedObject private var theme = AtlasTheme.shared
    @ObservedObject var controller: AppDelegate
    @ObservedObject var presentation: LiveMonitorPresentation

    private var snapshot: LiveTokenSnapshot { presentation.snapshot }
    private var isActive: Bool {
        snapshot.lastEventAt.map { Date().timeIntervalSince($0) <= LiveTokenSnapshot.windowSeconds } ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            sourcePicker
            historySummary
            rateHeader
            LiveRateChart(samples: snapshot.samples)
                .frame(height: 38)
            rateBreakdown
            Divider().opacity(0.55)
            statusLine
        }
        .padding(14)
        .frame(width: 300, height: 288)
        .atlasGlass(
            in: RoundedRectangle(cornerRadius: 22, style: .continuous),
            tint: Color(nsColor: AtlasColor.teal).opacity(0.012),
            clear: true
        )
        .environment(\.atlasGlassFrostAmount, controller.liveGlassFrostAmount)
    }

    private var sourcePicker: some View {
        Picker(
            "实时监控来源",
            selection: Binding(
                get: { presentation.selectedSourceID },
                set: { controller.selectLiveMonitorSource($0) }
            )
        ) {
            ForEach(presentation.sourceOptions) { source in
                Text(source.label).tag(source.id)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .accessibilityLabel("实时监控来源")
    }

    private var historySummary: some View {
        HStack(alignment: .lastTextBaseline, spacing: 8) {
            Text("\(presentation.sourceLabel) · 上次统计")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color(nsColor: AtlasColor.inkSoft))
                .help("\(presentation.sourcePath)\n累计量取各来源最近刷新确认值；实时速率独立计算。")
            Spacer()
            Text(presentation.historicalTotalTokens.map(shortNumber) ?? "待刷新")
                .font(.system(size: 18, weight: .bold, design: .monospaced))
                .foregroundStyle(Color(nsColor: AtlasColor.ink))
                .help(presentation.historicalTotalTokens.map(formatInt) ?? "请在主窗口刷新所选来源后查看累计量")
        }
    }

    private var rateHeader: some View {
        HStack(alignment: .lastTextBaseline, spacing: 8) {
            Text(formatTokenRate(snapshot.totalRate))
                .font(.system(size: 32, weight: .bold, design: .monospaced))
                .foregroundStyle(Color(nsColor: AtlasColor.ink))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text("Tokens/s")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(nsColor: AtlasColor.teal))
            Spacer(minLength: 4)
            Text(isActive ? "ACTIVE" : "IDLE")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(Color(nsColor: isActive ? AtlasColor.tealDeep : AtlasColor.inkSoft))
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
            Text("\(snapshot.monitoredFiles) 文件 · \(String(format: "%.1fms", snapshot.pollDurationMilliseconds))")
            Spacer()
            Text("60秒 \(shortNumber(snapshot.windowUsage.totalTokens))")
            Text("·")
            Text(lastEventLabel)
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .foregroundStyle(Color(nsColor: AtlasColor.inkSoft))
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
        .atlasGlass(in: Circle())
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
    @ObservedObject private var theme = AtlasTheme.shared
    @ObservedObject var controller: AppDelegate
    @State private var sessionSearch = ""
    @State private var sessionPage = 0
    @State private var showingAchievements = false
    @State private var achievementCategory = "all"
    @State private var achievementState = "all"
    @State private var showAllModelFootprints = false

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
                            if showingAchievements {
                                HStack {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text("成就与纪录").font(.system(size: 28, weight: .bold))
                                        Text(achievementSummary(data))
                                            .font(.system(size: 12)).foregroundStyle(Color(nsColor: AtlasColor.muted))
                                    }
                                    Spacer()
                                    AtlasControl(label: "数据源") { dataSourceMenu }
                                }
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                HStack(spacing: 18) {
                                    ForEach([("personal-records", "个人最佳"), ("achievement-wall", "成就墙"), ("daily-highlights", "单日高光"), ("model-footprints", "模型足迹"), ("milestone-history", "达成时间线")], id: \.0) { section in
                                        Button(section.1) { proxy.scrollTo(section.0, anchor: .top) }
                                    }
                                    Spacer()
                                }
                                .buttonStyle(.borderless).font(.system(size: 12)).padding(.horizontal, 12)
                                if let records = data.records {
                                    recordsPanel(records, data: data, proxy: proxy).id("personal-records")
                                    achievementsPanel(records).id("achievement-wall")
                                    if let insights = records.insights {
                                        dailyHighlights(insights, data: data, proxy: proxy).id("daily-highlights")
                                        modelFootprints(insights).id("model-footprints")
                                    }
                                    milestoneHistory(records).id("milestone-history")
                                } else {
                                    Text("刷新统计后生成使用纪录与成就。")
                                }
                            } else {
                                hero(data)
                                stats(data)
                                AtlasPanel(title: "一周 × 24 小时", subtitle: "按星期与本地小时聚合；悬停显示 token、calls 与当前计价金额。", trailing: hourlyScaleNote(data)) {
                                    HourlyHeatmap(data: data, controller: controller)
                                }
                                AtlasPanel(title: "每日历史", subtitle: "按本地日期排列；同样使用连续色阶，可随模型、指标与周期筛选。", trailing: dailyScaleNote(data)) {
                                    DailyHeatmap(data: data, controller: controller)
                                }
                                .id("daily")
                                if let records = data.records {
                                    AtlasPanel(title: "成就与纪录", subtitle: "\(controller.currentDataSourceLabel) · 全部历史 · 全部模型", trailing: "已解锁 \(records.unlockedCount) / \(records.levelCount) 级") {
                                        overviewHighlights(records, proxy: proxy)
                                    }
                                }
                                HStack(alignment: .top, spacing: 14) {
                                    AtlasPanel(title: "模型分布", subtitle: "模型按调用发生时的上下文归属。") {
                                        modelTable(data)
                                    }
                                    AtlasPanel(title: "高用量日期", subtitle: "当前模型、指标与周期筛选。") {
                                        topDaysTable(data)
                                    }
                                }
                                sessionPanel(data).id("sessions")
                                pricingPanel(data).id("pricing")
                                auditPanel(data).id("audit")
                            }
                            HStack {
                                Text("\(controller.currentDataSourceLabel) · \(controller.dataHomeDisplayPath) · Generated \(data.generated_at_label) · \(data.timezone)")
                                Spacer()
                            }
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Color(nsColor: AtlasColor.muted))
                            .padding(.horizontal, 4)
                        }
                        .frame(minWidth: 940, maxWidth: 1320)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 20)
                        .padding(.top, 24)
                        .padding(.bottom, 50)
                    }
                    .safeAreaInset(edge: .top, spacing: 0) {
                        HStack(spacing: 18) {
                            ForEach([("dashboard-top", "概览"), ("achievements", "成就"), ("daily", "每日"), ("sessions", "会话"), ("pricing", "价格"), ("audit", "审计")], id: \.0) { target in
                                Button(target.1) { navigate(to: target.0, proxy: proxy) }
                                    .accessibilityLabel("跳转至\(target.1)")
                                    .foregroundStyle(Color(nsColor: showingAchievements && target.0 == "achievements" ? AtlasColor.teal : AtlasColor.inkSoft))
                            }
                            Spacer()
                            Text("\(controller.currentDataSourceLabel) · \(showingAchievements ? "全部历史" : controller.selectedModel == "all" ? "全部模型" : controller.selectedModel)")
                                .foregroundStyle(Color(nsColor: AtlasColor.muted))
                                .lineLimit(1)
                        }
                        .buttonStyle(.borderless)
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 30)
                        .padding(.vertical, 9)
                        .background(Color(nsColor: AtlasColor.canvas))
                        .overlay(alignment: .bottom) { Divider() }
                    }
                    .onAppear {
                        DispatchQueue.main.async {
                            proxy.scrollTo("dashboard-top", anchor: .top)
                        }
                    }
                }
                .id(controller.dataHomePath)
            } else if !controller.generatorRunning {
                emptyDataState
            }
            if controller.generatorRunning {
                if controller.dashboard == nil {
                    loadingOverlay
                } else {
                    refreshBadge
                }
            }
        }
        .environment(\.atlasGlassFrostAmount, controller.appGlassFrostAmount)
        .environment(\.atlasWindowBackdropActive, controller.usesWindowBackdrop)
        .onChange(of: sessionSearch) { _ in sessionPage = 0 }
        .onChange(of: controller.selectedModel) { _ in sessionPage = 0 }
        .onChange(of: controller.selectedMetric) { _ in sessionPage = 0 }
        .onChange(of: controller.selectedStartDate) { _ in sessionPage = 0 }
        .onChange(of: controller.selectedEndDate) { _ in sessionPage = 0 }
        .onChange(of: controller.dataHomePath) { _ in sessionPage = 0; sessionSearch = "" }
    }

    private func navigate(to section: String, proxy: ScrollViewProxy, anchor overrideAnchor: String? = nil) {
        let destinationIsAchievements = section == "achievements"
        let changingPage = showingAchievements != destinationIsAchievements
        showingAchievements = destinationIsAchievements
        let anchor = overrideAnchor ?? (destinationIsAchievements ? "dashboard-top" : section)
        if changingPage {
            DispatchQueue.main.async { proxy.scrollTo(anchor, anchor: .top) }
        } else {
            proxy.scrollTo(anchor, anchor: .top)
        }
    }

    private var loadingOverlay: some View {
        ZStack {
            VStack(spacing: 11) {
                ProgressView().controlSize(.regular)
                Text(controller.loadingTitleText).font(.system(size: 18, weight: .semibold))
                Text(controller.loadingDetailText).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            Color(nsColor: AtlasColor.canvas)
        }
        .ignoresSafeArea()
    }

    private var refreshBadge: some View {
        VStack {
            HStack {
                Spacer()
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在刷新统计")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(nsColor: AtlasColor.inkSoft))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Color(nsColor: AtlasColor.surface))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color(nsColor: AtlasColor.line), lineWidth: 1)
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            Spacer()
        }
        .padding(18)
        .allowsHitTesting(false)
    }

    private var emptyDataState: some View {
        VStack(spacing: 12) {
            Text("选择会话数据目录")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color(nsColor: AtlasColor.ink))
            Text(controller.dataHomeDisplayPath)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color(nsColor: AtlasColor.muted))
                .textSelection(.enabled)
            HStack(spacing: 10) {
                if controller.codexDataHomeAvailable {
                    Button("使用 Codex") { controller.activateCodexDataHome() }
                }
                if controller.qodexDataHomeAvailable {
                    Button("使用 Qodex") { controller.activateQodexDataHome() }
                }
                Button("选择其他兼容目录…") {
                    controller.chooseDataHome()
                }
            }
        }
        .padding(28)
        .atlasGlass(
            in: RoundedRectangle(cornerRadius: 18, style: .continuous),
            tint: Color(nsColor: AtlasColor.teal).opacity(0.012),
            clear: true
        )
    }

    private func achievementSummary(_ data: DashboardData) -> String {
        guard let records = data.records else { return controller.currentDataSourceLabel }
        let base = "\(controller.currentDataSourceLabel) · 活跃 \(records.active_days) 天 · 已解锁 \(records.unlockedCount)/\(records.levelCount) 级"
        guard let insights = records.insights else { return base }
        return base + " · \(insights.model_count) 种模型 · \(insights.collaborative_sessions) 条协作会话"
    }

    private func overviewHighlights(_ records: UsageRecords, proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 8) {
            overviewHighlight(title: records.milestones.isEmpty ? "已解锁成就" : "最近达成", value: records.milestones.first.map { "\($0.title) · \($0.level)" } ?? "\(records.unlockedCount)/\(records.levelCount) 级",
                detail: records.milestones.first?.date ?? (records.unlockedCount > 0 ? "达成日期待确认" : "从第一次使用开始"), symbol: "seal", medal: records.milestones.first.flatMap { AtlasMedal(name: $0.level) }) {
                achievementCategory = "all"
                achievementState = "all"
                navigate(to: "achievements", proxy: proxy, anchor: records.milestones.isEmpty ? "achievement-wall" : "milestone-history")
            }
            overviewHighlight(title: records.nextAchievement?.progress == 0 ? "下一枚徽章" : "即将晋级", value: records.nextAchievement?.title ?? "全成就已达成",
                detail: records.nextAchievement?.remainingLabel ?? "\(records.levelCount) 级全部解锁", symbol: "flag") {
                achievementCategory = "all"
                achievementState = records.nextAchievement == nil ? "all" : "progress"
                navigate(to: "achievements", proxy: proxy, anchor: "achievement-wall")
            }
            overviewHighlight(title: "峰值输出秒速", value: records.peak_output_throughput?.rateLabel(output: true) ?? "—",
                detail: "历史最佳 · 60 秒平均", symbol: "speedometer") {
                navigate(to: "achievements", proxy: proxy, anchor: "personal-records")
            }
        }
        .help("当前数据源的全部历史与模型；点击查看详情")
    }

    private func overviewHighlight(title: String, value: String, detail: String, symbol: String, medal: AtlasMedal? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Label(title, systemImage: symbol).font(.system(size: 10)).foregroundStyle(Color(nsColor: AtlasColor.muted))
                Text(value).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(nsColor: medal.map(atlasMedalAccent) ?? AtlasColor.ink))
                    .lineLimit(1).minimumScaleFactor(0.85)
                Text(detail).font(.system(size: 10)).foregroundStyle(Color(nsColor: AtlasColor.inkSoft)).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Color(nsColor: AtlasColor.teal).opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain).accessibilityLabel("\(title)：\(value)，\(detail)，查看详情")
    }

    private func hero(_ data: DashboardData) -> some View {
        let range = controller.activeRange(data)
        let metric = MetricOption.all.first(where: { $0.key == controller.selectedMetric })?.title ?? "Total tokens"
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Token Atlas")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(Color(nsColor: AtlasColor.ink))
                Text("\(controller.currentDataSourceLabel) · \(controller.dataHomeDisplayPath) · \(range.start) → \(range.end) · \(controller.selectedModel == "all" ? "全部模型" : controller.selectedModel) · \(metric)")
                    .font(.system(size: 13))
                    .foregroundStyle(Color(nsColor: AtlasColor.inkSoft))
                    .lineLimit(2)
                    .help(controller.dataHomePath)
            }
            HStack(spacing: 10) {
                AtlasControl(label: "数据源") {
                    dataSourceMenu
                }
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
            dateFilterControls(data)
                .padding(.top, 10)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
    }

    private func recordsPanel(_ records: UsageRecords, data: DashboardData, proxy: ScrollViewProxy) -> some View {
        AtlasPanel(title: "个人最佳", subtitle: "全部历史 · 全部模型") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2), spacing: 12) {
                throughputCard(records.peak_throughput, output: false)
                throughputCard(records.peak_output_throughput, output: true)
                AtlasRecordCard(symbol: "text.bubble", title: "单次会话用量纪录", value: records.largest_session.map { shortNumber($0.total_tokens) } ?? "—", detail: records.largest_session?.title ?? "暂无会话用量", caption: "总 Token", tooltip: records.largest_session.map { "\($0.title)\n总用量 \(formatInt($0.total_tokens)) Token，包含输入、缓存与输出；汇总此会话及其内部线程。" }, action: records.largest_session.map { record in
                    { showRecordSession(record.session_id, data: data, proxy: proxy) }
                })
                AtlasRecordCard(symbol: "clock", title: "最长连续活动", value: records.longest_activity.map { activityDuration($0.seconds) } ?? "—", detail: records.longest_activity.map { "\($0.title)\n\(recordWindowLabel($0.start, $0.end))" } ?? "暂无连续调用记录", caption: "单次会话", tooltip: records.longest_activity.map { "\($0.title)\n\($0.start) → \($0.end)\n同一会话相邻用量上报间隔不超过 30 分钟时，计为一段连续活动。" }, action: records.longest_activity.map { record in
                    { showRecordSession(record.session_id, data: data, proxy: proxy) }
                })
            }
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 8) {
                    Text("秒速：按用量上报时间，在全部历史中分别寻找总 Token、输出 Token 最高的 60 秒窗口，再除以 60；汇总所有并行会话。总 Token 含输入、缓存与输出。")
                    Text("日志在调用完成后上报用量，因此这里展示的是用量上报速率。实际逐秒生成速度需要流式时间数据。")
                    Text("连续活动：同一会话相邻上报间隔不超过 30 分钟，统计首尾跨度。")
                    if records.excluded_replay_events > 0 || records.excluded_provenance_events > 0 {
                        Text("时间统计已排除 \(formatInt(Int64(records.excluded_replay_events))) 条重写时间的继承记录、\(formatInt(Int64(records.excluded_provenance_events))) 条时间来源待确认的记录；总用量仍按完整日志汇总。")
                    }
                    if records.excluded_timestamp_sessions > 0 {
                        Text("另有 \(records.excluded_timestamp_sessions) 条会话的时间戳不完整，仅参与用量汇总。")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
            } label: {
                HStack {
                    Text("统计口径")
                    Spacer()
                    if let summary = records.timingExclusionSummary { Text(summary) }
                }
            }
            .font(.system(size: 11)).foregroundStyle(Color(nsColor: AtlasColor.muted))
        }
    }

    private func throughputCard(_ peak: UsageRecords.Window?, output: Bool) -> some View {
        AtlasRecordCard(symbol: output ? "arrow.up.forward" : "speedometer", title: output ? "峰值输出秒速" : "峰值 Token 秒速", value: peak?.rateLabel(output: output) ?? "—",
            detail: peak.map { recordWindowLabel($0.start, $0.end, includeSeconds: true) } ?? "暂无可用的时间记录",
            caption: peak.map { "\($0.window_seconds) 秒平均" } ?? "60 秒平均", prominent: true,
            tooltip: peak.map { "\(formatInt(output ? $0.output_tokens : $0.total_tokens)) Token ÷ \($0.window_seconds) 秒 = \(String(format: "%.1f", $0.rate(output: output))) Token/s。\n\($0.start) → \($0.end)\n\(output ? "只统计输出 Token。" : "包含输入、缓存与输出 Token。")按调用完成后的上报时间计算，汇总所有并行会话。\n该值为用量上报速率；实际逐秒生成速度需要流式时间数据。" })
    }

    private func achievementsPanel(_ records: UsageRecords) -> some View {
        let filtered = records.achievements.filter { achievement in
            (achievementCategory == "all" || achievement.categoryID == achievementCategory) &&
            (achievementState == "all" || (achievementState == "unlocked" && achievement.unlockedLevels > 0) ||
                (achievementState == "progress" && achievement.nextLevel != nil))
        }
        return AtlasPanel(title: "成就墙", trailing: "已解锁 \(records.unlockedCount) / \(records.levelCount) 级") {
            HStack(spacing: 14) {
                AtlasSegmentedControl(items: [("all", "全部")] + UsageRecords.categories.map { ($0.0, $0.1) }, selection: $achievementCategory)
                    .frame(width: 460)
                Spacer(minLength: 0)
                AtlasSegmentedControl(items: [("all", "全部状态"), ("unlocked", "已解锁"), ("progress", "可晋级")], selection: $achievementState)
                    .frame(width: 258)
            }
            if filtered.isEmpty {
                Text(achievementState == "progress" ? "当前筛选的成就已全部达成。" : "尚未解锁成就。")
                    .font(.system(size: 12)).foregroundStyle(Color(nsColor: AtlasColor.muted)).padding(.vertical, 18)
            }
            if achievementCategory != "all", !filtered.isEmpty,
               let category = UsageRecords.categories.first(where: { $0.0 == achievementCategory }) {
                HStack {
                    Text(category.1).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("\(filtered.reduce(0) { $0 + $1.unlockedLevels }) / \(filtered.reduce(0) { $0 + $1.visibleLevels.count }) 级")
                        .font(.system(size: 10)).foregroundStyle(Color(nsColor: AtlasColor.muted))
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                ForEach(filtered) { achievement in AtlasAchievementCard(achievement: achievement) }
            }
        }
    }

    private func dailyHighlights(_ insights: UsageRecords.Insights, data: DashboardData, proxy: ScrollViewProxy) -> some View {
        AtlasPanel(title: "单日高光与探索", subtitle: "按本地日期统计 · 点击箭头回看对应日期或会话") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2), spacing: 12) {
                dailyRecordCard(insights.peak_day, title: "单日 Token 纪录", symbol: "sun.max", output: false, proxy: proxy)
                dailyRecordCard(insights.peak_output_day, title: "单日输出纪录", symbol: "text.alignleft", output: true, proxy: proxy)
                AtlasRecordCard(symbol: "bubble.left.and.bubble.right", title: "单日会话纪录", value: insights.busiest_day.map { formatInt(Int64($0.sessions)) } ?? "—",
                    detail: insights.busiest_day.map { "\($0.date) · \(formatInt(Int64($0.calls))) 次调用 · \($0.models) 种模型" } ?? "暂无可用的时间记录", caption: "条会话",
                    action: insights.busiest_day.map { day in { showRecordDay(day.date, metric: "calls", proxy: proxy) } })
                AtlasRecordCard(symbol: "square.stack.3d.up", title: "单次会话模型纪录", value: insights.most_models_session.map { String($0.model_count) } ?? "—",
                    detail: insights.most_models_session?.title ?? "暂无已知模型", caption: "种模型",
                    tooltip: insights.most_models_session.map { "\($0.title)\n\($0.models.joined(separator: "、"))\n包含所属内部线程使用的模型。" },
                    action: insights.most_models_session.map { record in { showRecordSession(record.session_id, data: data, proxy: proxy) } })
            }
            if let team = insights.largest_team_session {
                HStack(spacing: 14) {
                    Image(systemName: "person.3").foregroundStyle(Color(nsColor: AtlasColor.teal))
                    VStack(alignment: .leading, spacing: 5) {
                        Text("单次会话线程纪录").font(.system(size: 12, weight: .medium))
                        Text(team.title).font(.system(size: 11)).foregroundStyle(Color(nsColor: AtlasColor.muted)).lineLimit(1)
                    }
                    Spacer(minLength: 12)
                    Text("\(team.worker_count)").font(.system(size: 24, weight: .semibold, design: .rounded))
                    Text("个线程").font(.system(size: 11)).foregroundStyle(Color(nsColor: AtlasColor.muted))
                    Button { showRecordSession(team.session_id, data: data, proxy: proxy) } label: { Image(systemName: "arrow.up.right.square") }
                        .buttonStyle(.borderless).accessibilityLabel("查看纪录详情：单次会话线程纪录")
                }
                .padding(16)
                .background(Color(nsColor: AtlasColor.teal).opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
                .help("\(team.title)\n单条用户对话中累计参与的不同工作线程，以创建后的自身调用确认；不是同时运行数量。")
            }
        }
    }

    private func dailyRecordCard(_ day: UsageRecords.Day?, title: String, symbol: String, output: Bool, proxy: ScrollViewProxy) -> some View {
        AtlasRecordCard(symbol: symbol, title: title, value: day.map { shortNumber(output ? $0.output_tokens : $0.total_tokens) } ?? "—",
            detail: day.map { "\($0.date) · \($0.sessions) 条会话 · \(formatInt(Int64($0.calls))) 次调用" } ?? "暂无可用的时间记录", caption: "Token",
            tooltip: day.map { "\($0.date)\n\(formatInt(output ? $0.output_tokens : $0.total_tokens)) Token\n只统计时间可校验的用量上报；日期明细同时保留完整用量。" },
            action: day.map { record in { showRecordDay(record.date, metric: output ? "output_tokens" : "total_tokens", proxy: proxy) } })
    }

    private func showRecordDay(_ day: String, metric: String, proxy: ScrollViewProxy) {
        guard let date = reportDateFormatter.date(from: day) else { return }
        controller.selectedModel = "all"
        controller.selectedMetric = metric
        controller.updateDate(date, isStart: true)
        controller.updateDate(date, isStart: false)
        navigate(to: "daily", proxy: proxy)
    }

    private func modelFootprints(_ insights: UsageRecords.Insights) -> some View {
        let models = insights.models.filter { $0.total_tokens > 0 && !["", "(unknown)", "unknown", "codex-auto-review"].contains($0.id) }
        let maximum = max(1, models.map(\.calls).max() ?? 1)
        return AtlasPanel(title: "模型足迹", subtitle: "\(insights.model_count) 种模型 · 按调用次数排列 · 日期使用可确认的时间记录") {
            if models.isEmpty { Text("尝试一个模型后，足迹会出现在这里。").foregroundStyle(Color(nsColor: AtlasColor.muted)) }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                ForEach(showAllModelFootprints ? models : Array(models.prefix(6))) { model in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(model.id).font(.system(size: 14, weight: .semibold)).lineLimit(1).help(model.id)
                        HStack {
                            Text("\(shortNumber(Int64(model.calls))) 次调用").font(.system(size: 18, weight: .semibold, design: .rounded))
                            Spacer()
                        }
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color(nsColor: AtlasColor.zero))
                                Capsule().fill(Color(nsColor: AtlasColor.teal)).frame(width: geometry.size.width * CGFloat(model.calls) / CGFloat(maximum))
                            }
                        }.frame(height: 4)
                        Text("总量 \(shortNumber(model.total_tokens)) · 输出 \(shortNumber(model.output_tokens))")
                            .font(.system(size: 11)).foregroundStyle(Color(nsColor: AtlasColor.inkSoft))
                        Text("初次 \(model.first_used ?? "日期待确认")\n最近 \(model.last_used ?? "日期待确认")")
                            .font(.system(size: 10)).foregroundStyle(Color(nsColor: AtlasColor.muted))
                    }
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: AtlasColor.teal).opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                }
            }
            if models.count > 6 {
                Button(showAllModelFootprints ? "收起" : "查看全部 \(models.count) 种模型") { showAllModelFootprints.toggle() }
                    .buttonStyle(.borderless)
            }
        }
    }

    private func milestoneHistory(_ records: UsageRecords) -> some View {
        AtlasPanel(title: "达成时间线", subtitle: "最早可确认的达成日期 · 最近 12 项", trailing: "\(records.milestones.count) 项有日期记录") {
            if records.milestones.isEmpty {
                Text("有可确认的达成日期后，成长足迹会出现在这里。")
                    .font(.system(size: 12)).foregroundStyle(Color(nsColor: AtlasColor.muted))
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 2), spacing: 10) {
                ForEach(Array(records.milestones.prefix(12))) { milestone in
                    HStack(spacing: 12) {
                        AtlasMedalBadge(symbol: milestone.symbol, medal: AtlasMedal(name: milestone.level), size: 36)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("\(milestone.title) · \(milestone.level)级").font(.system(size: 13, weight: .semibold))
                            Text("\(milestone.date) · \(milestone.target)").font(.system(size: 11)).foregroundStyle(Color(nsColor: AtlasColor.muted))
                        }
                        Spacer()
                    }
                    .padding(12).background(Color(nsColor: AtlasColor.teal).opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }

    private func showRecordSession(_ id: String, data: DashboardData, proxy: ScrollViewProxy) {
        controller.selectedModel = "all"
        controller.selectedMetric = "total_tokens"
        controller.applyDatePreset(.all)
        sessionSearch = id
        sessionPage = 0
        navigate(to: "sessions", proxy: proxy)
    }

    private func activityDuration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds) 秒" }
        if seconds < 3600 { return "\(seconds / 60) 分钟" }
        return "\(seconds / 3600) 小时 \(seconds % 3600 / 60) 分"
    }

    private var dataSourceMenu: some View {
        Menu {
            Button {
                controller.activateCodexDataHome()
            } label: {
                Label("Codex · ~/.codex", systemImage: controller.isUsingCodexDataHome ? "checkmark" : "folder")
            }
            .disabled(!controller.codexDataHomeAvailable)

            if controller.qodexDataHomeAvailable {
                Button {
                    controller.activateQodexDataHome()
                } label: {
                    Label("Qodex · ~/.qodex", systemImage: controller.isUsingQodexDataHome ? "checkmark" : "folder")
                }
            }

            Divider()
            Button("选择其他兼容目录…") {
                controller.chooseDataHome()
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "externaldrive")
                    .foregroundStyle(Color(nsColor: AtlasColor.teal))
                Text(controller.currentDataSourceLabel)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(nsColor: AtlasColor.ink))
                    .lineLimit(1)
                Spacer(minLength: 2)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color(nsColor: AtlasColor.muted))
            }
            .padding(.horizontal, 8)
            .frame(width: 165, height: 28)
        }
        .menuStyle(BorderlessButtonMenuStyle())
        .disabled(controller.generatorRunning)
        .help("当前数据目录：\(controller.dataHomePath)")
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
            MetricCard(
                title: "UNCACHED INPUT",
                value: shortNumber(usage.uncached_input_tokens),
                detail: "\(shortNumber(usage.cached_input_tokens)) read · \(shortNumber(usage.cache_write_input_tokens)) write",
                accent: AtlasColor.coral
            )
            AtlasMetricDivider()
            MetricCard(title: "OUTPUT", value: shortNumber(usage.output_tokens), detail: "\(shortNumber(usage.reasoning_output_tokens)) reasoning", accent: AtlasColor.amber)
            AtlasMetricDivider()
            MetricCard(
                title: "CACHE RATIO",
                value: String(format: "%.1f%%", cacheRate),
                detail: "\(shortNumber(usage.cached_input_tokens)) cached",
                accent: AtlasColor.teal
            )
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
        let query = sessionSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = data.sessions.compactMap { session -> (SessionData, Usage)? in
            if !query.isEmpty,
               !([session.title, session.id, session.path] + session.by_model.keys.sorted())
                .joined(separator: " ").localizedCaseInsensitiveContains(query) { return nil }
            let usage = controller.filteredSessionUsage(session, data: data)
            return usage.value(for: controller.selectedMetric) > 0 ? (session, usage) : nil
        }
        .sorted {
            let lhs = $0.1.value(for: controller.selectedMetric), rhs = $1.1.value(for: controller.selectedMetric)
            return lhs == rhs ? $0.0.id < $1.0.id : lhs > rhs
        }
        let pageCount = max(1, (matches.count + 29) / 30)
        let currentPage = min(sessionPage, pageCount - 1)
        let rows = matches.dropFirst(currentPage * 30).prefix(30).map { session, usage -> [String] in
            let cost = controller.filteredSessionCost(session, data: data)
            return [session.title, session.by_model.keys.sorted().joined(separator: " · "), session.by_provider.keys.sorted().joined(separator: " · "), formatInt(usage.value(for: controller.selectedMetric)), formatInt(usage.calls), cost.priced_tokens > 0 ? formatUSD(controller.pricingMode.value(cost)) : "—", session.lineageLabel]
        }
        return AtlasPanel(title: "会话用量", subtitle: "内部线程用量归入所属会话；用户 fork 单列。按当前指标排序，每页 30 条。", trailing: "\(matches.count) 条") {
            HStack {
                TextField("搜索会话标题、ID 或模型", text: $sessionSearch)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 360)
                if !sessionSearch.isEmpty {
                    Button("清除") { sessionSearch = "" }
                }
                Spacer()
                Button("上一页") { sessionPage = max(0, currentPage - 1) }
                    .accessibilityLabel("上一页会话")
                    .disabled(currentPage == 0)
                Text("\(currentPage + 1) / \(pageCount)")
                    .font(.system(size: 11, design: .monospaced))
                Button("下一页") { sessionPage = min(pageCount - 1, currentPage + 1) }
                    .accessibilityLabel("下一页会话")
                    .disabled(currentPage + 1 >= pageCount)
            }
            AtlasTable(headers: ["SESSION", "MODELS", "ROUTING", "METRIC", "CALLS", "VALUE", "LINEAGE"], rows: Array(rows), widths: [], adaptiveWeights: [2.8, 1.5, 0.75, 1.4, 0.65, 1.1, 1.55])
        }
    }

    private func pricingPanel(_ data: DashboardData) -> some View {
        let cost = controller.filteredCost(scope: controller.selectedModel, data: data)
        let coverageBase = cost.priced_tokens + cost.unpriced_tokens
        let coverage = coverageBase > 0 ? Double(cost.priced_tokens) / Double(coverageBase) * 100 : 0
        let hasTrustedPricing = cost.priced_tokens > 0
        let hasCustomPricing = data.pricing.routes.contains {
            (controller.selectedModel == "all" || $0.model == controller.selectedModel) && $0.pricing_kind == "custom"
        }
        let hasTimeVariablePricing = data.pricing.routes.contains {
            (controller.selectedModel == "all" || $0.model == controller.selectedModel) && $0.rate_note != nil
        }
        let selectedValue = hasTrustedPricing ? formatUSD(controller.pricingMode.value(cost)) : "未定价"
        let standardValue = hasTrustedPricing ? formatUSD(cost.standard_equivalent_cost_usd) : "未定价"
        let secondaryValue = hasTrustedPricing ? formatUSD(controller.pricingMode == .tiered ? cost.service_tier_premium_usd : 0) : "—"
        let cacheValue = hasTrustedPricing ? formatUSD(controller.pricingMode.cacheSavings(cost)) : "—"
        let routes = data.pricing.routes.compactMap { route -> [String]? in
            guard controller.selectedModel == "all" || route.model == controller.selectedModel else { return nil }
            let filtered = controller.filteredRoute(route, data: data)
            guard filtered.0.calls > 0 else { return nil }
            let rates = route.displayedRates(for: controller.pricingMode)
            let model = route.pricing_model.map { $0 == route.model ? route.model : "\(route.model) → \($0)" } ?? route.model
            let tier = route.service_tier == "priority" ? "Fast / Priority" : route.service_tier
            let value = filtered.1.priced_tokens > 0 ? formatUSD(controller.pricingMode.value(filtered.1)) : route.pricing_model == nil ? "未匹配价格" : "暂无可计价用量"
            let unclassified = min(filtered.0.unclassified_tokens, filtered.1.unpriced_tokens)
            let missingRate = max(0, filtered.1.unpriced_tokens - unclassified)
            let valueDetail = route.pricing_model == nil
                ? "\n\(shortNumber(filtered.1.unpriced_tokens)) tokens"
                : (unclassified > 0 ? "\n\(shortNumber(unclassified)) 未分类" : "")
                    + (missingRate > 0 ? "\n\(shortNumber(missingRate)) 缺少类别单价" : "")
            return [model, "\(route.route_provider) · \(tier)", value + valueDetail, rates?.input.map(formatRate) ?? "—", rates?.cached_input.map(formatRate) ?? "—", rates?.cache_write_input.map(formatRate) ?? "—", rates?.output.map(formatRate) ?? "—", formatInt(filtered.0.calls)]
        }
        return AtlasPanel(
            title: "Token 价值估算",
            subtitle: hasTrustedPricing
                ? hasCustomPricing
                    ? "使用当前数据目录中保存的逐模型价格；周期和模型筛选会同步更新。"
                    : "按所选模型、周期与计价模式估算 API 等价价值。"
                : "当前数据目录尚未配置可用价格；模型、调用和 Token 仍完整统计。",
            trailing: hasTrustedPricing
                ? hasCustomPricing ? "CUSTOM MODEL RATES" : "OFFICIAL RATES · \(data.pricing.as_of)"
                : "UNPRICED SOURCE"
        ) {
            VStack(alignment: .leading, spacing: 15) {
                pricingControls(data)
                HStack(spacing: 0) {
                    MetricCard(title: controller.pricingMode == .simple ? "SIMPLE VALUE" : "TIERED VALUE", value: selectedValue, detail: String(format: "%.1f%% 总 Token 已计价", coverage), accent: AtlasColor.teal)
                    AtlasMetricDivider()
                    MetricCard(title: "STANDARD BASELINE", value: standardValue, detail: "\(formatInt(cost.default_tier_calls)) default · \(formatInt(cost.long_context_calls)) long context", accent: AtlasColor.teal)
                    AtlasMetricDivider()
                    MetricCard(title: "TIER PREMIUM", value: secondaryValue, detail: controller.pricingMode == .tiered ? "\(formatInt(cost.priority_tier_calls)) fast / priority calls" : "简单计价不应用 Fast 溢价", accent: AtlasColor.coral)
                    AtlasMetricDivider()
                    MetricCard(title: "CACHE SAVINGS", value: cacheValue, detail: hasTrustedPricing ? "\(formatUSD(controller.pricingMode.cacheReadCost(cost))) read · \(formatUSD(controller.pricingMode.cacheWriteCost(cost))) write" : "配置价格后计算", accent: AtlasColor.amber)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .atlasGlass(
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous),
                    tint: Color(nsColor: AtlasColor.teal).opacity(0.01),
                    clear: true
                )
                AtlasTable(headers: ["MODEL", "PROVIDER / TIER", "VALUE", "INPUT", "READ", "WRITE", "OUTPUT", "CALLS"], rows: routes, widths: [], adaptiveWeights: [1.6, 1.4, 1.2, 0.7, 0.7, 0.7, 0.7, 0.8])
                Text("未分类 = 日志 total − input − output 的差额；保留在总量中，但无法确定计价类别。‘未匹配价格’才表示模型没有可用单价。")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: AtlasColor.muted))
                Text(!hasTrustedPricing
                    ? "当前来源仅提供用量统计。可在设置中为已识别模型填写价格。"
                    : hasCustomPricing
                        ? "自定义价格按 USD / 100 万 tokens 保存，并分别应用于未缓存输入、缓存读取、缓存写入和输出。"
                        : (controller.pricingMode == .simple
                        ? "简单计价：全部调用按对应模型官方 Standard API 价格估算。"
                        : "分层计价：Default 使用 Standard；Fast/Priority 使用官方 Priority，无对应价格时回退 Standard。日志缺失 tier 的 \(formatInt(Int64(data.audit.fallback_service_tier_events))) 次调用按当前数据目录配置 \(tierLabel(data.audit.configured_service_tier_fallback)) 推断。")
                        + (hasTimeVariablePricing ? " DeepSeek V4 表中显示峰时价，历史金额按调用时间套用 UTC 工作日峰/谷价。" : ""))
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: AtlasColor.muted))
                    .textSelection(.enabled)
            }
        }
    }

    private func pricingControls(_ data: DashboardData) -> some View {
        HStack(spacing: 12) {
            AtlasControl(label: "计价") {
                AtlasSegmentedControl(
                    items: [(.simple, "简单计价"), (.tiered, "区分 Default / Fast")],
                    selection: Binding(get: { controller.pricingMode }, set: { controller.choosePricingMode($0) })
                )
                .frame(width: 276)
            }
            Spacer(minLength: 0)
            if controller.canEditModelPricing {
                Button("设置模型价格…") { controller.editModelPricing(nil) }
                    .accessibilityLabel("设置模型价格")
            }
            Text("USD / 100 万 tokens")
                .font(.system(size: 11))
                .foregroundStyle(Color(nsColor: AtlasColor.muted))
        }
    }

    private func dateFilterControls(_ data: DashboardData) -> some View {
        let minDate = reportDateFormatter.date(from: data.range.start) ?? Date()
        let maxDate = reportDateFormatter.date(from: data.range.end) ?? Date()
        return HStack(spacing: 12) {
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
            Spacer(minLength: 0)
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
            ("ROLLOUT FILES", Int64(audit.session_files)), ("CONVERSATIONS", Int64(audit.conversationSessionCount)), ("USER FORKS", Int64(audit.fork_sessions)),
            ("INTERNAL THREADS", Int64(audit.internalThreadCount)), ("ORPHAN INTERNAL", Int64(audit.orphanInternalThreadCount)), ("RAW EVENTS", Int64(audit.raw_token_events)),
            ("UNIQUE CALLS", Int64(audit.unique_model_calls)), ("REPLAY SKIPPED", Int64(audit.inherited_events)), ("LOCAL DUPLICATES", Int64(audit.local_duplicate_events)),
            ("NULL USAGE", Int64(audit.null_usage_events)), ("DELTA FALLBACKS", Int64(audit.fallback_delta_events)), ("MODEL FALLBACKS", Int64(audit.fallback_model_events)),
            ("PROVIDER FALLBACKS", Int64(audit.fallback_provider_events)), ("TIER FALLBACKS", Int64(audit.fallback_service_tier_events)), ("PRIORITY CALLS", cost.priority_tier_calls),
            ("PRICE FALLBACKS", cost.tier_rate_fallback_calls), ("REASONING INFERRED", Int64(audit.inferredReasoningEventCount)), ("INFERRED REASONING", audit.inferredReasoningTokenCount),
            ("HEURISTIC REASONING", Int64(audit.heuristicReasoningEventCount)), ("TOTAL REPAIRS", Int64(audit.repaired_total_events)), ("MISSING TIME", Int64(audit.missing_timestamp_events)),
            ("CONFIG ERRORS", Int64(audit.pricing_config_errors)), ("CACHE WRITES", controller.filteredUsage(scope: "all", data: data).cache_write_input_tokens), ("UNCLASSIFIED", controller.filteredUsage(scope: "all", data: data).unclassified_tokens)
        ]
        return AtlasPanel(title: "统计审计", subtitle: "用户会话、内部线程、异常、fallback 与去重结果。") {
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

private struct AtlasRecordCard: View {
    @ObservedObject private var theme = AtlasTheme.shared
    let symbol: String
    let title: String
    let value: String
    let detail: String
    var caption: String? = nil
    var prominent = false
    var tooltip: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: symbol).foregroundStyle(Color(nsColor: AtlasColor.teal))
                Text(title).foregroundStyle(Color(nsColor: AtlasColor.inkSoft))
                Spacer(minLength: 0)
                if let caption {
                    Text(caption).font(.system(size: 10))
                        .foregroundStyle(Color(nsColor: AtlasColor.muted))
                }
                if let action {
                    Button(action: action) { Image(systemName: "arrow.up.right.square") }
                        .buttonStyle(.borderless).help("查看对应明细")
                        .accessibilityLabel("查看纪录详情：\(title)")
                }
            }.font(.system(size: 12, weight: .medium))
            Text(value).font(.system(size: prominent ? 32 : 25, weight: .semibold, design: .rounded))
                .foregroundStyle(Color(nsColor: AtlasColor.ink)).lineLimit(1).minimumScaleFactor(0.75)
            Text(detail).font(.system(size: 11)).foregroundStyle(Color(nsColor: AtlasColor.muted))
                .lineLimit(2).frame(height: prominent ? 18 : 32, alignment: .topLeading).help(detail)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: AtlasColor.teal).opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(nsColor: AtlasColor.line).opacity(0.6), lineWidth: 1))
        .help(tooltip ?? detail)
    }
}

private func atlasMedalAccent(_ medal: AtlasMedal) -> NSColor {
    AtlasColor.adaptive(light: medal.accent(dark: false), dark: medal.accent(dark: true))
}

private struct AtlasEtchedMedalShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let points: [CGPoint] = [CGPoint(x: 0.5, y: 0.02), CGPoint(x: 0.92, y: 0.26), CGPoint(x: 0.92, y: 0.74), CGPoint(x: 0.5, y: 0.98), CGPoint(x: 0.08, y: 0.74), CGPoint(x: 0.08, y: 0.26)]
        path.addLines(points.map { CGPoint(x: rect.minX + $0.x * rect.width, y: rect.minY + $0.y * rect.height) })
        path.closeSubpath()
        return path
    }
}

private struct AtlasEtchedMedal: View {
    let symbol: String
    let size: CGFloat
    private var foil: LinearGradient {
        LinearGradient(colors: AtlasMedal.diamond.fillColors.map { Color(nsColor: $0) }, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    var body: some View {
        ZStack {
            AtlasEtchedMedalShape().fill(LinearGradient(colors: [Color(red: 0.12, green: 0.16, blue: 0.19), Color(red: 0.22, green: 0.26, blue: 0.29), Color(red: 0.08, green: 0.11, blue: 0.15)], startPoint: .topLeading, endPoint: .bottomTrailing))
            AtlasEtchedMedalShape().stroke(foil, lineWidth: max(1, size * 0.026))
            AtlasEtchedMedalShape().stroke(foil.opacity(0.7), lineWidth: max(0.5, size * 0.011)).scaleEffect(0.86)
            Path { path in
                for index in 0..<36 {
                    let angle = CGFloat(index) * .pi / 18
                    path.move(to: CGPoint(x: size * (0.5 + cos(angle) * 0.30), y: size * (0.5 + sin(angle) * 0.30)))
                    path.addLine(to: CGPoint(x: size * (0.5 + cos(angle) * 0.39), y: size * (0.5 + sin(angle) * 0.39)))
                }
            }.stroke(foil.opacity(0.7), lineWidth: max(0.45, size * 0.009))
            AtlasEtchedMedalShape().fill(Color(red: 0.10, green: 0.13, blue: 0.17)).scaleEffect(0.57)
            Image(systemName: symbol).font(.system(size: size * 0.31, weight: .semibold)).foregroundStyle(Color.black.opacity(0.8)).offset(y: size * 0.013)
            Image(systemName: symbol).font(.system(size: size * 0.31, weight: .semibold)).foregroundStyle(foil)
            Image(systemName: "diamond.fill").font(.system(size: size * 0.065)).foregroundStyle(foil).offset(y: size * 0.40)
        }.frame(width: size, height: size)
    }
}

private struct AtlasFoilHatching: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for x in stride(from: -rect.height, through: rect.width, by: 7) {
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.maxY))
        }
        return path
    }
}

private struct AtlasMedalBadge: View {
    let symbol: String
    let medal: AtlasMedal?
    var size: CGFloat = 54

    var body: some View {
        ZStack {
            if let medal {
                if medal == .diamond {
                    AtlasEtchedMedal(symbol: symbol, size: size)
                } else {
                    Image(systemName: "seal.fill").font(.system(size: size * 0.93))
                        .foregroundStyle(LinearGradient(colors: medal.fillColors.map { Color(nsColor: $0) }, startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: symbol).font(.system(size: size * 0.38, weight: .semibold)).foregroundStyle(Color.black)
                }
            } else {
                Image(systemName: "seal").font(.system(size: size * 0.93)).foregroundStyle(Color(nsColor: AtlasColor.line))
                Image(systemName: symbol).font(.system(size: size * 0.38, weight: .medium)).foregroundStyle(Color(nsColor: AtlasColor.muted))
            }
        }
        .frame(width: size, height: size).accessibilityHidden(true)
    }
}

private struct AtlasAchievementCard: View {
    @ObservedObject private var theme = AtlasTheme.shared
    let achievement: UsageRecords.Achievement

    private var currentMedal: AtlasMedal? { achievement.currentLevelIndex.flatMap { AtlasMedal(name: achievement.levels[$0].name) } }
    private var currentColor: NSColor { currentMedal.map(atlasMedalAccent) ?? AtlasColor.muted }
    private var diamondGradient: LinearGradient {
        LinearGradient(colors: AtlasMedal.diamond.fillColors.map { Color(nsColor: $0) }, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    private var diamondCardGradient: LinearGradient {
        LinearGradient(colors: zip(AtlasMedal.diamondCardColors(dark: false), AtlasMedal.diamondCardColors(dark: true)).map {
            Color(nsColor: AtlasColor.adaptive(light: $0.0, dark: $0.1))
        }, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                AtlasMedalBadge(symbol: achievement.symbol, medal: currentMedal)
                VStack(alignment: .leading, spacing: 6) {
                    Text(achievement.title).font(.system(size: 16, weight: .semibold))
                    Text(currentMedal == .diamond ? "钻石徽章" : achievement.currentLevelIndex.map { "\(achievement.levels[$0].name)级徽章" } ?? "待解锁")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(Color(nsColor: currentColor))
                }
                Spacer(minLength: 0)
            }
            Text("\(achievement.id == "sessions" ? "累计会话" : achievement.detail) · \(achievement.unit == "Token" ? achievement.formatted(achievement.value) : achievement.valueLabel)")
                .font(.system(size: 12)).foregroundStyle(Color(nsColor: AtlasColor.inkSoft))
                .lineLimit(1).minimumScaleFactor(0.85)
            HStack(spacing: 6) {
                ForEach(Array(achievement.visibleLevels.enumerated()), id: \.offset) { _, level in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 4) {
                            Image(systemName: achievement.value >= level.target ? "checkmark.circle.fill" : "circle")
                            Text(level.name)
                        }.foregroundStyle(Color(nsColor: AtlasMedal(name: level.name).map(atlasMedalAccent) ?? AtlasColor.muted))
                        Text("\(achievement.formatted(level.target))\(achievement.unit == "Token" ? "" : achievement.unit)")
                            .foregroundStyle(Color(nsColor: achievement.value >= level.target ? AtlasColor.inkSoft : AtlasColor.muted))
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .font(.system(size: 10, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(nsColor: AtlasColor.zero))
                    if currentMedal == .diamond {
                        Capsule().fill(diamondGradient).frame(width: geometry.size.width * achievement.progress)
                    } else {
                        Capsule().fill(Color(nsColor: currentColor)).frame(width: geometry.size.width * achievement.progress)
                    }
                }
            }.frame(height: 5)
            Text(achievement.progressLabel)
                .font(.system(size: 11)).foregroundStyle(Color(nsColor: AtlasColor.muted))
            Text(achievement.currentLevelIndex.map { achievement.levels[$0].unlocked_on.map { "\($0) · 达成记录" } ?? "已达成 · 日期待确认" } ?? " ")
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(Color(nsColor: AtlasColor.muted))
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if currentMedal == .diamond {
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(diamondCardGradient)
                    RoundedRectangle(cornerRadius: 12).fill(diamondGradient.opacity(0.055))
                    LinearGradient(stops: [.init(color: .clear, location: 0.10), .init(color: .white.opacity(0.07), location: 0.28), .init(color: .clear, location: 0.32), .init(color: .clear, location: 0.64), .init(color: .white.opacity(0.025), location: 0.67), .init(color: .clear, location: 0.82)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    AtlasFoilHatching().stroke(Color.white.opacity(0.035), lineWidth: 0.4)
                }.clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: currentColor).opacity(currentMedal == nil ? 0.025 : 0.065))
            }
        }
        .overlay {
            if currentMedal == .diamond {
                RoundedRectangle(cornerRadius: 12).stroke(diamondGradient, lineWidth: 1.2)
                    .overlay(RoundedRectangle(cornerRadius: 11).inset(by: 2.2).stroke(diamondGradient.opacity(0.22), lineWidth: 0.5))
            } else {
                RoundedRectangle(cornerRadius: 12).stroke(Color(nsColor: currentColor).opacity(currentMedal == nil ? 0.2 : 0.55), lineWidth: 1)
            }
        }
        .accessibilityElement(children: .combine)
        .help((achievement.rule ?? achievement.detail) + "\n当前值：\(formatInt(Int64(achievement.value))) \(achievement.unit)\n日期为可信时间记录中最早可确认的达成日期。")
    }
}

private func renderAchievementPreviews(_ fixtures: [UsageRecords.Achievement]) throws {
    for dark in [false, true] {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        let content = VStack(spacing: 12) {
            HStack(spacing: 12) {
                AtlasAchievementCard(achievement: fixtures[0])
                AtlasAchievementCard(achievement: fixtures[1])
            }
            HStack(spacing: 12) {
                AtlasAchievementCard(achievement: fixtures[2])
                AtlasAchievementCard(achievement: fixtures[3])
            }
        }
        .padding(20)
        .frame(width: 680, height: 570)
        .background(Color(nsColor: AtlasColor.canvas))
        .environment(\.colorScheme, dark ? .dark : .light)
        try writeAchievementPreview(content, size: NSSize(width: 680, height: 570), appearance: appearance,
            path: "/tmp/token-atlas-achievements-\(dark ? "dark" : "light").png")
        let showcase = HStack(spacing: 30) {
            AtlasEtchedMedal(symbol: fixtures[3].symbol, size: 144)
            AtlasAchievementCard(achievement: fixtures[3]).frame(width: 340)
        }
        .padding(28)
        .frame(width: 570, height: 310)
        .background(Color(nsColor: AtlasColor.canvas))
        .environment(\.colorScheme, dark ? .dark : .light)
        try writeAchievementPreview(showcase, size: NSSize(width: 570, height: 310), appearance: appearance,
            path: "/tmp/token-atlas-foil-\(dark ? "dark" : "light").png")
    }
}

private func writeAchievementPreview<Content: View>(_ content: Content, size: NSSize, appearance: NSAppearance, path: String) throws {
    let view = NSHostingView(rootView: content)
    let rect = NSRect(origin: .zero, size: size)
    let window = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
    window.appearance = appearance
    window.contentView = view
    view.frame = rect
    view.layoutSubtreeIfNeeded()
    var png: Data?
    appearance.performAsCurrentDrawingAppearance {
        if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            png = bitmap.representation(using: .png, properties: [:])
        }
    }
    guard let png else { throw NSError(domain: "CodexTokenAtlasSmoke", code: 3, userInfo: [NSLocalizedDescriptionKey: "Achievement preview rendering failed"]) }
    try png.write(to: URL(fileURLWithPath: path), options: .atomic)
}

private struct AtlasGridBackground: View {
    @Environment(\.atlasGlassFrostAmount) private var frostAmount
    @Environment(\.atlasWindowBackdropActive) private var windowBackdropActive

    @ViewBuilder
    var body: some View {
        if windowBackdropActive {
            let amount = min(1, max(0, frostAmount))
            let opacity = 0.78 + amount * 0.12
            LinearGradient(
                colors: [
                    Color(nsColor: AtlasColor.canvas).opacity(opacity),
                    Color(nsColor: AtlasColor.surface).opacity(opacity),
                    Color(nsColor: AtlasColor.canvas).opacity(opacity)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        } else {
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

private struct AtlasPersonalizationView: View {
    @ObservedObject var controller: AppDelegate
    @ObservedObject private var theme = AtlasTheme.shared
    @State private var hexDraft = AtlasTheme.shared.accentHex
    @State private var invalidHex = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("让 Atlas 更像你的空间").font(.system(size: 20, weight: .semibold))
            VStack(alignment: .leading, spacing: 8) {
                Text("外观").font(.headline)
                AtlasSegmentedControl(items: AppearanceMode.allCases.map { ($0, $0.title) }, selection: Binding(get: { controller.appearanceMode }, set: { controller.applyAppearanceMode($0) }))
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("主题色").font(.headline)
                HStack(spacing: 16) {
                    ForEach(AtlasTheme.presets, id: \.1) { preset in
                        Button { theme.setHex(preset.1) } label: {
                            Circle().fill(Color(nsColor: AtlasTheme.color(hex: preset.1)!))
                                .frame(width: 30, height: 30)
                                .overlay {
                                    if theme.accentHex == preset.1 {
                                        Image(systemName: "checkmark").font(.system(size: 13, weight: .bold))
                                            .foregroundStyle(Color(nsColor: AtlasTheme.text(on: AtlasTheme.color(hex: preset.1)!)))
                                    }
                                }
                        }.buttonStyle(.plain).accessibilityLabel("主题色：\(preset.0)").help(preset.0)
                    }
                    Spacer()
                    ColorPicker("自定义", selection: Binding(get: { Color(nsColor: theme.color) }, set: { theme.setColor(NSColor($0)) }), supportsOpacity: false)
                }
                HStack(spacing: 10) {
                    Text("HEX").foregroundStyle(.secondary)
                    TextField("#4569B4", text: $hexDraft).textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced)).frame(width: 110)
                        .accessibilityLabel("自定义主题色 HEX").onSubmit(applyHex)
                    Button("应用", action: applyHex)
                    if invalidHex { Text("请输入 6 位十六进制颜色").font(.caption).foregroundStyle(.red) }
                }
                HStack(spacing: 5) {
                    ForEach(0..<12) { index in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color(nsColor: [AtlasColor.zero, AtlasColor.heatLow, AtlasColor.heatMidLow, AtlasColor.heatMid, AtlasColor.heatHigh][index % 5]))
                            .frame(height: 20)
                    }
                }
                Text("按钮、强调色和热图同步预览并自动保存。深浅色模式会调整明度，保持文字清晰。")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            HStack {
                Button("恢复默认主题色") { theme.setHex(AtlasTheme.defaultAccentHex) }
                Spacer()
                Button("完成") { controller.closePersonalization() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 480, height: 420)
        .background(Color(nsColor: AtlasColor.canvas))
        .onChange(of: theme.accentHex) { value in hexDraft = value; invalidHex = false }
    }

    private func applyHex() { invalidHex = !theme.setHex(hexDraft) }
}

private struct AtlasSegmentedControl<Value: Hashable>: View {
    @ObservedObject private var theme = AtlasTheme.shared
    let items: [(value: Value, title: String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Button { selection = item.value } label: {
                    segmentLabel(item.title, selected: selection == item.value)
                        .background(selection == item.value ? Color(nsColor: AtlasColor.teal) : .clear, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == item.value ? [.isSelected] : [])
                .help(item.title)
            }
        }
        .padding(3)
        .background(Color(nsColor: AtlasColor.zero).opacity(0.7), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color(nsColor: AtlasColor.line).opacity(0.65), lineWidth: 0.5))
    }

    private func segmentLabel(_ title: String, selected: Bool) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color(nsColor: selected ? AtlasColor.onAccent : AtlasColor.inkSoft))
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: 26)
            .contentShape(Rectangle())
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
    let subtitle: String?
    let trailing: String?
    @ViewBuilder let content: Content

    init(title: String, subtitle: String? = nil, trailing: String? = nil, @ViewBuilder content: () -> Content) {
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
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle).font(.system(size: 12)).foregroundStyle(Color(nsColor: AtlasColor.muted))
                    }
                }
                Spacer()
                if let trailing { Text(trailing).font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(Color(nsColor: AtlasColor.muted)) }
            }
            content
        }
        .padding(.vertical, 22)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: AtlasColor.surface).opacity(0.30), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color(nsColor: AtlasColor.line).opacity(0.6), lineWidth: 1))
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
            if rows.isEmpty {
                Text("当前筛选没有记录")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(nsColor: AtlasColor.muted))
                    .frame(maxWidth: .infinity, minHeight: 54)
            } else if let adaptiveWeights {
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
                    .help(value)
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
                    .help(value)
                    .textSelection(.enabled)
            }
        }
        .frame(height: header ? 30 : 38)
    }
}

private struct HourlyHeatmap: View {
    @ObservedObject private var theme = AtlasTheme.shared
    let data: DashboardData
    @ObservedObject var controller: AppDelegate

    var body: some View {
        let filtered = controller.filteredHourly(data)
        let usage = filtered.0
        let costs = filtered.1
        let cap = percentile(usage.flatMap { $0 }.map { Double($0.value(for: controller.selectedMetric)) }, fraction: 0.98)
        VStack(alignment: .leading, spacing: 12) {
            GeometryReader { geometry in
                let cellWidth = max(16, (geometry.size.width - 40 - 24 * 4) / 24)
                VStack(spacing: 4) {
                    HStack(spacing: 4) {
                        Color.clear.frame(width: 40, height: 16)
                        ForEach(0..<24, id: \.self) {
                            Text(String(format: "%02d", $0))
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(Color(nsColor: AtlasColor.muted))
                                .frame(width: cellWidth)
                        }
                    }
                    ForEach(0..<7, id: \.self) { day in
                        HStack(spacing: 4) {
                            Text(["周一", "周二", "周三", "周四", "周五", "周六", "周日"][day])
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color(nsColor: AtlasColor.inkSoft))
                                .frame(width: 40, height: 30, alignment: .leading)
                            ForEach(0..<24, id: \.self) { hour in
                                let item = usage[day][hour]
                                AtlasHeatCell(
                                    color: heatColor(value: Double(item.value(for: controller.selectedMetric)), cap: cap),
                                    size: 30,
                                    width: cellWidth,
                                    tooltip: "\(["周一", "周二", "周三", "周四", "周五", "周六", "周日"][day]) \(String(format: "%02d", hour)):00\n\(formatInt(item.value(for: controller.selectedMetric))) · \(formatInt(item.calls)) calls\nToken 价值估算 \(formatCostValue(costs[day][hour], pricingMode: controller.pricingMode))"
                                )
                            }
                        }
                    }
                }
            }
            .frame(height: 254)
            HeatmapLegend(cap: cap)
        }
    }
}

private struct HeatmapLegend: View {
    @ObservedObject private var theme = AtlasTheme.shared
    let cap: Double

    var body: some View {
        HStack(spacing: 8) {
            Text("0")
            LinearGradient(colors: [AtlasColor.heatLow, AtlasColor.heatMidLow, AtlasColor.heatMid, AtlasColor.heatHigh].map { Color(nsColor: $0) }, startPoint: .leading, endPoint: .trailing)
                .frame(width: 140, height: 7)
                .clipShape(Capsule())
            Text(shortNumber(Int64(cap)))
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(Color(nsColor: AtlasColor.muted))
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

private struct AtlasHeatCell: View {
    let color: NSColor
    let size: CGFloat
    var width: CGFloat? = nil
    let tooltip: String
    var selected = false
    var hoverEnabled = true

    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color(nsColor: color))
            .frame(width: width ?? size, height: size)
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(Color(nsColor: AtlasColor.ink), lineWidth: 2)
                        .padding(-2)
                }
            }
            .contentShape(Rectangle())
            .overlay {
                AtlasHoverTooltip(text: tooltip, enabled: hoverEnabled,
                                  foreground: AtlasColor.ink, background: AtlasColor.surface,
                                  border: AtlasColor.lineStrong)
                    .accessibilityHidden(true)
            }
            .accessibilityLabel(tooltip)
    }
}

private struct DayGridCell: Identifiable {
    let id: String
    let day: String
    let inside: Bool
}

private struct DailyHourlyStrip: View {
    @ObservedObject private var theme = AtlasTheme.shared
    let day: String
    let data: DashboardData
    @ObservedObject var controller: AppDelegate

    var body: some View {
        let timeline = data.timeline_hourly[controller.selectedModel] ?? [:]
        let costTimeline = data.pricing.timeline_hourly[controller.selectedModel] ?? [:]
        let usage = (0..<24).map { timeline["\(day)T\(String(format: "%02d", $0))"] ?? Usage() }
        let cap = percentile(usage.map { Double($0.value(for: controller.selectedMetric)) }, fraction: 0.98)
        VStack(alignment: .leading, spacing: 9) {
            Text("\(day) · 每小时用量")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(nsColor: AtlasColor.inkSoft))
            GeometryReader { geometry in
                let cellWidth = max(16, (geometry.size.width - 23 * 4) / 24)
                HStack(spacing: 4) {
                    ForEach(0..<24, id: \.self) { hour in
                        let item = usage[hour]
                        let cost = costTimeline["\(day)T\(String(format: "%02d", hour))"] ?? Cost()
                        VStack(spacing: 5) {
                            Text(String(format: "%02d", hour))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Color(nsColor: AtlasColor.muted))
                            AtlasHeatCell(
                                color: heatColor(value: Double(item.value(for: controller.selectedMetric)), cap: cap),
                                size: 24,
                                width: cellWidth,
                                tooltip: "\(day) \(String(format: "%02d", hour)):00\n\(formatInt(item.value(for: controller.selectedMetric))) · \(formatInt(item.calls)) calls\nToken 价值估算 \(formatCostValue(cost, pricingMode: controller.pricingMode))"
                            )
                        }
                        .frame(width: cellWidth)
                    }
                }
            }
            .frame(height: 44)
        }
        .padding(12)
        .background(Color(nsColor: AtlasColor.zero).opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct DailyHeatmap: View {
    @ObservedObject private var theme = AtlasTheme.shared
    let data: DashboardData
    @ObservedObject var controller: AppDelegate
    @State private var selectedDay: String?

    var body: some View {
        let range = controller.activeRange(data)
        let cells = calendarCells(start: range.start, end: range.end)
        let usage = data.daily[controller.selectedModel] ?? [:]
        let costs = data.pricing.daily[controller.selectedModel] ?? [:]
        let cap = percentile(usage.filter { controller.isIncluded($0.key, in: data) }.map { Double($0.value.value(for: controller.selectedMetric)) }, fraction: 0.98)
        let months = monthLabels(cells)
        VStack(alignment: .leading, spacing: 12) {
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        Color.clear.frame(width: 20, height: 14)
                        HStack(spacing: 5) {
                            ForEach(Array(months.enumerated()), id: \.offset) { _, month in
                                Text(month)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(Color(nsColor: AtlasColor.muted))
                                    .frame(width: 22, height: 14, alignment: .leading)
                            }
                        }
                    }
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
                            ForEach(cells) { cell in
                                let item = usage[cell.day] ?? Usage()
                                Button {
                                    selectedDay = selectedDay == cell.day ? nil : cell.day
                                } label: {
                                    AtlasHeatCell(
                                        color: cell.inside ? heatColor(value: Double(item.value(for: controller.selectedMetric)), cap: cap) : NSColor.clear,
                                        size: 22,
                                        tooltip: cell.inside ? "\(cell.day)\n\(formatInt(item.value(for: controller.selectedMetric))) · \(formatInt(item.calls)) calls\nToken 价值估算 \(formatCostValue(costs[cell.day] ?? Cost(), pricingMode: controller.pricingMode))" : "不在所选周期内",
                                        selected: cell.inside && selectedDay == cell.day,
                                        hoverEnabled: cell.inside
                                    )
                                }
                                .buttonStyle(.plain)
                                .disabled(!cell.inside)
                                .accessibilityLabel(cell.day)
                                .accessibilityValue(selectedDay == cell.day ? "已展开" : "展开每小时用量")
                            }
                        }
                    }
                }
                .padding(3)
            }
            if let selectedDay, selectedDay >= range.start, selectedDay <= range.end {
                DailyHourlyStrip(day: selectedDay, data: data, controller: controller)
            }
            HeatmapLegend(cap: cap)
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
