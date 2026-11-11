import AppKit
import SwiftUI

/// A colour stored as sRGB components so it can live in UserDefaults.
struct RGBA: Equatable {
    var r: Double, g: Double, b: Double, a: Double

    init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
        r = Double(ns.redComponent); g = Double(ns.greenComponent)
        b = Double(ns.blueComponent); a = Double(ns.alphaComponent)
    }

    init?(array: [Double]?) {
        guard let v = array, v.count == 4 else { return nil }
        r = v[0]; g = v[1]; b = v[2]; a = v[3]
    }

    var array: [Double] { [r, g, b, a] }
    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
}

enum FontWeightChoice: Int, CaseIterable, Identifiable {
    case light, regular, medium, semibold, bold, heavy, black
    var id: Int { rawValue }

    var label: String {
        ["Light", "Regular", "Medium", "Semibold", "Bold", "Heavy", "Black"][rawValue]
    }

    var swiftUI: Font.Weight {
        [.light, .regular, .medium, .semibold, .bold, .heavy, .black][rawValue]
    }

    /// NSFontManager weight scale (0–15, 5 = regular, 9 = bold).
    var appKit: Int { [3, 5, 6, 8, 9, 11, 12][rawValue] }
}

@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()

    static let systemFamily = "System (SF Pro)"
    static let roundedFamily = "System Rounded"
    static let monoFamily = "System Mono"

    private let d = UserDefaults.standard

    // Appearance
    @Published var fontFamily: String { didSet { d.set(fontFamily, forKey: "fontFamily") } }
    @Published var clockWeight: FontWeightChoice { didSet { d.set(clockWeight.rawValue, forKey: "clockWeight") } }
    @Published var textWeight: FontWeightChoice { didSet { d.set(textWeight.rawValue, forKey: "textWeight") } }
    @Published var scale: Double { didSet { d.set(scale, forKey: "scale") } }
    @Published var textColor: RGBA { didSet { d.set(textColor.array, forKey: "textColor") } }
    @Published var backgroundColor: RGBA { didSet { d.set(backgroundColor.array, forKey: "backgroundColor") } }
    @Published var backgroundOpacity: Double { didSet { d.set(backgroundOpacity, forKey: "backgroundOpacity") } }
    @Published var displayOpacity: Double { didSet { d.set(displayOpacity, forKey: "displayOpacity") } }
    @Published var shadowStrength: Double { didSet { d.set(shadowStrength, forKey: "shadowStrength") } }
    @Published var frostedGlass: Bool { didSet { d.set(frostedGlass, forKey: "frostedGlass") } }
    @Published var keepIconsClear: Bool { didSet { d.set(keepIconsClear, forKey: "keepIconsClear") } }

    // Clock
    @Published var use24Hour: Bool { didSet { d.set(use24Hour, forKey: "use24Hour") } }
    @Published var showSeconds: Bool { didSet { d.set(showSeconds, forKey: "showSeconds") } }
    @Published var showDate: Bool { didSet { d.set(showDate, forKey: "showDate") } }
    @Published var showZulu: Bool { didSet { d.set(showZulu, forKey: "showZulu") } }

    // Weather
    @Published var latitude: Double { didSet { d.set(latitude, forKey: "latitude") } }
    @Published var longitude: Double { didSet { d.set(longitude, forKey: "longitude") } }
    @Published var placeName: String { didSet { d.set(placeName, forKey: "placeName") } }
    @Published var imperial: Bool { didSet { d.set(imperial, forKey: "imperial") } }

    // Calendar
    @Published var excludedCalendars: [String] { didSet { d.set(excludedCalendars, forKey: "excludedCalendars") } }
    @Published var hideFinishedEvents: Bool { didSet { d.set(hideFinishedEvents, forKey: "hideFinishedEvents") } }
    @Published var maxEvents: Int { didSet { d.set(maxEvents, forKey: "maxEvents") } }

    var hasLocation: Bool { !(latitude == 0 && longitude == 0) }

    private init() {
        let d = UserDefaults.standard
        func dbl(_ k: String, _ def: Double) -> Double { d.object(forKey: k) == nil ? def : d.double(forKey: k) }
        func bool(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) == nil ? def : d.bool(forKey: k) }
        func str(_ k: String, _ def: String) -> String { d.string(forKey: k) ?? def }
        func int(_ k: String, _ def: Int) -> Int { d.object(forKey: k) == nil ? def : d.integer(forKey: k) }

        fontFamily = str("fontFamily", Settings.systemFamily)
        clockWeight = FontWeightChoice(rawValue: int("clockWeight", FontWeightChoice.bold.rawValue)) ?? .bold
        textWeight = FontWeightChoice(rawValue: int("textWeight", FontWeightChoice.medium.rawValue)) ?? .medium
        scale = dbl("scale", 1.0)
        textColor = RGBA(array: d.array(forKey: "textColor") as? [Double]) ?? RGBA(r: 1, g: 1, b: 1)
        backgroundColor = RGBA(array: d.array(forKey: "backgroundColor") as? [Double]) ?? RGBA(r: 0.08, g: 0.09, b: 0.12)
        backgroundOpacity = dbl("backgroundOpacity", 0.45)
        displayOpacity = dbl("displayOpacity", 1.0)
        shadowStrength = dbl("shadowStrength", 0.7)
        frostedGlass = bool("frostedGlass", true)
        keepIconsClear = bool("keepIconsClear", true)

        use24Hour = bool("use24Hour", false)
        showSeconds = bool("showSeconds", true)
        showDate = bool("showDate", true)
        showZulu = bool("showZulu", true)

        // Windy support was removed; drop its saved key and choices.
        for k in ["weatherProvider", "windyKey", "windyModel"] { d.removeObject(forKey: k) }
        latitude = dbl("latitude", 0)
        longitude = dbl("longitude", 0)
        placeName = str("placeName", "")
        imperial = bool("imperial", true)

        excludedCalendars = (d.array(forKey: "excludedCalendars") as? [String]) ?? []
        hideFinishedEvents = bool("hideFinishedEvents", false)
        maxEvents = int("maxEvents", 8)
    }

    /// Every font family on the system, with the three system faces first.
    static let fontFamilies: [String] = {
        let installed = NSFontManager.shared.availableFontFamilies
            .filter { !$0.hasPrefix(".") }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return [systemFamily, roundedFamily, monoFamily] + installed
    }()

    func font(_ size: CGFloat, _ weight: FontWeightChoice) -> Font {
        switch fontFamily {
        case Settings.systemFamily:
            return .system(size: size, weight: weight.swiftUI)
        case Settings.roundedFamily:
            return .system(size: size, weight: weight.swiftUI, design: .rounded)
        case Settings.monoFamily:
            return .system(size: size, weight: weight.swiftUI, design: .monospaced)
        default:
            if let f = NSFontManager.shared.font(withFamily: fontFamily, traits: [], weight: weight.appKit, size: size) {
                return Font(f as CTFont)
            }
            return .custom(fontFamily, size: size).weight(weight.swiftUI)
        }
    }

    // Unit formatting (data is kept in °C, mm and m/s).
    func temp(_ c: Double) -> String {
        let v = imperial ? c * 9 / 5 + 32 : c
        return "\(Int(v.rounded()))°"
    }

    func precip(_ mm: Double) -> String {
        if imperial {
            let inch = mm / 25.4
            return inch < 0.01 ? "0\"" : String(format: "%.2f\"", inch)
        }
        return mm < 0.1 ? "0 mm" : String(format: mm < 10 ? "%.1f mm" : "%.0f mm", mm)
    }

    func wind(_ ms: Double) -> String {
        imperial ? "\(Int((ms * 2.23694).rounded())) mph" : "\(Int((ms * 3.6).rounded())) km/h"
    }
}

/// Things that are not settings: whether the widget is being configured.
@MainActor
final class AppState: ObservableObject {
    @Published var configuring = false
}
