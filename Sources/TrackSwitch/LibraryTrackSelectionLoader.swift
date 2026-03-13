import AppKit
import Foundation

protocol LibraryTrackSelecting {
    func selectedTrackURLs() throws -> [URL]
}

struct LibraryTrackSelectionLoader: LibraryTrackSelecting {
    static let musicBundleIdentifier = "com.apple.Music"
    static let musicSelectionScript = """
    tell application id "com.apple.Music"
        set selectedTracks to selection
        if selectedTracks is {} then error "No track is selected in Music."
        if (count of selectedTracks) > 2 then error "Select one or two tracks in Music."

        set outputLines to {}
        repeat with selectedTrack in selectedTracks
            try
                set trackLocation to location of selectedTrack
            on error
                error "The selected Music track is not a local file."
            end try

            set end of outputLines to ((index of selectedTrack as text) & tab & POSIX path of trackLocation)
        end repeat

        set previousDelimiters to AppleScript's text item delimiters
        set AppleScript's text item delimiters to linefeed
        set outputText to outputLines as text
        set AppleScript's text item delimiters to previousDelimiters
    end tell

    return outputText
    """

    func selectedTrackURLs() throws -> [URL] {
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

        return try Self.parseSelectionOutput(output)
    }

    static func parseSelectionOutput(_ output: String) throws -> [URL] {
        let entries = output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !entries.isEmpty else {
            throw PlaybackError.librarySelectionFailed("Music did not return a local file path.")
        }

        guard entries.count <= 2 else {
            throw PlaybackError.librarySelectionFailed("Select one or two tracks in Music.")
        }

        let ordered = try entries.map(parseSelectionEntry(_:)).sorted { $0.index < $1.index }
        return ordered.map { $0.url }
    }

    private static func parseSelectionEntry(_ entry: String) throws -> (index: Int, url: URL) {
        let components = entry.split(separator: "\t", maxSplits: 1).map(String.init)
        guard
            components.count == 2,
            let index = Int(components[0].trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            throw PlaybackError.librarySelectionFailed("Could not read the selected track order from Music.")
        }

        let path = components[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            throw PlaybackError.librarySelectionFailed("Music did not return a local file path.")
        }

        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PlaybackError.librarySelectionFailed("The selected track path does not exist on disk.")
        }

        return (index, url)
    }
}
