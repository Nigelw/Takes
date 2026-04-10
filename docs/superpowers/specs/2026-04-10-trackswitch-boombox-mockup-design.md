# TrackSwitch Boombox Mockup Design

Date: 2026-04-10

## Goal

Create a new Figma mockup for TrackSwitch that keeps the app's current comparison workflow intact while reimagining the interface with a modern visual language inspired by 1980s dual-tape boomboxes.

The mockup should feel like serious audio equipment rather than novelty retro skeuomorphism.

## Current Product Constraints

The current app supports:

- Two track sources: Track A and Track B
- Shared playback transport
- Instant switching between active playback sources
- Gain controls for both tracks
- Offset control for Track B
- File loading and Music.app import for each track

The mockup should preserve those core behaviors while rearranging the layout for stronger visual hierarchy.

## Explored Directions

### 1. Neutral Metal

Use brushed metallic surfaces, restrained amber indicators, and subtle cassette-window references.

Pros:

- Conservative and broadly usable
- Feels premium and mature
- Lower visual risk

Cons:

- Less distinctive
- May underdeliver on the requested boombox inspiration

### 2. Saturated Retro

Use smoked-glass panels, cobalt and orange accents, bright transport indicators, and stronger cassette-era material cues while keeping the overall layout modern.

Pros:

- More memorable
- Better expresses the 1980s-boombox inspiration
- Creates clearer active/inactive visual states

Cons:

- Higher styling risk if overdone
- Needs tighter restraint to avoid looking playful instead of precise

### Recommendation

Use the Saturated Retro direction with disciplined geometry and a clean layout. This best matches the requested inspiration while still allowing the mockup to read as a focused desktop audio tool.

## Approved Layout

### Top Control Area

The transport moves to the top and becomes the primary control console.

This area contains:

- Play / pause
- Rewind
- Switch playback
- Time display
- Shared scrubber / transport slider

Visually, this top bar should read like an illuminated equipment control panel with smoked-glass influence and clear status emphasis.

### Track Area

The Track A and Track B sections sit beneath the transport in two large deck panels.

Each track panel includes:

- Track label
- File name
- Metadata summary
- Load action
- Music import action
- Clear active or inactive state

The currently audible track must have a visibly stronger state than the inactive one.

### Embedded Utility Controls

Remove the separate lower tuning modules from the layout.

Replace them with embedded controls:

- Gain becomes a per-track volume popup triggered inside each track panel
- Offset becomes an additional inline control embedded inside the Track B panel only

This keeps utility controls closer to the source they affect and removes the disconnected lower control region.

## Visual System

### Overall Character

The interface should feel like a modern reinterpretation of a dual-tape boombox faceplate:

- Dark chassis
- Smoked-glass display surfaces
- Beveled deck cards
- Fine grille or texture accents used sparingly
- Cobalt and orange as primary accent colors

Avoid literal hardware reproduction such as exaggerated screws, oversized cassette art, or toy-like proportions.

### Color Direction

- Base surfaces: charcoal, graphite, dark navy-black
- Highlight color: hot orange for active playback and transport energy
- Secondary accent: electric cobalt for secondary controls and contrast
- Text: warm light neutrals rather than stark white

### Active State

The active track should stand out using a combination of:

- Brighter border or edge glow
- More illuminated deck header
- Higher-contrast cassette-window region
- Stronger status label or playback indicator

The inactive track should remain legible and available but visually quieter.

## Interaction Representation In The Mockup

This is a static mockup, but it should imply the following behaviors:

- Transport is global and always visually dominant
- Playback selection is obvious at a glance
- Gain is secondary and hidden until needed behind a compact volume affordance
- Offset is contextual to Track B and visually embedded in that panel

## Figma Deliverable

Create one polished desktop mockup frame that includes:

- Top transport console
- Two deck panels below
- Active-state treatment on one track
- Embedded Track B offset control
- Per-track volume affordance that suggests a popup

Optional if time allows:

- A second nearby variant frame showing the opposite track in the active state

## Success Criteria

The mockup succeeds if:

- It is clearly recognizable as TrackSwitch
- The layout hierarchy is stronger than the current app
- The boombox inspiration is evident without looking costume-like
- The active track is immediately obvious
- Gain and offset controls feel better integrated than in the current UI
