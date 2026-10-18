import CryptoKit
import CoreFoundation
import Foundation

enum QuotaProvider: String, Codable, CaseIterable {
    case codex, claude, antigravity
    var title: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .antigravity: return "Antigravity"
        }
    }
}

struct QuotaWindow: Codable, Equatable, Identifiable {
    let id: String
    let usedPercent: Double
    let durationMinutes: Int?
    let resetsAt: Date
    let label: String?

    init(id: String, usedPercent: Double, durationMinutes: Int?, resetsAt: Date, label: String? = nil) {
        self.id = id; self.usedPercent = usedPercent; self.durationMinutes = durationMinutes
        self.resetsAt = resetsAt; self.label = label
    }

    var remainingPercent: Double { max(0, 100 - usedPercent) }
    var title: String {
        if let label { return label }
        guard let minutes = durationMinutes else { return "额度" }
        if minutes == 10080 { return "本周" }
        if minutes % 60 == 0 { return "\(minutes / 60) 小时" }
        return "\(minutes) 分钟"
    }
    var shortTitle: String {
        guard let minutes = durationMinutes else { return "额度" }
        if minutes == 10080 { return "周" }
        return minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes)m"
    }
}

struct QuotaSnapshot: Codable, Equatable {
    let provider: QuotaProvider
    let observedAt: Date
    let accountKey: String?
    let windows: [QuotaWindow]

