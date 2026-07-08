## good
- waveform and timeline+playhead zooming are back in sync
- track info area interactions are no longer blocked when zoomed in
- dragging playhead & loop selection handles is buttery smooth

## decent
- vertical scroll during initial waveform render is improved. it's not buttery smooth but it's good enough that we can focus on other items for now

## bad
- when zooming you can now see scaled low-res waveforms before high res renders replace them. when zooming out you can see blank timeline areas before renders pop in. this looks cheap. high priority is finding a solution to keeping waveforms looking good & performant during zoom
- when 20+ tracks are loaded, zoom performance doesn't improve if i resize the window shorter so that only 1 track is visible. suggests to me that we're rendering waveforms of tracks that are off-screen. can we not do this, seems like it would be a big perf win?

## ideas
- is there some other overall approach to rendering waveforms we haven't considered? using garageband, their waveform rendering while zooming and scrolling has incredibly high frame rates even with 20 tracks loaded. what do apps like that do that we're not?
- initial waveform render: let's try loading one at a time. empty lanes get some kind of nice "pending" visual indication while they wait their turn to render. may allow UI to remain responsive during render, and gives priority to files at the top of the list, which you can see, instead of giving equal priority to those hidden below the fold