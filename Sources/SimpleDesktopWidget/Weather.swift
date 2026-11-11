import Foundation
import SwiftUI

struct DayForecast: Identifiable {
    let date: Date
    var id: Date { date }
    let highC: Double
    let lowC: Double
    let precipMM: Double
    let precipChance: Int?      // Open-Meteo only
    let windMS: Double
    let gustMS: Double?
    let symbol: String           // SF Symbol name
    let summary: String
}

@MainActor
final class WeatherModel: ObservableObject {
    @Published var days: [DayForecast] = []
    @Published var message: String?
    @Published var updated: Date?
    @Published var sourceLabel = ""
    @Published var loading = false

    private var timer: Timer?
    private var windyWarning: String?
    private let settings = Settings.shared

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
        let useWindy = settings.weatherProvider == "windy"
        if useWindy && settings.windyKey.trimmingCharacters(in: .whitespaces).isEmpty {
            message = "Add your Windy API key in Configure"
            days = []
            return
        }
        loading = true
        Task {
            do {
                let result = useWindy ? try await fetchWindy() : try await fetchOpenMeteo()
                days = result
                message = result.isEmpty ? "No forecast data returned" : (useWindy ? windyWarning : nil)
                updated = Date()
                sourceLabel = useWindy ? "Windy · \(Self.modelName(settings.windyModel))" : "Open-Meteo"
            } catch {
                message = error.localizedDescription
            }
            loading = false
        }
    }

    static let windyModels: [(id: String, name: String)] = [
        ("gfs", "GFS (global)"),
        ("iconEu", "ICON-EU (Europe)"),
        ("namConus", "NAM (USA)"),
        ("arome", "AROME (France)"),
    ]

    static func modelName(_ id: String) -> String {
        switch id {
        case "gfs": "GFS"
        case "iconEu": "ICON-EU"
        case "namConus": "NAM"
        case "arome": "AROME"
        default: id
        }
    }

    // MARK: Windy Point Forecast API v2

    private struct WindyError: LocalizedError {
        let text: String
        var errorDescription: String? { text }
    }

    private func fetchWindy() async throws -> [DayForecast] {
        var req = URLRequest(url: URL(string: "https://api.windy.com/api/point-forecast/v2")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 30
        let body: [String: Any] = [
            "lat": (settings.latitude * 100).rounded() / 100,
            "lon": (settings.longitude * 100).rounded() / 100,
            "model": settings.windyModel,
            "parameters": ["temp", "precip", "lclouds", "mclouds", "hclouds", "wind", "windGust", "ptype"],
            "levels": ["surface"],
            "key": settings.windyKey.trimmingCharacters(in: .whitespaces),
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            let msg = (obj["message"] as? String) ?? (obj["error"] as? String) ?? "HTTP \(http.statusCode)"
            throw WindyError(text: "Windy: \(msg)")
        }

        // The free testing tier says so in a "warning" field; its numbers are scrambled.
        windyWarning = (obj["warning"] as? String).map { _ in "Windy testing key: these numbers are scrambled sample data" }

        func series(_ prefix: String) -> [Double?] {
            guard let key = obj.keys.first(where: { $0.hasPrefix(prefix + "-") }),
                  let arr = obj[key] as? [Any] else { return [] }
            return arr.map { ($0 as? NSNumber)?.doubleValue }
        }
        let ts = ((obj["ts"] as? [Any]) ?? []).compactMap { ($0 as? NSNumber)?.doubleValue }
        let temp = series("temp")
        let precip = series("past3hprecip")
        let lc = series("lclouds"), mc = series("mclouds"), hc = series("hclouds")
        let u = series("wind_u"), v = series("wind_v")
        let gust = series("gust")
        let ptype = series("ptype")

        func at(_ a: [Double?], _ i: Int) -> Double? { i < a.count ? a[i] : nil }

        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var result: [DayForecast] = []

        for offset in 0..<3 {
            guard let dayStart = cal.date(byAdding: .day, value: offset, to: today),
                  let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) else { continue }
            let idx = ts.indices.filter {
                let t = Date(timeIntervalSince1970: ts[$0] / 1000)
                return t >= dayStart && t < dayEnd
            }
            let temps = idx.compactMap { at(temp, $0) }.map { $0 - 273.15 }
            guard let hi = temps.max(), let lo = temps.min() else { continue }

            let rain = idx.compactMap { at(precip, $0) }.reduce(0, +) * 1000   // m → mm
            let winds = idx.compactMap { i -> Double? in
                guard let uu = at(u, i), let vv = at(v, i) else { return nil }
                return (uu * uu + vv * vv).squareRoot()
            }
            let gusts = idx.compactMap { at(gust, $0) }

            // Total cloud cover from the three layers, averaged over daytime hours.
            func cover(_ i: Int) -> Double? {
                guard let l = at(lc, i), let m = at(mc, i), let h = at(hc, i) else { return nil }
                return 100 * (1 - (1 - l / 100) * (1 - m / 100) * (1 - h / 100))
            }
            let daytime = idx.filter {
                let hour = cal.component(.hour, from: Date(timeIntervalSince1970: ts[$0] / 1000))
                return hour >= 8 && hour <= 18
            }
            let clouds = (daytime.isEmpty ? idx : daytime).compactMap(cover)
            let cloud = clouds.isEmpty ? 50 : clouds.reduce(0, +) / Double(clouds.count)

            // Most common precipitation type among the wet steps.
            var counts: [Int: Int] = [:]
            for i in idx {
                if let p = at(ptype, i), p > 0, (at(precip, i) ?? 0) * 1000 > 0.1 {
                    counts[Int(p), default: 0] += 1
                }
            }
            let kind = counts.max { $0.value < $1.value }?.key ?? 1

            let gustMax = gusts.max()
            let (sym, text) = Self.symbol(cloud: cloud, precipMM: rain, ptype: kind, gustMS: gustMax ?? 0)
            result.append(DayForecast(date: dayStart, highC: hi, lowC: lo, precipMM: rain, precipChance: nil,
                                      windMS: winds.max() ?? 0, gustMS: gustMax, symbol: sym, summary: text))
        }
        return result
    }

    /// Windy ptype: 1 rain, 3 freezing rain, 5 snow, 7 rain/snow mix, 8 ice pellets.
    static func symbol(cloud: Double, precipMM: Double, ptype: Int, gustMS: Double) -> (String, String) {
        if precipMM >= 0.5 {
            switch ptype {
            case 5: return ("cloud.snow.fill", "Snow")
            case 3, 7, 8: return ("cloud.sleet.fill", "Wintry mix")
            default:
                if precipMM >= 12 { return ("cloud.heavyrain.fill", "Heavy rain") }
                if precipMM < 2 { return ("cloud.drizzle.fill", "Light rain") }
                return ("cloud.rain.fill", "Rain")
            }
        }
        if gustMS >= 17 { return ("wind", "Windy") }
        if cloud < 25 { return ("sun.max.fill", "Sunny") }
        if cloud < 65 { return ("cloud.sun.fill", "Partly cloudy") }
        return ("cloud.fill", "Cloudy")
    }

    // MARK: Open-Meteo (free, no key)

    private func fetchOpenMeteo() async throws -> [DayForecast] {
        var comps = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        comps.queryItems = [
            .init(name: "latitude", value: String(format: "%.3f", settings.latitude)),
            .init(name: "longitude", value: String(format: "%.3f", settings.longitude)),
            .init(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_sum,precipitation_probability_max,wind_speed_10m_max,wind_gusts_10m_max"),
            .init(name: "wind_speed_unit", value: "ms"),
            .init(name: "timezone", value: "auto"),
            .init(name: "forecast_days", value: "3"),
        ]
        let (data, _) = try await URLSession.shared.data(from: comps.url!)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let daily = obj["daily"] as? [String: Any],
              let times = daily["time"] as? [String] else {
            throw WindyError(text: "Open-Meteo: unexpected reply")
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

    static func wmo(_ c: Int) -> (String, String) {
        switch c {
        case 0: ("sun.max.fill", "Clear")
        case 1, 2: ("cloud.sun.fill", "Partly cloudy")
        case 3: ("cloud.fill", "Cloudy")
        case 45, 48: ("cloud.fog.fill", "Fog")
        case 51...57: ("cloud.drizzle.fill", "Drizzle")
        case 61, 63, 80, 81: ("cloud.rain.fill", "Rain")
        case 65, 82: ("cloud.heavyrain.fill", "Heavy rain")
        case 66, 67: ("cloud.sleet.fill", "Freezing rain")
        case 71...77, 85, 86: ("cloud.snow.fill", "Snow")
        case 95...99: ("cloud.bolt.rain.fill", "Thunderstorms")
        default: ("cloud.fill", "—")
        }
    }
}
