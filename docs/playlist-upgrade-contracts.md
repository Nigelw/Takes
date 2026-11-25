# Playlist implementation contracts

These boundaries implement the approved [specification](playlist-upgrade-spec.md).
They are internal interfaces, not a public API. Runtime integration follows the
workspace model; the existing comparison remains the app's entry point until
the coordinator and playlist UI are integrated together.

## Ownership and identity

`PlaylistWorkspace` owns ordered `PlaylistItem` values. Each item owns ordered
`PlaylistVersion` values, a selected version ID, and its comparison settings.
Version IDs become `SessionTrack.id` when preparing comparison. Grouping,
moving, reordering, restoration, and locating a file must retain those IDs.
File identity for duplicate checks remains standardized, symlink-resolved URL,
independent of version identity. Duplicate checks run again when imports commit.

Values contain metadata, file references, and adjustments only. They never own
audio files, engine nodes, tasks, or waveforms. The 32-version limit applies to
each item; no workspace item limit is introduced. Organization operations must
fail atomically and preserve supplied order.

When groups merge, retain the earliest group's configuration and translate
incoming offsets by `destinationReferenceOffset - sourceReferenceOffset`.
References are the groups' selected versions before mutation. Preserve gain.
The playing version, if included, becomes the result's selection. Splitting
resets the new item's offset and loop while preserving gain and identity.

## Coordinator and runtime boundary

The future `@MainActor @Observable PlaylistCoordinator` owns the workspace,
navigation, organization UndoManager transactions, import destinations, and
one `PlaybackController`. The controller continues to own the only audio engine.
The coordinator is the sole application-level import and transport entry point.
All view/menu/media-command entry points switch together at integration.

Runtime preparation accepts stable `SessionTrack` IDs and a comparison session
configuration. Prepare only one selected version in playlist mode, with zero
gain and offset and no comparison loop/blind state. Prepare only the current
item in comparison. Waveform decoding begins only for comparison versions.
Do not use `clearTracks()` as a navigation API: it currently deletes downloaded
files. Add a runtime-only replacement boundary when integrating the controller.

Before navigation or organization, capture current file time and copy comparison
edits back by version ID. Never copy blind-shuffled runtime order into persisted
version order. File time is `transport - offset`; comparison time is
`fileTime + offset`. Back clamps file time to the selected file's bounds.
Entering another item's comparison starts at its timeline beginning. Entering
the playing item preserves its version and position. Deselect a saved loop that
excludes the incoming position. Playing/paused state is transient and transfers
across navigation, but restoration always pauses.

Persisted listening position is always file seconds. Position checkpoints do
not mutate the observed workspace each frame. Comparison's transport anchors,
Core Animation motion, lane observation, and pre-queued wraps remain owned by
the existing controller.

## Asynchronous work

`PlaylistImportDestination` captures either the playlist or a specific item UUID
before any file picker, metadata lookup, Music selection, or download starts.
Navigation cannot redirect it. A deleted destination produces an explicit
failure rather than appending elsewhere. Undoing deletion restores the same ID.

`PlaylistRuntimeContext` identifies a runtime activation by an opaque UUID and
optional item ID. Each runtime replacement invalidates the previous context.
Loading, alignment, waveform, and schedule completions verify context plus
version identity before committing. Import operations use their captured
destination independently of runtime context; committing to an inactive item
must not alter the active engine.

## Persistence boundary

`PlaylistWorkspacePersisting` loads and saves versioned `PlaylistWorkspace`
snapshots asynchronously. Restoration distinguishes an absent snapshot from
successful restore, fallback recovery, and failure. A corrupt or newer schema
must not be treated as an empty workspace. Block automatic saves after a failed
restore until explicit recovery. Keep the unreadable files for recovery.

The implementation serializes writes, writes atomically, and retains a validated
last-known-good snapshot. Validate IDs, ownership, selected references, limits,
and finite timing/adjustment values before accepting a snapshot. Resolve file
bookmarks with a stored path fallback; unavailable files remain in the model.
Finish restoration before draining queued Finder/open events. Downloads live in
workspace-owned Application Support storage; cleanup considers workspace and
Undo history references and never removes original files.
