import Foundation

@main
enum UsageQuotaTests {
    static func main() throws {
        if CommandLine.arguments.contains("--live-antigravity") {
            let reader = AntigravityQuotaReader(scriptURL: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("scripts/antigravity_quota.py"))
            let finished = DispatchSemaphore(value: 0)
            reader.read { result in
                switch result {
                case .success(let snapshot): print("Antigravity live read: \(snapshot.windows.count) models, minimum remaining \(snapshot.windows.map(\.remainingPercent).min() ?? 0)%")
                case .failure(let error): print("Live read failed: \(error.localizedDescription)")
                }
                finished.signal()
            }
            guard finished.wait(timeout: .now() + 25) == .success else { throw NSError(domain: "UsageQuotaTests", code: 2) }
            return
        }
        if CommandLine.arguments.contains("--live-read") {
            let reader = CodexQuotaReader()
            let finished = DispatchSemaphore(value: 0)
            reader.read { result in
                switch result {
                case .success(let snapshot):
                    print("Codex official live read: " + snapshot.windows.map { "\($0.title) remaining=\($0.remainingPercent)%" }.joined(separator: ", "))
                case .failure(let error): print("Live read failed: \(error.localizedDescription)")
                }
                finished.signal()
            }
            guard finished.wait(timeout: .now() + 20) == .success else { throw NSError(domain: "UsageQuotaTests", code: 2) }
            return
        }
        func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
            if !value() { throw NSError(domain: "UsageQuotaTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = now.addingTimeInterval(36000)
        let codex = QuotaSnapshot.codex([
            "accountId": "synthetic-account",
            "rateLimits": ["primary": ["usedPercent": 15, "windowDurationMins": 10080, "resetsAt": reset.timeIntervalSince1970]]
        ], now: now)
        try require(codex.windows.count == 1, "weekly-only account gained a fictitious hourly quota")
        try require(codex.windows[0].title == "本周" && codex.windows[0].remainingPercent == 85, "used and remaining percentages differ")
        try require(codex.accountKey != "synthetic-account", "account identifier was not hashed")
        let preferred = QuotaSnapshot.codex([
            "rateLimits": ["primary": ["usedPercent": 99, "windowDurationMins": 300, "resetsAt": reset.timeIntervalSince1970]],
            "rateLimitsByLimitId": ["codex": ["primary": ["usedPercent": 10, "windowDurationMins": 60, "resetsAt": reset.timeIntervalSince1970],
                                                 "secondary": ["usedPercent": 20, "windowDurationMins": 10080, "resetsAt": reset.timeIntervalSince1970]]]
        ], now: now)
        try require(preferred.windows.map(\.remainingPercent) == [90, 80], "multi-bucket snapshot priority differs")
        try require(preferred.windows.first?.title == "1 小时", "hourly duration was hardcoded")
        let invalid = QuotaSnapshot.codex(["rateLimits": ["primary": ["usedPercent": true, "windowDurationMins": 1e90, "resetsAt": reset.timeIntervalSince1970]]], now: now)
        try require(invalid.windows.isEmpty, "invalid quota numbers were accepted")
        let claude = QuotaSnapshot.claude(Data(#"{"observed_at":1800000000,"rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":1800036000},"seven_day":{"used_percentage":41.2,"resets_at":1800604800}}}"#.utf8))
        try require(claude?.windows.count == 2 && claude?.windows.first?.remainingPercent == 76.5, "Claude status-line windows differ")
        try require(QuotaSnapshot.claude(Data(#"{"observed_at":1800000000,"rate_limits":{}}"#.utf8))?.windows.isEmpty == true, "missing Claude windows became unused quotas")
        try require(QuotaSnapshot.claude(Data(#"{"observed_at":1e100,"rate_limits":{}}"#.utf8)) == nil, "out-of-range observation date was accepted")
        let agData = Data(#"{"observed_at":1800000000,"windows":[{"id":"gemini-high","label":"Gemini (High)","used_percent":0.21,"resets_at":1800036000},{"id":"claude","label":"Claude","used_percent":4.69,"resets_at":1800036000}]}"#.utf8)
        guard let ag = QuotaSnapshot.antigravity(agData) else { throw NSError(domain: "UsageQuotaTests", code: 3) }
        try require(ag.windows.count == 2 && ag.windows.first?.title == "Claude", "Antigravity model labels or stable sorting differ")
        let agState = QuotaProviderState(provider: .antigravity, snapshot: ag, message: nil)
        try require(agState.compactSummary(now: now) == "最低 95% · 2 模型", "model percentages were summed or treated as usage")
        try require(agState.compactSummary(now: now.addingTimeInterval(400)) == "待更新", "stale model quotas remained current")
        let states = QuotaProvider.allCases.map { QuotaProviderState(provider: $0, snapshot: $0 == .antigravity ? ag : nil, message: nil) }
        try require(states.count == 3 && QuotaPanelLayout.height(states: states, expanded: nil) == 190, "three providers do not fit the compact section")
        try require(QuotaPanelLayout.liveStatisticsHeight == 288 && QuotaPanelLayout.width == 300, "original live statistics area dimensions changed")
        try require(QuotaPanelLayout.detailHeight(windowCount: 100) == 156, "model detail list is not height bounded")
        try require(QuotaPanelLayout.height(states: states, expanded: .antigravity) == 250, "expanded detail includes unexpected space")
        try require(agState.compactDetail(now: now) == "最近一组 · 10 小时后重置", "model reset time differs")
        let codexState = QuotaProviderState(provider: .codex, snapshot: codex, message: nil)
        try require(codexState.compactDetail(now: now) == "10 小时后重置", "official reset time differs")
        try require(codexState.compactDetail(now: now.addingTimeInterval(400)) == nil, "stale quota presented a current reset")
        let expired = QuotaSnapshot(provider: .codex, observedAt: reset, accountKey: nil, windows: codex.windows)
        try require(QuotaProviderState(provider: .codex, snapshot: expired, message: nil).currentWindows(now: reset).isEmpty, "reset window remained current")
        try testTopBarPreferences(states: states)
        print("Quota tests passed: official windows, model percentages, reset times, stale data and compact layout.")
    }

    private static func testTopBarPreferences(states: [QuotaProviderState]) throws {
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw NSError(domain: "UsageQuotaTests", code: 4, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        var preferences = TopBarPreferences()
        try require(QuotaPanelLayout.panelHeight(preferences: preferences, states: states, expanded: nil) == 479, "default panel layout changed")
        preferences.setVisible(false, provider: .claude)
        try require(preferences.enabledProviders == [.codex, .antigravity], "provider toggle affected another account")
        try require(QuotaPanelLayout.panelHeight(preferences: preferences, states: states, expanded: nil) == 431, "hidden provider retained row space")
        preferences.setVisible(false, provider: .codex)
        preferences.setVisible(false, provider: .antigravity)
        try require(preferences.sections.count == 1 && preferences.sections[0].isLive, "hiding quotas removed live statistics")
        try require(QuotaPanelLayout.panelHeight(preferences: preferences, states: states, expanded: .antigravity) == 288, "hidden details retained their height")
        preferences = TopBarPreferences()
        preferences.move(from: IndexSet(integer: 3), to: 0)
        try require(preferences.order == [.antigravity, .live, .codex, .claude], "upward component move differs")
        try require(preferences.sections.map(\.providers) == [[.antigravity], [], [.codex, .claude]], "split quota sections lost ordering")
        try require(QuotaPanelLayout.panelHeight(preferences: preferences, states: states, expanded: nil) == 526, "split section heights differ")
        preferences.move(from: IndexSet(integer: 0), to: 4)
        try require(preferences.order == TopBarComponent.allCases, "downward component move differs")
        preferences.move(from: IndexSet([0, 1]), to: 4)
        try require(preferences.order == [.claude, .antigravity, .live, .codex], "multi-row move lost components")
        preferences.setVisible(false, provider: .claude)
        let suite = "TokenAtlas-TopBarTests-" + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else { throw NSError(domain: "UsageQuotaTests", code: 5) }
        defer { defaults.removePersistentDomain(forName: suite) }
        preferences.save(to: defaults)
        try require(TopBarPreferences.load(from: defaults) == preferences, "layout preferences did not survive reload")
        defaults.set(["claude", "claude", "unknown"], forKey: "menuBarComponentOrderV1")
        defaults.set(["unknown", "antigravity"], forKey: "menuBarHiddenQuotaProvidersV1")
        let repaired = TopBarPreferences.load(from: defaults)
        try require(repaired.order == [.claude, .live, .codex, .antigravity], "saved layout was not normalized")
        try require(repaired.enabledProviders == [.codex, .claude], "unknown provider altered visibility")
        print("Top-bar preferences tests passed: independent visibility, ordering, persistence and adaptive height.")
    }
}
