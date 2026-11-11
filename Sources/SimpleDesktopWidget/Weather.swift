import Foundation
import SwiftUI

struct DayForecast: Identifiable {
    let date: Date
    var id: Date { date }
    let highC: Double
    let lowC: Double
    let precipMM: Double
    let precipChance: Int?
    let windMS: Double
    let gustMS: Double?
    let symbol: String           // SF Symbol name
    let summary: String
}

/// Three-day forecast from Open-Meteo (free, no key).
@MainActor
final class WeatherModel: ObservableObject {
    @Published var days: [DayForecast] = []
    @Published var message: String?
    @Published var updated: Date?
    @Published var loading = false
    let sourceLabel = "Open-Meteo"

    private var timer: Timer?
    private let settings = Settings.shared

    private struct FetchError: LocalizedError {
        let text: String
        var errorDescription: String? { text }
    }

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        guard settings.hasLocation else {
            message = "Set a location in Configure"
            days = []
            return
        }
        loading = true
        Task {
            do {
                let result = try await fetch()
                days = result
                message = result.isEmpty ? "No forecast data returned" : nil
                updated = Date()
            } catch {
                // Keep showing the last good forecast if there is one.
                message = days.isEmpty ? error.localizedDescription : "Couldn't refresh: \(error.localizedDescription)"
            }
            loading = false
        }
    }

    private func fetch() async throws -> [DayForecast] {
        var comps = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        comps.queryItems = [
            .init(name: "latitude", value: String(format: "%.3f", settings.latitude)),
            .init(name: "longitude", value: String(format: "%.3f", settings.longitude)),
            .init(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_sum,precipitation_probability_max,wind_speed_10m_max,wind_gusts_10m_max"),
            .init(name: "wind_speed_unit", value: "ms"),
            .init(name: "timezone", value: "auto"),
            .init(name: "forecast_days", value: "3"),
        ]
        var req = URLRequest(url: comps.url!)
        req.timeoutInterval = 30
        let (data, resp) = try await URLSession.shared.data(for: req)
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw FetchError(text: "Open-Meteo: \((obj["reason"] as? String) ?? "HTTP \(http.statusCode)")")
        }
        guard let daily = obj["daily"] as? [String: Any], let times = daily["time"] as? [String] else {
            throw FetchError(text: "Open-Meteo: unexpected reply")
        }
        func nums(_ k: String) -> [Double?] { ((daily[k] as? [Any]) ?? []).map { ($0 as? NSNumber)?.doubleValue } }
        let code = nums("weather_code"), hi = nums("temperature_2m_max"), lo = nums("temperature_2m_min")
        let pr = nums("precipitation_sum"), pp = nums("precipitation_probability_max")
        let ws = nums("wind_speed_10m_max"), wg = nums("wind_gusts_10m_max")
        func at(_ a: [Double?], _ i: Int) -> Double? { i < a.count ? a[i] : nil }

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = .current
        return times.indices.compactMap { i in
            guard let date = fmt.date(from: times[i]), let h = at(hi, i), let l = at(lo, i) else { return nil }
            let (sym, text) = Self.wmo(Int(at(code, i) ?? 0))
            return DayForecast(date: date, highC: h, lowC: l, precipMM: at(pr, i) ?? 0,
                               precipChance: at(pp, i).map { Int($0) }, windMS: at(ws, i) ?? 0,
                               gustMS: at(wg, i), symbol: sym, summary: text)
        }
    }

    /// WMO weather interpretation codes → SF Symbol and a short description.
    static func wmo(_ c: Int) -> (String, String) {
        switch c {
        case 0: ("sun.max.fill", "Clear")
        case 1: ("sun.max.fill", "Mainly clear")
        case 2: ("cloud.sun.fill", "Partly cloudy")
        case 3: ("cloud.fill", "Cloudy")
        case 45, 48: ("cloud.fog.fill", "Fog")
        case 51...55: ("cloud.drizzle.fill", "Drizzle")
        case 56, 57, 66, 67: ("cloud.sleet.fill", "Freezing rain")
        case 61, 63, 80, 81: ("cloud.rain.fill", "Rain")
        case 65, 82: ("cloud.heavyrain.fill", "Heavy rain")
        case 71...77, 85, 86: ("cloud.snow.fill", "Snow")
        case 95...99: ("cloud.bolt.rain.fill", "Thunderstorms")
        default: ("cloud.fill", "—")
        }
    }
}
