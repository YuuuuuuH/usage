import Foundation
import CoreFoundation

struct LiveTokenUsage: Equatable {
    var inputTokens: Int64 = 0
    var cachedInputTokens: Int64 = 0
    var outputTokens: Int64 = 0
    var totalTokens: Int64 = 0

    static let zero = LiveTokenUsage()

    func adding(_ other: LiveTokenUsage) -> LiveTokenUsage {
        LiveTokenUsage(
            inputTokens: inputTokens + other.inputTokens,
            cachedInputTokens: cachedInputTokens + other.cachedInputTokens,
            outputTokens: outputTokens + other.outputTokens,
            totalTokens: totalTokens + other.totalTokens
        )
    }

    func nonnegativeDelta(from previous: LiveTokenUsage) -> LiveTokenUsage {
        if totalTokens < previous.totalTokens { return self }
        return LiveTokenUsage(
            inputTokens: max(0, inputTokens - previous.inputTokens),
            cachedInputTokens: max(0, cachedInputTokens - previous.cachedInputTokens),
            outputTokens: max(0, outputTokens - previous.outputTokens),
            totalTokens: max(0, totalTokens - previous.totalTokens)
        )
    }
}

struct LiveTokenSnapshot {
    static let windowSeconds: TimeInterval = 60
    static let zero = LiveTokenSnapshot(
        totalRate: 0,
        inputRate: 0,
        cachedRate: 0,
        outputRate: 0,
        intervalUsage: .zero,
        windowUsage: .zero,
        samples: [],
        lastEventAt: nil,
        monitoredFiles: 0,
        pollDurationMilliseconds: 0
    )

    let totalRate: Double
    let inputRate: Double
    let cachedRate: Double
    let outputRate: Double
    let intervalUsage: LiveTokenUsage
    let windowUsage: LiveTokenUsage
    let samples: [Double]
    let lastEventAt: Date?
    let monitoredFiles: Int
    let pollDurationMilliseconds: Double

    static func combining(_ snapshots: [LiveTokenSnapshot]) -> LiveTokenSnapshot {
        guard !snapshots.isEmpty else { return .zero }

        let maxSampleCount = snapshots.map(\.samples.count).max() ?? 0
        let combinedSamples = (0..<maxSampleCount).map { index -> Double in
            let distanceFromEnd = maxSampleCount - index
            return snapshots.reduce(0) { result, snapshot in
                guard snapshot.samples.count >= distanceFromEnd else { return result }
                return result + snapshot.samples[snapshot.samples.count - distanceFromEnd]
            }
        }

        return LiveTokenSnapshot(
            totalRate: snapshots.reduce(0) { $0 + $1.totalRate },
            inputRate: snapshots.reduce(0) { $0 + $1.inputRate },
            cachedRate: snapshots.reduce(0) { $0 + $1.cachedRate },
            outputRate: snapshots.reduce(0) { $0 + $1.outputRate },
            intervalUsage: snapshots.reduce(.zero) { $0.adding($1.intervalUsage) },
            windowUsage: snapshots.reduce(.zero) { $0.adding($1.windowUsage) },
            samples: combinedSamples,
            lastEventAt: snapshots.compactMap(\.lastEventAt).max(),
            monitoredFiles: snapshots.reduce(0) { $0 + $1.monitoredFiles },
            pollDurationMilliseconds: snapshots.reduce(0) { $0 + $1.pollDurationMilliseconds }
        )
    }
}

struct ParsedLiveTokenEvent {
    let usage: LiveTokenUsage?
    let cumulative: LiveTokenUsage
    let fingerprint: String
}

final class LiveTokenMonitor {
    typealias SnapshotHandler = (LiveTokenSnapshot) -> Void

    private struct Cursor {
        var offset: UInt64
        var remainder = Data()
        var cumulative: LiveTokenUsage?
        var fingerprintOrder: [String] = []
        var fingerprints: Set<String> = []
        var ignoreUntil: Date?

