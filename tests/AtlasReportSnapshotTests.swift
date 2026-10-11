import Foundation

@main
struct AtlasReportSnapshotTests {
    static func main() {
        let home = URL(fileURLWithPath: "/synthetic")
        let codex = home.appendingPathComponent(".codex")
        let qodex = home.appendingPathComponent(".qodex")
        let url = atlasReportSnapshotURL(home: home, dataHome: codex)
        precondition(url.lastPathComponent == "usage-877c1bcf579e52bf8bcd.json")
        precondition(url != atlasReportSnapshotURL(home: home, dataHome: qodex))
        func matches(schema: Int? = 11, root: String? = "/synthetic/.codex/sessions",
                     source: String? = "codex", dashboard: String? = "codex") -> Bool {
            atlasSnapshotMatchesSource(schema: schema, sessionsRoot: root, sourceID: source,
                                       dashboardSourceID: dashboard, dataHome: codex)
        }
        precondition(matches())
        precondition(!matches(schema: nil))
        precondition(!matches(schema: 10))
        precondition(!matches(root: nil))
        precondition(!matches(root: ""))
        precondition(!matches(root: "/synthetic/.qodex/sessions"))
        precondition(!matches(root: "/synthetic/archive/.codex/sessions"))
        precondition(!matches(dashboard: "qodex"))
        precondition(atlasIsAllHome(home, userHome: home))
        precondition(!atlasIsAllHome(codex, userHome: home))
        precondition(atlasSnapshotMatchesSource(schema: 11, sessionsRoot: home.path, sourceID: "all", dashboardSourceID: "all", dataHome: home, userHome: home))
        precondition(!atlasSnapshotMatchesSource(schema: 11, sessionsRoot: codex.path, sourceID: "all", dashboardSourceID: "all", dataHome: home, userHome: home))
        let claude = home.appendingPathComponent(".claude")
        precondition(atlasIsClaudeHome(claude))
        precondition(atlasSnapshotMatchesSource(schema: 11, sessionsRoot: claude.path, sourceID: "claude", dashboardSourceID: "claude", dataHome: claude))
        precondition(!atlasSnapshotMatchesSource(schema: 11, sessionsRoot: codex.path, sourceID: "claude", dashboardSourceID: "claude", dataHome: claude))
        let roots = atlasSessionRoots(claude, userHome: home)
        precondition(roots.contains(claude.appendingPathComponent("projects")))
        precondition(roots.contains(home.appendingPathComponent("Library/Application Support/Claude/local-agent-mode-sessions")))
        print("Report snapshot tests passed")
    }
}
