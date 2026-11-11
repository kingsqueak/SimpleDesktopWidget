import AppKit
import SwiftUI

/// Moves the borderless widget window while the user drags it in configure mode.
@MainActor
final class WindowMover: ObservableObject {
    weak var window: NSWindow?
    var onMoved: () -> Void = {}
    var onDrag: () -> Void = {}
    private var startMouse: NSPoint?
    private var startOrigin: NSPoint = .zero

    func drag() {
        guard let w = window else { return }
        let m = NSEvent.mouseLocation
        if startMouse == nil {
            startMouse = m
            startOrigin = w.frame.origin
        }
        guard let s = startMouse else { return }
        var origin = NSPoint(x: startOrigin.x + m.x - s.x, y: startOrigin.y + m.y - s.y)

        // Snap the card (not the transparent margin) to the edges of the usable desktop,
        // and never let it go up under the menu bar.
        let screen = NSScreen.screens.first { $0.frame.contains(m) } ?? w.screen ?? NSScreen.main
        if let vf = screen?.visibleFrame {
            let mg = WidgetMetrics.margin, snap: CGFloat = 14, gap: CGFloat = 0
            let size = w.frame.size
            let cardLeft = origin.x + mg, cardRight = origin.x + size.width - mg
            let cardBottom = origin.y + mg, cardTop = origin.y + size.height - mg
            if cardTop > vf.maxY - snap { origin.y = vf.maxY - gap - size.height + mg }
            if cardBottom < vf.minY + snap && cardBottom > vf.minY - snap { origin.y = vf.minY + gap - mg }
            if abs(cardLeft - vf.minX) < snap { origin.x = vf.minX + gap - mg }
            if abs(cardRight - vf.maxX) < snap { origin.x = vf.maxX - gap - size.width + mg }
        }
        w.setFrameOrigin(origin)
        onDrag()
    }

    func end() {
        startMouse = nil
        onMoved()
    }
}

struct WidgetRoot: View {
    @EnvironmentObject var s: Settings
    @EnvironmentObject var state: AppState
    @EnvironmentObject var mover: WindowMover
    var onSize: (CGSize) -> Void

    var body: some View {
        let sc = s.scale
        let strength = s.shadowStrength
        WidgetCard()
            .overlay {
                if state.configuring {
                    RoundedRectangle(cornerRadius: 24 * sc)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
                        .overlay(alignment: .top) {
                            Label("Drag to position", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                                .font(.system(size: 11, weight: .semibold))
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(Capsule().fill(Color.accentColor))
                                .foregroundStyle(.white)
                                .offset(y: -12)
                        }
                }
            }
            .compositingGroup()
            // Two shadows: a wide soft one for "hovering", a tight one to crisp the edge.
            .shadow(color: .black.opacity(0.85 * strength), radius: 30 * strength, x: 0, y: 24 * strength)
            .shadow(color: .black.opacity(0.45 * strength), radius: 4, x: 0, y: 2)
            .opacity(s.displayOpacity)
            .padding(WidgetMetrics.margin)   // room for the shadow inside the transparent window
            .fixedSize()
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { _ in mover.drag() }
                    .onEnded { _ in mover.end() },
                including: state.configuring ? .all : .subviews
            )
            .onGeometryChange(for: CGSize.self, of: { $0.size }, action: onSize)
    }
}

struct WidgetCard: View {
    @EnvironmentObject var s: Settings
    @EnvironmentObject var backdrop: WallpaperBackdrop

    var body: some View {
        let sc = s.scale
        VStack(alignment: .leading, spacing: 16 * sc) {
            ClockView()
            Divider().overlay(s.textColor.color.opacity(0.25))
            WeatherView()
            Divider().overlay(s.textColor.color.opacity(0.25))
            EventsView()
        }
        .modifier(TextHalo(strength: s.textHalo, color: s.haloColor, scale: sc))
        .padding(22 * sc)
        .frame(width: 380 * sc, alignment: .leading)
        .foregroundStyle(s.textColor.color)
        .background {
            let shape = RoundedRectangle(cornerRadius: 24 * sc, style: .continuous)
            ZStack {
                if s.frostedGlass, let img = backdrop.image {
                    Image(nsImage: img).resizable()
                }
                shape.fill(s.backgroundColor.color.opacity(s.backgroundOpacity))
            }
            .clipShape(shape)
                .overlay {
                    if s.backgroundOpacity > 0.02 {
                        RoundedRectangle(cornerRadius: 24 * sc, style: .continuous)
                            .strokeBorder(.white.opacity(0.12 * min(1, s.backgroundOpacity * 2)), lineWidth: 1)
                    }
                }
        }
    }
}

