import AppKit
import Combine
import SwiftUI

@main
enum Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)     // no Dock icon; menu-bar item instead
        withExtendedLifetime(delegate) { app.run() }
    }
}

/// Borderless, transparent, never key: it just sits on the desktop.
final class WidgetWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    /// Don't let AppKit push the window down below the menu bar: only the card has to
    /// stay on screen, the transparent shadow margin around it can go off the edge.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let settings = Settings.shared
    let state = AppState()
    let weather = WeatherModel()
    let calendar = CalendarModel()
    let mover = WindowMover()
    let backdrop = WallpaperBackdrop()
    let iconMover = IconMover()

    var widget: WidgetWindow!
    var settingsWindow: NSWindow?
    var statusItem: NSStatusItem!
    var bag = Set<AnyCancellable>()
    var needsDefaultPlacement = false

    /// Just above the desktop icons, below every normal window.
    /// Icons that land under the widget are hidden behind it rather than drawn on top.
    static let desktopLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)

    func applicationDidFinishLaunching(_ note: Notification) {
        widget = WidgetWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        widget.isOpaque = false
        widget.backgroundColor = .clear
        widget.hasShadow = false                 // SwiftUI draws the drop shadow
        widget.level = Self.desktopLevel
        widget.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        widget.isMovable = false
        widget.isReleasedWhenClosed = false

        mover.window = widget
        mover.onMoved = { [weak self] in self?.savePosition(); self?.backdrop.crop() }
        mover.onDrag = { [weak self] in self?.backdrop.crop(throttled: true) }
        backdrop.window = widget
        iconMover.window = widget
        iconMover.isPaused = { [weak self] in self?.state.configuring ?? false }

        let root = WidgetRoot(onSize: { [weak self] size in self?.resizeWidget(to: size) })
            .environmentObject(settings)
            .environmentObject(state)
            .environmentObject(weather)
            .environmentObject(calendar)
            .environmentObject(mover)
            .environmentObject(backdrop)
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
        widget.contentView = host
        host.menu = makeMenu()                   // right-click on the widget

        let firstRun = UserDefaults.standard.object(forKey: "widgetTopLeftX") == nil
        placeInitially()
        widget.orderFront(nil)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "clock", accessibilityDescription: "Desktop widget")
        statusItem.menu = makeMenu()

        state.$configuring
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] on in self?.applyConfiguring(on) }
            .store(in: &bag)

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.keepOnScreen() }
        }

        weather.start()
        calendar.start()
        backdrop.start()
        iconMover.start()
        if settings.frostedGlass { backdrop.requestPermission() }

        // First run: open the settings so the user can set up weather and place the widget.
        if firstRun { state.configuring = true }
    }

    private func makeMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(withTitle: "Configure Widget…", action: #selector(configure), keyEquivalent: ",").target = self
        m.addItem(withTitle: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r").target = self
        m.addItem(.separator())
        m.addItem(withTitle: "Quit SimpleDesktopWidget", action: #selector(quit), keyEquivalent: "q").target = self
        return m
    }

    @objc func configure() { state.configuring = true; settingsWindow?.makeKeyAndOrderFront(nil); NSApp.activate() }
    @objc func refreshNow() { weather.refresh(); calendar.reload() }
    @objc func quit() { NSApp.terminate(nil) }

    private func applyConfiguring(_ on: Bool) {
        if on {
            widget.level = .floating             // above other windows while placing it
            showSettings()
        } else {
            widget.level = Self.desktopLevel
            savePosition()
            iconMover.schedule(after: 0.3)
            if let w = settingsWindow, w.isVisible { w.close() }
        }
    }

    private func showSettings() {
        if settingsWindow == nil {
            let view = SettingsView(onDone: { [weak self] in self?.state.configuring = false })
                .environmentObject(settings)
                .environmentObject(weather)
                .environmentObject(calendar)
                .environmentObject(backdrop)
                .environmentObject(iconMover)
            let w = NSWindow(contentViewController: NSHostingController(rootView: view))
            w.title = "SimpleDesktopWidget"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.setFrameAutosaveName("SettingsWindow")
            if !w.setFrameUsingName("SettingsWindow") { w.center() }
            settingsWindow = w
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === settingsWindow {
            state.configuring = false
        }
    }

    // MARK: Position (stored as the top-left corner, so the widget grows downward)

    private func resizeWidget(to size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let f = widget.frame
        if abs(f.width - size.width) < 0.5 && abs(f.height - size.height) < 0.5 { return }
        widget.setFrame(NSRect(x: f.minX, y: f.maxY - size.height, width: size.width, height: size.height), display: true)
        backdrop.crop()
        iconMover.schedule(after: 1)
        if needsDefaultPlacement {
            needsDefaultPlacement = false
            placeTopRight()
        }
    }

    /// Card about 24 pt in from the top-right of the main screen (the window has a transparent shadow margin).
    private func placeTopRight() {
        guard let s = NSScreen.main?.visibleFrame else { return }
        let m = WidgetMetrics.margin
        widget.setFrameTopLeftPoint(NSPoint(x: s.maxX - widget.frame.width + m - 24, y: s.maxY + m - 24))
        savePosition()
        backdrop.crop()
    }

    private func savePosition() {
        let d = UserDefaults.standard
        d.set(Double(widget.frame.minX), forKey: "widgetTopLeftX")
        d.set(Double(widget.frame.maxY), forKey: "widgetTopLeftY")
    }

    private func placeInitially() {
        let d = UserDefaults.standard
        if d.object(forKey: "widgetTopLeftX") != nil {
            let x = d.double(forKey: "widgetTopLeftX"), y = d.double(forKey: "widgetTopLeftY")
            widget.setFrameTopLeftPoint(NSPoint(x: x, y: y))
            keepOnScreen()
        } else {
            needsDefaultPlacement = true      // done once SwiftUI reports the real size
        }
    }

    /// If a display went away, bring the widget back onto one that's there.
    private func keepOnScreen() {
        let f = widget.frame
        let core = f.insetBy(dx: 60, dy: 60)
        if NSScreen.screens.contains(where: { $0.frame.intersects(core) }) { return }
        placeTopRight()
    }
}
