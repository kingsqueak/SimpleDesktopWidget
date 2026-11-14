// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris

import AppKit
import Combine
import SwiftUI

@main
enum Main {
    static func main() {
        // `SimpleDesktopWidget --snapshot out.png`: render the README screenshot and exit.
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            let path = CommandLine.arguments[i + 1]
            exit(MainActor.assumeIsolated { Snapshot.render(to: path) } ? 0 : 1)
        }
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
    let alerts = AlertsModel()
    let lightning = LightningMonitor()

    var widget: WidgetWindow!
    var settingsWindow: NSWindow?
    var statusItem: NSStatusItem!
    var bag = Set<AnyCancellable>()

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
            .environmentObject(alerts)
            .environmentObject(lightning)
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
        widget.contentView = host
        host.menu = makeMenu()                   // right-click on the widget

        let firstRun = UserDefaults.standard.object(forKey: "widgetTopLeftX") == nil && UserDefaults.standard.object(forKey: "anchorDX") == nil
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

        weather.start()
        calendar.start()
        backdrop.start()
        iconMover.start()
        alerts.start()
        lightning.start()
        NotificationCenter.default.addObserver(forName: .widgetLocationChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.alerts.refresh(); self?.lightning.apply() }
        }
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
    @objc func refreshNow() { weather.refresh(); calendar.reload(); alerts.refresh() }
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
                .environmentObject(alerts)
                .environmentObject(lightning)
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

    // MARK: Position
    //
    // Saved relative to the nearest corner of the screen the card is on: which screen,
    // left or right, top or bottom, and the gaps from those edges of the usable desktop.
    // Changes of size, resolution, or a monitor sleeping and waking can't shift it; only
    // dragging it (and Done) saves a new spot. Anything else that moves the window
    // (macOS during display changes) is undone by re-applying the saved spot.

    private struct Anchor {
        var screen: String
        var right: Bool
        var bottom: Bool
        var dx: CGFloat
        var dy: CGFloat
    }

    private var anchor: Anchor?
    private var screenChangeWork: DispatchWorkItem?
    private var healTimer: Timer?

    private func loadAnchor() -> Anchor? {
        let d = UserDefaults.standard
        guard d.object(forKey: "anchorDX") != nil else { return nil }
        return Anchor(screen: d.string(forKey: "anchorScreen") ?? "", right: d.bool(forKey: "anchorRight"),
                      bottom: d.bool(forKey: "anchorBottom"),
                      dx: CGFloat(d.double(forKey: "anchorDX")), dy: CGFloat(d.double(forKey: "anchorDY")))
    }

    private func screen(named name: String) -> NSScreen? {
        NSScreen.screens.first { $0.localizedName == name } ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// Window frame for the saved anchor at a given window size.
    private func frame(for a: Anchor, size: CGSize) -> NSRect? {
        guard let vf = screen(named: a.screen)?.visibleFrame else { return nil }
        let m = WidgetMetrics.margin
        let cardW = size.width - 2 * m, cardH = size.height - 2 * m
        let cardX = a.right ? vf.maxX - a.dx - cardW : vf.minX + a.dx
        let cardY = a.bottom ? vf.minY + a.dy : vf.maxY - a.dy - cardH
        return NSRect(x: cardX - m, y: cardY - m, width: size.width, height: size.height)
    }

    /// Put the window where the saved anchor says, unless the user is dragging it.
    private func applyAnchor(size: CGSize? = nil) {
        guard let a = anchor, !state.configuring || size != nil else { return }
        let sz = size ?? widget.frame.size
        guard let f = frame(for: a, size: sz) else { return }
        if f.integral != widget.frame.integral {
            widget.setFrame(f, display: true)
            backdrop.crop()
            iconMover.schedule(after: 1)
        }
    }

    private func resizeWidget(to size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let f = widget.frame
        if abs(f.width - size.width) < 0.5 && abs(f.height - size.height) < 0.5 { return }
        if anchor == nil {
            // First run: start at the top right, 24 pt in from the corner.
            anchor = Anchor(screen: NSScreen.main?.localizedName ?? "", right: true, bottom: false, dx: 24, dy: 24)
        }
        applyAnchor(size: size)
        backdrop.crop()
        iconMover.schedule(after: 1)
    }

    /// Save the card's current spot (after a drag or Done) relative to its nearest corner.
    private func savePosition() {
        let m = WidgetMetrics.margin
        let card = widget.frame.insetBy(dx: m, dy: m)
        let center = NSPoint(x: card.midX, y: card.midY)
        guard let scr = NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? widget.screen ?? NSScreen.main
        else { return }
        let vf = scr.visibleFrame
        let left = card.minX - vf.minX, right = vf.maxX - card.maxX
        let top = vf.maxY - card.maxY, bottom = card.minY - vf.minY
        let a = Anchor(screen: scr.localizedName, right: right < left, bottom: bottom < top,
                       dx: max(0, min(left, right)).rounded(), dy: max(0, min(top, bottom)).rounded())
        anchor = a
        let d = UserDefaults.standard
        d.set(a.screen, forKey: "anchorScreen")
        d.set(a.right, forKey: "anchorRight")
        d.set(a.bottom, forKey: "anchorBottom")
        d.set(Double(a.dx), forKey: "anchorDX")
        d.set(Double(a.dy), forKey: "anchorDY")
        d.removeObject(forKey: "widgetTopLeftX")     // the old absolute position
        d.removeObject(forKey: "widgetTopLeftY")
    }

    private func placeInitially() {
        anchor = loadAnchor()
        let d = UserDefaults.standard
        if anchor == nil, d.object(forKey: "widgetTopLeftX") != nil {
            // Older versions saved an absolute top-left point: convert it once.
            widget.setFrameTopLeftPoint(NSPoint(x: d.double(forKey: "widgetTopLeftX"), y: d.double(forKey: "widgetTopLeftY")))
            savePosition()
        }
        applyAnchor()

        // Displays sleeping, waking or changing: wait for things to settle, then put it back.
        let reapply: () -> Void = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.screenChangeWork?.cancel()
                let work = DispatchWorkItem { [weak self] in Task { @MainActor in self?.applyAnchor() } }
                self.screenChangeWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { _ in reapply() }
        let ws = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            ws.addObserver(forName: n, object: nil, queue: .main) { _ in reapply() }
        }
        // And a slow self-check, in case something moved it without telling us.
        healTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.applyAnchor() }
        }
    }
}
