import AppKit
import WebKit

private extension NSToolbarItem.Identifier {
    static let refreshReport = NSToolbarItem.Identifier("local.codex.token-atlas.refresh")
    static let reportStatus = NSToolbarItem.Identifier("local.codex.token-atlas.status")
    static let openBrowser = NSToolbarItem.Identifier("local.codex.token-atlas.browser")
    static let revealExports = NSToolbarItem.Identifier("local.codex.token-atlas.exports")
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSToolbarDelegate, WKNavigationDelegate {
    private var window: NSWindow!
    private var webView: WKWebView!
    private var loadingOverlay: NSVisualEffectView!
    private let loadingSpinner = NSProgressIndicator()
    private let loadingTitle = NSTextField(labelWithString: "正在刷新 Token 历史")
    private let loadingDetail = NSTextField(labelWithString: "读取本地 Codex 会话并校正 fork 用量…")
    private let toolbarSpinner = NSProgressIndicator()
    private let toolbarStatus = NSTextField(labelWithString: "准备中")
    private var refreshToolbarItem: NSToolbarItem?
    private var generatorRunning = false

    private let fileManager = FileManager.default
    private lazy var homeURL = fileManager.homeDirectoryForCurrentUser
    private lazy var reportURL = homeURL.appendingPathComponent("codex_token_heatmap.html")
    private lazy var logURL = homeURL.appendingPathComponent("Library/Logs/Codex Token Atlas.log")
    private lazy var outputURLs = [
        reportURL,
        homeURL.appendingPathComponent("codex_token_usage_by_day.csv"),
        homeURL.appendingPathComponent("codex_token_usage_by_hour.csv"),
        homeURL.appendingPathComponent("codex_token_usage_by_model.csv"),
        homeURL.appendingPathComponent("codex_token_usage_by_session.csv"),
        homeURL.appendingPathComponent("codex_token_usage_summary.json")
    ]

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMainMenu()
        configureWindow()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        refreshReport(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func configureMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "Codex Token Atlas")
        appMenu.addItem(withTitle: "关于 Codex Token Atlas", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 Codex Token Atlas", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "隐藏其他", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "全部显示", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 Codex Token Atlas", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "文件")
        let refresh = fileMenu.addItem(withTitle: "刷新统计", action: #selector(refreshReport(_:)), keyEquivalent: "r")
        refresh.target = self
        let browser = fileMenu.addItem(withTitle: "在浏览器中打开", action: #selector(openInBrowser(_:)), keyEquivalent: "o")
        browser.keyEquivalentModifierMask = [.command, .shift]
        browser.target = self
        let reveal = fileMenu.addItem(withTitle: "在 Finder 中显示导出文件", action: #selector(revealExportFiles(_:)), keyEquivalent: "e")
        reveal.keyEquivalentModifierMask = [.command, .shift]
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
        let pastePlain = editMenu.addItem(withTitle: "粘贴并匹配样式", action: #selector(NSTextView.pasteAsPlainText(_:)), keyEquivalent: "v")
        pastePlain.keyEquivalentModifierMask = [.command, .option, .shift]
        editMenu.addItem(withTitle: "删除", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = mainMenu
    }

    private func configureWindow() {
        let configuration = WKWebViewConfiguration()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
        webView.allowsMagnification = true

        let contentView = NSView()
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor(calibratedRed: 0.933, green: 0.961, blue: 0.949, alpha: 1).cgColor
        contentView.addSubview(webView)

        loadingOverlay = NSVisualEffectView()
        loadingOverlay.translatesAutoresizingMaskIntoConstraints = false
        loadingOverlay.material = .contentBackground
        loadingOverlay.blendingMode = .withinWindow
        loadingOverlay.state = .active
        contentView.addSubview(loadingOverlay)

        loadingSpinner.style = .spinning
        loadingSpinner.controlSize = .regular
        loadingSpinner.startAnimation(nil)

        loadingTitle.font = NSFont.systemFont(ofSize: 20, weight: .semibold)
        loadingTitle.textColor = .labelColor
        loadingTitle.alignment = .center
        loadingDetail.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        loadingDetail.textColor = .secondaryLabelColor
        loadingDetail.alignment = .center

        let loadingStack = NSStackView(views: [loadingSpinner, loadingTitle, loadingDetail])
        loadingStack.translatesAutoresizingMaskIntoConstraints = false
        loadingStack.orientation = .vertical
        loadingStack.alignment = .centerX
        loadingStack.spacing = 10
        loadingOverlay.addSubview(loadingStack)

        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            webView.topAnchor.constraint(equalTo: contentView.topAnchor),
            webView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            loadingOverlay.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            loadingOverlay.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            loadingOverlay.topAnchor.constraint(equalTo: contentView.topAnchor),
            loadingOverlay.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            loadingStack.centerXAnchor.constraint(equalTo: loadingOverlay.centerXAnchor),
            loadingStack.centerYAnchor.constraint(equalTo: loadingOverlay.centerYAnchor),
            loadingStack.leadingAnchor.constraint(greaterThanOrEqualTo: loadingOverlay.leadingAnchor, constant: 24),
            loadingStack.trailingAnchor.constraint(lessThanOrEqualTo: loadingOverlay.trailingAnchor, constant: -24)
        ])

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1240, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Codex Token Atlas"
        window.subtitle = "Fork-safe · Model-aware · Hourly resolution"
        window.minSize = NSSize(width: 860, height: 600)
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = contentView

        let toolbar = NSToolbar(identifier: "local.codex.token-atlas.toolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        window.toolbar = toolbar
        window.toolbarStyle = .unified
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.refreshReport, .reportStatus, .flexibleSpace, .space, .openBrowser, .revealExports]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.refreshReport, .flexibleSpace, .reportStatus, .flexibleSpace, .openBrowser, .revealExports]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case .refreshReport:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "刷新"
            item.paletteLabel = "刷新统计"
            item.toolTip = "重新扫描本地 Codex 会话 (⌘R)"
            item.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "刷新统计")
            item.target = self
            item.action = #selector(refreshReport(_:))
            refreshToolbarItem = item
            return item
        case .openBrowser:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "浏览器"
            item.paletteLabel = "在浏览器中打开"
            item.toolTip = "在默认浏览器中打开当前报表"
            item.image = NSImage(systemSymbolName: "safari", accessibilityDescription: "浏览器")
            item.target = self
            item.action = #selector(openInBrowser(_:))
            return item
        case .revealExports:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "导出文件"
            item.paletteLabel = "显示导出文件"
            item.toolTip = "在 Finder 中显示 HTML、CSV 和 JSON"
            item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "导出文件")
            item.target = self
            item.action = #selector(revealExportFiles(_:))
            return item
        case .reportStatus:
            toolbarSpinner.style = .spinning
            toolbarSpinner.controlSize = .small
            toolbarSpinner.isDisplayedWhenStopped = false
            toolbarStatus.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
            toolbarStatus.textColor = .secondaryLabelColor
            toolbarStatus.lineBreakMode = .byTruncatingTail
            let stack = NSStackView(views: [toolbarSpinner, toolbarStatus])
            stack.orientation = .horizontal
            stack.alignment = .centerY
            stack.spacing = 7
            stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 260).isActive = true
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = stack
            item.label = "状态"
            return item
        default:
            return nil
        }
    }

    @objc private func refreshReport(_ sender: Any?) {
        guard !generatorRunning else { return }
        guard let generatorURL = Bundle.main.resourceURL?.appendingPathComponent("codex_token_heatmap.py") else {
            presentError("应用内的统计生成器缺失。")
            return
        }
        guard let pythonURL = locatePython() else {
            presentError("需要 Python 3.9 或更高版本。")
            return
        }

        generatorRunning = true
        setLoading(true, title: "正在刷新 Token 历史", detail: "读取本地 Codex 会话并校正 fork 用量…")
        appendLog("\n[\(timestampLabel())] Native app refresh\nPython: \(pythonURL.path)\n")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let process = Process()
            process.executableURL = pythonURL
            process.arguments = [generatorURL.path]
            process.environment = ProcessInfo.processInfo.environment.merging(["HOME": self.homeURL.path]) { _, new in new }

            let logHandle = self.openLogHandle()
            process.standardOutput = logHandle
            process.standardError = logHandle
            do {
                try process.run()
                process.waitUntilExit()
                logHandle?.closeFile()
                let status = process.terminationStatus
                DispatchQueue.main.async {
                    if status == 0 {
                        self.loadGeneratedReport()
                    } else {
                        self.generatorRunning = false
                        self.setLoading(false, title: "", detail: "")
                        self.presentError("生成报表失败，退出状态为 \(status)。")
                    }
                }
            } catch {
                logHandle?.closeFile()
                DispatchQueue.main.async {
                    self.generatorRunning = false
                    self.setLoading(false, title: "", detail: "")
                    self.presentError("无法启动统计生成器：\(error.localizedDescription)")
                }
            }
        }
    }

    private func loadGeneratedReport() {
        guard fileManager.fileExists(atPath: reportURL.path) else {
            generatorRunning = false
            setLoading(false, title: "", detail: "")
            presentError("生成完成，但找不到 HTML 报表。")
            return
        }
        setLoading(true, title: "正在渲染仪表盘", detail: "载入模型、小时和会话统计…")
        webView.loadFileURL(reportURL, allowingReadAccessTo: homeURL)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript("window.scrollTo(0, 0)", completionHandler: nil)
        generatorRunning = false
        setLoading(false, title: "", detail: "")
        toolbarStatus.stringValue = "已更新 \(DateFormatter.shortTime.string(from: Date()))"
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard navigationAction.navigationType == .linkActivated,
              let url = navigationAction.request.url,
              !url.isFileURL else {
            decisionHandler(.allow)
            return
        }
        NSWorkspace.shared.open(url)
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        generatorRunning = false
        setLoading(false, title: "", detail: "")
        presentError("仪表盘载入失败：\(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        generatorRunning = false
        setLoading(false, title: "", detail: "")
        presentError("仪表盘载入失败：\(error.localizedDescription)")
    }

    @objc private func openInBrowser(_ sender: Any?) {
        if fileManager.fileExists(atPath: reportURL.path) {
            NSWorkspace.shared.open(reportURL)
        } else {
            presentError("当前还没有生成 HTML 报表。")
        }
    }

    @objc private func revealExportFiles(_ sender: Any?) {
        let existing = outputURLs.filter { fileManager.fileExists(atPath: $0.path) }
        if existing.isEmpty {
            presentError("当前还没有可显示的导出文件。")
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(existing)
        }
    }

    private func setLoading(_ loading: Bool, title: String, detail: String) {
        loadingOverlay.isHidden = !loading
        refreshToolbarItem?.isEnabled = !loading
        if loading {
            loadingTitle.stringValue = title
            loadingDetail.stringValue = detail
            loadingSpinner.startAnimation(nil)
            toolbarSpinner.startAnimation(nil)
            toolbarStatus.stringValue = title
        } else {
            loadingSpinner.stopAnimation(nil)
            toolbarSpinner.stopAnimation(nil)
        }
    }

    private func locatePython() -> URL? {
        let candidates = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
        return candidates.first(where: { fileManager.isExecutableFile(atPath: $0) }).map(URL.init(fileURLWithPath:))
    }

    private func presentError(_ message: String) {
        toolbarStatus.stringValue = "刷新失败"
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
        let directory = logURL.deletingLastPathComponent()
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: logURL.path) {
            fileManager.createFile(atPath: logURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: logURL) else { return nil }
        handle.seekToEndOfFile()
        return handle
    }

    private func appendLog(_ text: String) {
        guard let data = text.data(using: .utf8), let handle = openLogHandle() else { return }
        handle.write(data)
        handle.closeFile()
    }

    private func timestampLabel() -> String {
        DateFormatter.logTimestamp.string(from: Date())
    }
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

@main
enum CodexTokenAtlasMain {
    private static let delegate = AppDelegate()

    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        application.delegate = delegate
        application.run()
    }
}
