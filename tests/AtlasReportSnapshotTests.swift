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
        print("Report snapshot tests passed")
    }
}
