// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris

import Foundation
import SwiftUI

/// Live lightning near the saved location, from the Blitzortung.org volunteer network.
///
/// The widget listens to Blitzortung's public strike stream (every strike worldwide,
/// a few per second) and keeps only the ones inside the chosen radius. Nothing about
/// the user's location is sent to Blitzortung. Data is free for personal,
/// non-commercial use and comes with no guarantees: not for safety decisions.
@MainActor
final class LightningMonitor: ObservableObject {
    struct Strike { let time: Date; let km: Double; let bearing: Double }

    struct Summary: Equatable {
        let count: Int
        let nearestKm: Double
        let nearestBearing: Double
        let latest: Date
    }

    @Published var summary: Summary?
    @Published var connected = false
    @Published var status = "Not connected"

    /// How long a strike counts as "recent".
    static let window: TimeInterval = 30 * 60

    private let settings = Settings.shared
    private var strikes: [Strike] = []
    private var task: URLSessionWebSocketTask?
    private var hostIndex = 0
    private var retryDelay: TimeInterval = 5
    private var ageTimer: Timer?
    private var lastMessage = Date.distantPast
    private let hosts = ["ws1.blitzortung.org", "ws7.blitzortung.org", "ws8.blitzortung.org"]

    func start() {
        // Age out old strikes, and reconnect if the stream has gone quiet.
        ageTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.recompute()
                if self.settings.showLightning, self.task != nil, Date().timeIntervalSince(self.lastMessage) > 90 {
                    self.reconnect(nextHost: true)
                }
            }
        }
        apply()
    }

    /// Call when the toggle, radius or location changes.
    func apply() {
        strikes = []
        recompute()
        if settings.showLightning && settings.hasLocation {
            if task == nil { connect() }
        } else {
            disconnect()
            status = "Off"
        }
    }

    private func connect() {
        let host = hosts[hostIndex % hosts.count]
        let t = URLSession.shared.webSocketTask(with: URL(string: "wss://\(host)/")!)
        task = t
        t.resume()
        t.send(.string("{\"a\":111}")) { _ in }
        lastMessage = Date()
        status = "Connecting to \(host)…"
        receive(on: t)
    }

    private func disconnect() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        connected = false
    }

    private func reconnect(nextHost: Bool) {
        disconnect()
        if nextHost { hostIndex += 1 }
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 300)
        status = "Reconnecting in \(Int(delay)) s"
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.task == nil, self.settings.showLightning else { return }
            self.connect()
        }
    }

    private func receive(on t: URLSessionWebSocketTask) {
        let lat = settings.latitude, lon = settings.longitude
        let radius = settings.lightningRadiusKm
        t.receive { [weak self] result in
            switch result {
            case .success(let msg):
                var hit: Strike?
                if case .string(let s) = msg {
                    hit = Self.parse(s, lat: lat, lon: lon, radiusKm: radius)
                }
                Task { @MainActor in
                    guard let self, self.task === t else { return }
                    self.lastMessage = Date()
                    if !self.connected { self.connected = true; self.status = "Live"; self.retryDelay = 5 }
                    if let hit { self.strikes.append(hit); self.recompute() }
                    self.receive(on: t)
                }
            case .failure:
                Task { @MainActor in
                    guard let self, self.task === t else { return }
                    self.reconnect(nextHost: true)
                }
            }
        }
    }

    private func recompute() {
        let cutoff = Date().addingTimeInterval(-Self.window)
        strikes.removeAll { $0.time < cutoff }
        guard let nearest = strikes.min(by: { $0.km < $1.km }), let latest = strikes.map(\.time).max() else {
            if summary != nil { summary = nil }
            return
        }
        let s = Summary(count: strikes.count, nearestKm: nearest.km, nearestBearing: nearest.bearing, latest: latest)
        if s != summary { summary = s }
    }

    // MARK: Decoding (runs off the main thread)

    nonisolated static func parse(_ s: String, lat: Double, lon: Double, radiusKm: Double) -> Strike? {
        let json = decode(s)
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              let sLat = (obj["lat"] as? NSNumber)?.doubleValue,
              let sLon = (obj["lon"] as? NSNumber)?.doubleValue,
              let ns = (obj["time"] as? NSNumber)?.doubleValue else { return nil }
        // Cheap box test before the trig.
        if abs(sLat - lat) > radiusKm / 100 + 0.5 { return nil }
        let km = distanceKm(lat, lon, sLat, sLon)
        guard km <= radiusKm else { return nil }
        return Strike(time: Date(timeIntervalSince1970: ns / 1e9), km: km, bearing: bearing(lat, lon, sLat, sLon))
    }

    /// Blitzortung packs each message with a small LZW-style dictionary coder:
    /// code units below 256 are literal, higher ones refer back to earlier phrases.
    nonisolated static func decode(_ s: String) -> String {
        let d = Array(s.utf16)
        guard let first = d.first else { return "" }
        var dict: [Int: [UInt16]] = [:]
        var prev: [UInt16] = [first]
        var out: [UInt16] = [first]
        var code = 256
        for u in d.dropFirst() {
            let a = Int(u)
            let w: [UInt16] = a < 256 ? [u] : (dict[a] ?? (prev + [prev[0]]))
            out += w
            dict[code] = prev + [w[0]]
            code += 1
            prev = w
        }
        return String(decoding: out, as: UTF16.self)
    }

    nonisolated static func distanceKm(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let r = 6371.0, p1 = lat1 * .pi / 180, p2 = lat2 * .pi / 180
        let dp = p2 - p1, dl = (lon2 - lon1) * .pi / 180
        let a = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * r * asin(min(1, sqrt(a)))
    }

    nonisolated static func bearing(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let p1 = lat1 * .pi / 180, p2 = lat2 * .pi / 180, dl = (lon2 - lon1) * .pi / 180
        let y = sin(dl) * cos(p2)
        let x = cos(p1) * sin(p2) - sin(p1) * cos(p2) * cos(dl)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    static func compass(_ deg: Double) -> String {
        ["N", "NE", "E", "SE", "S", "SW", "W", "NW"][Int((deg + 22.5) / 45) % 8]
    }
}
