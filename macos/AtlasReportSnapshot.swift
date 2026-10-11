import CryptoKit
import Foundation

func atlasIsAllHome(_ home: URL, userHome: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
    home.standardizedFileURL.resolvingSymlinksInPath() == userHome.standardizedFileURL.resolvingSymlinksInPath()
}

func atlasIsClaudeHome(_ home: URL) -> Bool {
    let manager = FileManager.default
    return home.lastPathComponent == ".claude" || ["projects", "claude-code-sessions", "local-agent-mode-sessions"]
        .contains { manager.fileExists(atPath: home.appendingPathComponent($0).path) }
}

func atlasSessionRoots(_ dataHome: URL, userHome: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
    guard atlasIsClaudeHome(dataHome) else { return [dataHome.appendingPathComponent("sessions")] }
    let desktop = userHome.appendingPathComponent("Library/Application Support/Claude")
    let cli = userHome.appendingPathComponent(".claude")
    var homes = [dataHome]
    if dataHome == desktop || dataHome == cli {
        homes += [desktop, cli]
        if let custom = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !custom.isEmpty {
            homes.append(URL(fileURLWithPath: (custom as NSString).expandingTildeInPath))
        }
    }
    var seen = Set<String>()
    return homes.flatMap { home in ["projects", "claude-code-sessions", "local-agent-mode-sessions"].map { home.appendingPathComponent($0) } }
        .filter { seen.insert($0.standardizedFileURL.path).inserted }
}

func atlasReportSnapshotURL(home: URL, dataHome: URL) -> URL {
    let digest = SHA256.hash(data: Data(dataHome.path.utf8))
        .map { String(format: "%02x", $0) }.joined().prefix(20)
    return home.appendingPathComponent("Library/Caches/CodexTokenAtlas/usage-\(digest).json")
}

func atlasSnapshotMatchesSource(schema: Int?, sessionsRoot: String?, sourceID: String?, dashboardSourceID: String?, dataHome: URL, userHome: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
    guard schema == 11, let sessionsRoot, !sessionsRoot.isEmpty else { return false }
    let expected = (atlasIsClaudeHome(dataHome) || atlasIsAllHome(dataHome, userHome: userHome) ? dataHome : dataHome.appendingPathComponent("sessions")).standardizedFileURL.resolvingSymlinksInPath()
    let actual = URL(fileURLWithPath: sessionsRoot).standardizedFileURL.resolvingSymlinksInPath()
    guard expected == actual else { return false }
    if let sourceID, let dashboardSourceID, sourceID != dashboardSourceID { return false }
    return true
}