// MARK: Clock

struct ClockView: View {
    @EnvironmentObject var s: Settings

    var body: some View {
        let sc = s.scale
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let d = ctx.date
            VStack(alignment: .leading, spacing: 2 * sc) {
                HStack(alignment: .firstTextBaseline, spacing: 3 * sc) {
                    Text(hm(d))
                        .font(s.font(78 * sc, s.clockWeight))
                        .monospacedDigit()
                        .kerning(-1.5 * sc)
                    if s.showSeconds {
                        Text(sec(d))
                            .font(s.font(30 * sc, s.clockWeight))
                            .monospacedDigit()
                            .opacity(0.65)
                    }
                    if !s.use24Hour {
                        Text(ampm(d))
                            .font(s.font(20 * sc, s.textWeight))
                            .opacity(0.65)
                            .padding(.leading, 2 * sc)
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                if s.showDate || s.showZulu {
                    HStack(alignment: .firstTextBaseline) {
                        if s.showDate {
                            Text(d.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                        }
                        Spacer(minLength: 8 * sc)
                        if s.showZulu {
                            Text(zulu(d)).monospacedDigit()
                        }
                    }
                    .font(s.font(17 * sc, s.textWeight))
                    .lineLimit(1)
                    .opacity(0.85)
                }
            }
        }
    }

    private func fmt(_ pattern: String, _ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = pattern
        return f.string(from: d)
    }
    private func hm(_ d: Date) -> String { fmt(s.use24Hour ? "HH:mm" : "h:mm", d) }
    private func sec(_ d: Date) -> String { fmt("ss", d) }
    private func ampm(_ d: Date) -> String { fmt("a", d) }
    private func zulu(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "HH:mm'Z'"
        return f.string(from: d)
    }
}

// MARK: Weather

struct WeatherView: View {
    @EnvironmentObject var s: Settings
    @EnvironmentObject var weather: WeatherModel
    @EnvironmentObject var alerts: AlertsModel
    @EnvironmentObject var lightning: LightningMonitor

    var body: some View {
        let sc = s.scale
        VStack(alignment: .leading, spacing: 10 * sc) {
            HStack(spacing: 5 * sc) {
                Image(systemName: "location.fill")
                Text(s.placeName.isEmpty ? "Weather" : s.placeName)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(weather.sourceLabel).opacity(0.6)
            }
            .font(s.font(12 * sc, s.textWeight))
            .opacity(0.85)

            if s.showAlerts {
                ForEach(alerts.alerts.prefix(3)) { a in AlertBanner(alert: a) }
            }

            if weather.days.isEmpty {
                Text(weather.message ?? (weather.loading ? "Loading forecast…" : "No forecast"))
                    .font(s.font(13 * sc, s.textWeight))
                    .opacity(0.7)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                let lo = weather.days.map(\.lowC).min() ?? 0
                let hi = weather.days.map(\.highC).max() ?? 1
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Array(weather.days.prefix(3).enumerated()), id: \.element.id) { i, day in
                        DayColumn(day: day, index: i, rangeLow: lo, rangeHigh: hi)
                            .frame(maxWidth: .infinity)
                    }
                }
                if let msg = weather.message {
                    Label(msg, systemImage: "exclamationmark.triangle.fill")
                        .font(s.font(11 * sc, s.textWeight))
                        .foregroundStyle(.yellow)
                        .frame(maxWidth: .infinity)
                }
            }

            if s.showLightning, let l = lightning.summary {
                LightningLine(summary: l)
            }
        }
    }
}

struct AlertBanner: View {
    @EnvironmentObject var s: Settings
    let alert: WeatherAlert

