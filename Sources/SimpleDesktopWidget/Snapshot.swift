// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris

import AppKit
import SwiftUI

/// Renders the widget off-screen with made-up sample data, for the README screenshot:
///
///   TZ=America/Denver SimpleDesktopWidget --snapshot widget.png
///
/// Nothing real is used (no calendar, location or network) and no setting is saved.
/// The PNG has a transparent background around the card's drop shadow.
@MainActor
enum Snapshot {
    static func render(to path: String) -> Bool {
        Settings.snapshotMode = true
        let s = Settings.shared
        s.fontFamily = Settings.systemFamily
        s.clockWeight = .bold
        s.textWeight = .medium
        s.scale = 1
        s.textColor = RGBA(r: 1, g: 1, b: 1)
        s.backgroundColor = RGBA(r: 0.05, g: 0.07, b: 0.12)
        s.backgroundOpacity = 0.45
        s.displayOpacity = 1
        s.shadowStrength = 0.8
        s.textHalo = 0.12
        s.frostedGlass = false
        s.use24Hour = false
        s.showSeconds = true
        s.showDate = true
        s.showZulu = true
        s.imperial = true
        s.placeName = "Boulder, CO"
        s.latitude = 40.015
        s.longitude = -105.270
        s.showAlerts = true
        s.showLightning = true
        s.hideFinishedEvents = false
        s.maxEvents = 8

        let cal = Calendar.current
        let now = cal.date(from: DateComponents(year: 2026, month: 6, day: 17, hour: 15, minute: 10, second: 42))!
        let today = cal.startOfDay(for: now)
        func day(_ n: Int) -> Date { cal.date(byAdding: .day, value: n, to: today)! }
        func at(_ h: Int, _ m: Int) -> Date { cal.date(bySettingHour: h, minute: m, second: 0, of: today)! }
        func c(_ f: Double) -> Double { (f - 32) * 5 / 9 }
        let mph = 0.44704

        let weather = WeatherModel()
        weather.days = [
            DayForecast(date: day(0), highC: c(84), lowC: c(58), precipMM: 6.4, precipChance: 70,
                        windMS: 9 * mph, gustMS: 34 * mph, symbol: "cloud.bolt.rain.fill", summary: "Thunderstorms"),
            DayForecast(date: day(1), highC: c(79), lowC: c(55), precipMM: 0.5, precipChance: 20,
                        windMS: 7 * mph, gustMS: 18 * mph, symbol: "cloud.sun.fill", summary: "Partly cloudy"),
            DayForecast(date: day(2), highC: c(86), lowC: c(57), precipMM: 0, precipChance: 5,
                        windMS: 6 * mph, gustMS: 14 * mph, symbol: "sun.max.fill", summary: "Sunny"),
        ]
        weather.updated = now

        let alerts = AlertsModel()
        alerts.alerts = [WeatherAlert(id: "demo", event: "Severe Thunderstorm Watch", severity: "Moderate",
                                      headline: "Severe Thunderstorm Watch until 9:00 PM", ends: at(21, 0))]

        let lightning = LightningMonitor()
        lightning.summary = .init(count: 23, nearestKm: 14 * 1.609344, nearestBearing: 280,
                                  latest: now.addingTimeInterval(-120))

        let calendar = CalendarModel()
        calendar.access = .granted
        func ev(_ t: String, _ s: Date, _ e: Date, _ allDay: Bool = false, _ col: Color) -> EventItem {
            EventItem(id: t, title: t, start: s, end: e, allDay: allDay, color: col, location: nil)
        }
        calendar.events = [
            ev("Library books due", today, day(1), true, .green),
            ev("Team stand-up", at(9, 30), at(9, 45), false, .blue),
            ev("Lunch with Sam", at(12, 30), at(13, 30), false, .orange),
            ev("Dentist", at(15, 0), at(16, 0), false, .purple),
            ev("Radio club net on 2 m", at(19, 0), at(20, 0), false, .teal),
        ]

        let view = WidgetRoot(onSize: { _ in })
            .environmentObject(s)
            .environmentObject(AppState())
            .environmentObject(weather)
            .environmentObject(calendar)
            .environmentObject(WindowMover())
            .environmentObject(WallpaperBackdrop())
            .environmentObject(alerts)
            .environmentObject(lightning)
            .environment(\.widgetNow, now)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let cg = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write("snapshot: render failed\n".data(using: .utf8)!)
            return false
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("wrote \(path) (\(cg.width)x\(cg.height))")
            return true
        } catch {
            FileHandle.standardError.write("snapshot: \(error.localizedDescription)\n".data(using: .utf8)!)
            return false
        }
    }
}