        mutating func remember(_ fingerprint: String) -> Bool {
            guard fingerprints.insert(fingerprint).inserted else { return false }
            fingerprintOrder.append(fingerprint)
            if fingerprintOrder.count > 2_048 {
                fingerprints.remove(fingerprintOrder.removeFirst())
            }
            return true
        }
    }

    private struct WindowEvent {
        let observedAt: Date
        let usage: LiveTokenUsage
    }

    private let sessionRoots: [URL]
    private let claude: Bool
    private var claudeMessages: [String: LiveTokenUsage] = [:]
    private let callback: SnapshotHandler
    private let queue = DispatchQueue(label: "local.codex.token-atlas.live", qos: .utility)
    private let fileManager = FileManager.default
    private var timer: DispatchSourceTimer?
    private var interval: TimeInterval = 2
    private var initialized = false
    private var cursors: [String: Cursor] = [:]
    private var windowEvents: [WindowEvent] = []
    private var rateSamples: [Double] = []
    private var lastEventAt: Date?

    convenience init(sessionRoot: URL, callback: @escaping SnapshotHandler) {
        self.init(sessionRoots: [sessionRoot], callback: callback)
    }

    init(sessionRoots: [URL], claude: Bool = false, callback: @escaping SnapshotHandler) {
        self.sessionRoots = sessionRoots
        self.claude = claude
        self.callback = callback
    }

    func start(interval: TimeInterval) {
        queue.async { [weak self] in
            guard let self else { return }
            self.interval = Self.validatedInterval(interval)
            if !self.initialized {
                self.baselineCurrentFiles()
                self.initialized = true
            }
            self.scheduleTimer()
        }
    }

    func setInterval(_ interval: TimeInterval) {
        queue.async { [weak self] in
            guard let self else { return }
            self.interval = Self.validatedInterval(interval)
            if self.initialized {
                self.scheduleTimer()
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.timer?.cancel()
            self.timer = nil
            self.initialized = false
            self.cursors.removeAll()
            self.claudeMessages.removeAll()
            self.windowEvents.removeAll()
            self.rateSamples.removeAll()
            self.lastEventAt = nil
        }
    }

    private static func validatedInterval(_ interval: TimeInterval) -> TimeInterval {
        [1.0, 2.0, 5.0].contains(interval) ? interval : 2.0
    }

    private func scheduleTimer() {
        timer?.cancel()
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(100))
        source.setEventHandler { [weak self] in self?.poll() }
        timer = source
        source.resume()
    }

    private func baselineCurrentFiles() {
        let files = sessionFiles()
        if claude { files.forEach { baselineClaudeFile($0.url) } }
        cursors = Dictionary(uniqueKeysWithValues: files.map { file in
            (file.url.path, Cursor(offset: file.size))
        })
        publishSnapshot(intervalUsage: .zero, now: Date(), monitoredFiles: files.count, pollDurationMilliseconds: 0)
    }

