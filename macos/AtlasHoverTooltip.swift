import AppKit
import SwiftUI

struct AtlasHoverTooltip: NSViewRepresentable {
    let text: String
    let enabled: Bool
    let foreground: NSColor
    let background: NSColor
    let border: NSColor

    func makeNSView(context: Context) -> AtlasHoverTrackingView {
        AtlasHoverTrackingView()
    }

    func updateNSView(_ view: AtlasHoverTrackingView, context: Context) {
        view.configure(text: text, enabled: enabled, foreground: foreground,
                       background: background, border: border)
    }

    static func dismantleNSView(_ view: AtlasHoverTrackingView, coordinator: ()) {
        AtlasTooltipPresenter.shared.hide(for: view)
    }
}

final class AtlasHoverTrackingView: NSView {
    private var tracking: NSTrackingArea?
    private(set) var tooltipText = ""
    private(set) var tooltipEnabled = false
    private(set) var foreground = NSColor.labelColor
    private(set) var background = NSColor.windowBackgroundColor
    private(set) var border = NSColor.separatorColor
    var highlighted = false {
        didSet { if oldValue != highlighted { needsDisplay = true } }
    }

    func configure(text: String, enabled: Bool, foreground: NSColor,
                   background: NSColor, border: NSColor) {
        tooltipText = text
        tooltipEnabled = enabled && !text.isEmpty
        self.foreground = foreground
        self.background = background
        self.border = border
        if !tooltipEnabled {
            AtlasTooltipPresenter.shared.hide(for: self)
        } else if AtlasTooltipPresenter.shared.isShowing(self) {
            AtlasTooltipPresenter.shared.show(for: self)
        }
        if highlighted { needsDisplay = true }
    }

    // Tracking is independent of hit testing; daily cells remain clickable buttons.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero,
                                 options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                 owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { trackTooltip(with: event) }
    override func mouseMoved(with event: NSEvent) { trackTooltip(with: event) }
    override func mouseExited(with event: NSEvent) { AtlasTooltipPresenter.shared.hide(for: self) }

    private func trackTooltip(with event: NSEvent) {
        guard tooltipEnabled, let window, window.isKeyWindow else { return }
        let pointer = event.window.map { $0.convertPoint(toScreen: event.locationInWindow) } ?? NSEvent.mouseLocation
        AtlasTooltipPresenter.shared.track(for: self, at: pointer)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        AtlasTooltipPresenter.shared.hide(for: self)
        super.viewWillMove(toWindow: newWindow)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard highlighted else { return }
        foreground.setStroke()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), xRadius: 3, yRadius: 3)
        path.lineWidth = 1.5
        path.stroke()
    }
}

// Screen coordinates use AppKit's bottom-left origin. Prefer below/right of the
// pointer, flip each axis near an edge, then clamp to the visible window.
func atlasTooltipFrame(pointer: NSPoint, size: NSSize, viewport: NSRect) -> NSRect {
    let area = viewport.insetBy(dx: min(8, viewport.width / 4), dy: min(8, viewport.height / 4))
    let width = min(size.width, area.width)
    let height = min(size.height, area.height)
    let right = pointer.x + 14
    let below = pointer.y - 18 - height
    let x = right + width <= area.maxX ? right : pointer.x - 14 - width
    let y = below >= area.minY ? below : pointer.y + 18
    return NSRect(x: min(max(x, area.minX), area.maxX - width),
                  y: min(max(y, area.minY), area.maxY - height), width: width, height: height)
}

private final class AtlasTooltipPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class AtlasTooltipPresenter {
    static let shared = AtlasTooltipPresenter()
    private weak var owner: AtlasHoverTrackingView?
    private var observations: [NSObjectProtocol] = []
    private let panel: NSPanel
    private let label = NSTextField(wrappingLabelWithString: "")
    private let surface = NSView()
    private var pointerLocation: NSPoint?
    private var visibleViewport = NSRect.zero
    private weak var trackingWindow: NSWindow?
    private var previousAcceptsMouseMovedEvents: Bool?

