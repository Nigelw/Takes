import AppKit
import MediaPlayer
import SwiftUI
import UniformTypeIdentifiers

enum AppOpenedURLResolver {
    static func audioFileURLs(from urls: [URL], fileManager: FileManager = .default) -> [URL] {
        let inputURLs = urls.flatMap { url in
            automationFileURLs(from: url) ?? [url]
        }

        return inputURLs.flatMap { url in
            if isDirectory(url, fileManager: fileManager) {
                return audioFileURLs(in: url, fileManager: fileManager)
            }
            return isAudioFile(url) ? [url] : []
        }
    }

    private static func audioFileURLs(in directoryURL: URL, fileManager: FileManager) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else {
            return []
        }

        return enumerator
            .compactMap { $0 as? URL }
            .filter { isRegularFile($0, fileManager: fileManager) && isAudioFile($0) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    static func streamingURLStrings(from urls: [URL]) -> [String] {
        urls.compactMap(streamingURLString)
    }

    static func streamingURLString(from url: URL) -> String? {
        guard url.scheme?.lowercased() == "takes",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let command = automationCommand(from: components),
              command == "open-url",
              let value = components.queryItems?.first(where: { $0.name == "url" })?.value?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              URL(string: value)?.scheme != nil
        else {
            return nil
        }
        return value
    }

    static func automationFileURLs(from url: URL) -> [URL]? {
        guard url.scheme?.lowercased() == "takes",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let command = automationCommand(from: components),
              command == "open-file"
        else {
            return nil
        }

        let fileURLs = components.queryItems?
            .filter { $0.name == "url" }
            .compactMap(\.value)
            .compactMap { URL(string: $0) }
            .filter { $0.isFileURL } ?? []

        return fileURLs.isEmpty ? nil : fileURLs
    }

    private static func automationCommand(from components: URLComponents) -> String? {
        if let host = components.host?.lowercased(), !host.isEmpty {
            return host
        }

        return components.path
            .split(separator: "/")
            .first
            .map { String($0).lowercased() }
    }

    private static func isDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func isRegularFile(_ url: URL, fileManager: FileManager) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    private static func isAudioFile(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .audio)
    }
}

@MainActor
final class AppFileOpenRouter {
    typealias AudioFileHandler = @MainActor ([URL], PlaylistImportDestination) -> Void
    typealias StreamingURLHandler = @MainActor ([String]) -> Void

    private var audioFileHandler: AudioFileHandler?
    private var streamingURLHandler: StreamingURLHandler?
    private var pendingURLBatches: [(urls: [URL], destination: PlaylistImportDestination)] = []
    private var pendingStreamingURLBatches: [[String]] = []

    func setHandler(_ handler: @escaping AudioFileHandler) {
        audioFileHandler = handler

        let pendingURLBatches = self.pendingURLBatches
        self.pendingURLBatches.removeAll()
        for batch in pendingURLBatches {
            handler(batch.urls, batch.destination)
        }
    }

    func setStreamingURLHandler(_ handler: @escaping StreamingURLHandler) {
        streamingURLHandler = handler

        let pendingStreamingURLBatches = self.pendingStreamingURLBatches
        self.pendingStreamingURLBatches.removeAll()
        pendingStreamingURLBatches.forEach(handler)
    }

    func open(_ urls: [URL], modifierFlags: NSEvent.ModifierFlags = []) {
        let destination: PlaylistImportDestination = modifierFlags.contains(.shift) && urls.allSatisfy(\.isFileURL)
            ? .newComparison : .playlist
        let audioFileURLs = AppOpenedURLResolver.audioFileURLs(from: urls)
        if !audioFileURLs.isEmpty {
            if let audioFileHandler {
                audioFileHandler(audioFileURLs, destination)
            } else {
                pendingURLBatches.append((audioFileURLs, destination))
            }
        }

        let streamingURLStrings = AppOpenedURLResolver.streamingURLStrings(from: urls)
        guard !streamingURLStrings.isEmpty else { return }
        if let streamingURLHandler {
            streamingURLHandler(streamingURLStrings)
        } else {
            pendingStreamingURLBatches.append(streamingURLStrings)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let fileOpenRouter = AppFileOpenRouter()
    var flushWorkspaceBeforeTermination: (@MainActor () async -> Bool)?
    private var terminationInProgress = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let flushWorkspaceBeforeTermination else { return .terminateNow }
        guard !terminationInProgress else { return .terminateLater }
        terminationInProgress = true
        Task { @MainActor in
            let saved = await flushWorkspaceBeforeTermination()
            if !saved { terminationInProgress = false }
            sender.reply(toApplicationShouldTerminate: saved)
        }
        return .terminateLater
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        // Icon drops arrive as document opens. Read Shift before the request
        // can wait for workspace restoration or another import.
        fileOpenRouter.open(urls, modifierFlags: NSEvent.modifierFlags)
    }
}

enum TakesAboutPanel {
    static let creditsText = """
    Designed & developed by
    Nigel M. Warren: https://nigelwarren.com

    Third-Party Resources
    Sparkle: https://sparkle-project.org
    yt-dlp: https://github.com/yt-dlp/yt-dlp
    Tabler Icons: https://tabler.io/icons
    """

    private static let creditLinks: [(label: String, destination: String)] = [
        ("https://nigelwarren.com", "https://nigelwarren.com"),
        ("https://sparkle-project.org", "https://sparkle-project.org"),
        ("https://github.com/yt-dlp/yt-dlp", "https://github.com/yt-dlp/yt-dlp"),
        ("https://tabler.io/icons", "https://tabler.io/icons")
    ]

    static var options: [NSApplication.AboutPanelOptionKey: Any] {
        [.credits: credits]
    }

    static var credits: NSAttributedString {
        let credits = NSMutableAttributedString(string: creditsText)
        let fullRange = NSRange(location: 0, length: credits.length)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        paragraphStyle.paragraphSpacing = 6

        credits.addAttributes([
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraphStyle
        ], range: fullRange)

        for (label, destination) in creditLinks {
            guard let range = credits.string.range(of: label),
                  let url = URL(string: destination)
            else { continue }

            credits.addAttributes([
                .link: url,
                .foregroundColor: NSColor.linkColor
            ], range: NSRange(range, in: credits.string))
        }

        return credits
    }
}

@MainActor
final class RemotePlaybackCommandController: ObservableObject {
    private struct CommandTarget {
        let command: MPRemoteCommand
        let target: Any
    }
    private weak var coordinator: PlaylistCoordinator?
    private let commandCenter: MPRemoteCommandCenter
    private let nowPlayingInfoCenter: MPNowPlayingInfoCenter
    private var commandTargets: [CommandTarget] = []

