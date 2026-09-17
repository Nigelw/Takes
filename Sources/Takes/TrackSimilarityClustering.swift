import Foundation

/// The reduced outcome needed by playlist grouping. Missing or inconclusive
/// metadata maps to ``unknown`` and cannot create a group.
enum TrackSimilarityClusterDecision: Equatable, Sendable {
    case match
    case mismatch
    case unknown
}

/// An unordered pair of track identifiers. Pair equality deliberately ignores
/// endpoint order so analyzer output can be consumed in any traversal order.
struct TrackSimilarityClusterPair<TrackID: Hashable & Sendable>: Hashable, Sendable {
    let first: TrackID
    let second: TrackID

    init(_ first: TrackID, _ second: TrackID) {
        self.first = first
        self.second = second
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        (lhs.first == rhs.first && lhs.second == rhs.second)
            || (lhs.first == rhs.second && lhs.second == rhs.first)
    }

    func hash(into hasher: inout Hasher) {
        // Both operations are commutative. Hash collisions are harmless and
        // equality above still performs the exact endpoint comparison.
        hasher.combine(first.hashValue &+ second.hashValue)
        hasher.combine(first.hashValue ^ second.hashValue)
    }
}

/// Pair evidence supplied by the metadata matcher or a deterministic test
/// double. Evidence for a pair may be repeated; the clusterer resolves
/// conflicting records conservatively, with mismatch taking precedence.
struct TrackSimilarityClusterEvidence<TrackID: Hashable & Sendable>: Sendable {
    let pair: TrackSimilarityClusterPair<TrackID>
    let decision: TrackSimilarityClusterDecision

    init(
        first: TrackID,
        second: TrackID,
        decision: TrackSimilarityClusterDecision
    ) {
        self.pair = TrackSimilarityClusterPair(first, second)
        self.decision = decision
    }
}

/// A current playlist item used as a possible destination for an imported
/// cluster. `availableCapacity` is the number of versions that can still be
/// admitted; pass `Int.max` when the caller has no practical limit.
struct TrackSimilarityExistingGroup<
    GroupID: Hashable & Sendable,
    TrackID: Hashable & Sendable
>: Sendable {
    let id: GroupID
    let versionIDs: [TrackID]
    let availableCapacity: Int

    init(id: GroupID, versionIDs: [TrackID], availableCapacity: Int = .max) {
        self.id = id
        self.versionIDs = versionIDs
        self.availableCapacity = max(0, availableCapacity)
    }
}

struct TrackSimilarityExistingAssignment<
    GroupID: Hashable & Sendable,
    TrackID: Hashable & Sendable
>: Sendable, Equatable where GroupID: Equatable, TrackID: Equatable {
    let groupID: GroupID
    let members: [TrackID]
}

/// The deterministic organization proposal produced for one import batch.
/// Existing items are never merged or reordered by this value.
struct TrackSimilarityClusteringResult<
    GroupID: Hashable & Sendable,
    TrackID: Hashable & Sendable
>: Sendable, Equatable where GroupID: Equatable, TrackID: Equatable {
    let newGroups: [[TrackID]]
    let existingAssignments: [TrackSimilarityExistingAssignment<GroupID, TrackID>]
    let didOverflowCapacity: Bool

    var newItemMembers: [[TrackID]] { newGroups }
}

/// Builds conservative playlist groups from pairwise similarity decisions.
///
/// Positive edges define candidate connected components. Unknown edges do not
/// prevent a component from forming. A mismatch anywhere inside a candidate
/// component vetoes that merge and leaves its members as singleton groups.
/// Existing-item admission is all-or-nothing per component, except that an
/// admitted component may be split at an item's remaining capacity; overflow
/// is returned as a new group.
struct TrackSimilarityClusterer<
    GroupID: Hashable & Sendable,
    TrackID: Hashable & Sendable
