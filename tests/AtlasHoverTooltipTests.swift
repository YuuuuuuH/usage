import AppKit

private final class HoverTestWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

@main
enum AtlasHoverTooltipTests {
    static func main() {
        let viewport = NSRect(x: 100, y: 200, width: 900, height: 600)
        let size = NSSize(width: 280, height: 80)
        let pointer = NSPoint(x: 400, y: 400)
        let initial = atlasTooltipFrame(pointer: pointer, size: size, viewport: viewport)
        precondition(initial.minX == pointer.x + 14 && initial.maxY == pointer.y - 18)
        let moved = atlasTooltipFrame(pointer: NSPoint(x: 407, y: 411), size: size, viewport: viewport)
        precondition(moved.minX - initial.minX == 7 && moved.minY - initial.minY == 11)
        let bottomRight = NSPoint(x: viewport.maxX - 10, y: viewport.minY + 10)
        let flipped = atlasTooltipFrame(pointer: bottomRight, size: size, viewport: viewport)
        precondition(flipped.maxX == bottomRight.x - 14 && flipped.minY == bottomRight.y + 18)
        for bounds in [viewport, NSRect(x: -1920, y: -400, width: 1280, height: 800), NSRect(x: 0, y: 0, width: 100, height: 50)] {
            for x in [bounds.minX, bounds.midX, bounds.maxX - 22] {
                for y in [bounds.minY, bounds.midY, bounds.maxY - 22] {
                    let point = NSPoint(x: x, y: y)
                    let frame = atlasTooltipFrame(pointer: point, size: size, viewport: bounds)
                    precondition(bounds.contains(frame) && frame.width > 0 && frame.height > 0)
                    if bounds.width >= 2 * size.width + 44 && bounds.height >= 2 * size.height + 52 {
                        precondition(!frame.insetBy(dx: -8, dy: -8).contains(point))
                    }
                }
            }
        }

        print("Hover tooltip geometry tests passed")
        // Window-server integration is opt-in so command-line CI can run geometry tests.
        guard ProcessInfo.processInfo.environment["TOKEN_ATLAS_TEST_NATIVE_HOVER"] == "1" else { return }
        _ = NSApplication.shared
        let window = HoverTestWindow(contentRect: viewport, styleMask: .borderless, backing: .buffered, defer: false)
        window.acceptsMouseMovedEvents = false
        let scroll = NSScrollView(frame: NSRect(origin: .zero, size: viewport.size))
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 1200))
        scroll.documentView = document
        window.contentView = scroll
        let a = AtlasHoverTrackingView(frame: NSRect(x: 300, y: 200, width: 30, height: 30))
        let b = AtlasHoverTrackingView(frame: NSRect(x: 340, y: 200, width: 30, height: 30))
        for view in [a, b] {
            document.addSubview(view)
            view.configure(text: "周一 00:00\n1,234 · 5 calls\nToken 价值估算 US$0.12", enabled: true,
                           foreground: .labelColor, background: .windowBackgroundColor, border: .separatorColor)
            precondition(view.hitTest(NSPoint(x: 5, y: 5)) == nil)
            view.updateTrackingAreas()
            view.updateTrackingAreas()
            precondition(view.trackingAreas.count == 1)
        }
        let presenter = AtlasTooltipPresenter.shared
        let cellPointer = window.convertPoint(toScreen: a.convert(NSPoint(x: 5, y: 5), to: nil))
        presenter.show(for: a, at: cellPointer)
        precondition(presenter.isShowing(a) && a.highlighted && window.childWindows?.count == 1)
        precondition(window.acceptsMouseMovedEvents)
        let popup = window.childWindows!.first!
        precondition(popup.isVisible && popup.ignoresMouseEvents && !popup.canBecomeKey && !popup.canBecomeMain)
        let label = popup.contentView!.subviews.first as! NSTextField
        precondition(label.stringValue == a.tooltipText && label.frame.width > 0)
        precondition(label.cell!.cellSize(forBounds: label.bounds).height <= label.bounds.height)
        let originalText = label.attributedStringValue
        let originalFrame = popup.frame
        // Exercise the actual mouseMoved handler twice while remaining in one cell.
        for delta in [NSPoint(x: 5, y: 7), NSPoint(x: 12, y: 14)] {
            let screenPoint = NSPoint(x: cellPointer.x + delta.x, y: cellPointer.y + delta.y)
            let event = NSEvent.mouseEvent(with: .mouseMoved, location: window.convertPoint(fromScreen: screenPoint),
                                          modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                          context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
            precondition(event.window === window, "Fixture event must carry the test window")
            a.mouseMoved(with: event)
            precondition(popup.frame.minX == originalFrame.minX + delta.x, "Horizontal pointer movement must move the popup")
            precondition(popup.frame.minY == originalFrame.minY + delta.y, "Vertical pointer movement must move the popup")
            precondition(popup.frame.size == originalFrame.size && label.attributedStringValue.isEqual(to: originalText))
            precondition(window.childWindows?.count == 1 && a.highlighted)
        }
        let movedFrame = popup.frame
        a.configure(text: "周二 23:00\n987,654,321 · 1,234 calls\nToken 价值估算 US$123.45", enabled: true,
                    foreground: .labelColor, background: .windowBackgroundColor, border: .separatorColor)
        precondition(label.stringValue == a.tooltipText && popup.isVisible)
        precondition(popup.frame.minX == movedFrame.minX && popup.frame.maxY == movedFrame.maxY)
        if ProcessInfo.processInfo.environment["TOKEN_ATLAS_RENDER_HOVER"] == "1" {
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                window.appearance = NSAppearance(named: appearance)
                presenter.show(for: a)
                let view = popup.contentView!
                if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/token-atlas-hover-\(name).png"))
                }
            }
        }
        presenter.show(for: a)
        precondition(window.childWindows?.count == 1)
        presenter.show(for: b)
        presenter.hide(for: a)
        precondition(presenter.isShowing(b) && !a.highlighted && b.highlighted)
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        precondition(!presenter.isShowing(b) && !b.highlighted && !popup.isVisible)
        precondition(!window.acceptsMouseMovedEvents)
        window.acceptsMouseMovedEvents = true
        presenter.show(for: a)
        presenter.hide()
        precondition(window.acceptsMouseMovedEvents)
        window.acceptsMouseMovedEvents = false
        for notification in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification, NSWindow.willMoveNotification, NSWindow.didResizeNotification] {
            presenter.show(for: a)
            NotificationCenter.default.post(name: notification, object: window)
            precondition(!presenter.isShowing(a) && !a.highlighted)
        }
        presenter.show(for: a)
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        precondition(!presenter.isShowing(a) && !a.highlighted)
        presenter.show(for: a)
        a.configure(text: "", enabled: false, foreground: .labelColor, background: .windowBackgroundColor, border: .separatorColor)
        precondition(!presenter.isShowing(a) && !a.highlighted)
        presenter.show(for: a)
        precondition(!presenter.isShowing(a))
        presenter.show(for: b)
        b.removeFromSuperview()
        precondition(!presenter.isShowing(b) && !b.highlighted && !popup.isVisible)
        presenter.hide()
        print("Hover tooltip tests passed")
    }
}