    init(commandCenter: MPRemoteCommandCenter = .shared(), nowPlayingInfoCenter: MPNowPlayingInfoCenter = .default()) {
        self.commandCenter = commandCenter
        self.nowPlayingInfoCenter = nowPlayingInfoCenter
    }

    func connect(to coordinator: PlaylistCoordinator) {
        guard self.coordinator == nil else { return }
        self.coordinator = coordinator
        configureCommands()
        refreshRemoteState()
    }

    private func refreshRemoteState() {
        guard let coordinator else { return }
        let state = withObservationTracking {
            var snapshot = coordinator.controller.remotePlaybackSnapshot()
            let item = coordinator.workspace.items.first { $0.id == coordinator.currentItemID }
            let version = item?.versions.first { $0.id == coordinator.currentVersionID }
            if coordinator.mode == .playlist {
                snapshot.title = item?.title ?? "Takes"
                snapshot.trackCount = coordinator.workspace.items.count
                snapshot.trackNumber = coordinator.workspace.items.firstIndex { $0.id == coordinator.currentItemID }.map { $0 + 1 }
            }
            return (snapshot, coordinator.canNext, coordinator.canPrevious,
                    coordinator.mode == .playlist ? version?.metadata.artist : nil,
                    coordinator.mode == .playlist ? version?.metadata.album : nil)
        } onChange: { [weak self] in
            Task { @MainActor in self?.refreshRemoteState() }
        }
        let snapshot = state.0
        commandCenter.playCommand.isEnabled = coordinator.canPlay && !snapshot.isPlaying
        commandCenter.pauseCommand.isEnabled = snapshot.isPlayable && snapshot.isPlaying
        commandCenter.togglePlayPauseCommand.isEnabled = coordinator.canPlay
        commandCenter.nextTrackCommand.isEnabled = state.1
        commandCenter.previousTrackCommand.isEnabled = state.2
        commandCenter.changePlaybackPositionCommand.isEnabled = snapshot.isPlayable
        guard snapshot.isPlayable else {
            nowPlayingInfoCenter.nowPlayingInfo = nil
            nowPlayingInfoCenter.playbackState = .stopped
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: snapshot.title,
            MPMediaItemPropertyPlaybackDuration: snapshot.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: snapshot.elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: snapshot.isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue
        ]
        if let number = snapshot.trackNumber {
            info[MPMediaItemPropertyAlbumTrackNumber] = number
            info[MPMediaItemPropertyAlbumTrackCount] = snapshot.trackCount
        }
        if let artist = state.3 { info[MPMediaItemPropertyArtist] = artist }
        if let album = state.4 { info[MPMediaItemPropertyAlbumTitle] = album }
        nowPlayingInfoCenter.nowPlayingInfo = info
        nowPlayingInfoCenter.playbackState = snapshot.isPlaying ? .playing : .paused
    }

    private func configureCommands() {
        addHandler(to: commandCenter.playCommand) { [weak self] in self?.coordinator?.play() }
        addHandler(to: commandCenter.pauseCommand) { [weak self] in self?.coordinator?.pause() }
        addHandler(to: commandCenter.togglePlayPauseCommand) { [weak self] in self?.coordinator?.togglePlayback() }
        addHandler(to: commandCenter.nextTrackCommand) { [weak self] in self?.coordinator?.next() }
        addHandler(to: commandCenter.previousTrackCommand) { [weak self] in self?.coordinator?.previous() }
        let target = commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            Task { @MainActor in
                guard let coordinator = self?.coordinator else { return }
                coordinator.seek(to: coordinator.controller.session.playbackStart + position)
            }
            return .success
        }
        commandTargets.append(CommandTarget(command: commandCenter.changePlaybackPositionCommand, target: target))
    }

    private func addHandler(to command: MPRemoteCommand, perform action: @escaping @MainActor () -> Void) {
        let target = command.addTarget { _ in
            Task { @MainActor in action() }
            return .success
        }
        commandTargets.append(CommandTarget(command: command, target: target))
    }
}

/// Main-window geometry for the A2 cover-column layout
/// (docs/a2-redesign-spec.md §2).
///
/// One window serves playlist and comparison. It opens 360 pt wide in both
/// modes, which share the same width. The artwork toggle, mode switches and
/// track fitting keep the top edge in place when the window changes height.
enum TakesWindowPolicy {
    static let mainWindowID = "main"
    static let analysisWindowID = "analysis"
    static let comparisonWindowID = "comparison"
    static let replacesDefaultNewItemCommands = true
    /// The frame is saved under an A2-specific name so a pre-A2 frame (640 pt
    /// or wider, sized per mode) is not restored into the cover-column layout.
    static let mainWindowFrameAutosaveName = "main.a2"
    static let mainWindowFrameDefaultsKey = "NSWindow Frame \(mainWindowFrameAutosaveName)"
    /// Pre-A2 keys for the playlist frame, the comparison's per-window
    /// autosave, and the comparison's track-info column width (removed with
    /// the column in A2 milestone 4). No longer read; removed on launch.
    static let retiredLayoutDefaultsKeys = ["playlistWindowFrame", "NSWindow Frame main", "trackInfoColumnWidth",
                                            retiredCompareHeightDefaultsKey]

    // MARK: Window size

    static let defaultWidth: CGFloat = 360
    static let minimumWidth = ControlBarMetrics.minimumWidth
    static let artworkResizeDuration: TimeInterval = 0.24
    /// Control-bar top padding under the cover.
    static let controlBarTopPaddingBelowArtwork: CGFloat = 12
    /// Control-bar top padding when the titlebar overlays the bar, so the
    /// transport buttons clear the window buttons and the artwork toggle.
    static let controlBarTopPaddingUnderTitlebar: CGFloat = 24
    /// The cover is square when there is room. At wide, short frames it fits
    /// above the same controls and minimum content area.
    static func artworkHeight(in size: CGSize, reserving heightBelowArtwork: CGFloat = minimumHeightBelowArtwork) -> CGFloat {
        max(min(size.width, size.height - heightBelowArtwork), 0)
    }

    static func artworkCollapseHeight(coverHeight: CGFloat) -> CGFloat {
        max(coverHeight - (controlBarTopPaddingUnderTitlebar - controlBarTopPaddingBelowArtwork), 0)
    }

    /// For a full toggle the window itself drives the reveal. When the screen
    /// clamps its travel, the cover still needs to slide the full distance.
    struct ArtworkResize: Equatable {
        let shownFrame: CGRect
        let hiddenFrame: CGRect
        let heightBelowArtwork: CGFloat
        var showsArtwork: Bool

