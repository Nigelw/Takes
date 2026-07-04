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
                    Label("Updates", systemImage: "arrow.triangle.2.circlepath")
                }
        }
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct GeneralSettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Picker("Theme", selection: $settings.appearanceTheme) {
                    Text(AppearanceTheme.system.title).tag(AppearanceTheme.system)
                    Divider()
                    Text(AppearanceTheme.light.title).tag(AppearanceTheme.light)
                    Text(AppearanceTheme.dark.title).tag(AppearanceTheme.dark)
                }

                Picker("Readout frame", selection: $settings.readoutStyle) {
                    ForEach(ReadoutStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
            } header: {
                Text("Appearance")
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Auto-align tracks on open", isOn: $settings.alignTracksOnOpen)
                    OffsetHint("Align audio files when opening in Takes")
                }

                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent("Nudge") {
                        OffsetAmountField(value: $settings.offsetStep, stepperIncrement: 10)
                    }
                    OffsetHint("Offset adjustment when using the stepper buttons or the up/down arrow keys.")
                }

                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent("Large nudge") {
                        OffsetAmountField(value: $settings.offsetLargeStep, stepperIncrement: 50)
                    }
                    OffsetHint("Hold Shift while using steppers or arrow keys to adjust by a larger amount.")
                }
            } header: {
                Text("Track Alignment")
            }

            Section {
                HStack {
                    Spacer()
                    Button("Restore Defaults") {
                        settings.restoreDefaults()
                    }
                    .disabled(settings.settingsAreDefault)
                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
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
    @EnvironmentObject private var ytdlpUpdates: YTDLPUpdateState

    var body: some View {
        Form {
            Section {
                Toggle("Automatically check for updates", isOn: $updater.automaticallyChecksForUpdates)

                Toggle("Automatically install updates", isOn: $updater.automaticallyDownloadsUpdates)
                    .disabled(!updater.automaticallyChecksForUpdates || !updater.allowsAutomaticUpdates)

                Picker("Check for updates", selection: $updater.checkFrequency) {
                    ForEach(UpdateCheckFrequency.allCases) { frequency in
                        Text(frequency.title).tag(frequency)
                    }
                }
                .disabled(!updater.automaticallyChecksForUpdates)
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
            } header: {
                Text("App Updates")
            }

            Section {
                LabeledContent("Check for updates") {
                    Text(ytdlpUpdates.cadenceDescription)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text(ytdlpUpdates.lastCheckedDescription)
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    Spacer()

                    HStack(spacing: 8) {
                        if ytdlpUpdates.isUpdating {
                            ProgressView()
                                .controlSize(.small)
                        }

                        Button("Check Now") {
                            ytdlpUpdates.updateNow()
                        }
                        .disabled(ytdlpUpdates.isUpdating)
                    }
                }
            } header: {
                Text("YouTube Downloader (yt-dlp)")
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            updater.refreshLastCheckDate()
            ytdlpUpdates.refresh()
        }
        .alert(item: $ytdlpUpdates.updateAlert) { updateAlert in
            Alert(
                title: Text(updateAlert.title),
                message: Text(updateAlert.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private var lastCheckedDescription: String {
        guard let date = updater.lastUpdateCheckDate else {
            return "Not checked yet"
        }
        return "Last checked \(date.formatted(date: .abbreviated, time: .shortened))"
    }
}