    var body: some View {
        let sc = s.scale
        HStack(spacing: 7 * sc) {
            Image(systemName: alert.symbol)
                .font(.system(size: 14 * sc, weight: .bold))
            Text(alert.event)
                .font(s.font(13 * sc, .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 4)
            if let end = alert.ends {
                Text("until \(end.formatted(date: Calendar.current.isDateInToday(end) ? .omitted : .abbreviated, time: .shortened))")
                    .font(s.font(11 * sc, s.textWeight))
                    .lineLimit(1)
                    .opacity(0.9)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10 * sc).padding(.vertical, 6 * sc)
        .background(RoundedRectangle(cornerRadius: 8 * sc, style: .continuous).fill(alert.color.opacity(0.85)))
        .help(alert.headline)
    }
}

struct LightningLine: View {
    @EnvironmentObject var s: Settings
    let summary: LightningMonitor.Summary

    var body: some View {
        let sc = s.scale
        let close = summary.nearestKm <= 16     // ~10 miles: the usual "go indoors" distance
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            let mins = max(0, Int(ctx.date.timeIntervalSince(summary.latest) / 60))
            HStack(spacing: 6 * sc) {
                Image(systemName: "bolt.fill")
                    .foregroundStyle(close ? .red : .yellow)
                    .font(.system(size: 14 * sc, weight: .bold))
                Text("Lightning \(s.distance(summary.nearestKm)) \(LightningMonitor.compass(summary.nearestBearing))")
                    .font(s.font(13 * sc, .bold))
                Spacer(minLength: 4)
                Text("\(summary.count) in 30 min · \(mins == 0 ? "now" : "\(mins) min ago")")
                    .font(s.font(11 * sc, s.textWeight))
                    .opacity(0.8)
            }
            .lineLimit(1)
            .padding(.horizontal, 10 * sc).padding(.vertical, 6 * sc)
            .background(RoundedRectangle(cornerRadius: 8 * sc, style: .continuous)
                .fill((close ? Color.red : Color.yellow).opacity(0.18)))
        }
    }
}

struct DayColumn: View {
    @EnvironmentObject var s: Settings
    let day: DayForecast
    let index: Int
    let rangeLow: Double
    let rangeHigh: Double

    var body: some View {
        let sc = s.scale
        VStack(spacing: 5 * sc) {
            Text(index == 0 ? "Today" : day.date.formatted(.dateTime.weekday(.abbreviated)))
                .font(s.font(14 * sc, .bold))
            Image(systemName: day.symbol)
                .symbolRenderingMode(.multicolor)
                .font(.system(size: 36 * sc))
                .frame(height: 44 * sc)
                .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
                .help(day.summary)
            HStack(alignment: .firstTextBaseline, spacing: 4 * sc) {
                Text(s.temp(day.highC)).font(s.font(20 * sc, .semibold))
                Text(s.temp(day.lowC)).font(s.font(15 * sc, s.textWeight)).opacity(0.6)
            }
            .monospacedDigit()
            TempBar(low: day.lowC, high: day.highC, rangeLow: rangeLow, rangeHigh: rangeHigh)
                .frame(width: 70 * sc, height: 5 * sc)
            VStack(spacing: 2 * sc) {
                Label(day.precipChance.map { "\($0)%  \(s.precip(day.precipMM))" } ?? s.precip(day.precipMM),
                      systemImage: "drop.fill")
                Label(s.wind(day.gustMS ?? day.windMS), systemImage: "wind")
            }
            .labelStyle(SmallLabel(scale: sc))
            .font(s.font(11 * sc, s.textWeight))
            .opacity(0.75)
            .monospacedDigit()
        }
    }
}

struct SmallLabel: LabelStyle {
    let scale: Double
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3 * scale) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
        .lineLimit(1)
    }
}

/// iOS-weather style bar: where today's low..high sits inside the three-day range.
struct TempBar: View {
    let low: Double, high: Double, rangeLow: Double, rangeHigh: Double