        init(from frame: CGRect, showsArtwork: Bool, visibleFrame: CGRect,
             heightBelowArtwork: CGFloat = minimumHeightBelowArtwork,
             hiddenMinimumHeight: CGFloat = minimumHeightWithoutArtwork) {
            let target = frameTogglingArtwork(
                currentFrame: frame, showsArtwork: showsArtwork, visibleFrame: visibleFrame,
                heightBelowArtwork: heightBelowArtwork, hiddenMinimumHeight: hiddenMinimumHeight
            )
            shownFrame = showsArtwork ? target : frame
            hiddenFrame = showsArtwork ? frame : target
            self.heightBelowArtwork = heightBelowArtwork
            self.showsArtwork = showsArtwork
        }

        var targetFrame: CGRect { showsArtwork ? shownFrame : hiddenFrame }
        var coverHeight: CGFloat { artworkHeight(in: shownFrame.size, reserving: heightBelowArtwork) }
        var followsWindow: Bool {
            let travel = shownFrame.height - hiddenFrame.height
            return travel > 0 && abs(travel - artworkCollapseHeight(coverHeight: coverHeight)) < 1
        }

        func fraction(at windowHeight: CGFloat) -> CGFloat {
            guard followsWindow else { return showsArtwork ? 1 : 0 }
            let progress = (windowHeight - hiddenFrame.height) / (shownFrame.height - hiddenFrame.height)
            return min(max(progress, 0), 1)
        }
    }
    static let defaultHeightWithArtwork: CGFloat = 760
    /// Room below the cover at the minimum height (A2 milestone 5, §13, and
    /// the compare info-bar variant): the compare control bar, its title
    /// bar, the ruler, one whole lane and the bottom bar (91 + 32 + 22 + 96
    /// + 30 = 271 pt). The playlist's control bar is 51 pt taller, which
    /// leaves its list two rows and part of a third.
    static let minimumHeightWithoutArtwork: CGFloat = compareControlBarHeight(showsArtwork: false)
        + CompareInfoBarMetrics.height + CompareLaneLayout.seatBottom + CompareLaneLayout.laneStep
        + BottomBarMetrics.height
    static let minimumHeightBelowArtwork = minimumHeightWithoutArtwork
        - (controlBarTopPaddingUnderTitlebar - controlBarTopPaddingBelowArtwork)

    static func controlBarTopPadding(showsArtwork: Bool) -> CGFloat {
        controlBarTopPadding(artworkFraction: showsArtwork ? 1 : 0)
    }

    static func controlBarTopPadding(artworkFraction: CGFloat) -> CGFloat {
        controlBarTopPaddingUnderTitlebar + (controlBarTopPaddingBelowArtwork - controlBarTopPaddingUnderTitlebar) * artworkFraction
    }

    static func defaultHeight(showsArtwork: Bool) -> CGFloat {
        showsArtwork ? defaultHeightWithArtwork : defaultHeightWithArtwork - artworkCollapseHeight(coverHeight: defaultWidth)
    }

    static func minimumHeight(showsArtwork: Bool, width: CGFloat = minimumWidth) -> CGFloat {
        showsArtwork ? width + minimumHeightBelowArtwork : minimumHeightWithoutArtwork
    }

    static func defaultSize(showsArtwork: Bool) -> CGSize {
        CGSize(width: defaultWidth, height: defaultHeight(showsArtwork: showsArtwork))
    }

    static func minimumSize(showsArtwork: Bool) -> CGSize {
        CGSize(width: minimumWidth, height: minimumHeight(showsArtwork: showsArtwork))
    }

    // The hidden titlebar still reports a top safe-area inset, and
    // NSHostingView adds that inset to the root view's declared minimum height
    // when it enforces the window's minimum size — even though the root view
    // ignores the inset and lays out under the titlebar. Declare the SwiftUI
    // minimum short by the inset so the enforced window minimum lands exactly
    // on the window policy's minimum.
    static let hiddenTitlebarSafeAreaInset: CGFloat = 28

    @MainActor
    static func heightBelowArtwork(for visibility: WorkspaceVisibility, isComparison: Bool) -> CGFloat {
        if visibility.showsPlaylist {
            return minimumHeight(showsArtwork: visibility.showsArtwork, width: 0)
                - (visibility.showsPlayer ? 0 : playerHeightWithoutDivider(showsArtwork: visibility.showsArtwork, isComparison: true))
        }
        guard visibility.showsPlayer else { return 0 }
        return playerHeightWithoutDivider(showsArtwork: visibility.showsArtwork, isComparison: isComparison)
    }

    /// The divider belongs to the lower content when the player is hidden.
    @MainActor
    static func playerHeightWithoutDivider(showsArtwork: Bool, isComparison: Bool) -> CGFloat {
        let barHeight = isComparison ? compareControlBarHeight(showsArtwork: showsArtwork)
            : playlistControlBarHeight(showsArtwork: showsArtwork)
        return barHeight - ControlBarDivider.height
    }

    @MainActor
    static func minimumSize(for visibility: WorkspaceVisibility, isComparison: Bool) -> CGSize {
        let cover = visibility.showsArtwork ? minimumWidth : 0
        return CGSize(width: minimumWidth, height: cover + heightBelowArtwork(for: visibility, isComparison: isComparison))
    }

    @MainActor
    static func defaultSize(for visibility: WorkspaceVisibility) -> CGSize {
        let height = visibility.showsPlaylist
            ? defaultHeight(showsArtwork: visibility.showsArtwork)
                - (visibility.showsPlayer ? 0 : playerHeightWithoutDivider(showsArtwork: visibility.showsArtwork, isComparison: false))
            : (visibility.showsArtwork ? defaultWidth : 0) + heightBelowArtwork(for: visibility, isComparison: false)
        return CGSize(width: defaultWidth, height: height)
    }

    // MARK: Comparison

    /// The compare control bar's height with the artwork shown (12 + 56 +
    /// 10 + 1 divider; no readout): the import highlight's starting inset
    /// until the bar's measured height arrives. The info bar, ruler and
    /// lanes below it are sized by `CompareInfoBarMetrics` and `CompareLaneLayout`.
    static let controlBarReservedHeight = controlBarTopPaddingBelowArtwork
        + ControlBarMetrics.primaryDiameter + ControlBarMetrics.transportRowBottomPadding + ControlBarDivider.height

    /// The compare control bar's height: 79 pt under the cover, 91 under
    /// the titlebar, whose overlay adds 12 pt of top padding.
    static func compareControlBarHeight(showsArtwork: Bool) -> CGFloat {
        controlBarReservedHeight - controlBarTopPaddingBelowArtwork + controlBarTopPadding(showsArtwork: showsArtwork)
    }

    // MARK: Fitting content

