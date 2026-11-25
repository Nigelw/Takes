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

            MetadataSettingsView()
                .tabItem {
                    Label("Metadata", systemImage: "tag")
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
            } header: {
                Text("Appearance")
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Group similar tracks", isOn: Binding(
                        get: { settings.automaticGroupingMode == .automatic },
                        set: { settings.automaticGroupingMode = $0 ? .automatic : .off }
                    ))
                    .toggleStyle(.switch)
                    SettingsHint(settings.automaticGroupingMode.explanation)
                }
            } header: {
                Text("Opening Files")
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Auto-align tracks on open", isOn: $settings.alignTracksOnOpen)
                    SettingsHint("Align audio files when opening in Takes")
                }

                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent("Nudge") {
                        OffsetAmountField(value: $settings.offsetStep, stepperIncrement: 10)
                    }
                    SettingsHint("Use ↑ and ↓ in the offset input field for small adjustments")
                }

                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent("Large nudge") {
                        OffsetAmountField(value: $settings.offsetLargeStep, stepperIncrement: 50)
                    }
                    SettingsHint("Use ⇧↑ and ⇧↓ in the offset input field for larger adjustments")
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

private struct MetadataSettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section {
                MetadataFieldToggles(fields: TrackMetadataField.allCases, enabledFields: $settings.playlistMetadataFields)
            } header: {
                Text("Playlist Metadata")
            }

            Section {
                MetadataFieldToggles(fields: TrackMetadataField.compareFields, enabledFields: $settings.compareMetadataFields)
            } header: {
                Text("Comparison Metadata")
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct MetadataFieldToggles: View {
    let fields: [TrackMetadataField]
    @Binding var enabledFields: Set<TrackMetadataField>

    var body: some View {
        ForEach(fields) { field in
            Toggle(field.title, isOn: Binding(
                get: { enabledFields.contains(field) },
                set: { isEnabled in
                    if isEnabled {
                        enabledFields.insert(field)
                    } else {
                        enabledFields.remove(field)
                    }
                }
            ))
        }
    }
}

private struct SettingsHint: View {
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

                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Update to beta builds", isOn: $updater.includesBetaBuilds)
                    SettingsHint("Beta builds have more bugs")
                }

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
