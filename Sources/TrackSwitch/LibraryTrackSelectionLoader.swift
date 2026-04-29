import AppKit
import Foundation

protocol LibraryTrackSelecting {
    func selectedTracks() throws -> LibraryTrackSelection
}

struct LibraryTrackSelection: Equatable {
    let urls: [URL]
    let failures: [ImportFailure]
}

struct LibraryTrackSelectionLoader: LibraryTrackSelecting {
    static let musicBundleIdentifier = "com.apple.Music"
    static let musicSelectionScript = """
    tell application id "com.apple.Music"
        set selectedTracks to selection
        if selectedTracks is {} then error "No track is selected in Music."

        set outputLines to {}
        repeat with selectedTrack in selectedTracks
            set trackIndex to index of selectedTrack as text
            try
                set trackLocation to location of selectedTrack
            on error
                set end of outputLines to (trackIndex & tab & "ERROR" & tab & "The selected Music track is not a local file.")
                set trackLocation to missing value
            end try

            if trackLocation is not missing value then
                set end of outputLines to (trackIndex & tab & "OK" & tab & POSIX path of trackLocation)
            end if
        end repeat

        set previousDelimiters to AppleScript's text item delimiters
        set AppleScript's text item delimiters to linefeed
        set outputText to outputLines as text
        set AppleScript's text item delimiters to previousDelimiters
    end tell

    return outputText
    """

    func selectedTracks() throws -> LibraryTrackSelection {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.musicBundleIdentifier) != nil else {
            throw PlaybackError.librarySelectionFailed("Music.app is required to use this button.")
        }

        guard !NSRunningApplication.runningApplications(withBundleIdentifier: Self.musicBundleIdentifier).isEmpty else {
            throw PlaybackError.librarySelectionFailed("Music must be open with a track selected.")
        }

        var errorInfo: NSDictionary?
        guard let appleScript = NSAppleScript(source: Self.musicSelectionScript) else {
            throw PlaybackError.librarySelectionFailed("Could not prepare the Music selection script.")
        }

        let result = appleScript.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let message = errorInfo[NSAppleScript.errorMessage] as? String
            throw PlaybackError.librarySelectionFailed(message ?? "Could not read the selected track from Music.")
        }

        guard let output = result.stringValue else {
            throw PlaybackError.librarySelectionFailed("Music did not return a local file path.")
        }

        return try Self.parseSelection(output)
    }

    static func parseSelectionOutput(_ output: String) throws -> [URL] {
        try parseSelection(output).urls
    }

    static func parseSelection(_ output: String) throws -> LibraryTrackSelection {
        let entries = output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !entries.isEmpty else {
            throw PlaybackError.librarySelectionFailed("Music did not return a local file path.")
        }

        let ordered = try entries.map(parseSelectionEntry(_:)).sorted { $0.index < $1.index }
        return LibraryTrackSelection(
            urls: ordered.compactMap(\.url),
            failures: ordered.compactMap(\.failure)
        )
    }

    private static func parseSelectionEntry(_ entry: String) throws -> (index: Int, url: URL?, failure: ImportFailure?) {
        let components = entry.split(separator: "\t", maxSplits: 2).map(String.init)
        guard
            components.count >= 2,
            let index = Int(components[0].trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            throw PlaybackError.librarySelectionFailed("Could not read the selected track order from Music.")
        }

        if components.count == 3 {
            return try parseTaggedSelectionEntry(index: index, status: components[1], value: components[2])
        }

        return parsePathSelectionEntry(index: index, path: components[1])
    }

    private static func parseTaggedSelectionEntry(
        index: Int,
        status: String,
        value: String
    ) throws -> (index: Int, url: URL?, failure: ImportFailure?) {
        let trimmedStatus = status.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        switch trimmedStatus {
        case "OK":
            return parsePathSelectionEntry(index: index, path: trimmedValue)
        case "ERROR":
            return (
                index,
                nil,
                ImportFailure(fileName: "Music item \(index)", message: trimmedValue.ifEmpty("The selected Music track is not a local file."))
            )
        default:
            throw PlaybackError.librarySelectionFailed("Could not read the selected track status from Music.")
        }
    }

    private static func parsePathSelectionEntry(
        index: Int,
        path: String
    ) -> (index: Int, url: URL?, failure: ImportFailure?) {
        let path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            return (
                index,
                nil,
                ImportFailure(fileName: "Music item \(index)", message: "Music did not return a local file path.")
            )
        }

        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return (
                index,
                nil,
                ImportFailure(url: url, message: "The selected track path does not exist on disk.")
            )
        }

        return (index, url, nil)
    }
}