    init() {
        panel = AtlasTooltipPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.transient, .ignoresCycle]
        surface.wantsLayer = true
        surface.layer?.cornerRadius = 8
        surface.layer?.borderWidth = 1
        label.isSelectable = false
        label.maximumNumberOfLines = 0
        surface.addSubview(label)
        panel.contentView = surface
    }

    func isShowing(_ view: AtlasHoverTrackingView) -> Bool { owner === view }

    func track(for view: AtlasHoverTrackingView, at pointer: NSPoint) {
        guard owner === view else { show(for: view, at: pointer); return }
        pointerLocation = pointer
        let frame = atlasTooltipFrame(pointer: pointer, size: panel.frame.size, viewport: visibleViewport)
        // Moving inside a cell only moves the existing window; its text/layout stay cached.
        if frame.origin != panel.frame.origin { panel.setFrameOrigin(frame.origin) }
    }

    func show(for view: AtlasHoverTrackingView, at pointer: NSPoint? = nil) {
        guard view.tooltipEnabled, let window = view.window,
              !view.visibleRect.isEmpty else { hide(for: view); return }
        let location = pointer ?? (owner === view ? pointerLocation : nil) ?? NSEvent.mouseLocation
        var viewport = window.convertToScreen(window.contentLayoutRect)
        if let screen = window.screen { viewport = viewport.intersection(screen.visibleFrame) }
        guard !viewport.isEmpty else { hide(for: view); return }

        if owner !== view {
            hide()
            owner = view
            view.highlighted = true
            trackingWindow = window
            previousAcceptsMouseMovedEvents = window.acceptsMouseMovedEvents
            window.acceptsMouseMovedEvents = true
            observeDismissal(of: view, in: window)
            window.addChildWindow(panel, ordered: .above)
        }
        pointerLocation = location
        visibleViewport = viewport
        panel.appearance = view.effectiveAppearance
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            surface.layer?.backgroundColor = view.background.cgColor
            surface.layer?.borderColor = view.border.cgColor
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        let text = NSMutableAttributedString(string: view.tooltipText, attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: view.foreground,
            .paragraphStyle: paragraph
        ])
        let title = (view.tooltipText as NSString).range(of: "\n")
        text.addAttribute(.font, value: NSFont.systemFont(ofSize: 12, weight: .semibold),
                          range: NSRange(location: 0, length: title.location == NSNotFound ? text.length : title.location))
        label.attributedStringValue = text
        let maxWidth = max(1, min(360, viewport.width - 40))
        let measured = label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: maxWidth, height: 10_000)) ?? .zero
        let size = NSSize(width: min(maxWidth, ceil(measured.width)) + 24, height: ceil(measured.height) + 20)
        let frame = atlasTooltipFrame(pointer: location, size: size, viewport: viewport)
        panel.setFrame(frame, display: false)
        label.frame = NSRect(x: 12, y: 10, width: max(0, frame.width - 24), height: max(0, frame.height - 20))
        panel.orderFront(nil)
    }

    func hide(for view: AtlasHoverTrackingView) {
        if owner === view { hide() }
    }

    func hide() {
        owner?.highlighted = false
        owner = nil
        observations.forEach { NotificationCenter.default.removeObserver($0) }
        observations.removeAll()
        if let previousAcceptsMouseMovedEvents {
            trackingWindow?.acceptsMouseMovedEvents = previousAcceptsMouseMovedEvents
        }
        previousAcceptsMouseMovedEvents = nil
        trackingWindow = nil
        pointerLocation = nil
        visibleViewport = .zero
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    private func observeDismissal(of view: NSView, in window: NSWindow) {
        func observe(_ name: Notification.Name, object: AnyObject) {
            observations.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                self?.hide()
            })
        }
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification,
                     NSWindow.willMoveNotification, NSWindow.didResizeNotification] {
            observe(name, object: window)
        }
        observe(NSApplication.didResignActiveNotification, object: NSApp)
        var ancestor = view.superview
        while let current = ancestor {
            if let clip = current as? NSClipView {
                clip.postsBoundsChangedNotifications = true
                observe(NSView.boundsDidChangeNotification, object: clip)
            }
            ancestor = current.superview
        }
    }
}
