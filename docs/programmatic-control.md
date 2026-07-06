# Programmatic Control

This document explains the programmatic ways to open media in Takes.
It is written for novice programmers who are comfortable copying shell
commands but may not yet know how macOS app opening, file URLs, or custom URL
schemes work.

Takes currently has two public automation surfaces:

1. Opening the app with files through macOS:

   ```sh
   open -a "Takes.app" "$FILE"
   open -a "Takes.app" "$FILE_1" "$FILE_2"
   ```

2. Opening a custom `takes://` URL:

   ```sh
   open 'takes://open-url?url=<streaming URL>'
   open 'takes://open-file?url=<file URL>'
   open 'takes://open-file?url=<file 1 URL>&url=<file 2 URL>'
   ```

There are also launch-time options:

```sh
open -a "Takes.app" --args --appearance-theme dark
open -a "Takes.app" --args --default-window-layout
```

Those options are different from the media-opening commands. They control the
app's startup appearance or layout for that launch. They are not a general
command channel.

## Route 1: Open Files with macOS

The simplest way to script Takes is to ask macOS to open audio files with the
app:

```sh
open -a "Takes.app" "/Users/me/Music/take-a.wav" "/Users/me/Music/take-b.wav"
```

This uses the same mechanism as dragging files onto the app icon or choosing
Takes as the app to open a file.

You can also pass a folder:

```sh
open -a "Takes.app" "/Users/me/Music/session-folder"
```

When Takes receives a folder this way, it searches the folder for audio files
and opens the matching files.

Use this route when:

- You already have local audio files.
- You are writing a shell script.
- You do not need to open a streaming URL.
- You do not need to build a `takes://` URL by hand.

## Route 2: Open Custom `takes://` URLs

Takes also registers the `takes` URL scheme. That means macOS can send URLs
starting with `takes://` to Takes:

```sh
open 'takes://open-file?url=file:///Users/me/Music/take-a.wav'
```

A `takes://` URL has three main parts:

```text
takes://open-file?url=file:///Users/me/Music/take-a.wav
|       |         |
scheme  command   query parameter
```

- `takes` is the URL scheme registered by Takes.
- `open-file` is the command.
- `url=...` is the value being passed to that command.

### Open Local Files

Use `open-file` for one local file:

```sh
open 'takes://open-file?url=file:///Users/me/Music/take-a.wav'
```

The value after `url=` must be a file URL, not a normal shell path.

This is a shell path:

```text
/Users/me/Music/take-a.wav
```

This is a file URL:

```text
file:///Users/me/Music/take-a.wav
```

Use the same `open-file` command for more than one local file. Repeat the
`url` parameter once for each file:

```sh
open 'takes://open-file?url=file:///Users/me/Music/take-a.wav&url=file:///Users/me/Music/take-b.wav'
```

Takes reads all of the `url` parameters and opens the valid file URLs.

### Open a Streaming URL

Use `open-url` for a streaming page URL, such as a YouTube, Music, or Spotify
URL:

```sh
open 'takes://open-url?url=https://www.youtube.com/watch?v=abc123'
```

Internally, this follows the same path as the "Open Streaming URL" command in
the app. Takes shows the streaming URL sheet, starts reading metadata, downloads
audio through its streaming import pipeline, and then opens the downloaded audio
as a track.

## URL Encoding

URLs often contain characters that have special meaning inside another URL.
For example, `&` separates query parameters. If the streaming URL itself
contains `&`, it can confuse the outer `takes://` URL.

The safest approach is to percent-encode the value passed to `url=`.

Unencoded:

```sh
open 'takes://open-url?url=https://www.youtube.com/watch?v=abc123&list=xyz'
```

Encoded:

```sh
open 'takes://open-url?url=https%3A%2F%2Fwww.youtube.com%2Fwatch%3Fv%3Dabc123%26list%3Dxyz'
```

