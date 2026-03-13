import AppKit
import Foundation

protocol LibraryTrackSelecting {
    func selectedTrackURL() throws -> URL
}

struct LibraryTrackSelectionLoader: LibraryTrackSelecting {
    static let musicBundleIdentifier = "com.apple.Music"
    static let musicSelectionScript = """
    tell application id "com.apple.Music"
        if selection is {} then error "No track is selected in Music."
        set selectedTrack to item 1 of selection
        try
            set trackLocation to location of selectedTrack
        on error
            error "The selected Music track is not a local file."
        end try
    end tell

    return POSIX path of trackLocation
    """

    func selectedTrackURL() throws -> URL {
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

        guard
            let path = result.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
            !path.isEmpty
        else {
            throw PlaybackError.librarySelectionFailed("Music did not return a local file path.")
        }

        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PlaybackError.librarySelectionFailed("The selected track path does not exist on disk.")
        }

        return url
    }
}