    var body: some View {
        GeometryReader { g in
            let span = max(rangeHigh - rangeLow, 1)
            let x0 = (low - rangeLow) / span * g.size.width
            let x1 = (high - rangeLow) / span * g.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.18))
                Capsule()
                    .fill(LinearGradient(colors: [Self.color(low), Self.color(high)], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(x1 - x0, g.size.height))
                    .offset(x: x0)
            }
        }
    }

    /// Cold blue through green and yellow to hot red, by °C.
    static func color(_ c: Double) -> Color {
        let stops: [(Double, Color)] = [(-10, .indigo), (0, .blue), (10, .teal), (18, .green), (25, .yellow), (32, .orange), (40, .red)]
        if c <= stops.first!.0 { return stops.first!.1 }
        for (a, b) in zip(stops, stops.dropFirst()) where c <= b.0 {
            return (c - a.0) / (b.0 - a.0) < 0.5 ? a.1 : b.1
        }
        return stops.last!.1
    }
}

// MARK: Calendar

struct EventsView: View {
    @EnvironmentObject var s: Settings
    @EnvironmentObject var cal: CalendarModel

    var body: some View {
        let sc = s.scale
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            let now = ctx.date
            VStack(alignment: .leading, spacing: 7 * sc) {
                HStack(spacing: 5 * sc) {
                    Image(systemName: "calendar")
                    Text("Today")
                    Spacer()
                    if cal.access == .granted {
                        Text(cal.events.isEmpty ? "" : "\(cal.events.count) event\(cal.events.count == 1 ? "" : "s")")
                            .opacity(0.6)
                    }
                }
                .font(s.font(12 * sc, s.textWeight))
                .opacity(0.85)

                switch cal.access {
                case .denied:
                    note("Calendar access is off — allow it in System Settings → Privacy & Security → Calendars.")
                case .unknown:
                    note("Waiting for calendar access…")
                case .granted:
                    if cal.events.isEmpty {
                        note("Nothing on the calendar today")
                    } else {
                        ForEach(cal.events.prefix(s.maxEvents)) { e in
                            row(e, now: now)
                        }
                        if cal.events.count > s.maxEvents {
                            note("+ \(cal.events.count - s.maxEvents) more")
                        }
                    }
                }
            }
        }
    }

    private func note(_ t: String) -> some View {
        Text(t).font(s.font(13 * s.scale, s.textWeight)).opacity(0.65)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func row(_ e: EventItem, now: Date) -> some View {
        let sc = s.scale
        let finished = !e.allDay && e.end <= now
        let current = !e.allDay && e.start <= now && e.end > now
        return HStack(spacing: 9 * sc) {
            Capsule().fill(e.color).frame(width: 4 * sc, height: 18 * sc)
            Text(timeLabel(e))
                .font(s.font(13 * sc, s.textWeight))
                .monospacedDigit()
                .opacity(0.75)
                .frame(width: 64 * sc, alignment: .leading)
            Text(e.title)
                .font(s.font(14 * sc, current ? .bold : s.textWeight))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if current {
                Text("NOW")
                    .font(.system(size: 9 * sc, weight: .heavy))
                    .padding(.horizontal, 5 * sc).padding(.vertical, 2 * sc)
                    .background(Capsule().fill(e.color.opacity(0.85)))
                    .foregroundStyle(.white)
            }
        }
        .opacity(finished ? 0.4 : 1)
    }

    private func timeLabel(_ e: EventItem) -> String {
        if e.allDay { return "All day" }
        let f = DateFormatter()
        f.dateFormat = s.use24Hour ? "HH:mm" : "h:mm a"
        return f.string(from: e.start).lowercased()
    }
}

/// A thin, tight edge around every letter, icon and line so the text stays readable
/// on wallpaper of the same colour (white on white). Three stacked tight shadows build
/// a near-solid outline at full strength; it fades to nothing at 0.
struct TextHalo: ViewModifier {
    let strength: Double
    let color: Color
    let scale: Double

    func body(content: Content) -> some View {
        if strength <= 0.01 {
            content
        } else {
            content
                .shadow(color: color.opacity(min(1, strength * 1.2)), radius: 0.6 * scale)
                .shadow(color: color.opacity(strength * 0.9), radius: 1.2 * scale)
                .shadow(color: color.opacity(strength * 0.6), radius: 2.5 * scale)
        }
    }
}
