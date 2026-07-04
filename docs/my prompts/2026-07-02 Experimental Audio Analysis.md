We're going to implement an experimental audio analysis feature. The goal of the feature is to analyze the similarities/differences between tracks. When I compare tracks, I usually want to know which sounds better. This often breaks down into looking at properties such as:

- is one mastered louder or quieter?
- does one have more bass/midrange/treble?
- does one sound clearer or muffled?
- is there background hiss, possibly indicating a vinyl or other analog source?
- does one have poorer quality encoding (due to re-encoding, or an older codec implementation)?
- is a lossless file actually a reencode from a lossy source (e.g. a lossless file with a 16 kHz cutoff usually indicates it was originally a lossy file that's been transcoded)

I'd like you to investigate a feature that tries to determine these properties.

This work involves several pieces:
1. sourcing test files known to meet these conditions, so we have data which can be used to benchmark the implementation
2. researching & implementing algorithm(s) to analyze audio
3. presentation of results in a UI, ideally alongside a visual representation (frequency cutoff could use a spectrogram for example)

For the most part you should just use your best judgment, not ask me questions, unless you get hard stuck - I want you to show me what you are capable of. Build it and verify the functionality if you can. Use the web to download audio files, or local tools to make/encode ones.

Make commits as you go, keep yourself organized with docs so you don't lose track. Write clean, maintainable, modular code

An initial version of the feature can just work on one file at a time. We can worry about comparative analysis later.

Because this is experimental let's put it in a new window and not worry about integrating it into the main UI yet. Add it to the debug menu with the name "Analysis" and keyboard shortcut cmd+opt+z.