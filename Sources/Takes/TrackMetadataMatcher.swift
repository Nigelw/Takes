import Foundation

/// Title matching for automatic playlist grouping, with a filename fallback.
struct TrackMetadataMatcher {
    private static let performanceMarker = #"(?<![\p{L}\p{N}])(?:live|demo|acoustic|cover|(?:alternate|alt)[\s_-]+take(?:[\s_#-]+\d+)?)(?![\p{L}\p{N}])"#

    static func decision(
        between first: PlaylistVersion,
        and second: PlaylistVersion
    ) -> TrackSimilarityClusterDecision {
        decision(between: normalizedTitle(for: first), and: normalizedTitle(for: second))
    }

    static func decision(
        between first: String,
        and second: String
    ) -> TrackSimilarityClusterDecision {
        guard !first.isEmpty, !second.isEmpty else { return .unknown }
        if first == second { return .match }

        let firstCount = first.count
        let secondCount = second.count
        let longestCount = max(firstCount, secondCount)
        guard longestCount >= 6,
              1 - Double(abs(firstCount - secondCount)) / Double(longestCount) >= 0.92 else { return .mismatch }
        return similarity(first, second) >= 0.92 ? .match : .mismatch
    }

    static func normalizedTitle(for version: PlaylistVersion) -> String {
        if let title = meaningful(version.metadata.title) {
            return normalizeTitle(removingPerformanceDescriptions(from: folded(title)))
        }
        let filename = version.metadata.displayName.isEmpty
            ? version.file.storedURL.lastPathComponent
            : version.metadata.displayName
        let stem = folded((filename as NSString).deletingPathExtension)
        return normalizeTitle(titleFromFilenameStem(removingPerformanceDescriptions(from: stem)))
    }

    private static func meaningful(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func titleFromFilenameStem(_ filenameStem: String) -> String {
        let stem = replacing(
            #"^\s*(?:cd|disc)?\s*\d{1,3}(?:[.-]\d{1,3})?\s*[-._)]*\s*"#,
            in: filenameStem,
            with: ""
        )
        for separator in [" - ", " – ", " — "] {
            let parts = stem.components(separatedBy: separator)
            if parts.count >= 2, meaningful(parts.first) != nil {
                return parts.dropFirst().joined(separator: separator)
            }
        }
        return stem
    }

    private static func removingPerformanceDescriptions(from title: String) -> String {
        let annotation = #"(?:\([^()]*\)|\[[^\[\]]*\])"#
        let performanceAnnotation = #"(?:\([^()]*\#(performanceMarker)[^()]*\)|\[[^\[\]]*\#(performanceMarker)[^\[\]]*\])"#
        // Allow other trailing annotations, such as a remaster credit, after a performance description.
        let trailingPerformanceAnnotation = #"\#(performanceAnnotation)(?=(?:\s*\#(annotation))*\s*$)"#
        return replacing(trailingPerformanceAnnotation, in: title, with: " ")
    }

    private static func normalizeTitle(_ value: String) -> String {
        var result = value
        let removablePatterns = [
            performanceMarker,
            #"\bradio\s+edit\b"#,
            #"\bsingle\s+edit\b"#,
            #"\balbum\s+edit\b"#,
            #"\bextended\s+(?:mix|version|edit)\b"#,
            #"\b(?:19|20)\d{2}\s+(?:mono|stereo)\s+(?:mix|remix)\b"#,
            #"\b(?:mono|stereo)\s+(?:mix|remix|version)\b"#,
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
        return wordsOnly(result)
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
