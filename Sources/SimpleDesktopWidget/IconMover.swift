import AppKit

/// Keeps Finder's desktop icons out of the widget's area.
///
/// macOS has no setting for "keep icons away from this rectangle", but Finder is
/// scriptable: every desktop item has a `desktop position` (its centre, in points from
/// the top-left of the main display). Any icon whose footprint overlaps the card is
/// moved to the nearest free spot on an icon grid. Runs when the widget is placed or
/// resized and when something new appears on the Desktop or a disk mounts.
/// Needs Automation permission for Finder (asked once).
@MainActor
final class IconMover: ObservableObject {
    @Published var lastError: String?
    @Published var lastMoved = 0

    weak var window: NSWindow?
    var isPaused: () -> Bool = { false }
    private var pending: DispatchWorkItem?
    private var desktopWatch: DispatchSourceFileSystemObject?

    // Footprint of one icon around its centre: icon plus a two-line label below.
    private let halfWidth: CGFloat = 62
    private let above: CGFloat = 42
    private let below: CGFloat = 72
    // Grid used to find new places (Finder's own spacing at 64 pt icons).
    private let cellW: CGFloat = 136
    private let cellH: CGFloat = 122

    func start() {
        let ws = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            ws.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.schedule(after: 2) }
            }
        }
        watchDesktopFolder()
    }

    /// Debounced: Finder needs a moment to place a new item before we can move it.
    func schedule(after seconds: Double = 1) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.run() }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func watchDesktopFolder() {
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop").path
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        src.setEventHandler { [weak self] in
            Task { @MainActor in self?.schedule(after: 1.5) }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        desktopWatch = src
    }

    func run() {
        guard Settings.shared.keepIconsClear, !isPaused(), let w = window,
              let main = NSScreen.screens.first else { return }

        // Everything below is in Finder's coordinates: points, origin top-left of the main display.
        let H = main.frame.height
        let cardAK = w.frame.insetBy(dx: WidgetMetrics.margin, dy: WidgetMetrics.margin)
        let card = CGRect(x: cardAK.minX, y: H - cardAK.maxY, width: cardAK.width, height: cardAK.height)
        let blocked = card.insetBy(dx: -8, dy: -8)

        guard let icons = readIcons() else { return }
        func footprint(_ p: CGPoint) -> CGRect {
            CGRect(x: p.x - halfWidth, y: p.y - above, width: halfWidth * 2, height: above + below)
        }
        let toMove = icons.filter { footprint($0.pos).intersects(blocked) }
        guard !toMove.isEmpty else { lastError = nil; return }

        // Candidate spots: a grid anchored like Finder's, at the top-right of the main display.
        let vf = main.visibleFrame
        let top = H - vf.maxY + 70
        let right = vf.maxX - 72
        var spots: [CGPoint] = []
        var x = right
        while x > vf.minX + 40 {
            var y = top
            while y < H - (vf.minY - main.frame.minY) - below {
                spots.append(CGPoint(x: x, y: y))
                y += cellH
            }
            x -= cellW
        }

        var occupied = icons.filter { i in !toMove.contains { $0.name == i.name } }.map { footprint($0.pos) }
        var script = "tell application \"Finder\"\n"
        for icon in toMove {
            let free = spots
                .filter { s in
                    let f = footprint(s)
                    return !f.intersects(blocked) && !occupied.contains { $0.insetBy(dx: 4, dy: 4).intersects(f) }
                }
                .min { hypot($0.x - icon.pos.x, $0.y - icon.pos.y) < hypot($1.x - icon.pos.x, $1.y - icon.pos.y) }
            guard let spot = free else { continue }
            occupied.append(footprint(spot))
            script += "set desktop position of item \"\(escape(icon.name))\" of desktop to {\(Int(spot.x)), \(Int(spot.y))}\n"
        }
        script += "end tell"

        var err: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&err)
        if let err {
            lastError = Self.describe(err)
        } else {
            lastError = nil
            lastMoved = toMove.count
        }
    }

    private struct Icon { let name: String; let pos: CGPoint }

    private func readIcons() -> [Icon]? {
        let src = """
        tell application "Finder"
            set out to ""
            set L to every item of desktop
            repeat with i from 1 to count of L
                set it_ to item i of L
                set p to desktop position of it_
                set out to out & (name of it_) & tab & (item 1 of p) & tab & (item 2 of p) & linefeed
            end repeat
            return out
        end tell
        """
        var err: NSDictionary?
        guard let result = NSAppleScript(source: src)?.executeAndReturnError(&err), err == nil else {
            lastError = err.map(Self.describe) ?? "Couldn't read desktop icons"
            return nil
        }
        return (result.stringValue ?? "").split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard f.count == 3, let x = Double(f[1]), let y = Double(f[2]) else { return nil }
            return Icon(name: String(f[0]), pos: CGPoint(x: x, y: y))
        }
    }

    private func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func describe(_ err: NSDictionary) -> String {
        let code = err[NSAppleScript.errorNumber] as? Int ?? 0
        if code == -1743 {
            return "Not allowed to control Finder. Turn on Finder for SimpleDesktopWidget in System Settings → Privacy & Security → Automation."
        }
        return (err[NSAppleScript.errorMessage] as? String) ?? "Finder error \(code)"
    }
}