    static func codex(_ result: [String: Any], now: Date = Date()) -> QuotaSnapshot {
        let buckets = result["rateLimitsByLimitId"] as? [String: Any]
        let bucket = (buckets?["codex"] as? [String: Any]) ?? (result["rateLimits"] as? [String: Any]) ?? [:]
        let bucketID = bucket["limitId"] as? String ?? "codex"
        let windows = ["primary", "secondary"].compactMap { slot -> QuotaWindow? in
            guard let row = bucket[slot] as? [String: Any] else { return nil }
            let minutes = number(row["windowDurationMins"]).flatMap { $0 > 0 && $0 <= 525600 ? Int($0) : nil }
            return parseWindow(row, id: "\(bucketID):\(minutes.map(String.init) ?? slot)", percentKey: "usedPercent", resetKey: "resetsAt", duration: minutes)
        }
        let accountKey = (result["accountId"] as? String).map {
            SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        return QuotaSnapshot(provider: .codex, observedAt: now, accountKey: accountKey, windows: windows.sorted { ($0.durationMinutes ?? 0) < ($1.durationMinutes ?? 0) })
    }

    static func claude(_ data: Data) -> QuotaSnapshot? {
        guard let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let observed = number(row["observed_at"]), observed > 0,
              observed < Date.distantFuture.timeIntervalSince1970,
              let limits = row["rate_limits"] as? [String: Any] else { return nil }
        let windows = [("five_hour", 300), ("seven_day", 10080)].compactMap { key, duration -> QuotaWindow? in
            guard let value = limits[key] as? [String: Any] else { return nil }
            return parseWindow(value, id: key, percentKey: "used_percentage", resetKey: "resets_at", duration: duration)
        }
        return QuotaSnapshot(provider: .claude, observedAt: Date(timeIntervalSince1970: observed), accountKey: row["account_key"] as? String, windows: windows)
    }

    static func antigravity(_ data: Data) -> QuotaSnapshot? {
        guard let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let observed = number(row["observed_at"]), observed > 0,
              observed < Date.distantFuture.timeIntervalSince1970,
              let models = row["windows"] as? [[String: Any]] else { return nil }
        var ids = Set<String>()
        let windows = models.prefix(100).compactMap { model -> QuotaWindow? in
            guard let id = model["id"] as? String, !id.isEmpty, id.count <= 160, ids.insert(id).inserted,
                  let label = model["label"] as? String, !label.isEmpty,
                  let parsed = parseWindow(model, id: id, percentKey: "used_percent", resetKey: "resets_at", duration: nil) else { return nil }
            return QuotaWindow(id: parsed.id, usedPercent: parsed.usedPercent, durationMinutes: nil, resetsAt: parsed.resetsAt, label: String(label.prefix(120)))
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return QuotaSnapshot(provider: .antigravity, observedAt: Date(timeIntervalSince1970: observed), accountKey: row["account_key"] as? String, windows: windows)
    }

    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }

    private static func parseWindow(_ row: [String: Any], id: String, percentKey: String, resetKey: String, duration: Int?) -> QuotaWindow? {
        guard let used = number(row[percentKey]), used >= 0,
              let reset = number(row[resetKey]), reset > 0, reset < Date.distantFuture.timeIntervalSince1970 else { return nil }
        let minutes = duration.flatMap { $0 > 0 && $0 <= 525600 ? $0 : nil }
        return QuotaWindow(id: id, usedPercent: min(100, used), durationMinutes: minutes, resetsAt: Date(timeIntervalSince1970: reset))
    }
}

func quotaDuration(_ seconds: TimeInterval) -> String {
    let minutes = max(1, Int(ceil(min(max(0, seconds), 31536000) / 60)))
    if minutes < 60 { return "\(minutes) 分钟" }
    if minutes < 1440 { return "\(minutes / 60) 小时\(minutes % 60 == 0 ? "" : " \(minutes % 60) 分")" }
    return "\(minutes / 1440) 天 \((minutes % 1440) / 60) 小时"
}

struct QuotaProviderState {
    let provider: QuotaProvider
    let snapshot: QuotaSnapshot?
    let message: String?
    func currentWindows(now: Date = Date()) -> [QuotaWindow] {
        guard let snapshot, (-30...300).contains(now.timeIntervalSince(snapshot.observedAt)) else { return [] }
        return snapshot.windows.filter { $0.resetsAt > now }
    }
    func compactSummary(now: Date = Date()) -> String {
        let windows = currentWindows(now: now)
        guard !windows.isEmpty else { return snapshot == nil ? "" : "待更新" }
        if provider == .antigravity, let lowest = windows.map(\.remainingPercent).min() {
            return "最低 \(Int(lowest.rounded(.down)))% · \(windows.count) 模型"
        }
        return windows.map { "\($0.shortTitle) \(Int($0.remainingPercent.rounded(.down)))%" }.joined(separator: "  ")
    }
    func compactDetail(now: Date = Date()) -> String? {
        let windows = currentWindows(now: now)
        guard !windows.isEmpty else { return nil }
        guard let reset = windows.map(\.resetsAt).min() else { return nil }
        let prefix = provider == .antigravity && windows.count > 1 ? "最近一组 · " : ""
        return prefix + quotaDuration(reset.timeIntervalSince(now)) + "后重置"
    }
}

enum TopBarComponent: String, CaseIterable, Identifiable {
    case live, codex, claude, antigravity
    var id: String { rawValue }
    var provider: QuotaProvider? { QuotaProvider(rawValue: rawValue) }
    var title: String { provider.map { $0.title + " 额度" } ?? "实时 Token 统计" }
}

struct TopBarSection: Identifiable {
    let id: String
    let providers: [QuotaProvider]
    var isLive: Bool { id == TopBarComponent.live.rawValue }
}

struct TopBarPreferences: Equatable {
    private static let orderKey = "menuBarComponentOrderV1"
    private static let hiddenKey = "menuBarHiddenQuotaProvidersV1"
    var order: [TopBarComponent] = TopBarComponent.allCases
    var hiddenProviders: Set<QuotaProvider> = []

    static func load(from defaults: UserDefaults = .standard) -> TopBarPreferences {
        var value = TopBarPreferences()
        var seen = Set<String>()
        let saved = (defaults.stringArray(forKey: orderKey) ?? []).compactMap(TopBarComponent.init(rawValue:))
        value.order = (saved + TopBarComponent.allCases).filter { seen.insert($0.rawValue).inserted }
        value.hiddenProviders = Set((defaults.stringArray(forKey: hiddenKey) ?? []).compactMap(QuotaProvider.init(rawValue:)))
        return value
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(order.map(\.rawValue), forKey: Self.orderKey)
        defaults.set(hiddenProviders.map(\.rawValue).sorted(), forKey: Self.hiddenKey)
    }

