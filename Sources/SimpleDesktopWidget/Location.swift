import CoreLocation

/// One-shot "where am I" plus place-name lookups for the weather location.
@MainActor
final class LocationFinder: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var busy = false
    @Published var message: String?

    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private var pending = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func useCurrentLocation() {
        message = nil
        busy = true
        pending = true
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            busy = false; pending = false
            message = "Location access is off for this app (System Settings → Privacy & Security → Location Services)."
        default: manager.requestLocation()
        }
    }

    func search(_ text: String) {
        let q = text.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        message = nil
        busy = true
        geocoder.geocodeAddressString(q) { [weak self] marks, error in
            Task { @MainActor in
                guard let self else { return }
                self.busy = false
                guard let m = marks?.first, let loc = m.location else {
                    self.message = "Couldn't find “\(q)”."
                    return
                }
                self.apply(loc, name: Self.name(for: m))
            }
        }
    }

    private func apply(_ loc: CLLocation, name: String?) {
        let s = Settings.shared
        s.latitude = (loc.coordinate.latitude * 1000).rounded() / 1000
        s.longitude = (loc.coordinate.longitude * 1000).rounded() / 1000
        s.placeName = name ?? String(format: "%.2f, %.2f", s.latitude, s.longitude)
        NotificationCenter.default.post(name: .widgetLocationChanged, object: nil)
    }

    private static func name(for m: CLPlacemark) -> String? {
        let parts = [m.locality ?? m.name, m.administrativeArea].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            guard self.pending else { return }
            switch manager.authorizationStatus {
            case .notDetermined: break
            case .denied, .restricted:
                self.pending = false; self.busy = false
                self.message = "Location access was declined."
            default: manager.requestLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in
            guard self.pending else { return }
            self.pending = false
            self.geocoder.reverseGeocodeLocation(loc) { marks, _ in
                Task { @MainActor in
                    self.busy = false
                    self.apply(loc, name: marks?.first.flatMap(Self.name(for:)))
                }
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.pending = false; self.busy = false
            self.message = "Couldn't get your location: \(error.localizedDescription)"
        }
    }
}

extension Notification.Name {
    static let widgetLocationChanged = Notification.Name("widgetLocationChanged")
}
