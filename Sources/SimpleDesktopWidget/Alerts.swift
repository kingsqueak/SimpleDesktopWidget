import Foundation
import SwiftUI

struct WeatherAlert: Identifiable, Equatable {
    let id: String
    let event: String          // "Severe Thunderstorm Warning"
    let severity: String       // Extreme, Severe, Moderate, Minor, Unknown
    let headline: String
    let ends: Date?

    var rank: Int { ["Extreme": 0, "Severe": 1, "Moderate": 2, "Minor": 3][severity] ?? 4 }

    var color: Color {
        switch severity {
        case "Extreme", "Severe": .red
        case "Moderate": .orange
        default: .yellow
        }
    }

    var symbol: String {
        let e = event.lowercased()
        if e.contains("thunder") { return "cloud.bolt.rain.fill" }
        if e.contains("tornado") { return "tornado" }
        if e.contains("flood") { return "water.waves" }
        if e.contains("winter") || e.contains("snow") || e.contains("blizzard") || e.contains("ice") { return "snowflake" }
        if e.contains("wind") { return "wind" }
        if e.contains("heat") { return "thermometer.sun.fill" }
        if e.contains("fog") { return "cloud.fog.fill" }
        return "exclamationmark.triangle.fill"
    }
}

/// Active National Weather Service alerts for the saved location (US only, free, no key).
@MainActor
final class AlertsModel: ObservableObject {
    @Published var alerts: [WeatherAlert] = []
    @Published var message: String?
    @Published var updated: Date?

    private var timer: Timer?
    private let settings = Settings.shared

    func start() {
        refresh()
        // Warnings are issued and cancelled quickly; NWS asks clients not to poll faster than this.
        timer = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        guard settings.showAlerts, settings.hasLocation else { alerts = []; message = nil; return }
        let url = URL(string: String(format: "https://api.weather.gov/alerts/active?point=%.3f,%.3f",
                                     settings.latitude, settings.longitude))!
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        // NWS requires a User-Agent that names the client.
        req.setValue("SimpleDesktopWidget/0.1 (personal desktop widget)", forHTTPHeaderField: "User-Agent")
        req.setValue("application/geo+json", forHTTPHeaderField: "Accept")
        Task {
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
                if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                    // 404 here means the point is outside NWS coverage (outside the US).
                    message = http.statusCode == 404 ? "NWS alerts cover the US only"
                        : "NWS: \((obj["detail"] as? String) ?? "HTTP \(http.statusCode)")"
                    alerts = []
                    return
                }
                let iso = ISO8601DateFormatter()
                let feats = (obj["features"] as? [[String: Any]]) ?? []
                let list: [WeatherAlert] = feats.compactMap { f in
                    guard let p = f["properties"] as? [String: Any], let event = p["event"] as? String else { return nil }
                    if (p["status"] as? String).map({ $0 != "Actual" }) ?? false { return nil }
                    let end = (p["ends"] as? String).flatMap(iso.date) ?? (p["expires"] as? String).flatMap(iso.date)
                    return WeatherAlert(id: (p["id"] as? String) ?? UUID().uuidString, event: event,
                                        severity: (p["severity"] as? String) ?? "Unknown",
                                        headline: (p["headline"] as? String) ?? event, ends: end)
                }
                // One line per kind of alert (updates of the same warning come as separate items).
                var seen = Set<String>()
                alerts = list.sorted { ($0.rank, $0.ends ?? .distantFuture) < ($1.rank, $1.ends ?? .distantFuture) }
                    .filter { seen.insert($0.event).inserted }
                message = nil
                updated = Date()
            } catch {
                message = "NWS: \(error.localizedDescription)"
            }
        }
    }
}