    var enabledProviders: Set<QuotaProvider> { Set(QuotaProvider.allCases).subtracting(hiddenProviders) }

    mutating func setVisible(_ visible: Bool, provider: QuotaProvider) {
        if visible { hiddenProviders.remove(provider) } else { hiddenProviders.insert(provider) }
    }

    mutating func move(from offsets: IndexSet, to destination: Int) {
        guard !offsets.isEmpty, offsets.allSatisfy({ order.indices.contains($0) }), (0...order.count).contains(destination) else { return }
        let moved = offsets.sorted().map { order[$0] }
        let insertion = destination - offsets.filter { $0 < destination }.count
        order = order.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
        order.insert(contentsOf: moved, at: insertion)
    }

    var sections: [TopBarSection] {
        var result: [TopBarSection] = []
        var group: [QuotaProvider] = []
        func flush() {
            guard let first = group.first else { return }
            result.append(TopBarSection(id: "quotas-" + first.rawValue, providers: group))
            group.removeAll()
        }
        for component in order {
            if let provider = component.provider {
                if !hiddenProviders.contains(provider) { group.append(provider) }
            } else {
                flush()
                result.append(TopBarSection(id: component.rawValue, providers: []))
            }
        }
        flush()
        return result
    }
}

enum QuotaPanelLayout {
    static let width: CGFloat = 300
    static let liveStatisticsHeight: CGFloat = 288
    static let rowHeight: CGFloat = 44
    static func detailHeight(windowCount: Int) -> CGFloat { min(CGFloat(max(0, windowCount)) * 26, 156) }
    static func height(states: [QuotaProviderState], expanded: QuotaProvider?) -> CGFloat {
        guard !states.isEmpty else { return 0 }
        let base = 50 + CGFloat(states.count) * rowHeight + CGFloat(max(0, states.count - 1)) * 4
        guard let state = states.first(where: { $0.provider == expanded }), let snapshot = state.snapshot, !snapshot.windows.isEmpty else { return base }
        return base + detailHeight(windowCount: snapshot.windows.count) + 8
    }

    static func panelHeight(preferences: TopBarPreferences, states: [QuotaProviderState], expanded: QuotaProvider?) -> CGFloat {
        let sections = preferences.sections
        return sections.reduce(CGFloat(max(0, sections.count - 1))) { total, section in
            total + (section.isLive ? liveStatisticsHeight : height(states: section.providers.compactMap { provider in states.first { $0.provider == provider } }, expanded: expanded))
        }
    }
}

final class AntigravityQuotaReader {
    private let queue = DispatchQueue(label: "local.codex.token-atlas.antigravity-quota", qos: .utility)
    private let scriptURL: URL?
    init(scriptURL: URL? = Bundle.main.url(forResource: "antigravity_quota", withExtension: "py")) { self.scriptURL = scriptURL }
    func read(completion: @escaping (Result<QuotaSnapshot, Error>) -> Void) {
        queue.async {
            func fail(_ message: String) { completion(.failure(NSError(domain: "TokenAtlasQuota", code: 10, userInfo: [NSLocalizedDescriptionKey: message]))) }
            let python = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"].first { FileManager.default.isExecutableFile(atPath: $0) }
            guard let python, let script = self.scriptURL else { fail("Antigravity 额度读取组件不可用"); return }
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: python)
            process.arguments = [script.path]
            process.standardOutput = output; process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 20) { if process.isRunning { process.terminate() } }
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0, data.count <= 65536 else { fail("Antigravity 额度暂不可用"); return }
                if let snapshot = QuotaSnapshot.antigravity(data) { completion(.success(snapshot)); return }
                let row = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                let message = row?["error"] as? String ?? ""
                let allowed = ["打开 Antigravity 后自动读取", "Antigravity 本地服务尚未就绪", "请先在 Antigravity 中登录"]
                fail(allowed.contains(message) ? message : "Antigravity 额度暂不可用")
            } catch { fail("Antigravity 额度暂不可用") }
        }
    }
}

