import Foundation

/// Fast, deterministic evidence for automatic playlist grouping. Embedded
/// title and artist tags are preferred; the filename is used when tags are
/// absent. Duration can reject a match but never establishes one.
struct TrackMetadataMatcher {
    private struct Identity {
        let artist: String?
        let title: String
        let duration: TimeInterval
        let isExplicitEdit: Bool

        var isUsable: Bool {
            !title.isEmpty && duration.isFinite && duration > 0
        }
    }

    static func decision(
        between first: PlaylistVersion,
        and second: PlaylistVersion
    ) -> TrackSimilarityClusterDecision {
        decision(between: identity(for: first), and: identity(for: second))
    }

    static func canAttemptMatch(_ version: PlaylistVersion) -> Bool {
        identity(for: version).isUsable
    }

    private static func decision(
        between first: Identity,
        and second: Identity
    ) -> TrackSimilarityClusterDecision {
        guard first.isUsable, second.isUsable else { return .unknown }
        guard durationsAreCompatible(first, second) else { return .mismatch }

        switch (first.artist, second.artist) {
        case let (.some(lhs), .some(rhs)) where lhs != rhs:
            return .mismatch
        case (.some, .none), (.none, .some):
            return .unknown
        default:
            break
        }

        guard !first.title.isEmpty, !second.title.isEmpty else { return .unknown }
        if first.title == second.title { return .match }

        let longestCount = max(first.title.count, second.title.count)
        guard longestCount >= 6 else { return .mismatch }
        return similarity(first.title, second.title) >= 0.92 ? .match : .mismatch
    }

    private static func durationsAreCompatible(_ first: Identity, _ second: Identity) -> Bool {
        let difference = abs(first.duration - second.duration)
        let longest = max(first.duration, second.duration)
        let tolerance: TimeInterval
        if first.isExplicitEdit || second.isExplicitEdit {
            tolerance = max(120, longest * 0.35)
        } else {
            tolerance = max(5, longest * 0.05)
        }
        return difference <= tolerance
    }

    private static func identity(for version: PlaylistVersion) -> Identity {
        let filename = version.metadata.displayName.isEmpty
            ? version.file.storedURL.lastPathComponent
            : version.metadata.displayName
        let parsedFilename = parseFilename(filename)
        let taggedTitle = meaningful(version.metadata.title)
        let taggedArtist = meaningful(version.metadata.artist)
        let rawTitle = taggedTitle ?? parsedFilename.title
        let rawArtist = taggedArtist ?? parsedFilename.artist
        let normalizedTitle = normalizeTitle(rawTitle)

        return Identity(
            artist: rawArtist.map(normalizeArtist).flatMap { $0.isEmpty ? nil : $0 },
            title: normalizedTitle.base,
            duration: version.metadata.duration,
            isExplicitEdit: normalizedTitle.isExplicitEdit
        )
    }

    private static func meaningful(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func parseFilename(_ filename: String) -> (artist: String?, title: String) {
        var stem = (filename as NSString).deletingPathExtension
        stem = replacing(
            #"^\s*(?:cd|disc)?\s*\d{1,3}(?:[.-]\d{1,3})?\s*[-._)]*\s*"#,
            in: stem,
            with: ""
        )
        for separator in [" - ", " – ", " — "] {
            let parts = stem.components(separatedBy: separator)
            if parts.count >= 2,
               let artist = meaningful(parts.first) {
                return (artist, parts.dropFirst().joined(separator: separator))
            }
        }
        return (nil, stem)
    }

    private static func normalizeArtist(_ value: String) -> String {
        var result = folded(value)
        result = replacing(#"\b(?:feat|featuring|ft)\b.*$"#, in: result, with: "")
        result = result.replacingOccurrences(of: "&", with: " and ")
        result = wordsOnly(result)
        if result.hasPrefix("the ") { result.removeFirst(4) }
        return result
    }

    private static func normalizeTitle(_ value: String) -> (base: String, isExplicitEdit: Bool) {
        var result = folded(value)
        let explicitEditPatterns = [
            #"\bradio\s+edit\b"#,
            #"\bsingle\s+edit\b"#,
            #"\balbum\s+edit\b"#,
            #"\bextended\s+(?:mix|version|edit)\b"#,
            #"\b(?:19|20)\d{2}\s+(?:mono|stereo)\s+(?:mix|remix)\b"#,
            #"\b(?:mono|stereo)\s+(?:mix|remix|version)\b"#
        ]
        let isExplicitEdit = explicitEditPatterns.contains { contains($0, in: result) }

        let removablePatterns = explicitEditPatterns + [
            #"\b(?:feat|featuring|ft)\b.*$"#,
            #"\b(?:19|20)\d{2}\s+(?:re)?master(?:ed)?\b"#,
            #"\b(?:re)?master(?:ed)?(?:\s+(?:19|20)\d{2})?\b"#,
            #"\b(?:lossless|flac|wav|aiff|aac|mp3|opus)\b"#,
            #"\b\d{2,4}\s*kbps\b"#,
            #"\b(?:original\s+)?master\b"#
        ]
        for pattern in removablePatterns {
            result = replacing(pattern, in: result, with: " ")
        }
        return (wordsOnly(result), isExplicitEdit)
    }

    private static func folded(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
            .lowercased()
    }

    private static func wordsOnly(_ value: String) -> String {
        replacing(#"[^\p{L}\p{N}]+"#, in: value, with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func contains(_ pattern: String, in value: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }

    private static func replacing(_ pattern: String, in value: String, with replacement: String) -> String {
        value.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
    }

    private static func similarity(_ lhs: String, _ rhs: String) -> Double {
        let left = Array(lhs)
        let right = Array(rhs)
        let longest = max(left.count, right.count)
        guard longest > 0 else { return 1 }
        var previous = Array(0...right.count)
        for (leftIndex, leftCharacter) in left.enumerated() {
            var current = [leftIndex + 1]
            current.reserveCapacity(right.count + 1)
            for (rightIndex, rightCharacter) in right.enumerated() {
                current.append(min(
                    current[rightIndex] + 1,
                    previous[rightIndex + 1] + 1,
                    previous[rightIndex] + (leftCharacter == rightCharacter ? 0 : 1)
                ))
            }
            previous = current
        }
        return 1 - (Double(previous[right.count]) / Double(longest))
    }
}