>: Sendable {
    init() {}

    func cluster(
        incoming: [TrackID],
        evidence: [TrackSimilarityClusterEvidence<TrackID>],
        existingGroups: [TrackSimilarityExistingGroup<GroupID, TrackID>] = []
    ) -> TrackSimilarityClusteringResult<GroupID, TrackID> {
        let orderedIncoming = uniquePreservingOrder(incoming)
        guard !orderedIncoming.isEmpty else {
            return TrackSimilarityClusteringResult(
                newGroups: [],
                existingAssignments: [],
                didOverflowCapacity: false
            )
        }

        let order = Dictionary(uniqueKeysWithValues: orderedIncoming.enumerated().map { ($1, $0) })
        let incomingSet = Set(orderedIncoming)
        let decisions = canonicalDecisions(evidence)

        var adjacency = Dictionary(uniqueKeysWithValues: orderedIncoming.map { ($0, Set<TrackID>()) })
        for (pair, decision) in decisions where decision == .match {
            guard incomingSet.contains(pair.first), incomingSet.contains(pair.second),
                  pair.first != pair.second else { continue }
            adjacency[pair.first, default: []].insert(pair.second)
            adjacency[pair.second, default: []].insert(pair.first)
        }

        let components = connectedComponents(
            orderedIncoming: orderedIncoming,
            order: order,
            adjacency: adjacency,
            decisions: decisions
        )

        var remainingCapacity = existingGroups.map(\.availableCapacity)
        var assignmentMembers = Array(repeating: [TrackID](), count: existingGroups.count)
        var newGroupsWithOrder: [(firstIndex: Int, members: [TrackID])] = []
        var didOverflowCapacity = false

        for component in components {
            // Ambiguity is a property of evidence, not available capacity. A
            // full matching item must still prevent attachment to another
            // matching item.
            let candidates = existingGroups.indices.filter { index in
                qualifiesForExistingGroup(
                        component,
                        group: existingGroups[index],
                        decisions: decisions
                    )
                    && isCompatible(
                        component.members,
                        with: assignmentMembers[index],
                        decisions: decisions
                    )
            }

            guard candidates.count == 1, let destinationIndex = candidates.first else {
                newGroupsWithOrder.append((component.firstIndex, component.members))
                continue
            }

            guard remainingCapacity[destinationIndex] > 0 else {
                didOverflowCapacity = true
                newGroupsWithOrder.append((component.firstIndex, component.members))
                continue
            }

            let admittedCount = min(remainingCapacity[destinationIndex], component.members.count)
            guard admittedCount > 0 else {
                newGroupsWithOrder.append((component.firstIndex, component.members))
                continue
            }
            let admitted = Array(component.members.prefix(admittedCount))
            assignmentMembers[destinationIndex].append(contentsOf: admitted)
            remainingCapacity[destinationIndex] -= admittedCount

            if admittedCount < component.members.count {
                didOverflowCapacity = true
                let overflow = Array(component.members.dropFirst(admittedCount))
                newGroupsWithOrder.append((
                    order[overflow[0]] ?? component.firstIndex,
                    overflow
                ))
            }
        }

        let assignments: [TrackSimilarityExistingAssignment<GroupID, TrackID>] = existingGroups.indices.compactMap { index in
            guard !assignmentMembers[index].isEmpty else { return nil }
            return TrackSimilarityExistingAssignment(
                groupID: existingGroups[index].id,
                members: assignmentMembers[index].sorted { (order[$0] ?? .max) < (order[$1] ?? .max) }
            )
        }

        let newGroups = newGroupsWithOrder
            .sorted { lhs, rhs in lhs.firstIndex < rhs.firstIndex }
            .map(\.members)
        return TrackSimilarityClusteringResult(
            newGroups: newGroups,
            existingAssignments: assignments,
            didOverflowCapacity: didOverflowCapacity
        )
    }

    private func uniquePreservingOrder(_ incoming: [TrackID]) -> [TrackID] {
        var seen = Set<TrackID>()
        return incoming.filter { seen.insert($0).inserted }
    }

    private func canonicalDecisions(
        _ evidence: [TrackSimilarityClusterEvidence<TrackID>]
    ) -> [TrackSimilarityClusterPair<TrackID>: TrackSimilarityClusterDecision] {
        var decisions: [TrackSimilarityClusterPair<TrackID>: TrackSimilarityClusterDecision] = [:]
        for record in evidence {
            let pair = record.pair
            guard pair.first != pair.second else { continue }
            if let previous = decisions[pair] {
                decisions[pair] = conservativeDecision(previous, record.decision)
            } else {
                decisions[pair] = record.decision
            }
        }
        return decisions
    }

    private func conservativeDecision(
        _ lhs: TrackSimilarityClusterDecision,
        _ rhs: TrackSimilarityClusterDecision
    ) -> TrackSimilarityClusterDecision {
        if lhs == .mismatch || rhs == .mismatch { return .mismatch }
        if lhs == .match || rhs == .match { return .match }
        return .unknown
    }

    private func connectedComponents(
        orderedIncoming: [TrackID],
        order: [TrackID: Int],
        adjacency: [TrackID: Set<TrackID>],
        decisions: [TrackSimilarityClusterPair<TrackID>: TrackSimilarityClusterDecision]
    ) -> [(firstIndex: Int, members: [TrackID])] {
        var visited = Set<TrackID>()
        var components: [(firstIndex: Int, members: [TrackID])] = []

        for start in orderedIncoming where !visited.contains(start) {
            var stack = [start]
            var members: [TrackID] = []
            visited.insert(start)
            while let current = stack.popLast() {
                members.append(current)
                let neighbors = (adjacency[current] ?? []).sorted { (order[$0] ?? .max) > (order[$1] ?? .max) }
                for neighbor in neighbors where visited.insert(neighbor).inserted {
                    stack.append(neighbor)
                }
            }
            members.sort { (order[$0] ?? .max) < (order[$1] ?? .max) }

            var hasVeto = false
            if members.count > 1 {
                for leftIndex in 0..<(members.count - 1) where !hasVeto {
                    for rightIndex in (leftIndex + 1)..<members.count {
                        if decisions[TrackSimilarityClusterPair(members[leftIndex], members[rightIndex])] == .mismatch {
                            hasVeto = true
                            break
                        }
                    }
                }
            }
            if hasVeto && members.count > 1 {
                components.append(contentsOf: members.enumerated().map { (index, member) in
                    (order[member] ?? index, [member])
                })
            } else {
                components.append((order[members[0]] ?? 0, members))
            }
        }
        return components.sorted { lhs, rhs in lhs.firstIndex < rhs.firstIndex }
    }

    private func qualifiesForExistingGroup(
        _ component: (firstIndex: Int, members: [TrackID]),
        group: TrackSimilarityExistingGroup<GroupID, TrackID>,
        decisions: [TrackSimilarityClusterPair<TrackID>: TrackSimilarityClusterDecision]
    ) -> Bool {
        for member in component.members {
            var hasWitness = false
            for existingVersion in group.versionIDs {
                switch decisions[TrackSimilarityClusterPair(member, existingVersion)] {
                case .mismatch:
                    return false
                case .match:
                    hasWitness = true
                case .unknown, .none:
                    break
                }
            }
            guard hasWitness else { return false }
        }
        return true
    }

    private func isCompatible(
        _ incoming: [TrackID],
        with alreadyAssigned: [TrackID],
        decisions: [TrackSimilarityClusterPair<TrackID>: TrackSimilarityClusterDecision]
    ) -> Bool {
        for first in incoming {
            for second in alreadyAssigned where
                decisions[TrackSimilarityClusterPair(first, second)] == .mismatch {
                return false
            }
        }
        return true
    }
}
