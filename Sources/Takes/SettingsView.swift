import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var updater: SoftwareUpdater

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }

            UpdateSettingsView()
                .tabItem {
                    Label("Update", systemImage: "arrow.triangle.2.circlepath")
                }
        }
        .frame(width: 460)
    }
}

private struct GeneralSettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent("Nudge") {
                        OffsetAmountField(value: $settings.offsetStep, stepperIncrement: 10)
                    }
                    OffsetHint("Offset adjustment when using the stepper buttons or the up/down arrow keys.")
                }

                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent("Large Nudge") {
                        OffsetAmountField(value: $settings.offsetLargeStep, stepperIncrement: 50)
                    }
                    OffsetHint("Hold Shift while using steppers or arrow keys to adjust by a larger amount.")
                }
            } header: {
                Text("Track Offset")
            }

            Section {
                HStack {
                    Spacer()
                    Button("Restore Defaults") {
                        settings.restoreOffsetDefaults()
                    }
                    .disabled(settings.offsetAmountsAreDefault)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct OffsetHint: View {
    private let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .multilineTextAlignment(.leading)
    }
}

private struct OffsetAmountField: View {
    @Binding var value: Int
    let stepperIncrement: Int

    var body: some View {
        HStack(spacing: 6) {
            TextField("", value: $value, format: .number)
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: 64)
            Text("ms")
                .foregroundStyle(.secondary)
            Stepper("", value: $value, in: AppSettings.offsetStepRange, step: stepperIncrement)
                .labelsHidden()
        }
    }
}

private struct UpdateSettingsView: View {
    @EnvironmentObject private var updater: SoftwareUpdater

    var body: some View {
        Form {
            Section {
                Toggle("Automatically check for updates", isOn: $updater.automaticallyChecksForUpdates)

                Picker("Check for updates", selection: $updater.checkFrequency) {
                    ForEach(UpdateCheckFrequency.allCases) { frequency in
                        Text(frequency.title).tag(frequency)
                    }
                }
                .disabled(!updater.automaticallyChecksForUpdates)
            } header: {
                Text("Software Updates")
            }

            Section {
                HStack {
                    Text(lastCheckedDescription)
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button("Check Now") {
                        updater.checkForUpdates()
                    }
                    .disabled(!updater.canCheckForUpdates)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            updater.refreshLastCheckDate()
        }
    }

    private var lastCheckedDescription: String {
        guard let date = updater.lastUpdateCheckDate else {
            return "Not checked yet"
        }
        return "Last checked \(date.formatted(date: .abbreviated, time: .shortened))"
    }
}
