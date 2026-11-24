import AppKit

/// A plain window with the log, tap status and a way to look at the hidden
/// SoundCloud widget (consent / sign-in prompts would show up there).
@MainActor
final class DebugConsole: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let logView = NSTextView()
    private let status = NSTextField(labelWithString: "")
    private let showWidget = NSButton(checkboxWithTitle: "Show player widget", target: nil, action: nil)
    private let widgetHost = NSView()
    private var observer: NSObjectProtocol?

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "SoundAmp — Debug Console"
        window.isReleasedWhenClosed = false
        super.init()
        window.delegate = self

        logView.isEditable = false
        logView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        logView.isVerticallyResizable = true
        logView.autoresizingMask = [.width]
        logView.textContainer?.widthTracksTextView = true
        logView.string = Logger.shared.history.joined(separator: "\n") + "\n"
        let scroll = NSScrollView()
        scroll.documentView = logView
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        status.lineBreakMode = .byTruncatingTail
        showWidget.target = self
        showWidget.action = #selector(toggleWidget)
        let attach = NSButton(title: "Attach tap", target: self, action: #selector(attach))
        let detach = NSButton(title: "Detach", target: self, action: #selector(detach))
        let openLog = NSButton(title: "Open log file", target: self, action: #selector(openLogFile))
        let row = NSStackView(views: [showWidget, attach, detach, openLog, status])
        row.translatesAutoresizingMaskIntoConstraints = false

        widgetHost.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(row)
        content.addSubview(widgetHost)
        content.addSubview(scroll)
        let hostHeight = widgetHost.heightAnchor.constraint(equalToConstant: 0)
        hostHeight.identifier = "hostHeight"
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            row.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -12),
            widgetHost.topAnchor.constraint(equalTo: row.bottomAnchor, constant: 8),
            widgetHost.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            widgetHost.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            hostHeight,
            scroll.topAnchor.constraint(equalTo: widgetHost.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content
        window.center()

        Logger.shared.sink = { [weak self] line in self?.append(line) }
        observer = NotificationCenter.default.addObserver(forName: PlayerController.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateStatus() }
        }
        updateStatus()
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func updateStatus() {
        let p = Env.player!
        status.stringValue = "state: \(p.state) · tap: \(p.tapStatus) · resolver queue: \(p.resolver.pendingCount)"
    }

    private func append(_ line: String) {
        guard let storage = logView.textStorage else { return }
        storage.append(NSAttributedString(string: line + "\n", attributes: [.font: logView.font as Any, .foregroundColor: NSColor.textColor]))
        logView.scrollToEndOfDocument(nil)
    }

    @objc private func toggleWidget() {
        let web = Env.player.player.webView
        let height = widgetHost.constraints.first { $0.identifier == "hostHeight" }
        if showWidget.state == .on {
            web.removeFromSuperview()
            web.frame = widgetHost.bounds
            web.autoresizingMask = [.width, .height]
            widgetHost.addSubview(web)
            height?.constant = 166
        } else {
            height?.constant = 0
            Env.windows.hostWebViews([web, Env.player.resolver.widget.webView])
        }
    }

    @objc private func attach() { Env.player.attachTap() }
    @objc private func detach() { Env.player.detachTap() }
    @objc private func openLogFile() { NSWorkspace.shared.open(Logger.fileURL) }

    func windowWillClose(_ notification: Notification) {
        if showWidget.state == .on {
            showWidget.state = .off
            toggleWidget()
        }
    }
}