    private func poll() {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let now = Date()
        let files = sessionFiles()
        let paths = Set(files.map(\.url.path))
        cursors = cursors.filter { paths.contains($0.key) }
        var intervalUsage = LiveTokenUsage.zero

        for file in files {
            let path = file.url.path
            guard var cursor = cursors[path] else {
                // A newly discovered rollout may be a fork containing inherited history.
                cursors[path] = Cursor(offset: file.size, ignoreUntil: now.addingTimeInterval(5))
                if claude { baselineClaudeFile(file.url) }
                continue
            }
            if file.size < cursor.offset {
                cursor = Cursor(offset: file.size)
                cursors[path] = cursor
                continue
            }
            if let ignoreUntil = cursor.ignoreUntil {
                if file.size != cursor.offset {
                    if claude { baselineClaudeFile(file.url) }
                    cursor.offset = file.size
                    cursor.remainder.removeAll(keepingCapacity: true)
                    cursor.ignoreUntil = now.addingTimeInterval(5)
                    cursors[path] = cursor
                    continue
                }
                if now < ignoreUntil { continue }
                cursor.ignoreUntil = nil
                cursors[path] = cursor
            }
            guard file.size > cursor.offset else { continue }

            do {
                let handle = try FileHandle(forReadingFrom: file.url)
                defer { try? handle.close() }
                try handle.seek(toOffset: cursor.offset)
                // Read only this snapshot's byte range. The file can grow during
                // the read; advancing to the earlier stat size would replay bytes.
                let appended = try handle.read(upToCount: Int(min(file.size - cursor.offset, 4 * 1024 * 1024))) ?? Data()
                cursor.offset += UInt64(appended.count)

                var bytes = cursor.remainder
                bytes.append(appended)
                var lineStart = bytes.startIndex
                for index in bytes.indices where bytes[index] == 0x0A {
                    let line = bytes.subdata(in: lineStart..<index)
                    lineStart = bytes.index(after: index)
                    let usage: LiveTokenUsage
                    if claude {
                        guard let delta = Self.claudeDelta(line, seen: &claudeMessages), delta.totalTokens > 0 else { continue }
                        usage = delta
                    } else {
                        guard let parsed = Self.parseTokenCountLine(line, previousCumulative: cursor.cumulative) else { continue }
                        cursor.cumulative = parsed.cumulative
                        guard cursor.remember(parsed.fingerprint), let parsedUsage = parsed.usage else { continue }
                        usage = parsedUsage
                    }
                    intervalUsage = intervalUsage.adding(usage)
                    windowEvents.append(WindowEvent(observedAt: now, usage: usage))
                    lastEventAt = now
                }
                cursor.remainder = lineStart < bytes.endIndex ? bytes.subdata(in: lineStart..<bytes.endIndex) : Data()
                cursors[path] = cursor
            } catch {
                cursors[path] = cursor
            }
        }

        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
        publishSnapshot(intervalUsage: intervalUsage, now: now, monitoredFiles: files.count, pollDurationMilliseconds: elapsed)
    }

    private func publishSnapshot(intervalUsage: LiveTokenUsage, now: Date, monitoredFiles: Int, pollDurationMilliseconds: Double) {
        let cutoff = now.addingTimeInterval(-LiveTokenSnapshot.windowSeconds)
        windowEvents.removeAll { $0.observedAt < cutoff }
        let usage = windowEvents.reduce(LiveTokenUsage.zero) { $0.adding($1.usage) }
        let denominator = LiveTokenSnapshot.windowSeconds
        let totalRate = Double(usage.totalTokens) / denominator
        rateSamples.append(totalRate)
        if rateSamples.count > 60 {
            rateSamples.removeFirst(rateSamples.count - 60)
        }
        let snapshot = LiveTokenSnapshot(
            totalRate: totalRate,
            inputRate: Double(usage.inputTokens) / denominator,
            cachedRate: Double(usage.cachedInputTokens) / denominator,
            outputRate: Double(usage.outputTokens) / denominator,
            intervalUsage: intervalUsage,
            windowUsage: usage,
            samples: rateSamples,
            lastEventAt: lastEventAt,
            monitoredFiles: monitoredFiles,
            pollDurationMilliseconds: pollDurationMilliseconds
        )
        DispatchQueue.main.async { [callback] in callback(snapshot) }
    }

