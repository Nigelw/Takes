import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import Takes

struct TrackDropHighlightTests {
    @Test
    func emptyTrackRowUsesDropHighlightWhenTargeted() {
        #expect(TrackDropHighlight.empty(isTargeted: true) == .dropTarget)
    }

    @Test
    func emptyTrackRowUsesDefaultHighlightWhenNotTargeted() {
        #expect(TrackDropHighlight.empty(isTargeted: false) == .normal)
    }

    @Test
    func trackReorderDragUsesPrivateTakesType() {
        // A private marker type: external drags (Finder file drags carry a
        // plain-text path flavor) must never match the reorder-only drop target.
        #expect(TrackReorderDrag.contentType.identifier == "com.nigelwarren.takes.track-reorder")
        #expect(!UTType.fileURL.conforms(to: TrackReorderDrag.contentType))
        #expect(!UTType.plainText.conforms(to: TrackReorderDrag.contentType))
    }

    @Test
    func trackRowDropTargetAcceptsReorderAndFileDrops() {
        #expect(TrackRowDropTarget.acceptedContentTypeIdentifiers == [
            TrackReorderDrag.contentType.identifier,
            UTType.fileURL.identifier
        ])
    }

    @Test
    func trackRowDropKindPrioritizesReorderDragsOverFileDrops() {
        // A reorder drag carries the track's file URL too (for dragging out of
        // the window), so the reorder marker decides the kind when both exist.
        #expect(TrackRowDropKind.kind(hasFileURLs: true, hasReorderItems: true) == .reorder)
        #expect(TrackRowDropKind.kind(hasFileURLs: true, hasReorderItems: false) == .file)
        #expect(TrackRowDropKind.kind(hasFileURLs: false, hasReorderItems: true) == .reorder)
        #expect(TrackRowDropKind.kind(hasFileURLs: false, hasReorderItems: false) == nil)
    }

    @Test
    func trackReorderInsertionPlacementUsesDropLocation() {
        #expect(TrackReorderInsertionPlacement.location(y: 10, rowHeight: 100) == .before)
        #expect(TrackReorderInsertionPlacement.location(y: 60, rowHeight: 100) == .after)
    }

    @MainActor
    @Test(arguments: [false, true])
    func playlistOutlineRejectsDropsPastVersionLimit(dragVersionRows: Bool) throws {
        func makeVersion(_ name: String) -> PlaylistVersion {
            PlaylistVersion(
                file: PlaylistFileReference(storedURL: URL(fileURLWithPath: "/tmp/\(name).wav")),
                metadata: PlaylistMetadata(displayName: name)
            )
        }

        let limit = PlaylistWorkspace.maximumVersionsPerItem
        let destination = PlaylistItem(title: "Destination", versions: (1..<limit).map { makeVersion("Take \($0)") })
        let source = PlaylistItem(title: "Source", versions: [makeVersion("First"), makeVersion("Second")])
        let single = PlaylistItem(title: "Single", versions: [makeVersion("Single")])
        let workspace = PlaylistWorkspace(items: [destination, source, single])
        let playlist = PlaylistCoordinator(workspace: workspace)
        let presentation = PlaylistPresentationState()
        if dragVersionRows { presentation.expanded.insert(source.id) }
        let controller = PlaylistOutlineController(
            playlist: playlist, presentation: presentation, artworkStore: PlaylistArtworkStore()
        )
        let scroll = controller.makeScrollView()
        let outline = try #require(scroll.documentView as? NSOutlineView)
        controller.update(
            items: workspace.items, fileIssues: [:], currentItemID: nil, currentVersionID: nil,
            isPlaying: false, isActive: true, moveRevision: 0, reduceMotion: true, metadataFields: []
        )

        let info = PlaylistTestDraggingInfo(source: outline)
        let session = NSDraggingSession()
        let target = try #require(outline.item(atRow: 0))
        let onItem = NSOutlineViewDropOnItemIndex
        let sourceRows = dragVersionRows ? [2, 3] : [1]
        let sources = try sourceRows.map { row in try #require(outline.item(atRow: row)) }
        controller.outlineView(outline, draggingSession: session, willBeginAt: .zero, forItems: sources)

        #expect(controller.outlineView(outline, validateDrop: info, proposedItem: target, proposedChildIndex: onItem).isEmpty)
        #expect(!controller.outlineView(outline, acceptDrop: info, item: target, childIndex: onItem))
        #expect(playlist.workspace == workspace)

        let singleRow = try #require(outline.item(atRow: 2))
        controller.outlineView(outline, draggingSession: session, willBeginAt: .zero, forItems: [singleRow])

        #expect(controller.outlineView(outline, validateDrop: info, proposedItem: target, proposedChildIndex: onItem) == .move)
        #expect(controller.outlineView(outline, acceptDrop: info, item: target, childIndex: onItem))
        #expect(playlist.workspace.items.first?.versions.count == limit)
        if dragVersionRows {
            #expect(playlist.workspace.items[1].versions == Array(source.versions.dropFirst()))
            #expect(playlist.workspace.items.last == single)
        } else {
            #expect(playlist.workspace.items.last == source)
        }
    }

    @MainActor
    @Test
    func comparisonDisablesRetainedOutlineAndPlaylistSelectionCommands() async throws {
        let versions = ["Take 1", "Take 2"].map { name in
            PlaylistVersion(
                file: PlaylistFileReference(storedURL: URL(fileURLWithPath: "/tmp/\(UUID()).wav")),
                metadata: PlaylistMetadata(duration: 2, sampleRate: 44_100, channelCount: 1, displayName: name)
            )
        }
        let item = PlaylistItem(title: "Takes", versions: versions)
        let playlist = PlaylistCoordinator(workspace: PlaylistWorkspace(items: [item]))
        let presentation = PlaylistPresentationState()
        presentation.expanded = [item.id]
        let command = PlaylistCommandContext(coordinator: playlist, presentation: presentation, undoManager: nil)
        let controller = PlaylistOutlineController(
            playlist: playlist, presentation: presentation, artworkStore: PlaylistArtworkStore()
        )
        let scroll = controller.makeScrollView()
        let outline = try #require(scroll.documentView as? PlaylistNSOutlineView)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        defer { window.close() }

        func updateOutline() {
            controller.update(
                items: playlist.workspace.items, fileIssues: [:], currentItemID: nil, currentVersionID: nil,
                isPlaying: false, isActive: playlist.mode == .playlist, moveRevision: 0,
                reduceMotion: true, metadataFields: []
            )
        }

        updateOutline()
        #expect(window.makeFirstResponder(outline))
        #expect(window.firstResponder === outline)
        outline.selectRowIndexes([0], byExtendingSelection: false)
        #expect(presentation.selection == [.item(item.id)])

        await playlist.enterComparison(itemID: item.id)
        try #require(playlist.mode.itemID == item.id)
        // The live mode changes before SwiftUI updates the retained AppKit view.
        outline.selectAll(nil)
        command.selectAll()
        command.deselectAll()
        #expect(outline.selectedRowIndexes == [0])
        #expect(presentation.selection == [.item(item.id)])

        updateOutline()
        #expect(window.firstResponder !== outline)
        #expect(!outline.acceptsFirstResponder)
        #expect(!outline.canBecomeKeyView)

        await playlist.backToPlaylist()
        updateOutline()
        #expect(outline.acceptsFirstResponder)
        outline.selectAll(nil)
        #expect(presentation.selection == Set(presentation.visibleRows(in: playlist.workspace)))
    }

    @Test
    func droppedFolderRecursivelyResolvesAudioFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let nested = root.appending(path: "nested", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let directAudio = root.appending(path: "direct.wav")
        let ignoredText = root.appending(path: "notes.txt")
        let nestedAudio = nested.appending(path: "nested.m4a")
        let directInputAudio = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".mp3")
        try Data().write(to: directAudio)
        try Data().write(to: ignoredText)
        try Data().write(to: nestedAudio)
        try Data().write(to: directInputAudio)
        defer { try? FileManager.default.removeItem(at: directInputAudio) }

        let resolvedURLs = AppOpenedURLResolver.audioFileURLs(from: [root, directInputAudio])

        #expect(
            resolvedURLs.map { $0.resolvingSymlinksInPath() }
                == [directAudio, nestedAudio, directInputAudio].map { $0.resolvingSymlinksInPath() }
        )
    }

    @Test
    func importActionMenuOffersFinderSelectionAndMusicSelection() {
        #expect(ImportActionMenuItem.dropdownItems.map(\.title) == [
            "Open Streaming URL...",
            "Quick Open from Finder",
            "Quick Open from Apple Music"
        ])
    }

    @MainActor
    @Test
    func openFileCommandStateControlsImporterPresentation() {
        let state = OpenFileCommandState()

        #expect(!state.isImportingTracks)

        state.presentOpenDialog()

        #expect(state.isImportingTracks)

        state.dismissOpenDialog()

        #expect(!state.isImportingTracks)
    }

    @MainActor
    @Test
    func openFileCommandStateControlsStreamingURLPromptPresentation() {
        let state = OpenFileCommandState()

        #expect(!state.isPromptingForStreamingURL)

        state.presentStreamingURLPrompt()

        #expect(state.isPromptingForStreamingURL)

        state.dismissStreamingURLPrompt()

        #expect(!state.isPromptingForStreamingURL)
    }

    @MainActor
    @Test
    func openFileCommandStateSubmitsStreamingURLAction() {
        var submittedURLString: String?
        let state = OpenFileCommandState(loadStreamingURL: { urlString, commandState in
            submittedURLString = urlString
            commandState.dismissStreamingURLPrompt()
        })

        state.presentStreamingURLPrompt()
        state.streamingURLText = "  https://open.spotify.com/track/example  "
        state.submitStreamingURL()

        #expect(submittedURLString == "https://open.spotify.com/track/example")
        #expect(!state.isPromptingForStreamingURL)
        #expect(state.streamingURLText.isEmpty)
    }

    @MainActor
    @Test
    func openFileCommandStateOpensAutomationStreamingURLInPrompt() {
        var submittedURLString: String?
        let state = OpenFileCommandState(loadStreamingURL: { urlString, _ in
            submittedURLString = urlString
        })

        state.openStreamingURL("https://www.youtube.com/watch?v=XPL_qGqSJxA")

        #expect(submittedURLString == "https://www.youtube.com/watch?v=XPL_qGqSJxA")
        #expect(state.isPromptingForStreamingURL)
        #expect(state.streamingURLText == "https://www.youtube.com/watch?v=XPL_qGqSJxA")
        #expect(state.streamingURLStatus.isWorking)
    }

    @MainActor
    @Test
    func openFileCommandStateKeepsStreamingPromptOpenWhileLoading() {
        var submittedURLString: String?
        let state = OpenFileCommandState(loadStreamingURL: { urlString, _ in
            submittedURLString = urlString
        })

        state.presentStreamingURLPrompt()
        state.streamingURLText = "https://open.spotify.com/track/example"
        state.submitStreamingURL()

        #expect(submittedURLString == "https://open.spotify.com/track/example")
        #expect(state.isPromptingForStreamingURL)
        #expect(state.streamingURLStatus.isWorking)
        #expect(!state.streamingURLText.isEmpty)
    }

    @MainActor
    @Test
    func openFileCommandStateCancelsRegisteredStreamingTaskOnDismiss() async {
        let recorder = StreamingURLCancellationRecorder()
        let state = OpenFileCommandState(loadStreamingURL: { _, commandState in
            let taskID = UUID()
            let task = Task {
                do {
                    try await Task.sleep(for: .seconds(10))
                } catch is CancellationError {
                    await recorder.recordCancellation()
                } catch {
                }
                await MainActor.run {
                    commandState.finishStreamingURLTask(id: taskID)
                }
            }
            commandState.registerStreamingURLTask(task, id: taskID)
        })

        state.presentStreamingURLPrompt()
        state.streamingURLText = "https://www.youtube.com/watch?v=XPL_qGqSJxA"
        state.submitStreamingURL()
        state.dismissStreamingURLPrompt()

        #expect(await recorder.waitForCancellation())

        // `dismissStreamingURLPrompt()` clears both of these synchronously.
        #expect(!state.isPromptingForStreamingURL)
        #expect(!state.streamingURLStatus.isWorking)
    }

    @MainActor
    @Test
    func openFileCommandStatePerformsAppleMusicSelectionAction() {
        var loadCount = 0
        let state = OpenFileCommandState(loadAppleMusicSelection: {
            loadCount += 1
        })

        state.openAppleMusicSelection()

        #expect(loadCount == 1)
    }

    @MainActor
    @Test
    func openFileCommandStatePerformsFinderSelectionAction() {
        var loadCount = 0
        let state = OpenFileCommandState(loadFinderSelection: {
            loadCount += 1
        })

        state.openFinderSelection()

        #expect(loadCount == 1)
    }

    @MainActor
    @Test
    func openFileCommandStatePerformsShowActiveTrackInFinderAction() {
        var showCount = 0
        let state = OpenFileCommandState(showActiveTrackInFinder: {
            showCount += 1
        })

        state.showActiveTrackInFinder()

        #expect(showCount == 1)
    }

    @MainActor
    @Test
    func openFileCommandStatePerformsClearAllTracksAction() {
        var clearCount = 0
        let state = OpenFileCommandState(clearAllTracks: {
            clearCount += 1
        })

        state.clearAllTracks()

        #expect(clearCount == 1)
    }

    @Test
    func finderSelectionResolverReturnsAudioFileURLs() throws {
        let wav = URL(fileURLWithPath: "/tmp/selection.wav")
        let mp3 = URL(fileURLWithPath: "/tmp/selection.mp3")

        #expect(try FinderSelectionResolver.audioFileURLs(from: [wav, mp3]) == [wav, mp3])
    }

    @Test
    func finderSelectionResolverReturnsAudioFilesFromMixedSelection() throws {
        let wav = URL(fileURLWithPath: "/tmp/selection.wav")
        let text = URL(fileURLWithPath: "/tmp/notes.txt")
        let mp3 = URL(fileURLWithPath: "/tmp/selection.mp3")

        #expect(try FinderSelectionResolver.audioFileURLs(from: [wav, text, mp3]) == [wav, mp3])
    }

    @Test
    func finderSelectionResolverRecursivelyFindsAudioFilesInFolders() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let nested = root.appending(path: "nested", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let directAudio = root.appending(path: "direct.wav")
        let ignoredText = root.appending(path: "notes.txt")
        let nestedAudio = nested.appending(path: "nested.m4a")
        let directInputAudio = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".mp3")
        try Data().write(to: directAudio)
        try Data().write(to: ignoredText)
        try Data().write(to: nestedAudio)
        try Data().write(to: directInputAudio)
        defer { try? FileManager.default.removeItem(at: directInputAudio) }

        let resolvedURLs = try FinderSelectionResolver.audioFileURLs(from: [root, directInputAudio])

        #expect(
            resolvedURLs.map { $0.resolvingSymlinksInPath() }
                == [directAudio, nestedAudio, directInputAudio].map { $0.resolvingSymlinksInPath() }
        )
    }

    @Test
    func finderSelectionResolverRejectsEmptySelection() {
        #expect(throws: PlaybackError.librarySelectionFailed("Finder has no selected files.")) {
            try FinderSelectionResolver.audioFileURLs(from: [])
        }
    }

    @Test
    func finderSelectionResolverRejectsSelectionWithNoAudioFiles() {
        let text = URL(fileURLWithPath: "/tmp/notes.txt")

        #expect(throws: PlaybackError.librarySelectionFailed("No audio files are selected in the Finder.")) {
            try FinderSelectionResolver.audioFileURLs(from: [text])
        }
    }

    @Test
    func finderSelectionResolverRejectsFolderSelectionWithNoAudioFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let nested = root.appending(path: "nested", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data().write(to: root.appending(path: "notes.txt"))
        try Data().write(to: nested.appending(path: "image.png"))

        #expect(throws: PlaybackError.librarySelectionFailed("No audio files are selected in the Finder.")) {
            try FinderSelectionResolver.audioFileURLs(from: [root])
        }
    }

    @MainActor
    @Test
    func appFileOpenRouterQueuesURLsUntilHandlerIsConfigured() {
        let router = AppFileOpenRouter()
        let earlyURL = URL(fileURLWithPath: "/tmp/early.wav")
        let laterURL = URL(fileURLWithPath: "/tmp/later.mp3")
        var handledURLBatches: [[URL]] = []

        router.open([earlyURL])

        #expect(handledURLBatches.isEmpty)

        router.setHandler { urls in
            handledURLBatches.append(urls)
        }

        #expect(handledURLBatches == [[earlyURL]])

        router.open([laterURL])

        #expect(handledURLBatches == [[earlyURL], [laterURL]])
    }

    @MainActor
    @Test
    func appFileOpenRouterQueuesAutomationFileURLsUntilHandlerIsConfigured() {
        let router = AppFileOpenRouter()
        let earlyURL = URL(string: "takes://open-file?url=file%3A%2F%2F%2Ftmp%2Fearly.wav")!
        let laterURL = URL(string: "takes://open-file?url=file%3A%2F%2F%2Ftmp%2Flater.mp3&url=file%3A%2F%2F%2Ftmp%2Fthird.m4a")!
        var handledURLBatches: [[URL]] = []

        router.open([earlyURL])

        #expect(handledURLBatches.isEmpty)

        router.setHandler { urls in
            handledURLBatches.append(urls)
        }

        #expect(handledURLBatches == [[URL(fileURLWithPath: "/tmp/early.wav")]])

        router.open([laterURL])

        #expect(handledURLBatches == [
            [URL(fileURLWithPath: "/tmp/early.wav")],
            [
                URL(fileURLWithPath: "/tmp/later.mp3"),
                URL(fileURLWithPath: "/tmp/third.m4a")
            ]
        ])
    }

    @MainActor
    @Test
    func appFileOpenRouterQueuesStreamingURLsUntilHandlerIsConfigured() {
        let router = AppFileOpenRouter()
        let earlyURL = URL(string: "takes://open-url?url=https%3A%2F%2Fmusic.apple.com%2Fus%2Falbum%2Fexample%2F123%3Fi%3D456")!
        let laterURL = URL(string: "takes://open-url?url=https%3A%2F%2Fopen.spotify.com%2Ftrack%2Fabc")!
        var handledURLBatches: [[String]] = []

        router.open([earlyURL])

        #expect(handledURLBatches.isEmpty)

        router.setStreamingURLHandler { urlStrings in
            handledURLBatches.append(urlStrings)
        }

        #expect(handledURLBatches == [["https://music.apple.com/us/album/example/123?i=456"]])

        router.open([laterURL])

        #expect(handledURLBatches == [
            ["https://music.apple.com/us/album/example/123?i=456"],
            ["https://open.spotify.com/track/abc"]
        ])
    }

    @Test
    func appOpenedURLResolverExtractsStreamingURLsFromTakesAutomationScheme() {
        let url = URL(string: "takes://open-url?url=https%3A%2F%2Fmusic.youtube.com%2Fwatch%3Fv%3Dabc")!

        #expect(AppOpenedURLResolver.streamingURLString(from: url) == "https://music.youtube.com/watch?v=abc")
        #expect(AppOpenedURLResolver.streamingURLStrings(from: [url]) == ["https://music.youtube.com/watch?v=abc"])
    }

    @Test
    func appOpenedURLResolverExtractsUnescapedStreamingURLFromTakesAutomationScheme() {
        let url = URL(string: "takes://open-url?url=https://www.youtube.com/watch?v=XPL_qGqSJxA")!

        #expect(AppOpenedURLResolver.streamingURLString(from: url) == "https://www.youtube.com/watch?v=XPL_qGqSJxA")
        #expect(AppOpenedURLResolver.streamingURLStrings(from: [url]) == ["https://www.youtube.com/watch?v=XPL_qGqSJxA"])
    }

    @Test
    func appOpenedURLResolverExtractsAudioFilesFromTakesAutomationScheme() {
        let url = URL(string: "takes://open-file?url=file%3A%2F%2F%2Ftmp%2Ffirst.wav&url=file%3A%2F%2F%2Ftmp%2Fsecond.m4a")!

        #expect(AppOpenedURLResolver.automationFileURLs(from: url) == [
            URL(fileURLWithPath: "/tmp/first.wav"),
            URL(fileURLWithPath: "/tmp/second.m4a")
        ])
        #expect(AppOpenedURLResolver.audioFileURLs(from: [url]) == [
            URL(fileURLWithPath: "/tmp/first.wav"),
            URL(fileURLWithPath: "/tmp/second.m4a")
        ])
    }

    @Test
    func appOpenedURLResolverRecursivelyFindsAudioFilesInFolders() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let nested = root.appending(path: "nested", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let directAudio = root.appending(path: "direct.wav")
        let ignoredText = root.appending(path: "notes.txt")
        let nestedAudio = nested.appending(path: "nested.m4a")
        let directInputAudio = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".mp3")
        try Data().write(to: directAudio)
        try Data().write(to: ignoredText)
        try Data().write(to: nestedAudio)
        try Data().write(to: directInputAudio)
        defer { try? FileManager.default.removeItem(at: directInputAudio) }

        let resolvedURLs = AppOpenedURLResolver.audioFileURLs(from: [root, directInputAudio])

        #expect(
            resolvedURLs.map { $0.resolvingSymlinksInPath() }
                == [directAudio, nestedAudio, directInputAudio].map { $0.resolvingSymlinksInPath() }
        )
    }

    @Test
    func appUsesSingleMainWindowPolicy() {
        #expect(TakesWindowPolicy.mainWindowID == "main")
        #expect(TakesWindowPolicy.replacesDefaultNewItemCommands)
    }
}