final class CodexQuotaReader {
    private let queue = DispatchQueue(label: "local.codex.token-atlas.quota-reader", qos: .utility)
    private var process: Process?
    private var finish: ((Result<QuotaSnapshot, Error>) -> Void)?
    private var buffer = Data()
    private var input: Pipe?
    private var output: Pipe?

    func read(completion: @escaping (Result<QuotaSnapshot, Error>) -> Void) {
        queue.async {
            guard self.process == nil else { return }
            let home = FileManager.default.homeDirectoryForCurrentUser
            let candidates = [home.appendingPathComponent(".local/bin/codex").path, "/opt/homebrew/bin/codex", "/usr/local/bin/codex", "/Applications/Codex.app/Contents/Resources/codex"]
            guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
                completion(.failure(NSError(domain: "TokenAtlasQuota", code: 1, userInfo: [NSLocalizedDescriptionKey: "请先安装并登录 Codex"])))
                return
            }
            let process = Process(), input = Pipe(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["app-server", "--stdio"]
            process.currentDirectoryURL = home
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            self.process = process; self.input = input; self.output = output; self.finish = completion
            self.buffer.removeAll()
            output.fileHandleForReading.readabilityHandler = { [weak self, weak process] handle in
                let data = handle.availableData
                self?.queue.async {
                    guard let self, let process, self.process === process else { return }
                    self.received(data)
                }
            }
            process.terminationHandler = { [weak self, weak process] _ in
                self?.queue.async {
                    guard let self, let process, self.process === process else { return }
                    self.complete(.failure(NSError(domain: "TokenAtlasQuota", code: 2, userInfo: [NSLocalizedDescriptionKey: "Codex 额度暂不可用"])))
                }
            }
            do {
                try process.run()
                let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.5.4"
                self.send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "token_atlas", "title": "Token Atlas", "version": version]]])
                self.queue.asyncAfter(deadline: .now() + 15) { [weak self, weak process] in
                    guard let self, let process, self.process === process else { return }
                    self.complete(.failure(NSError(domain: "TokenAtlasQuota", code: 3, userInfo: [NSLocalizedDescriptionKey: "额度查询超时，稍后重试"])))
                }
            } catch { self.complete(.failure(error)) }
        }
    }

    private func send(_ value: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: value) else { return }
        try? input?.fileHandleForWriting.write(contentsOf: data + Data([10]))
    }

    private func received(_ data: Data) {
        guard finish != nil else { return }
        guard !data.isEmpty else { return }
        buffer.append(data)
        guard buffer.count <= 1024 * 1024 else {
            complete(.failure(NSError(domain: "TokenAtlasQuota", code: 4)))
            return
        }
        while let newline = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            guard let row = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let id = row["id"] as? Int else { continue }
            if row["error"] != nil {
                complete(.failure(NSError(domain: "TokenAtlasQuota", code: 5, userInfo: [NSLocalizedDescriptionKey: "请检查 Codex 登录与账户额度"])))
                return
            }
            if id == 1 {
                send(["method": "initialized"])
                send(["id": 2, "method": "account/rateLimits/read"])
            } else if id == 2, let result = row["result"] as? [String: Any] {
                complete(.success(QuotaSnapshot.codex(result)))
                return
            }
        }
    }

    private func complete(_ result: Result<QuotaSnapshot, Error>) {
        guard let completion = finish else { return }
        finish = nil
        output?.fileHandleForReading.readabilityHandler = nil
        process?.terminationHandler = nil
        if process?.isRunning == true { process?.terminate() }
        try? input?.fileHandleForWriting.close()
        try? output?.fileHandleForReading.close()
        process = nil; input = nil; output = nil
        completion(result)
    }
}

final class UsageQuotaMonitor {
    private let queue = DispatchQueue(label: "local.codex.token-atlas.quotas", qos: .utility)
    private let reader = CodexQuotaReader()
    private let antigravityReader = AntigravityQuotaReader()
    private let callback: ([QuotaProviderState]) -> Void
    private var timer: DispatchSourceTimer?
    private var snapshots: [QuotaProvider: QuotaSnapshot] = [:]
    private var enabledProviders = Set(QuotaProvider.allCases)
    private var messages: [QuotaProvider: String] = [:]
    private var lastCodexAttempt = Date.distantPast
    private var querying = false
    private var lastAntigravityAttempt = Date.distantPast
    private var queryingAntigravity = false
    private var claudeModified: Date?
    private let cacheRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/CodexTokenAtlas")