The encoded version is safer because Takes receives the full streaming URL as
one value.

Takes currently accepts some unencoded streaming URLs, but scripts should prefer
encoded values.

## Launch Options

Takes has command-line options for temporary launch-time setup. To override the appearance theme at launch:

```sh
open -a "Takes.app" --args --appearance-theme dark
open -a "Takes.app" --args --appearance-theme light
open -a "Takes.app" --args --appearance-theme system
```

The same option can also be written with an equals sign:

```sh
open -a "Takes.app" --args --appearance-theme=dark
```

To start with the default main window size and default track info column width:

```sh
open -a "Takes.app" --args --default-window-layout
```

Important details:

- These are read only when Takes starts.
- They do not permanently change the stored theme or normal-launch window layout.
- They are not part of the `takes://` URL scheme.
- They should be treated as launch options, not as runtime automation commands.

For example, this opens Takes with the dark theme for that launch:

```sh
open -a "Takes.app" --args --appearance-theme dark
```

If Takes is already running, launch arguments may not have the effect you expect,
because the app has already read its settings.

## What Happens Inside Takes

The file-opening routes meet inside the app.

Whether you use this:

```sh
open -a "Takes.app" "/Users/me/Music/take-a.wav"
```

or this:

```sh
open 'takes://open-file?url=file:///Users/me/Music/take-a.wav'
```

Takes eventually passes the file to the same import path. That shared path:

- ignores duplicate files that are already open;
- expands folders into audio files;
- skips non-audio files;
- enforces the app's track limit;
- applies the "align tracks on open" setting;
- preserves playback behavior when files are added while audio is playing.

Streaming URLs use a related but separate first step. Takes first resolves and
downloads the streaming audio, then passes the downloaded audio file into the
normal file import path.

## Which Route Should I Use?

Use `open -a "Takes.app" "$FILES"` for normal local files:

```sh
open -a "Takes.app" "$HOME/Music/take-a.wav" "$HOME/Music/take-b.wav"
```

Use `takes://open-url` for streaming URLs:

```sh
open 'takes://open-url?url=https%3A%2F%2Fwww.youtube.com%2Fwatch%3Fv%3Dabc123'
```

Use `takes://open-file` when another app, shortcut, or web-style automation
system needs to send Takes file URLs instead of shell file arguments:

```sh
open 'takes://open-file?url=file:///Users/me/Music/take-a.wav&url=file:///Users/me/Music/take-b.wav'
```

Use `--appearance-theme` only when launching Takes with a temporary appearance,
or `--default-window-layout` only when starting with the default window layout:

```sh
open -a "Takes.app" --args --appearance-theme dark
open -a "Takes.app" --args --default-window-layout
```

## Current Commands

| Command | Example | Purpose |
| --- | --- | --- |
| `open -a "Takes.app" "$FILE"` | `open -a "Takes.app" take.wav` | Open one or more local files through macOS. |
| `takes://open-file?url=<file URL>` | `open 'takes://open-file?url=file:///tmp/a.wav&url=file:///tmp/b.wav'` | Open one or more local files through the Takes URL scheme. |
| `takes://open-url?url=<streaming URL>` | `open 'takes://open-url?url=https%3A%2F%2Fwww.youtube.com%2Fwatch%3Fv%3Dabc123'` | Open a streaming URL. |
| `--appearance-theme <theme>` | `open -a "Takes.app" --args --appearance-theme dark` | Override the appearance theme for this launch. |
| `--default-window-layout` | `open -a "Takes.app" --args --default-window-layout` | Start this launch with the default window size and track info column width. |

## Current Limitations

- There is no single command that opens files and streaming URLs together.
- The `takes://` scheme currently opens media; it does not expose playback
  controls such as play, pause, seek, or switch track.
- The `takes://` scheme does not currently set launch options.
- Launch options are not runtime commands.
- The `takes://open-file` command accepts file URLs, not plain shell paths.
