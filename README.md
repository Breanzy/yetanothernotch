# yetanothernotch

**Islet**, yet another notch app for macOS. Hover over the notch to open a panel with your music, calendar, a focus timer, a mirror, clipboard history and a file shelf. It's light (about 15 MB of memory, ~0% CPU when idle), free and open source, and everything stays on your Mac.

Works on any Mac with **macOS 15 Sequoia or later**: Apple Silicon or Intel, with or without a notch. Without a notch (or on an external display) it shows as a small pill in the middle of the menu bar.

## Install

Paste this into Terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/Breanzy/yetanothernotch/main/install.sh | bash
```

It downloads the latest release into `/Applications` (or `~/Applications` if you can't write there) and opens it. Run the same line again any time to update.

<details>
<summary>Prefer not to pipe a script into bash?</summary>

1. Download `Islet.zip` from the [latest release](https://github.com/Breanzy/yetanothernotch/releases/latest) and unzip it.
2. Drag `Islet.app` into Applications and open it.
3. macOS will say it can't verify the developer (the app isn't signed with a paid Apple Developer ID). Open **System Settings → Privacy & Security**, scroll down and click **Open Anyway**. You only need to do this once.

Or read [`install.sh`](install.sh) first; it's short.
</details>

### Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/Breanzy/yetanothernotch/main/install.sh | bash -s -- --uninstall
```

This moves the app to the Trash. Your settings, clipboard history and anything still on the shelf stay in `~/Library/Application Support/Islet`, so check its `Shelf` folder for files you parked there before deleting it.

## Features
- **Hover to open.** The notch expands with a spring animation when you hover over it and collapses when you move away. Supports haptic feedback.
- **Now playing.** Shows artwork, title, artist and a progress bar you can click to seek, plus previous, play/pause and next buttons. Works with Apple Music and Spotify.
- **Live activity.** While music plays, the closed notch shows the album art and an equalizer tinted with the artwork's color.
- **Mirror.** Click the Mirror tile to see yourself through the FaceTime camera, or the ⤢ button for a big mirror that fills the island. The camera turns off when you click it again or when the notch closes.
- **Focus timer widget.** A home widget with a progress ring. Tap the ring or ▶︎ to start a 1-hour countdown (or the default length you set), tap again to pause; ↺ resets; the clock menu has 5–90 minute presets, +5 min and the default length. While it runs, the closed notch shows a ring and the time left, and it chimes when done.
- **Keep Awake.** A home tile that keeps your Mac from sleeping, dimming the display, starting the screen saver or auto-locking. Tap to turn it on or off; the clock menu sets a duration (indefinitely, 30 min, 1, 2, 4 or 8 hours). The menu bar icon becomes a cup while it's on, and it's also in the menu bar menu. It uses the standard power assertions (like `caffeinate`), so it can't block a manual lock or closing the lid.
- **Clipboard history.** An Alfred-style list with a preview of the selected item on the right (full text, image, link or file details, source app and when it was copied). Type to search, ↑/↓ to move, ↩ or click to copy, ⌘1–⌘9 to copy one of the first nine, ⌘⌫ to delete, Esc to clear the search. Right-click to pin. The clipboard opens in a bigger island by default for a longer list and larger preview; ⤡ shrinks it for that visit. Items password managers mark as secret are never saved. History is stored in `~/Library/Application Support/Islet` and is readable only by you.
- **Settings (⚙︎).** *General*: launch at login, menu bar icon. *Behavior*: open delay (how long to hover before it opens) and close delay (how long after you leave before it closes), both instant by default; **Animations**: how fast the island opens and closes and every other animation (Instant, Faster, Fast, Normal, Slow; *Instant* turns animations off so everything just appears); and haptic feedback. *Layout*: choose the home widgets (Now Playing, Calendar, Focus Timer, Mirror, Keep Awake) and top bar items (Shelf tab, Clipboard tab, Battery). Calendar and Battery are off by default. Switched-off features don't run at all: with **Now Playing** off, Islet stops checking Music and Spotify and the closed notch shows no album art or equalizer; with **Clipboard** off, nothing you copy is recorded and history is unloaded from memory (it stays on disk for when you turn it back on). *Shelf*: move files in or keep them in place, remove or keep items after dragging them out, and how long items stay (default 3 days). *Clipboard*: how long history is kept (default 1 week; pinned items stay) and Clear. *Appearance*: Classic, Liquid Glass, Clear Glass, Tinted Glass, Frosted and Aurora themes, plus a tint color.
- **Calendar.** A week strip plus that day's events, from EventKit.
- **File shelf.** Drag almost anything onto the notch: files, the screenshot thumbnail you get after ⌘⇧4, images, selected text or links. Files keep their names.
  - **Real files are moved onto the shelf** by default (they leave their folder); *Put Back* returns them. Things that aren't files yet are saved as files (`.png`, `.txt`, `.webloc`).
  - **Drag items out** to Finder or any app: the real file is dragged, so names are kept, and the item leaves the shelf once dropped.
  - **Select:** click, ⌘/⇧-click, drag a box across empty space, or ⌘A. **⌫** moves the selection to the Trash; the selection bar also has Remove and AirDrop. Right-click for Open, Show in Finder, AirDrop, Put Back, Remove and Move to Trash.
  - **Islet never permanently deletes files.** Removing or auto-clearing puts your own files back where they came from; files Islet saved, or anything you delete, go to the Trash.