    /// The playlist control bar's height: compare's plus the readout row
    /// (51 pt): 130 pt under the cover, 142 under the titlebar.
    @MainActor
    static func playlistControlBarHeight(showsArtwork: Bool) -> CGFloat {
        compareControlBarHeight(showsArtwork: showsArtwork) - ControlBarMetrics.transportRowBottomPadding
            + ControlBarMetrics.readoutTopSpacing + PlaylistControlBarReadout.height + ControlBarMetrics.readoutBottomPadding
    }

    /// The window height that shows every row of the playlist table without
    /// scrolling, never below the minimum.
    @MainActor
    static func playlistFittingHeight(itemRows: Int, versionRows: Int, showsArtwork: Bool, width: CGFloat) -> CGFloat {
        let list = PlaylistRowMetrics.itemHeight * CGFloat(itemRows)
            + PlaylistRowMetrics.versionHeight * CGFloat(versionRows)
        let height = (showsArtwork ? width : 0) + playlistControlBarHeight(showsArtwork: showsArtwork)
            + list + BottomBarMetrics.height
        return max(height, minimumHeight(showsArtwork: showsArtwork, width: width))
    }

    /// The window height that shows every compare lane without scrolling:
    /// the minimum holds one lane, and each further lane adds a lane step.
    static func compareFittingHeight(laneCount: Int, showsArtwork: Bool, width: CGFloat) -> CGFloat {
        minimumHeight(showsArtwork: showsArtwork, width: width) + CGFloat(max(laneCount, 1) - 1) * CompareLaneLayout.laneStep
    }

    /// v2.9.0's resize on adding and removing tracks, for either mode.
    /// Adding tracks grows a window too short to show them all; removing
    /// tracks shrinks a window taller than the rest need. Otherwise the
    /// window keeps its size, so a window the user made taller stays taller
    /// as tracks are added. The top edge stays put, and growth stops at the
    /// bottom of the screen. Returns `nil` when the frame should not change.
    static func frameFittingContent(
        previousTrackCount: Int,
        newTrackCount: Int,
        fittingHeight: CGFloat,
        currentFrame: CGRect,
        visibleFrame: CGRect
    ) -> CGRect? {
        let grows = newTrackCount > previousTrackCount && fittingHeight > currentFrame.height + 0.5
        let shrinks = newTrackCount < previousTrackCount && fittingHeight < currentFrame.height - 0.5
        guard grows || shrinks else { return nil }
        let height = min(fittingHeight, max(currentFrame.maxY - visibleFrame.minY, 0))
        guard grows ? height > currentFrame.height + 0.5 : height < currentFrame.height - 0.5 else { return nil }
        return CGRect(x: currentFrame.minX, y: currentFrame.maxY - height, width: currentFrame.width, height: height)
    }

    // MARK: Mode heights

    /// The playlist remembers its window height; compare doesn't, and sizes
    /// to its lanes instead (`compareFittingHeight`). The height is stored
    /// without the cover and normalized to include the player, so one stored
    /// height works with either visibility setting and at a different width.
    static let playlistHeightDefaultsKey = "main.a2.height.playlist"
    /// Written by an earlier build, when compare remembered its height too.
    static let retiredCompareHeightDefaultsKey = "main.a2.height.compare"

    static func storedPlaylistHeight(defaults: UserDefaults = .standard) -> CGFloat? {
        guard let value = defaults.object(forKey: playlistHeightDefaultsKey) as? Double, value > 0 else { return nil }
        return CGFloat(value)
    }

    static func storePlaylistHeight(_ size: CGSize, showsArtwork: Bool,
                                    heightBelowArtwork: CGFloat = minimumHeightBelowArtwork,
                                    playerHeightReduction: CGFloat = 0, defaults: UserDefaults = .standard) {
        let coverHeight = showsArtwork ? artworkHeight(in: size, reserving: heightBelowArtwork) : 0
        let height = size.height - artworkCollapseHeight(coverHeight: coverHeight) + playerHeightReduction
        defaults.set(Double(max(height, minimumHeightWithoutArtwork)), forKey: playlistHeightDefaultsKey)
    }

    /// The frame for the stored playlist height: the cover added back when
    /// shown. `nil` when the height is unchanged.
    static func frameRestoringPlaylistHeight(_ storedHeight: CGFloat, showsArtwork: Bool,
                                             currentFrame: CGRect, visibleFrame: CGRect) -> CGRect? {
        let height = playlistHeight(restoring: storedHeight, coverWidth: showsArtwork ? currentFrame.width : 0)
        return frameSettingHeight(height, showsArtwork: showsArtwork, currentFrame: currentFrame, visibleFrame: visibleFrame)
    }

    static func playlistHeight(restoring storedHeight: CGFloat, coverWidth: CGFloat) -> CGFloat {
        max(storedHeight, minimumHeightWithoutArtwork) + artworkCollapseHeight(coverHeight: coverWidth)
    }

    /// A frame of the given window height: never below the minimum, top edge
    /// fixed, and no lower than the bottom of the screen. Entering compare
    /// uses it with `compareFittingHeight`, growing or shrinking to the
    /// lanes. `nil` when the height is unchanged.
    static func frameSettingHeight(_ windowHeight: CGFloat, showsArtwork: Bool,
                                   currentFrame: CGRect, visibleFrame: CGRect) -> CGRect? {
        frameSettingHeight(windowHeight, minimum: minimumHeight(showsArtwork: showsArtwork),
                           currentFrame: currentFrame, visibleFrame: visibleFrame)
    }

    static func frameSettingHeight(_ windowHeight: CGFloat, minimum: CGFloat,
                                   currentFrame: CGRect, visibleFrame: CGRect) -> CGRect? {
        let height = max(min(max(windowHeight, minimum), currentFrame.maxY - visibleFrame.minY), minimum)
        guard abs(height - currentFrame.height) > 0.5 else { return nil }
        return CGRect(x: currentFrame.minX, y: currentFrame.maxY - height, width: currentFrame.width, height: height)
    }

    // MARK: Frames

    /// Default size at the top-left of the visible screen.
    static func defaultFrame(showsArtwork: Bool, visibleFrame: CGRect) -> CGRect {
        defaultFrame(size: defaultSize(showsArtwork: showsArtwork), visibleFrame: visibleFrame)
    }

    private static func defaultFrame(size: CGSize, visibleFrame: CGRect) -> CGRect {
        return clampedFrame(
            CGRect(x: visibleFrame.minX, y: visibleFrame.maxY - size.height, width: size.width, height: size.height),
            visibleFrame: visibleFrame
        )
    }