    private func sessionFiles() -> [(url: URL, size: UInt64)] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        var files: [(URL, UInt64)] = []
        var seen = Set<String>()
        for sessionRoot in sessionRoots {
        guard let enumerator = fileManager.enumerator(
            at: sessionRoot,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { continue }

        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            if url.pathComponents.contains("skills-plugin") || url.pathComponents.contains("memory") { continue }
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            guard seen.insert(url.standardizedFileURL.resolvingSymlinksInPath().path).inserted else { continue }
            files.append((url, UInt64(max(0, values.fileSize ?? 0))))
        }
        }
        return files
    }

    private func baselineClaudeFile(_ url: URL) {
        guard let bytes = try? Data(contentsOf: url) else { return }
        var start = bytes.startIndex
        for index in bytes.indices where bytes[index] == 0x0A {
            _ = Self.claudeDelta(bytes.subdata(in: start..<index), seen: &claudeMessages)
            start = bytes.index(after: index)
        }
    }

    static func claudeDelta(_ line: Data, seen: inout [String: LiveTokenUsage]) -> LiveTokenUsage? {
        guard let root = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              root["type"] as? String == "assistant", let message = root["message"] as? [String: Any],
              let fields = message["usage"] as? [String: Any],
              fields["input_tokens"] != nil || fields["output_tokens"] != nil,
              let identity = (message["id"] as? String) ?? (root["requestId"] as? String), !identity.isEmpty
        else { return nil }
        guard (message["role"] as? String ?? "assistant") == "assistant" else { return nil }
        let names = ["input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"]
        for name in names {
            if let value = fields[name] {
                guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                      number.doubleValue >= 0, number.doubleValue.rounded(.towardZero) == number.doubleValue else { return nil }
            }
        }
        let input = integer(fields["input_tokens"]) + integer(fields["cache_read_input_tokens"]) + integer(fields["cache_creation_input_tokens"])
        let output = integer(fields["output_tokens"])
        let usage = LiveTokenUsage(inputTokens: input, cachedInputTokens: integer(fields["cache_read_input_tokens"]),
                                   outputTokens: output, totalTokens: input + output)
        if let previous = seen[identity] {
            guard output > previous.outputTokens || (output == previous.outputTokens && input > previous.inputTokens) else { return .zero }
            seen[identity] = usage
            return LiveTokenUsage(inputTokens: max(0, input - previous.inputTokens),
                cachedInputTokens: max(0, usage.cachedInputTokens - previous.cachedInputTokens),
                outputTokens: output - previous.outputTokens,
                totalTokens: max(0, input - previous.inputTokens) + output - previous.outputTokens)
        }
        seen[identity] = usage
        return usage
    }

    static func parseTokenCountLine(_ line: Data, previousCumulative: LiveTokenUsage? = nil) -> ParsedLiveTokenEvent? {
        guard !line.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: line),
              let root = object as? [String: Any],
              root["type"] as? String == "event_msg",
              let payload = root["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any],
              let total = usage(from: info["total_token_usage"])
        else { return nil }

        let last = usage(from: info["last_token_usage"])
        let delta = last ?? previousCumulative.map { total.nonnegativeDelta(from: $0) }
        let context = integer(info["model_context_window"])
        let lastFingerprint = last.map { "\($0.inputTokens),\($0.cachedInputTokens),\($0.outputTokens),\($0.totalTokens)" } ?? "nil"
        let fingerprint = "\(total.inputTokens),\(total.cachedInputTokens),\(total.outputTokens),\(total.totalTokens)|\(lastFingerprint)|\(context)"
        return ParsedLiveTokenEvent(usage: delta, cumulative: total, fingerprint: fingerprint)
    }

    private static func usage(from value: Any?) -> LiveTokenUsage? {
        guard let dictionary = value as? [String: Any] else { return nil }
        let input = integer(dictionary["input_tokens"])
        let cached = integer(dictionary["cached_input_tokens"])
        let output = integer(dictionary["output_tokens"])
        let reportedTotal = integer(dictionary["total_tokens"])
        return LiveTokenUsage(
            inputTokens: input,
            cachedInputTokens: cached,
            outputTokens: output,
            totalTokens: max(reportedTotal, input + output)
        )
    }

    private static func integer(_ value: Any?) -> Int64 {
        if let number = value as? NSNumber { return number.int64Value }
        if let string = value as? String { return Int64(string) ?? 0 }
        return 0
    }
}
