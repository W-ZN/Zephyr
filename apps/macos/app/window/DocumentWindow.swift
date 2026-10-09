import AppKit
import ZephyrRender

/// Chrome lives in the full-size title bar. Route its pointer sequence before AppKit's
/// title-bar drag and double-click handling. Blank-space double clicks zoom once at every height.
final class DocumentWindow: NSWindow {
    /// Snapshot mode (`-ZephyrActive YES`): drawn as the active window, window buttons lit, though
    /// a snapshot never brings the app forward.
    var drawsAsActive = false
    override var isKeyWindow: Bool { drawsAsActive || super.isKeyWindow }
    override var isMainWindow: Bool { drawsAsActive || super.isMainWindow }

    private weak var pressedButton: ChromeButton?
    private weak var hoveredButton: ChromeButton?
    private weak var pressedCrumb: PathCrumb?
    private var zoomClick = false

    private func chrome(at event: NSEvent) -> ChromeButton? {
        guard let content = contentView, let frame = content.superview else { return nil }
        return content.hitTest(frame.convert(event.locationInWindow, from: nil)) as? ChromeButton
    }

    private func hitView(at event: NSEvent) -> NSView? {
        guard let contentView, let frame = contentView.superview else { return nil }
        return contentView.hitTest(frame.convert(event.locationInWindow, from: nil))
    }

    private func topBar(at event: NSEvent) -> TopBar? {
        guard let canvas = contentViewController as? CanvasViewController, let hit = hitView(at: event), hit === canvas.topBar || hit.isDescendant(of: canvas.topBar) || canvas.topBar.ownsFieldEditor(hit) else { return nil }
        return canvas.topBar
    }

    private func blankTitlebar(at event: NSEvent) -> Bool {
        guard let bar = topBar(at: event), bar.isBlank(at: event.locationInWindow) else { return false }
        return ![NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].contains { type in
            guard let button = standardWindowButton(type), !button.isHidden else { return false }
            return button.bounds.contains(button.convert(event.locationInWindow, from: nil))
        }
    }

    private func pathCrumb(at event: NSEvent) -> PathCrumb? {
        guard let canvas = contentViewController as? CanvasViewController,
              let crumb = canvas.topBar.pathCrumb(at: event.locationInWindow), let hit = hitView(at: event) else { return nil }
        let editor = crumb.currentEditor() as? NSTextView
        guard hit === crumb || hit.isDescendant(of: crumb) || hit === editor || editor.map({ hit.isDescendant(of: $0) }) == true else { return nil }
        return crumb
    }

    /// The window's other open documents are part of its state (design §7.8).
    override func encodeRestorableState(with coder: NSCoder) {
        super.encodeRestorableState(with: coder)
        (windowController as? DocumentWindowController)?.encodeOpenDocuments(with: coder)
    }

    override func restoreState(with coder: NSCoder) {
        super.restoreState(with: coder)
        (windowController as? DocumentWindowController)?.restoreOpenDocuments(with: coder)
    }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .mouseMoved:
            let button = chrome(at: event)
            if button !== hoveredButton {
                hoveredButton?.mouseExited(with: event)
                button?.mouseEntered(with: event)
                hoveredButton = button
            }
        case .leftMouseDown:
            if let button = chrome(at: event) {
                // Preserve normal activation, including dismissing a key floating card.
                if !isKeyWindow { makeKey() }
                if !isMainWindow { makeMain() }
                pressedButton = button
                button.mouseDown(with: event)
                return
            }
            if let crumb = pathCrumb(at: event) {
                // NSTextView enters AppKit's synchronous mouse-tracking loop. Let the window route
                // an active field editor normally instead of invoking its mouseDown from here.
                if crumb.isEditable {
                    super.sendEvent(event)
                    return
                }
                pressedCrumb = crumb
                crumb.mouseDown(with: event)
                return
            }
            if event.clickCount == 2, blankTitlebar(at: event) {
                zoomClick = true
                performZoom(nil)
                return
            }
        case .leftMouseDragged:
            if let crumb = pressedCrumb {
                crumb.mouseDragged(with: event)
                return
            }
            if let button = pressedButton {
                button.mouseDragged(with: event)
                return
            }
        case .leftMouseUp:
            if let crumb = pressedCrumb {
                crumb.mouseUp(with: event)
                pressedCrumb = nil
                return
            }
            if zoomClick {
                zoomClick = false
                return
            }
            if let button = pressedButton {
                pressedButton = nil
                button.mouseUp(with: event)
                return
            }
        default: break
        }
        super.sendEvent(event)
    }
}