    /// Help ▸ Debug ▸ Reset Window Size: the default width and `height`,
    /// keeping the top-left corner. The caller turns the artwork on and
    /// picks the mode's height (`WorkspaceView.resetWindowSize`).
    static func frameResettingSize(currentFrame: CGRect, height: CGFloat, visibleFrame: CGRect) -> CGRect {
        clampedFrame(
            CGRect(x: currentFrame.minX, y: currentFrame.maxY - height, width: defaultWidth, height: height),
            visibleFrame: visibleFrame
        )
    }

    /// Default size, keeping the top-left corner.
    static func frameResettingSize(currentFrame: CGRect, showsArtwork: Bool, visibleFrame: CGRect) -> CGRect {
        let size = defaultSize(showsArtwork: showsArtwork)
        return clampedFrame(
            CGRect(x: currentFrame.minX, y: currentFrame.maxY - size.height, width: size.width, height: size.height),
            visibleFrame: visibleFrame
        )
    }

    /// Showing adds room for a square cover at the current width. Hiding
    /// removes the cover's visible height. A window that
    /// would run off the bottom of the screen moves up only as far as needed.
    static func frameTogglingArtwork(currentFrame: CGRect, showsArtwork: Bool, visibleFrame: CGRect,
                                     heightBelowArtwork: CGFloat = minimumHeightBelowArtwork,
                                     hiddenMinimumHeight: CGFloat = minimumHeightWithoutArtwork) -> CGRect {
        let coverHeight = showsArtwork ? currentFrame.width : artworkHeight(in: currentFrame.size, reserving: heightBelowArtwork)
        let collapseHeight = artworkCollapseHeight(coverHeight: coverHeight)
        let delta = showsArtwork ? collapseHeight : -collapseHeight
        let minimum = showsArtwork ? minimumWidth + heightBelowArtwork : hiddenMinimumHeight
        let height = max(currentFrame.height + delta, minimum)
        return clampedFrame(
            CGRect(x: currentFrame.minX, y: currentFrame.maxY - height, width: currentFrame.width, height: height),
            visibleFrame: visibleFrame
        )
    }

    /// Fits a frame inside the visible screen: shrinks it if it is larger,
    /// then shifts it the least distance that brings it fully on screen.
    static func clampedFrame(_ frame: CGRect, visibleFrame: CGRect) -> CGRect {
        let width = min(frame.width, visibleFrame.width)
        let height = min(frame.height, visibleFrame.height)
        return CGRect(
            x: min(max(frame.minX, visibleFrame.minX), visibleFrame.maxX - width),
            y: min(max(frame.maxY - height, visibleFrame.minY), visibleFrame.maxY - height),
            width: width,
            height: height
        )
    }

    static func hasSavedMainWindowFrame(defaults: UserDefaults = .standard) -> Bool {
        hasSavedMainWindowFrame(objectForKey: defaults.object(forKey:))
    }

    static func hasSavedMainWindowFrame(objectForKey: (String) -> Any?) -> Bool {
        objectForKey(mainWindowFrameDefaultsKey) != nil
    }

    // MARK: Window configuration

    @MainActor
    static func configureMainWindow(
        _ window: NSWindow,
        visibility: WorkspaceVisibility,
        defaults: UserDefaults = .standard,
        resetsLayoutForLaunch: Bool = false
    ) {
        let minimum = minimumSize(for: visibility, isComparison: false)
        let size = defaultSize(for: visibility)
        let visibleFrame = visibleFrame(for: window)
        window.minSize = minimum

        // Content draws up behind a transparent titlebar so the cover (or,
        // with the artwork hidden, the control bar) reaches the window's top
        // edge, with only the window buttons and visibility toggles over it.
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = false

        guard !resetsLayoutForLaunch else {
            let frame = frameResettingSize(currentFrame: window.frame, height: size.height, visibleFrame: visibleFrame)
            if frame != window.frame { window.setFrame(frame, display: true) }
            return
        }

        retiredLayoutDefaultsKeys.forEach(defaults.removeObject(forKey:))
        let hasSavedFrame = hasSavedMainWindowFrame(defaults: defaults)
        window.setFrameAutosaveName(mainWindowFrameAutosaveName)
        if !hasSavedFrame {
            window.setFrame(defaultFrame(size: size, visibleFrame: visibleFrame), display: true)
        } else {
            // A frame saved with the other artwork state (or below the
            // current minimum) is brought up to this state's minimum.
            var frame = window.frame
            frame.size.width = max(frame.width, minimum.width)
            let height = max(frame.height, minimum.height)
            frame.origin.y = frame.maxY - height
            frame.size.height = height
            window.setFrame(clampedFrame(frame, visibleFrame: visibleFrame), display: true)
        }
    }

    @MainActor
    static func resizeForArtwork(_ window: NSWindow, to frame: CGRect, minimumHeight: CGFloat, animate: Bool) async {
        // Both the window and the hosting view must allow intermediate
        // heights until the cover has finished opening.
        window.minSize = CGSize(width: minimumWidth, height: minimumHeight)
        if animate {
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = artworkResizeDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window.animator().setFrame(frame, display: true)
            }
        } else {
            window.setFrame(frame, display: true)
        }
    }

    @MainActor
    static func visibleFrame(for window: NSWindow) -> CGRect {
        window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
    }
}

struct TakesLaunchOptions {
    static let defaultWindowLayoutArgument = "--default-window-layout"

    var usesDefaultWindowLayout = false

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        usesDefaultWindowLayout = arguments.contains(Self.defaultWindowLayoutArgument)
    }
}

