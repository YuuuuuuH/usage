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

        let repairedTotalLine = Data(#"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":20,"total_tokens":1},"last_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":2,"total_tokens":1}}}}"#.utf8)
        let repaired = LiveTokenMonitor.parseTokenCountLine(repairedTotalLine)
        try require(repaired?.usage?.totalTokens == 12, "reported total below input plus output was not repaired")

        let unrelatedLine = Data(#"{"type":"event_msg","payload":{"type":"agent_message"}}"#.utf8)
        try require(LiveTokenMonitor.parseTokenCountLine(unrelatedLine) == nil, "non-token event was accepted")

        try testIncrementalSampling(historicalLine: lastUsageLine)
        print("Live token monitor tests passed")
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
        try handle.write(contentsOf: appendedLine)
        try handle.write(contentsOf: Data([0x0A]))
        try handle.close()

        let deadline = Date().addingTimeInterval(2.5)
        while snapshots.last?.windowUsage.totalTokens != 100, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        monitor.stop()
        try require(snapshots.last?.windowUsage.totalTokens == 100, "appended usage was not sampled")
        try require(abs((snapshots.last?.totalRate ?? 0) - (100.0 / 30.0)) < 0.0001, "rolling rate denominator differs")
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
