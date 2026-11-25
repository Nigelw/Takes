import Foundation
import Testing
@testable import Takes

struct TrackSimilarityClusteringTests {
    typealias Clusterer = TrackSimilarityClusterer<String, String>

    @Test
    func positiveEdgesFormComponentsAcrossUnknownEdges() {
        let result = Clusterer().cluster(
            incoming: ["a", "b", "c"],
            evidence: [
                evidence("a", "b", .match),
                evidence("b", "c", .match),
                evidence("a", "c", .unknown)
            ]
        )

        #expect(result.newGroups == [["a", "b", "c"]])
        #expect(result.existingAssignments.isEmpty)
    }

    @Test
    func mismatchInsidePositiveComponentVetoesTheMerge() {
        let result = Clusterer().cluster(
            incoming: ["a", "b", "c"],
            evidence: [
                evidence("a", "b", .match),
                evidence("b", "c", .match),
                evidence("a", "c", .mismatch)
            ]
        )

        #expect(result.newGroups == [["a"], ["b"], ["c"]])
    }

    @Test
    func membershipIsIndependentOfEvidenceTraversalAndPresentationFollowsInputOrder() {
        let forward = Clusterer().cluster(
            incoming: ["a", "b", "c", "d"],
            evidence: [
                evidence("a", "b", .match),
                evidence("c", "d", .match),
                evidence("b", "c", .unknown)
            ]
        )
        let reversed = Clusterer().cluster(
            incoming: ["d", "c", "b", "a"],
            evidence: [
                evidence("b", "c", .unknown),
                evidence("c", "d", .match),
                evidence("a", "b", .match)
            ]
        )

        let forwardMembership = forward.newGroups.map { Set($0) }
        #expect(forwardMembership.count == 2)
        #expect(forwardMembership.contains(Set(["a", "b"])))
        #expect(forwardMembership.contains(Set(["c", "d"])))
        #expect(reversed.newGroups == [["d", "c"], ["b", "a"]])
    }

    @Test
    func ambiguousExistingDestinationsLeaveTheWholeComponentNew() {
        let result = Clusterer().cluster(
            incoming: ["a", "b"],
            evidence: [
                evidence("a", "x1", .match),
                evidence("b", "x1", .match),
                evidence("a", "y1", .match),
                evidence("b", "y1", .match),
                evidence("a", "b", .match)
            ],
            existingGroups: [
                .init(id: "x", versionIDs: ["x1"]),
                .init(id: "y", versionIDs: ["y1"])
            ]
        )

        #expect(result.newGroups == [["a", "b"]])
        #expect(result.existingAssignments.isEmpty)
    }

    @Test
    func partialExistingMatchDoesNotSplitAConnectedComponent() {
        let result = Clusterer().cluster(
            incoming: ["a", "b"],
            evidence: [
                evidence("a", "b", .match),
                evidence("a", "x1", .match)
            ],
            existingGroups: [.init(id: "x", versionIDs: ["x1"])]
        )

        #expect(result.newGroups == [["a", "b"]])
        #expect(result.existingAssignments.isEmpty)
    }

    @Test
    func heterogeneousExistingItemMismatchVetoesAdmission() {
        let result = Clusterer().cluster(
            incoming: ["incoming"],
            evidence: [
                evidence("incoming", "known", .match),
                evidence("incoming", "unrelated", .mismatch)
            ],
            existingGroups: [.init(id: "mixed", versionIDs: ["known", "unrelated"])]
        )

        #expect(result.newGroups == [["incoming"]])
        #expect(result.existingAssignments.isEmpty)
    }

    @Test
    func missingExistingEvidenceCannotAdmitAnIncomingTrack() {
        let result = Clusterer().cluster(
            incoming: ["incoming"],
            evidence: [],
            existingGroups: [.init(id: "existing", versionIDs: ["old"])]
        )

        #expect(result.newGroups == [["incoming"]])
        #expect(result.existingAssignments.isEmpty)
    }

    @Test
    func capacityPlacesOverflowInAnOrderedNewGroup() {
        let result = Clusterer().cluster(
            incoming: ["a", "b", "c"],
            evidence: [
                evidence("a", "b", .match),
                evidence("b", "c", .match),
                evidence("a", "x1", .match),
                evidence("b", "x1", .match),
                evidence("c", "x1", .match)
            ],
            existingGroups: [.init(id: "existing", versionIDs: ["x1"], availableCapacity: 2)]
        )

        #expect(result.existingAssignments == [.init(groupID: "existing", members: ["a", "b"])])
        #expect(result.newGroups == [["c"]])
        #expect(result.didOverflowCapacity)
    }

    @Test
    func mismatchPreventsSeparateComponentsFromJoiningTheSameExistingItem() {
        let result = Clusterer().cluster(
            incoming: ["a", "b"],
            evidence: [
                evidence("a", "existing", .match),
                evidence("b", "existing", .match),
                evidence("a", "b", .mismatch)
            ],
            existingGroups: [.init(id: "group", versionIDs: ["existing"])]
        )

        #expect(result.existingAssignments == [.init(groupID: "group", members: ["a"])])
        #expect(result.newGroups == [["b"]])
    }

    @Test
    func fullMatchingItemStillMakesExistingDestinationAmbiguous() {
        let result = Clusterer().cluster(
            incoming: ["incoming"],
            evidence: [
                evidence("incoming", "full-version", .match),
                evidence("incoming", "open-version", .match)
            ],
            existingGroups: [
                .init(id: "full", versionIDs: ["full-version"], availableCapacity: 0),
                .init(id: "open", versionIDs: ["open-version"], availableCapacity: 1)
            ]
        )

        #expect(result.existingAssignments.isEmpty)
        #expect(result.newGroups == [["incoming"]])
        #expect(!result.didOverflowCapacity)
    }

    @Test
    func conflictingDuplicateEvidenceResolvesConservatively() {
        let result = Clusterer().cluster(
            incoming: ["a", "b"],
            evidence: [
                evidence("a", "b", .match),
                evidence("b", "a", .unknown),
                evidence("a", "b", .mismatch)
            ]
        )

        #expect(result.newGroups == [["a"], ["b"]])
    }

    @Test
    func duplicateIncomingIDsAreIgnoredAndEmptyInputIsStable() {
        let duplicateResult = Clusterer().cluster(incoming: ["a", "a", "b"], evidence: [])
        let emptyResult = Clusterer().cluster(incoming: [], evidence: [])

        #expect(duplicateResult.newGroups == [["a"], ["b"]])
        #expect(emptyResult.newGroups.isEmpty)
        #expect(emptyResult.existingAssignments.isEmpty)
    }

    private func evidence(
        _ first: String,
        _ second: String,
        _ decision: TrackSimilarityClusterDecision
    ) -> TrackSimilarityClusterEvidence<String> {
        TrackSimilarityClusterEvidence(first: first, second: second, decision: decision)
    }
}
