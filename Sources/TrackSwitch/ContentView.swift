import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var controller: PlaybackController

    @State private var importingTrack = false
    @State private var pendingImportSide: TrackSide?
    @State private var sliderPosition = 0.0
    @State private var keyMonitor: KeyMonitor?
    @State private var dropTargetSide: TrackSide?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            headerSection
            transportSection
            controlsSection
            if let warning = controller.overlapWarning {
                Text(warning)
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            if let error = controller.playbackError {
                Text(error.localizedDescription)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            Spacer()
        }
        .padding(20)
        .frame(minWidth: 760, minHeight: 520)
        .fileImporter(isPresented: $importingTrack, allowedContentTypes: [.audio]) { result in
            handleImport(result)
        }
        .onAppear {
            sliderPosition = controller.session.transportPosition
            setupKeyMonitor()
        }
        .onDisappear {
            keyMonitor?.stop()
        }
        .onChange(of: controller.session.transportPosition) { _, newValue in
            sliderPosition = newValue
        }
    }

    private var headerSection: some View {
        HStack(alignment: .top, spacing: 16) {
            trackHeader(side: .a, track: controller.session.trackA) {
                pendingImportSide = .a
                importingTrack = true
            }
            trackHeader(side: .b, track: controller.session.trackB) {
                pendingImportSide = .b
                importingTrack = true
            }
        }
    }

    private func trackHeader(side: TrackSide, track: LoadedTrack?, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(side.title)
                    .font(.headline)
                if controller.session.activeTrack == side {
                    Text("Active")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.blue.opacity(0.15), in: Capsule())
                }
            }
            if let track {
                Text(track.displayName)
                    .font(.title3.weight(.medium))
                    .lineLimit(1)
                Text(track.metadataSummary)
                    .foregroundStyle(.secondary)
            } else {
                Text("No file loaded")
                    .foregroundStyle(.secondary)
            }
            Button("Load \(side.title)", action: action)
            Button("Load Selected from Music") {
                Task {
                    await controller.loadSelectedLibraryTrack(side)
                }
            }
            Text("Drop audio file here")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(backgroundStyle(for: side), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: dropBinding(for: side)) { providers in
            handleDrop(providers: providers, side: side)
        }
    }

    private var transportSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button(controller.session.isPlaying ? "Pause" : "Play") {
                    controller.session.isPlaying ? controller.pause() : controller.play()
                }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(!controller.session.isPlayable)

                Button("Stop") {
                    controller.stop()
                }
                .disabled(!controller.session.isPlayable)

                Button("Toggle A/B") {
                    controller.toggleActiveTrack()
                }
                .keyboardShortcut(.tab, modifiers: [])
                .disabled(!controller.session.canToggleComparison)

                Spacer()

                Text("\(controller.session.transportPosition.formattedTimestamp) / \(controller.session.duration.formattedTimestamp)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Slider(
                value: Binding(
                    get: { sliderPosition },
                    set: { sliderPosition = $0 }
                ),
                in: 0...max(controller.session.duration, 0.001),
                onEditingChanged: { editing in
                    if !editing {
                        controller.seek(to: sliderPosition)
                    }
                }
            )
            .disabled(!controller.session.isPlayable)

            Text("Keyboard: Space play/pause, Tab toggle, Left/Right seek 1s, Shift+Left/Right seek 5s")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var controlsSection: some View {
        HStack(alignment: .top, spacing: 16) {
            gainCard(side: .a, track: controller.session.trackA, showOffset: false)
            gainCard(side: .b, track: controller.session.trackB, showOffset: true)
        }
    }

    private func gainCard(side: TrackSide, track: LoadedTrack?, showOffset: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(side.title)
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("Gain \(Int(track?.gainDB ?? 0)) dB")
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { Double(track?.gainDB ?? 0) },
                        set: { controller.setGain(side, db: Float($0)) }
                    ),
                    in: -24...24,
                    step: 0.5
                )
                .disabled(track == nil)
            }

            if showOffset {
                VStack(alignment: .leading, spacing: 6) {
                    let offsetMs = Int(((track?.offsetSeconds ?? 0) * 1000).rounded())
                    Text("Offset \(offsetMs) ms")
                        .foregroundStyle(.secondary)
                    Slider(
                        value: Binding(
                            get: { (track?.offsetSeconds ?? 0) * 1000 },
                            set: { controller.setOffset(side, seconds: $0 / 1000) }
                        ),
                        in: -5000...5000,
                        step: 1
                    )
                    .disabled(track == nil)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func handleImport(_ result: Result<URL, Error>) {
        let side = pendingImportSide
        importingTrack = false
        pendingImportSide = nil

        switch result {
        case let .success(url):
            guard let side else { return }
            Task {
                await controller.loadTrack(side, from: url)
            }
        case .failure:
            break
        }
    }

    private func backgroundStyle(for side: TrackSide) -> some ShapeStyle {
        if dropTargetSide == side {
            return AnyShapeStyle(.blue.opacity(0.16))
        }
        return AnyShapeStyle(.quaternary.opacity(0.4))
    }

    private func dropBinding(for side: TrackSide) -> Binding<Bool> {
        Binding(
            get: { dropTargetSide == side },
            set: { isTargeted in
                dropTargetSide = isTargeted ? side : nil
            }
        )
    }

    private func handleDrop(providers: [NSItemProvider], side: TrackSide) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            return false
        }

        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            guard let url = extractDroppedFileURL(from: item) else { return }
            Task { @MainActor in
                await controller.loadTrack(side, from: url)
            }
        }

        return true
    }

    private func setupKeyMonitor() {
        let monitor = KeyMonitor { event in
            switch event.keyCode {
            case 123:
                controller.skip(by: event.modifierFlags.contains(.shift) ? -5 : -1)
                return true
            case 124:
                controller.skip(by: event.modifierFlags.contains(.shift) ? 5 : 1)
                return true
            default:
                return false
            }
        }
        monitor.start()
        keyMonitor = monitor
    }
}

private func extractDroppedFileURL(from item: NSSecureCoding?) -> URL? {
    if let data = item as? Data {
        return URL(dataRepresentation: data, relativeTo: nil)
    }

    if let url = item as? URL {
        return url
    }

    if let text = item as? String {
        return URL(string: text)
    }

    return nil
}
