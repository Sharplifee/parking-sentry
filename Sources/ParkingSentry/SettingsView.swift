import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var engine: DetectionEngine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Units") {
                    Picker("Show distances in", selection: $settings.useMetric) {
                        Text("Feet / mph").tag(false)
                        Text("Metres / km-h").tag(true)
                    }
                    .pickerStyle(.segmented)
                }

                Section("Camera") {
                    Toggle("Night view (depth)", isOn: $settings.nightView)
                    Text(engine.depthAvailable
                         ? "Renders what the depth sensor sees instead of the colour image. It works in total darkness because the sensor lights the scene with its own infrared, and unlike the camera it is not fooled by shadows. Range is about 15 ft — it is for a doorway, not a parking lot."
                         : "This device has no depth sensor, so night view is unavailable here. iOS gives apps no access to a raw infrared image on any device.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Front camera", isOn: $settings.useFrontCamera)
                    Toggle("Long range (4K capture)", isOn: $settings.longRangeMode)
                    slider("Zoom", value: $settings.zoomFactor, range: 1...5, step: 0.25,
                           format: { String(format: "%.2fx", $0) })
                    Text("Zoom past the lens's optical factor is digital and will shorten reliable detection range.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Detection") {
                    slider("Person confidence", value: $settings.personConfidence, range: 0.3...0.9, step: 0.05,
                           format: { String(format: "%.2f", $0) })
                    slider("Motion sensitivity", value: $settings.motionSensitivity, range: 0.001...0.05, step: 0.001,
                           format: { String(format: "%.3f", $0) })
                    Stepper("Confirm over \(settings.confirmHits) frames", value: $settings.confirmHits, in: 1...10)
                    Toggle("Only alert when closing in", isOn: $settings.requireApproach)
                    Toggle("Wake on sudden sound", isOn: $settings.soundTrigger)
                }

                Section("Alert me about") {
                    ForEach(SubjectCategory.allCases, id: \.rawValue) { cat in
                        Toggle(cat.display, isOn: Binding(
                            get: { settings.alertCategories.contains(cat) },
                            set: { on in
                                if on { settings.alertCategories.insert(cat) }
                                else { settings.alertCategories.remove(cat) }
                            }))
                    }
                    Text("People, vehicles and animals are named by an on-device classifier. \"Unidentified movement\" catches anything coherent it cannot name — useful, but the noisiest setting here.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Range") {
                    // Step in whole feet when showing feet, whole metres when
                    // showing metres — otherwise dragging lands on 23 ft, 26 ft
                    // and never on a round number anyone would choose.
                    slider("Alert within", value: $settings.alertDistanceMeters,
                           range: 0...80,
                           step: settings.useMetric ? 1 : 0.3048,
                           format: { $0 == 0 ? "any distance" : Units.distance($0) })
                    slider("Assumed person height", value: $settings.subjectHeightMeters,
                           range: 1.4...2.0,
                           step: settings.useMetric ? 0.01 : 0.0254,   // 1 inch
                           format: { Units.height($0) })
                    Text("Vehicles are ranged from width rather than height, using standard widths per class. Anything with no known real-world size reports range unknown instead of a guess.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(engine.depthAvailable
                         ? "LiDAR gives true range under about 16 ft; beyond that the app falls back to an optical estimate from apparent height."
                         : "No depth sensor on this camera, so range comes from apparent height and the lens's own focal length. Typical error is 10 to 15 percent for a fully visible standing person.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Alerts") {
                    Toggle("Local notification", isOn: $settings.notificationsEnabled)
                    Toggle("Siren on the device", isOn: $settings.sirenEnabled)
                    TextField("Webhook URL (e.g. https://ntfy.sh/your-topic)", text: $settings.webhookURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    slider("Per-subject cooldown", value: $settings.cooldownSeconds, range: 5...120, step: 5,
                           format: { String(format: "%.0f s", $0) })
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Arming delay")
                            Spacer()
                            Text(settings.armDelaySeconds == 0
                                 ? "immediate"
                                 : String(format: "%.0f s", settings.armDelaySeconds))
                                .foregroundStyle(.secondary).monospacedDigit()
                        }
                        Picker("", selection: $settings.armDelaySeconds) {
                            Text("Now").tag(0.0)
                            Text("3s").tag(3.0)
                            Text("5s").tag(5.0)
                            Text("10s").tag(10.0)
                            Text("30s").tag(30.0)
                            Text("60s").tag(60.0)
                        }
                        .pickerStyle(.segmented)
                    }
                    Text("The webhook is a plain POST with the message as the body, so an ntfy.sh topic will buzz your phone while the iPad sits in the lot.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    Button("Apply camera changes and re-arm") {
                        engine.restartForSettingsChange()
                        dismiss()
                    }
                    Button("Test alert") {
                        AlertManager.shared.fire(title: "Test alert",
                                                 body: "Parking Sentry alert path is working.",
                                                 snapshot: nil,
                                                 settings: settings)
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }

    private func slider(_ label: String,
                        value: Binding<Double>,
                        range: ClosedRange<Double>,
                        step: Double,
                        format: @escaping (Double) -> String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                Spacer()
                Text(format(value.wrappedValue)).foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: value, in: range, step: step)
        }
    }
}
