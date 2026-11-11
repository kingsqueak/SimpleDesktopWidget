import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var s: Settings
    @EnvironmentObject var weather: WeatherModel
    @EnvironmentObject var cal: CalendarModel
    @EnvironmentObject var backdrop: WallpaperBackdrop
    @EnvironmentObject var icons: IconMover
    @EnvironmentObject var alerts: AlertsModel
    @EnvironmentObject var lightning: LightningMonitor
    @StateObject private var finder = LocationFinder()
    @State private var placeQuery = ""
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    var onDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Form {
                appearance
                clock
                weatherSection
                calendarSection
                general
            }
            .formStyle(.grouped)

            HStack {
                Text("Drag the widget to place it. Done locks it in place and clears icons from under it.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { onDone() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 500, height: 720)
    }

    /// Lightning radius in the user's units (stored in km).
    private var radiusBinding: Binding<Double> {
        Binding(get: {
                    let v = s.imperial ? s.lightningRadiusKm / 1.609344 : s.lightningRadiusKm
                    return (v / 5).rounded() * 5
                },
                set: { s.lightningRadiusKm = s.imperial ? $0 * 1.609344 : $0 })
    }

    private func color(_ kp: ReferenceWritableKeyPath<Settings, RGBA>) -> Binding<Color> {
        Binding(get: { s[keyPath: kp].color }, set: { s[keyPath: kp] = RGBA($0) })
    }

    private var appearance: some View {
        Section("Appearance") {
            Picker("Font", selection: $s.fontFamily) {
                ForEach(Settings.fontFamilies, id: \.self) { fam in
                    Text(fam).tag(fam)
                }
            }
            Picker("Clock weight", selection: $s.clockWeight) {
                ForEach(FontWeightChoice.allCases) { Text($0.label).tag($0) }
            }
            Picker("Text weight", selection: $s.textWeight) {
                ForEach(FontWeightChoice.allCases) { Text($0.label).tag($0) }
            }
            ColorPicker("Text colour", selection: color(\.textColor), supportsOpacity: false)
            ColorPicker("Background colour", selection: color(\.backgroundColor), supportsOpacity: false)
            Toggle("Frosted glass (covers desktop icons behind the widget)", isOn: $s.frostedGlass)
                .onChange(of: s.frostedGlass) { _, on in
                    if on { backdrop.requestPermission() } else { backdrop.recapture() }
                }
            if s.frostedGlass && backdrop.permissionMissing {
                Text("Frosted glass needs Screen Recording permission (only the wallpaper layer is captured). Turn on SimpleDesktopWidget in System Settings → Privacy & Security → Screen & System Audio Recording, then quit and reopen the widget.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Open Privacy Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                }
            }
            Toggle("Move desktop icons out of the widget's way", isOn: $s.keepIconsClear)
                .onChange(of: s.keepIconsClear) { _, on in if on { icons.schedule(after: 0.2) } }
            if s.keepIconsClear, let e = icons.lastError {
                Text(e).font(.caption).foregroundStyle(.red)
            }
            slider(s.frostedGlass ? "Background tint" : "Background opacity", $s.backgroundOpacity, 0...1, percent: true)
            slider("Whole display opacity", $s.displayOpacity, 0.15...1, percent: true)
            slider("Drop shadow", $s.shadowStrength, 0...1, percent: true)
            slider("Size", $s.scale, 0.6...1.8, percent: true)
        }
    }

    private var clock: some View {
        Section("Clock") {
            Toggle("24-hour time", isOn: $s.use24Hour)
            Toggle("Show seconds", isOn: $s.showSeconds)
            Toggle("Show date", isOn: $s.showDate)
            Toggle("Show Zulu (UTC) time, 24-hour", isOn: $s.showZulu)
        }
    }

    private var weatherSection: some View {
        Section {
            Picker("Units", selection: $s.imperial) {
                Text("°F, inches, mph").tag(true)
                Text("°C, mm, km/h").tag(false)
            }
            Text("Forecast from Open-Meteo (free, no key), refreshed every 30 minutes.")
                .font(.caption).foregroundStyle(.secondary)

            Toggle("Show National Weather Service alerts", isOn: $s.showAlerts)
                .onChange(of: s.showAlerts) { alerts.refresh() }
            if s.showAlerts {
                Text(alerts.message ?? "Warnings, watches and advisories for your location (US only), checked every 5 minutes. \(alerts.alerts.isEmpty ? "None active right now." : "\(alerts.alerts.count) active.")")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Toggle("Show nearby lightning", isOn: $s.showLightning)
                .onChange(of: s.showLightning) { lightning.apply() }
            if s.showLightning {
                Stepper(value: radiusBinding, in: 5...150, step: 5) {
                    Text("Within \(Int(radiusBinding.wrappedValue)) \(s.imperial ? "miles" : "km")")
                }
                .onChange(of: s.lightningRadiusKm) { lightning.apply() }
                Text("Live strikes from the Blitzortung.org volunteer network (\(lightning.status.lowercased())). Shown only when there have been strikes within the radius in the last 30 minutes. Free for personal use, not guaranteed: not for safety decisions.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            LabeledContent("Location") {
                Text(s.hasLocation ? "\(s.placeName)  (\(String(format: "%.3f, %.3f", s.latitude, s.longitude)))" : "Not set")
                    .foregroundStyle(.secondary)
            }
            HStack {
                TextField("Find a town", text: $placeQuery, prompt: Text("Town, state or postcode"))
                    .onSubmit { finder.search(placeQuery) }
                Button("Find") { finder.search(placeQuery) }
            }
            HStack {
                Button {
                    finder.useCurrentLocation()
                } label: {
                    Label("Use my current location", systemImage: "location")
                }
                if finder.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Refresh forecast") { weather.refresh() }
            }
            if let m = finder.message {
                Text(m).font(.caption).foregroundStyle(.red)
            }
            if let m = weather.message {
                Text(m).font(.caption).foregroundStyle(.secondary)
            } else if let u = weather.updated {
                Text("Updated \(u.formatted(date: .omitted, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Weather")
        }
        .onReceive(NotificationCenter.default.publisher(for: .widgetLocationChanged)) { _ in
            weather.refresh()
        }
    }

    private var calendarSection: some View {
        Section("Calendar") {
            switch cal.access {
            case .unknown:
                Button("Allow calendar access") { cal.requestAccess() }
            case .denied:
                Text("Calendar access is off. Turn it on in System Settings → Privacy & Security → Calendars.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Open Privacy Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                }
            case .granted:
                ForEach(cal.calendars) { c in
                    Toggle(isOn: Binding(
                        get: { !s.excludedCalendars.contains(c.id) },
                        set: { on in
                            if on { s.excludedCalendars.removeAll { $0 == c.id } }
                            else { s.excludedCalendars.append(c.id) }
                            cal.reload()
                        })) {
                        HStack {
                            Circle().fill(c.color).frame(width: 9, height: 9)
                            Text(c.title)
                            Text(c.source).foregroundStyle(.secondary).font(.caption)
                        }
                    }
                }
            }
            Toggle("Hide events that have finished", isOn: $s.hideFinishedEvents)
                .onChange(of: s.hideFinishedEvents) { cal.reload() }
            Stepper("Show up to \(s.maxEvents) events", value: $s.maxEvents, in: 1...20)
        }
    }

    private var general: some View {
        Section("General") {
            Toggle("Start at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, on in
                    do {
                        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        loginError = nil
                    } catch {
                        loginError = error.localizedDescription
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            if let e = loginError {
                Text(e).font(.caption).foregroundStyle(.red)
            }
            Button("Quit SimpleDesktopWidget") { NSApp.terminate(nil) }
        }
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, percent: Bool) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: range)
                Text("\(Int((value.wrappedValue * 100).rounded()))%")
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
