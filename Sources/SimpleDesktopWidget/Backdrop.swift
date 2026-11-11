import AppKit
import CoreImage
import ScreenCaptureKit
import SwiftUI

enum WidgetMetrics {
    /// Transparent margin around the card inside the window, room for the drop shadow.
    static let margin: CGFloat = 72
}

/// Frosted-glass backing for the card.
///
/// Captures only the system's wallpaper window (never the desktop icons or other
/// windows), blurs the piece behind the card, and draws it as the card background.
/// It looks like glass over the wallpaper, but hides any icons under the widget.
/// Capturing needs Screen Recording permission; without it the card just uses its tint.
@MainActor
final class WallpaperBackdrop: ObservableObject {
    @Published var image: NSImage?
    @Published var permissionMissing = false

    weak var window: NSWindow?
    private var wallpaper: CGImage?          // whole screen's wallpaper, 1 px per point
    private var wallpaperScreen: CGRect = .zero
    private var capturing = false
    private var lastCrop = Date.distantPast
    private var timer: Timer?
    private let ci = CIContext()

    func start() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.recapture() }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.recapture() }
        }
        // Wallpapers can shuffle or change without any notification.
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.recapture() }
        }
    }

    /// Ask for Screen Recording permission (shows the system prompt once).
    func requestPermission() {
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
        recapture()
    }

    func recapture() {
        guard Settings.shared.frostedGlass else { image = nil; return }
        guard !capturing, let w = window, let screen = w.screen ?? NSScreen.main else { return }
        guard CGPreflightScreenCaptureAccess() else {
            permissionMissing = true
            image = nil
            return
        }
        permissionMissing = false
        capturing = true
        let screenFrame = screen.frame
        // ScreenCaptureKit uses top-left-origin global coordinates.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screenFrame.height
        let cgFrame = CGRect(x: screenFrame.minX, y: primaryHeight - screenFrame.maxY,
                             width: screenFrame.width, height: screenFrame.height)
        Task {
            defer { capturing = false }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                let candidates = content.windows.filter {
                    $0.owningApplication?.bundleIdentifier == "com.apple.WindowManager" && $0.title == "Wallpaper"
                }
                guard let wp = candidates.first(where: { $0.frame.intersects(cgFrame) && $0.isOnScreen })
                        ?? candidates.first(where: { $0.frame.intersects(cgFrame) }) else {
                    return
                }
                let cfg = SCStreamConfiguration()
                cfg.width = Int(wp.frame.width)
                cfg.height = Int(wp.frame.height)
                cfg.showsCursor = false
                cfg.ignoreShadowsSingleWindow = true
                let img = try await SCScreenshotManager.captureImage(
                    contentFilter: SCContentFilter(desktopIndependentWindow: wp), configuration: cfg)
                wallpaper = img
                // The wallpaper window's frame, back in AppKit (bottom-left origin) coordinates.
                wallpaperScreen = CGRect(x: wp.frame.minX, y: primaryHeight - wp.frame.maxY,
                                         width: wp.frame.width, height: wp.frame.height)
                crop()
            } catch {
                // Leave the previous image in place; the next timer tick tries again.
            }
        }
    }

    /// Re-cut the card's piece from the cached wallpaper (cheap: call while dragging).
    func crop(throttled: Bool = false) {
        if throttled && Date().timeIntervalSince(lastCrop) < 0.04 { return }
        lastCrop = Date()
        guard Settings.shared.frostedGlass else { image = nil; return }
        guard let wall = wallpaper, let w = window else { return }
        let card = w.frame.insetBy(dx: WidgetMetrics.margin, dy: WidgetMetrics.margin)
        guard card.width > 10, card.height > 10 else { return }

        // Image is 1 px per point; Core Image's origin is bottom-left like AppKit's.
        let sx = CGFloat(wall.width) / wallpaperScreen.width
        let sy = CGFloat(wall.height) / wallpaperScreen.height
        let rect = CGRect(x: (card.minX - wallpaperScreen.minX) * sx, y: (card.minY - wallpaperScreen.minY) * sy,
                          width: card.width * sx, height: card.height * sy)
        let blurred = CIImage(cgImage: wall).clampedToExtent()
            .applyingGaussianBlur(sigma: 14)
            .cropped(to: rect)
        guard let out = ci.createCGImage(blurred, from: rect) else { return }
        image = NSImage(cgImage: out, size: card.size)
    }
}
