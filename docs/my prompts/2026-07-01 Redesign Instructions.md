I want you to implement a visual overhaul of the Takes UI. Our goal is for it to feel like the best indie macOS apps (Flexibits, Panic, Cultured Code etc). Use these apps as visual inspiration. Sweat all the tiny details and make everything feel super premium.

To guide the redesign, I've created a directory of reference designs that we'll refer to in these instructions: `docs/redesign references`. The most important design is this rough sketch of the window layout: `Takes v4 UI Sketch.png`. We'll use this as a wireframe to anchor the layout that our visual design decisions sit on top of.

Let's break the redesign into these milestones:
1. Overall Design
2. Transport Bar
3. Timeline Header
4. Track Rows

Come up with a plan for the design and implementation of each of these milestones. Ask any clarifying questions as you work on it; I'd like to guide this process closely. Once a milestone is ready for testing, I'll review it and provide feedback on fixes. We'll get each milestone correct before moving to the next one.

Here are detailed notes on each milestone:

## Overall Design
- The current design has a border around all elements. Let's move to a full-bleed design, where components extend to the edges of the window.
- Let's unify UI colors around a primary and secondary color. The primary color will be used to show e.g. the active track and active buttons. The secondary color will be used for things like the playhead and loop selection highlight.
- The primary color should be based on the purple used in the app's icon, or perhaps the purple used in the `UI Colors.png` image. Use your best judgement for the secondary color.

## Transport Bar
- I want to visually unify the window titlebar with the transport bar. Refer to `Visual Concept.png` for what I mean in terms of structure (not necessarily visual design). 
- Replace the current "Play" and "Switch Track" text buttons with inviting icon-based buttons. Find an appropriate SFSymbol to use to represent Switch Track.
- The elapsed/total time display should be visually striking, an inset to look like a digital readout on a piece of physical hardware.
- The repeat toggle should match the Switch Track button in style.

## Timeline Header
- The track list header and timeline ruler should sit directly on top of the track rows.
- The timeline ruler should have numbers on top and notches below, like the Fission timeline ruler.
- There should be a playhead widget that sits on top of the notches and is connected to the playhead line that extends down over the waveforms.
-  See `Main Content Area.png`, `Visual Concept.png`, and `fission-timeline-ruler.jpg` for design inspiration of all these elements.

## Track Rows
- Each row consists of its Track Info and Waveform Lane. These currently look like discrete components, but they should be visually unified. The Track Info should anchor the row, in the same way that a frozen column in Excel or Google Sheets anchors its scrollable row.
- The Track Info is currently taller than its corresponding waveform row. Make the heights uniform.
- When a row is active, it should gain a highlight that encompasses the Track Info and Waveform Lane.
- The active row state should draw from the primary color.
- Inactive rows should have gray waveforms.
- Track info area should show an index number, filename as the primary title, and metadata as secondary info. Refer to the wireframe.
- The Offset field should use a standard stepper control. Get rid of the reset button.
- Get rid of the gear icon with the gain control popover.
- Make the trash icon show on hover.
- The background of the Waveform Lanes should have faint lines corresponding to the major tick marks from the Timeline Ruler.