@main
struct TakesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var coordinator: PlaylistCoordinator
    @State private var persistence: PlaylistPersistenceController
    private var controller: PlaybackController { coordinator.controller }
    @StateObject private var remotePlaybackCommands = RemotePlaybackCommandController()
    @StateObject private var settings = AppSettings.shared
    @StateObject private var updater = SoftwareUpdater()
    @StateObject private var ytdlpUpdates = YTDLPUpdateState()
    @StateObject private var zoomHaptics = ZoomHapticsController()
    private let launchOptions = TakesLaunchOptions()
    private let appearanceTunerPanel = AppearanceTunerPanelController()
    private let analysisWindowController = AnalysisWindowController()
    private let comparisonWindowController = ComparisonWindowController()

    init() {
        let coordinator = PlaylistCoordinator()
        _coordinator = State(initialValue: coordinator)
        _persistence = State(initialValue: PlaylistPersistenceController(coordinator: coordinator, store: PlaylistWorkspaceStore()))
    }

    var body: some Scene {
        Window("Takes", id: TakesWindowPolicy.mainWindowID) {
            WorkspaceView(
                coordinator: coordinator,
                persistence: persistence,
                appFileOpenRouter: appDelegate.fileOpenRouter,
                usesTemporaryDefaultWindowLayout: launchOptions.usesDefaultWindowLayout
            )
                .environmentObject(settings)
                .environmentObject(updater)
                .environmentObject(zoomHaptics)
                .onAppear {
                    controller.settings = settings
                    remotePlaybackCommands.connect(to: coordinator)
                    appDelegate.flushWorkspaceBeforeTermination = { await persistence.flush() }
                }
        }
        .defaultSize(TakesWindowPolicy.defaultSize(for: settings.windowVisibility))
        // Declared on the scene (not just patched onto the NSWindow later) so
        // SwiftUI sizes the hosting view full-height from creation, letting
        // the window background genuinely draw under the titlebar.
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Takes") {
                    NSApp.orderFrontStandardAboutPanel(options: TakesAboutPanel.options)
                }

                Button("Check for Updates…") {
                    updater.checkForUpdates()
                }
            }

            FileCommands()
            EditCommands(coordinator: coordinator)
            PlaylistCommands(coordinator: coordinator)
            PlaybackCommands(coordinator: coordinator)
            ViewCommands(coordinator: coordinator)

            CommandGroup(replacing: .help) {
                Link("Visit Website", destination: URL(string: "https://takes.nigelwarren.com")!)
                Link("Release Notes", destination: URL(string: "https://takes.nigelwarren.com/changelog.html")!)

                Divider()

                Menu("Debug") {
                    Toggle("Show Component Names", isOn: $settings.showsComponentDebugLabels)
                    ResetMainWindowSizeButton()
                    OpenAppearanceTunerButton(panel: appearanceTunerPanel, settings: settings)
                    OpenAnalysisWindowButton(controller: analysisWindowController)
                    OpenComparisonWindowButton(
                        controller: comparisonWindowController,
                        playbackController: controller
                    )
                    .disabled(coordinator.mode.itemID == nil)
                }
            }
        }

        Settings {
            SettingsView()
                .environmentObject(settings)
                .environmentObject(updater)
                .environmentObject(ytdlpUpdates)
        }
        .windowResizability(.contentSize)
    }
}

/// Opens the Appearance Tuner from the Debug menu as a floating palette that
/// stays above the main window without stealing key focus, so slider tweaks
/// update the transport controls live in the window behind it.
private struct OpenAppearanceTunerButton: View {
    let panel: AppearanceTunerPanelController
    let settings: AppSettings

    var body: some View {
        Button("Appearance Tuner") {
            panel.show(settings: settings)
        }
    }
}

/// Hosts the Appearance Tuner in a non-activating utility `NSPanel`. A panel
/// (rather than a SwiftUI `Window` scene) gives us a floating palette that
/// never becomes the key window on its own — so adjusting a slider leaves the
/// main window key and the transport buttons visibly updating behind it — and
/// keeps the tuner out of the standard Window menu.
///
/// The panel is attached as a *child* of the main window rather than raised to
/// the global floating level, so it hovers above the Takes window only and
/// drops behind other apps normally instead of floating over everything.
@MainActor
final class AppearanceTunerPanelController {
    private var panel: NSPanel?

    func show(settings: AppSettings) {
        if let panel {
            reparent(panel)
            panel.orderFront(nil)
            return
        }

        let hosting = NSHostingController(rootView: AppearanceTunerView(settings: settings))
        let panel = NSPanel(contentViewController: hosting)
        panel.title = "Appearance Tuner"
        panel.styleMask = [.titled, .closable, .utilityWindow, .nonactivatingPanel]
        // Takes key only when a control that needs text entry is focused, so it
        // never steals focus from the main window by itself.
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isExcludedFromWindowsMenu = true
        // We hold the only strong reference; closing just orders it out so it
        // can be reopened without reconstructing the view.
        panel.isReleasedWhenClosed = false
        panel.setContentSize(NSSize(width: 320, height: 680))
        panel.setFrameAutosaveName("AppearanceTunerPanel")
        panel.center()
        self.panel = panel
        reparent(panel)
        panel.orderFront(nil)
    }

    /// Attach the panel above the current main window so it tracks that window's
    /// stacking (above it, hidden with it) instead of floating over every app.
    private func reparent(_ panel: NSPanel) {
        let parent = NSApp.mainWindow ?? NSApp.windows.first { $0 !== panel && $0.isVisible }
        guard let parent, parent !== panel else { return }
        panel.parent?.removeChildWindow(panel)
        parent.addChildWindow(panel, ordered: .above)
    }
}

/// Hosts the experimental Analysis tool outside SwiftUI's `Window` scene list
/// so it remains reachable only from Help > Debug instead of Window > Analysis.
@MainActor
final class AnalysisWindowController {
    private var window: NSWindow?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: AnalysisWindowView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "Analysis"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isExcludedFromWindowsMenu = true
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 760, height: 640))
        window.setFrameAutosaveName(TakesWindowPolicy.analysisWindowID)
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Hosts the experimental Compare Quality tool outside SwiftUI's `Window`
/// scene list, like the Analysis window, so it stays reachable only from
/// Help > Debug.
///
/// The window is rebuilt on every open rather than reused: its input is the
/// set of tracks loaded right now, and a stale track list would be worse than
/// no window at all.
@MainActor
final class ComparisonWindowController {
    private var window: NSWindow?

    func show(trackURLs: [URL]) {
        window?.close()
        let hosting = NSHostingController(rootView: ComparisonWindowView(trackURLs: trackURLs))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Compare Quality"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isExcludedFromWindowsMenu = true
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 820, height: 680))
        window.setFrameAutosaveName(TakesWindowPolicy.comparisonWindowID)
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Opens the experimental Compare Quality window over the session's tracks.
private struct OpenComparisonWindowButton: View {
    let controller: ComparisonWindowController
    let playbackController: PlaybackController

    var body: some View {
        Button("Compare Quality") {
            controller.show(trackURLs: playbackController.session.tracks.map(\.loadedTrack.url))
        }
        .keyboardShortcut("l", modifiers: [.command, .shift])
        .disabled(playbackController.session.tracks.count < 2)
    }
}

/// Opens the experimental single-file Analysis window from the Debug menu.
private struct OpenAnalysisWindowButton: View {
    let controller: AnalysisWindowController

    var body: some View {
        Button("Analysis") {
            controller.show()
        }
        .keyboardShortcut("z", modifiers: [.command, .option])
    }
}

private struct ResetMainWindowSizeButton: View {
    @FocusedValue(\.mainWindowCommandState) private var mainWindowCommandState

    var body: some View {
        Button("Reset Window Size") {
            mainWindowCommandState?.resetWindowSizing()
        }
        .disabled(mainWindowCommandState == nil)
    }
}