private actor StreamingURLCancellationRecorder {
    private(set) var didCancel = false

    func recordCancellation() {
        didCancel = true
    }

    /// Waits for the cancelled task to report in instead of assuming it lands
    /// within a fixed sleep. The cancellation normally arrives in well under a
    /// millisecond, but the whole suite runs bundles in parallel, and a busy
    /// machine can push the task's resumption past any deadline short enough
    /// to be worth waiting on.
    func waitForCancellation(timeout: Duration = .seconds(5)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !didCancel, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return didCancel
    }
}

@MainActor
private final class PlaylistTestDraggingInfo: NSObject, NSDraggingInfo {
    let draggingSource: Any?
    let draggingDestinationWindow: NSWindow? = nil
    let draggingSourceOperationMask: NSDragOperation = .move
    let draggingLocation: NSPoint = .zero
    let draggedImageLocation: NSPoint = .zero
    let draggedImage: NSImage? = nil
    let draggingPasteboard = NSPasteboard.withUniqueName()
    let draggingSequenceNumber = 0
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    let springLoadingHighlight: NSSpringLoadingHighlight = .none

    init(source: NSOutlineView) {
        draggingSource = source
    }

    func slideDraggedImage(to screenPoint: NSPoint) {}
    func resetSpringLoading() {}

    func enumerateDraggingItems(
        options: NSDraggingItemEnumerationOptions,
        for view: NSView?,
        classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
}