- **AirDrop zone.** Drop files on it to AirDrop them, or click it to send everything on the shelf.
- **Battery.** Shows charge level and charging state.
- On Macs or external displays without a notch, Islet draws a black pill in the menu bar instead.
- **Hiding the menu bar icon.** If the icon is hidden, turn it back on in the Settings tab, or open Islet again from Finder or Spotlight while it's running.

## Build from source
Needs only the Xcode Command Line Tools (`xcode-select --install`), not the full Xcode. With Swift 6.2+ (macOS 26 SDK) you get the real Liquid Glass themes. Older toolchains build a material look-alike.

```bash
git clone https://github.com/Breanzy/yetanothernotch.git
cd yetanothernotch
./build.sh --install    # build for this Mac, copy to /Applications and open it
```

Other options: `./build.sh` (just build to `build/Islet.app`), `./build.sh --run` (build and launch from `build/`), and `./build.sh --release` (universal Apple Silicon + Intel build plus `build/Islet.zip` for a GitHub release).

Install it in Applications before turning on **Launch at login**. macOS records where the app is, and the `build` folder may move or be deleted.

## Permissions (asked the first time they're needed)
- **Automation → Music / Spotify**: needed to read and control playback.
- **Camera**: asked the first time you open the Mirror.
- **Calendars**: click "Connect Calendar" in the panel.

The app is signed ad hoc (no paid Developer ID), so macOS may ask for these permissions again after an update.

## Notes
- **Memory.** About 12–15 MB at idle (the Memory column in Activity Monitor), a little more after the panel has been used, and well under 1% CPU. Islet talks to Music and Spotify with raw Apple Events, so the AppleScript engine (~10 MB) is never loaded. The camera, calendar database and image thumbnails load only when used and are released afterward. Glass and Frosted themes are only rendered while the panel is open. Classic is the lightest theme: Apple's Liquid Glass effect alone can take 60–100 MB while the island is open (all of it is released when it closes).
- **Icon changes crossfade** instead of using macOS's symbol-morph effect (play ⇄ pause, Keep Awake's cup and so on). That effect runs on the GPU, briefly allocated ~50 MB every time an icon changed, and left a few MB behind each time.
- Apple has locked the private MediaRemote framework for third-party apps, so Islet controls Music and Spotify directly with Apple Events. Other players (browsers, etc.) are not shown.
- The Command Line Tools SDK doesn't include SwiftUI's `@State` macro plugin, so the views use `@ViewState`, a small wrapper around `State`.
- `Islet --snapshot <dir>` renders the panel states to PNG files for checking the layout.
- Haptics use Apple's private MultitouchSupport framework (the public API doesn't play for background apps). If it's unavailable, Islet falls back to the public API.

## License
[MIT](LICENSE)