    init(callback: @escaping ([QuotaProviderState]) -> Void) { self.callback = callback }
    func setEnabledProviders(_ providers: Set<QuotaProvider>) {
        queue.async {
            let added = providers.subtracting(self.enabledProviders)
            self.enabledProviders = providers
            if added.contains(.claude) { self.claudeModified = nil }
            if added.contains(.codex), Date().timeIntervalSince(self.lastCodexAttempt) >= 10 { self.lastCodexAttempt = .distantPast }
            if added.contains(.antigravity), Date().timeIntervalSince(self.lastAntigravityAttempt) >= 10 { self.lastAntigravityAttempt = .distantPast }
            if self.timer != nil { self.poll() }
        }
    }
    func start() {
        queue.async {
            guard self.timer == nil else { return }
            self.publish()
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: 15, leeway: .seconds(2))
            timer.setEventHandler { [weak self] in self?.poll() }
            self.timer = timer; timer.resume()
        }
    }
    func stop() { queue.async { self.timer?.cancel(); self.timer = nil } }
    func refresh() {
        queue.async {
            if Date().timeIntervalSince(self.lastCodexAttempt) >= 10 { self.lastCodexAttempt = .distantPast }
            if Date().timeIntervalSince(self.lastAntigravityAttempt) >= 10 { self.lastAntigravityAttempt = .distantPast }
            self.claudeModified = nil
            self.poll()
        }
    }

    private func poll() {
        guard timer != nil, !enabledProviders.isEmpty else { return }
        let bridge = cacheRoot.appendingPathComponent("claude-quota.json")
        if enabledProviders.contains(.claude), let modified = (try? FileManager.default.attributesOfItem(atPath: bridge.path)[.modificationDate]) as? Date, modified != claudeModified {
            claudeModified = modified
            if let data = try? Data(contentsOf: bridge), data.count <= 65536, let snapshot = QuotaSnapshot.claude(data) { accept(snapshot) }
        }
        if enabledProviders.contains(.codex), !querying && Date().timeIntervalSince(lastCodexAttempt) >= 60 {
            querying = true; lastCodexAttempt = Date()
            reader.read { [weak self] result in
                self?.queue.async {
                    guard let self else { return }
                    self.querying = false
                    guard self.enabledProviders.contains(.codex), self.timer != nil else { return }
                    switch result {
                    case .success(let snapshot): self.messages[.codex] = nil; self.accept(snapshot)
                    case .failure(let error): self.messages[.codex] = (error as NSError).domain == "TokenAtlasQuota" ? error.localizedDescription : "Codex 额度暂不可用"; self.publish()
                    }
                }
            }
        }
        if enabledProviders.contains(.antigravity), !queryingAntigravity && Date().timeIntervalSince(lastAntigravityAttempt) >= 60 {
            queryingAntigravity = true; lastAntigravityAttempt = Date()
            antigravityReader.read { [weak self] result in
                self?.queue.async {
                    guard let self else { return }
                    self.queryingAntigravity = false
                    guard self.enabledProviders.contains(.antigravity), self.timer != nil else { return }
                    switch result {
                    case .success(let snapshot): self.messages[.antigravity] = nil; self.accept(snapshot)
                    case .failure(let error): self.messages[.antigravity] = error.localizedDescription; self.publish()
                    }
                }
            }
        }
        publish()
    }
    private func accept(_ snapshot: QuotaSnapshot) {
        if let previous = snapshots[snapshot.provider], snapshot.observedAt < previous.observedAt { return }
        snapshots[snapshot.provider] = snapshot
        publish()
    }
    private func publish() {
        let states = QuotaProvider.allCases.map { provider in
            QuotaProviderState(provider: provider, snapshot: snapshots[provider], message: messages[provider])
        }
        DispatchQueue.main.async { [callback] in callback(states) }
    }
}