private struct FileCommands: Commands {
    @FocusedValue(\.openFileCommandState) private var openFileCommandState
    @FocusedValue(\.canShowActiveTrackInFinder) private var canShowActiveTrackInFinder
    @FocusedValue(\.canUseGlobalMenuShortcuts) private var canUseGlobalMenuShortcuts
    @FocusedValue(\.playlistCommandContext) private var playlistContext

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open…") {
                openFileCommandState?.presentOpenDialog()
            }
            .keyboardShortcut("o")
            .disabled(openFileCommandState == nil)

            Button(ImportActionMenuItem.streamingURL.title) {
                openFileCommandState?.presentStreamingURLPrompt()
            }
            .keyboardShortcut("o", modifiers: [.shift, .command])
            .disabled(openFileCommandState == nil)

            Button(ImportActionMenuItem.finderSelection.title) {
                openFileCommandState?.openFinderSelection()
            }
            .keyboardShortcut("f", modifiers: [.shift, .command])
            .disabled(openFileCommandState == nil)

            Button(ImportActionMenuItem.musicSelection.title) {
                openFileCommandState?.openAppleMusicSelection()
            }
            .keyboardShortcut("m", modifiers: [.shift, .command])
            .disabled(openFileCommandState == nil)

            Divider()

            Button("Reveal in Finder") {
                openFileCommandState?.showActiveTrackInFinder()
            }
            .keyboardShortcut("r", modifiers: [.shift, .command])
            .disabled(openFileCommandState == nil || canShowActiveTrackInFinder != true)

            // Playlist: the selection's first missing file. Compare's lanes
            // offer it from their strip menu.
            Button("Locate File…") { playlistContext?.locate() }
                .disabled(playlistContext?.locateVersionID == nil || canUseGlobalMenuShortcuts != true)
        }
    }
}

private struct EditCommands: Commands {
    let coordinator: PlaylistCoordinator
    @FocusedValue(\.playlistCommandContext) private var playlistContext
    @FocusedValue(\.canUseGlobalMenuShortcuts) private var canUseGlobalMenuShortcuts
    @FocusedValue(\.mainWindowCommandState) private var mainWindowCommandState
    @FocusedValue(\.canDeselect) private var canDeselect

    private var isComparison: Bool { coordinator.mode.itemID != nil }

    private var selectsPlaylistRows: Bool {
        !isComparison && playlistContext != nil && canUseGlobalMenuShortcuts == true
            && mainWindowCommandState?.visibility.showsPlaylist == true
    }

