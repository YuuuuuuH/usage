import Foundation

@main
enum LiveTokenMonitorTests {
    static func main() throws {
        let lastUsageLine = Data(#"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":900,"cached_input_tokens":500,"output_tokens":100,"total_tokens":1000},"last_token_usage":{"input_tokens":90,"cached_input_tokens":50,"output_tokens":10,"total_tokens":100},"model_context_window":258400}}}"#.utf8)
        guard let parsed = LiveTokenMonitor.parseTokenCountLine(lastUsageLine) else {
            throw TestFailure("valid token_count line was not parsed")
        }
        try require(parsed.usage == LiveTokenUsage(inputTokens: 90, cachedInputTokens: 50, outputTokens: 10, totalTokens: 100), "last_token_usage fields differ")

        let cumulativeOnlyLine = Data(#"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":950,"cached_input_tokens":530,"output_tokens":125,"total_tokens":1075},"last_token_usage":null,"model_context_window":258400}}}"#.utf8)
        guard let fallback = LiveTokenMonitor.parseTokenCountLine(cumulativeOnlyLine, previousCumulative: parsed.cumulative) else {
            throw TestFailure("cumulative fallback line was not parsed")
        }
        try require(fallback.usage == LiveTokenUsage(inputTokens: 50, cachedInputTokens: 30, outputTokens: 25, totalTokens: 75), "cumulative fallback delta differs")
        let reset = LiveTokenMonitor.parseTokenCountLine(cumulativeOnlyLine, previousCumulative: LiveTokenUsage(inputTokens: 1800, outputTokens: 200, totalTokens: 2000))
        try require(reset?.usage?.totalTokens == 1075, "cumulative reset lost the new context usage")

        let repairedTotalLine = Data(#"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":20,"total_tokens":1},"last_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":2,"total_tokens":1}}}}"#.utf8)
        let repaired = LiveTokenMonitor.parseTokenCountLine(repairedTotalLine)
        try require(repaired?.usage?.totalTokens == 12, "reported total below input plus output was not repaired")

        let unrelatedLine = Data(#"{"type":"event_msg","payload":{"type":"agent_message"}}"#.utf8)
        try require(LiveTokenMonitor.parseTokenCountLine(unrelatedLine) == nil, "non-token event was accepted")

        try testCombinedSnapshots()
        try testIncrementalSampling(historicalLine: lastUsageLine)
        print("Live token monitor tests passed")
    }

    private static func testCombinedSnapshots() throws {
        let olderEvent = Date(timeIntervalSince1970: 100)
        let newerEvent = Date(timeIntervalSince1970: 200)
        let codex = LiveTokenSnapshot(
            totalRate: 3,
            inputRate: 2,
            cachedRate: 1,
            outputRate: 1,
            intervalUsage: LiveTokenUsage(inputTokens: 20, cachedInputTokens: 10, outputTokens: 10, totalTokens: 30),
            windowUsage: LiveTokenUsage(inputTokens: 120, cachedInputTokens: 60, outputTokens: 60, totalTokens: 180),
            samples: [1, 2, 3],
            lastEventAt: olderEvent,
            monitoredFiles: 4,
            pollDurationMilliseconds: 1.5
        )
        let qodex = LiveTokenSnapshot(
            totalRate: 5,
            inputRate: 4,
            cachedRate: 2,
            outputRate: 1,
            intervalUsage: LiveTokenUsage(inputTokens: 40, cachedInputTokens: 20, outputTokens: 10, totalTokens: 50),
            windowUsage: LiveTokenUsage(inputTokens: 240, cachedInputTokens: 120, outputTokens: 60, totalTokens: 300),
            samples: [4, 5],
            lastEventAt: newerEvent,
            monitoredFiles: 6,
            pollDurationMilliseconds: 2.5
        )

        let combined = LiveTokenSnapshot.combining([codex, qodex])
        try require(combined.totalRate == 8, "combined total rate differs")
        try require(combined.inputRate == 6 && combined.cachedRate == 3 && combined.outputRate == 2, "combined rate breakdown differs")
        try require(combined.intervalUsage.totalTokens == 80 && combined.windowUsage.totalTokens == 480, "combined usage differs")
        try require(combined.samples == [1, 6, 8], "combined samples are not aligned at the newest edge")
        try require(combined.lastEventAt == newerEvent, "combined last event is not the newest event")
        try require(combined.monitoredFiles == 10 && combined.pollDurationMilliseconds == 4, "combined monitor diagnostics differ")
        try require(LiveTokenSnapshot.combining([]).totalRate == 0, "empty combined snapshot is not zero")
    }

    private static func testIncrementalSampling(historicalLine: Data) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("token-atlas-live-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("rollout-test.jsonl")
        var baseline = historicalLine
        baseline.append(0x0A)
        try baseline.write(to: log)

        var snapshots: [LiveTokenSnapshot] = []
        let monitor = LiveTokenMonitor(sessionRoot: directory) { snapshots.append($0) }
        monitor.start(interval: 1)
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        try require(snapshots.allSatisfy { $0.windowUsage.totalTokens == 0 }, "startup baseline replayed historical usage")

        let appendedLine = Data(#"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":990,"cached_input_tokens":550,"output_tokens":110,"total_tokens":1100},"last_token_usage":{"input_tokens":90,"cached_input_tokens":50,"output_tokens":10,"total_tokens":100},"model_context_window":258400}}}"#.utf8)
        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd()
        let split = appendedLine.count / 2
        try handle.write(contentsOf: appendedLine.prefix(split))
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        try require(snapshots.last?.windowUsage.totalTokens == 0, "partial JSON line was counted")
        try handle.write(contentsOf: appendedLine.suffix(appendedLine.count - split))
        try handle.write(contentsOf: Data([0x0A]))
        try handle.close()

        let deadline = Date().addingTimeInterval(2.5)
        while snapshots.last?.windowUsage.totalTokens != 100, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        try require(snapshots.last?.windowUsage.totalTokens == 100, "appended usage was not sampled")
        try require(abs((snapshots.last?.totalRate ?? 0) - (100.0 / 60.0)) < 0.0001, "rolling rate denominator differs")
        let duplicate = try FileHandle(forWritingTo: log)
        try duplicate.seekToEnd()
        try duplicate.write(contentsOf: appendedLine)
        try duplicate.write(contentsOf: Data([0x0A]))
        try duplicate.close()
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        try require(snapshots.last?.windowUsage.totalTokens == 100, "duplicate event was counted again")
        monitor.stop()
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw TestFailure(message) }
    }

    private struct TestFailure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
