import CryptoKit
import Foundation

func atlasReportSnapshotURL(home: URL, dataHome: URL) -> URL {
    let digest = SHA256.hash(data: Data(dataHome.path.utf8))
        .map { String(format: "%02x", $0) }.joined().prefix(20)
    return home.appendingPathComponent("Library/Caches/CodexTokenAtlas/usage-\(digest).json")
}

func atlasSnapshotMatchesSource(schema: Int?, sessionsRoot: String?, sourceID: String?, dashboardSourceID: String?, dataHome: URL) -> Bool {
    guard schema == 11, let sessionsRoot, !sessionsRoot.isEmpty else { return false }
    let expected = dataHome.appendingPathComponent("sessions").standardizedFileURL.resolvingSymlinksInPath()
    let actual = URL(fileURLWithPath: sessionsRoot).standardizedFileURL.resolvingSymlinksInPath()
    guard expected == actual else { return false }
    if let sourceID, let dashboardSourceID, sourceID != dashboardSourceID { return false }
    return true
}