    var body: some Commands {
        CommandGroup(replacing: .pasteboard) {
            responderCommand("Cut", key: "x", action: #selector(NSText.cut(_:)))
            responderCommand("Copy", key: "c", action: #selector(NSText.copy(_:)))
            responderCommand("Paste", key: "v", action: #selector(NSText.paste(_:)))
            Divider()
            if selectsPlaylistRows {
                Button("Select All") { playlistContext?.selectAll() }
                    .keyboardShortcut("a", modifiers: [.command])
                    .disabled(coordinator.workspace.items.isEmpty)
            } else {
                Button("Select All") {
                    if let target = selectAllResponder {
                        NSApp.sendAction(#selector(NSText.selectAll(_:)), to: target, from: nil)
                    }
                }
                .keyboardShortcut("a", modifiers: [.command])
                .disabled(selectAllResponder == nil)
            }
            Button(isComparison ? "Deselect" : "Deselect All") {
                if isComparison {
                    coordinator.deselectLoop()
                } else {
                    playlistContext?.deselectAll()
                }
            }
            .keyboardShortcut("d", modifiers: [.command])
            .disabled(canDeselect != true)
        }
    }

    private var selectAllResponder: Any? {
        let target = NSApp.target(forAction: #selector(NSText.selectAll(_:)))
        if mainWindowCommandState != nil { return target as? NSText }
        return target
    }

    private func responderCommand(_ title: String, key: KeyEquivalent, action: Selector) -> some View {
        Button(title) { NSApp.sendAction(action, to: nil, from: nil) }
            .keyboardShortcut(key, modifiers: [.command])
            .disabled(NSApp.target(forAction: action) == nil)
    }
}

private struct PlaybackCommands: Commands {
    let coordinator: PlaylistCoordinator
    private var controller: PlaybackController { coordinator.controller }
    private var isComparison: Bool { coordinator.mode.itemID != nil }
    @FocusedValue(\.canUseGlobalMenuShortcuts) private var canUseGlobalMenuShortcuts

    var body: some Commands {
        CommandMenu("Playback") {
            Button(coordinator.isPlaying ? "Pause" : "Play") {
                coordinator.togglePlayback()
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(!coordinator.canPlay || canUseGlobalMenuShortcuts != true)

            if isComparison {
                Button("Switch Track") { coordinator.next() }
                    .keyboardShortcut("x", modifiers: [])
                    .disabled(!coordinator.canNext || canUseGlobalMenuShortcuts != true)

                Button("Switch to Previous Track") { coordinator.previous() }
                    .keyboardShortcut("x", modifiers: [.shift])
                    .disabled(!coordinator.canPrevious || canUseGlobalMenuShortcuts != true)

                Divider()

                Button("Jump to Beginning") { coordinator.seek(to: controller.session.timelineStart) }
                    .keyboardShortcut(.leftArrow, modifiers: [.command])
                    .disabled(!coordinator.canPlay || canUseGlobalMenuShortcuts != true)

                Button("Jump to End") { coordinator.seek(to: controller.session.timelineEnd) }
                    .keyboardShortcut(.rightArrow, modifiers: [.command])
                    .disabled(!coordinator.canPlay || canUseGlobalMenuShortcuts != true)
            } else {
                // Standard media-player Previous/Next (`PlaylistCoordinator.previous`,
                // `next`): Previous restarts a track past its first seconds.
                Button("Next Track") { coordinator.next() }
                    .keyboardShortcut(.rightArrow, modifiers: [.command])
                    .disabled(!coordinator.canNext || canUseGlobalMenuShortcuts != true)

                Button("Previous Track") { coordinator.previous() }
                    .keyboardShortcut(.leftArrow, modifiers: [.command])
                    .disabled(!coordinator.canPrevious || canUseGlobalMenuShortcuts != true)
            }

            // Compare skips on the plain arrows; the playlist's arrows move
            // through the list, so it skips with ⌥.
            Menu("Skip") {
                Button("Skip Forward 1s") { coordinator.skip(by: 1) }
                    .keyboardShortcut(.rightArrow, modifiers: skipModifiers)
                Button("Skip Forward 10s") { coordinator.skip(by: 10) }
                    .keyboardShortcut(.rightArrow, modifiers: skipModifiers.union(.shift))
                Button("Skip Backward 1s") { coordinator.skip(by: -1) }
                    .keyboardShortcut(.leftArrow, modifiers: skipModifiers)
                Button("Skip Backward 10s") { coordinator.skip(by: -10) }
                    .keyboardShortcut(.leftArrow, modifiers: skipModifiers.union(.shift))
            }
            .disabled(!coordinator.canPlay || canUseGlobalMenuShortcuts != true)

            Divider()

            Menu("Repeat") {
                Button("Change Repeat Mode") {
                    if isComparison { coordinator.cycleRepeatMode() } else { coordinator.cyclePlaylistRepeatMode() }
                }
                .keyboardShortcut("r", modifiers: [.command, .option])

                Divider()

                if isComparison {
                    Picker(selection: Binding(
                        get: { controller.session.repeatMode },
                        set: { coordinator.setRepeatMode($0) }
                    )) {
                        Text("Off").tag(RepeatMode.off)
                        Text("One").tag(RepeatMode.one)
                        Text("Switch & Repeat").tag(RepeatMode.switchAndRepeat)
                    } label: {
                        EmptyView()
                    }
                    .pickerStyle(.inline)
                } else {
                    Picker(selection: Binding(
                        get: { coordinator.workspace.playlistRepeatMode },
                        set: { coordinator.setPlaylistRepeatMode($0) }
                    )) {
                        Text("Off").tag(PlaylistRepeatMode.off)
                        Text("All").tag(PlaylistRepeatMode.all)
                        Text("One").tag(PlaylistRepeatMode.one)
                    } label: {
                        EmptyView()
                    }
                    .pickerStyle(.inline)
                    .disabled(!coordinator.canPlay)
                }
            }
            .disabled((isComparison && !controller.session.isPlayable) || canUseGlobalMenuShortcuts != true)

            if !isComparison {
                Toggle("Shuffle", isOn: Binding(get: { coordinator.workspace.isShuffleEnabled }, set: { coordinator.setShuffleEnabled($0) }))
                    .keyboardShortcut("s", modifiers: [.command, .option])
            }
            Toggle(
                "Blind Listening Mode",
                isOn: Binding(
                    get: { controller.session.isBlindListeningModeEnabled },
                    set: { coordinator.setBlindListeningMode($0) }
                )
            )
            .keyboardShortcut("b", modifiers: [.command])
            .disabled(!isComparison || !controller.session.canToggleBlindListeningMode)

            Divider()

            Button("Auto-Align Tracks") {
                controller.autoAlignTracks()
            }
            .keyboardShortcut("a", modifiers: [.command, .shift])
            .disabled(!isComparison || !controller.session.hasMultipleTracks || controller.isAligning)

            Menu("Nudge Track") {
                Button("Nudge Left") {
                    coordinator.nudgeActiveTrackOffset(direction: -1, largeStep: false)
                }
                .keyboardShortcut("j", modifiers: [.command])

                Button("Large Nudge Left") {
                    coordinator.nudgeActiveTrackOffset(direction: -1, largeStep: true)
                }
                .keyboardShortcut("j", modifiers: [.command, .shift])

                Button("Nudge Right") {
                    coordinator.nudgeActiveTrackOffset(direction: 1, largeStep: false)
                }
                .keyboardShortcut("k", modifiers: [.command])

                Button("Large Nudge Right") {
                    coordinator.nudgeActiveTrackOffset(direction: 1, largeStep: true)
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
            }
            .disabled(!isComparison || controller.session.activeTrack == nil || canUseGlobalMenuShortcuts != true)

            Button("Reset Offset") {
                if let trackID = coordinator.activeComparisonVersionID {
                    coordinator.setOffset(trackID, seconds: 0)
                }
            }
            .disabled(!isComparison || (controller.session.activeTrack?.loadedTrack.offsetSeconds ?? 0) == 0)

            Button("Reset All Offsets") {
                coordinator.resetAllComparisonOffsets()
            }
            .disabled(!isComparison || !controller.session.tracks.contains { $0.loadedTrack.offsetSeconds != 0 })
        }
    }

    private var skipModifiers: EventModifiers { isComparison ? [] : [.option] }
}

private struct ViewCommands: Commands {
    let coordinator: PlaylistCoordinator
    private var controller: PlaybackController { coordinator.controller }
    @FocusedValue(\.playlistCommandContext) private var playlistContext
    @FocusedValue(\.canUseGlobalMenuShortcuts) private var canUseGlobalMenuShortcuts
    @FocusedValue(\.mainWindowCommandState) private var mainWindowCommandState

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            ForEach(WorkspaceVisibility.Region.allCases, id: \.self) { region in
                Button(region.visibilityAction(isVisible: mainWindowCommandState?.visibility[region] ?? true)) {
                    mainWindowCommandState?.toggleVisibility(region)
                }
                .keyboardShortcut(region.visibilityShortcut)
                .disabled(mainWindowCommandState?.visibility.canToggle(region) != true)
            }
            Divider()
            Button("Compare Versions") { playlistContext?.compare() }
                .keyboardShortcut("]", modifiers: [.command])
                .disabled(!showsPlaylist || coordinator.mode.itemID != nil || playlistContext?.compareItemID == nil)
            Button("Back to Playlist") { Task { await coordinator.backToPlaylist() } }
                .keyboardShortcut("[", modifiers: [.command])
                .disabled(!showsPlaylist || coordinator.mode.itemID == nil)
            Divider()
            Button("Zoom In") {
                controller.stepZoom(zoomingIn: true)
            }
            .keyboardShortcut("+", modifiers: [.command])
            .disabled(!canUseZoomShortcuts || !controller.canZoomTimeline)

            Button("Zoom Out") {
                controller.stepZoom(zoomingIn: false)
            }
            .keyboardShortcut("-", modifiers: [.command])
            .disabled(!canUseZoomShortcuts || !controller.canZoomTimeline)

            Button("Zoom to Selection") {
                controller.zoomToSelection()
            }
            .keyboardShortcut("+", modifiers: [.command, .option])
            .disabled(
                !canUseZoomShortcuts
                    || !controller.canZoomTimeline
                    || controller.session.loopRegion == nil
            )

            Button("Zoom to Fit") {
                controller.zoomToFit()
            }
            .keyboardShortcut("-", modifiers: [.command, .option])
            .disabled(!canUseZoomShortcuts || !controller.canZoomTimeline)

            Divider()
        }
    }

    private var showsPlaylist: Bool { mainWindowCommandState?.visibility.showsPlaylist == true }

    private var canUseZoomShortcuts: Bool {
        coordinator.mode.itemID != nil && canUseGlobalMenuShortcuts == true
    }
}
