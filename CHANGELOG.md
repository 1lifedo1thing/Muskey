# 1.1.1

**[Download Muskey 1.1.1 →](https://files.lowtechguys.com/releases/Muskey-1.1.1.dmg)**
## Fixes

- Fix `Space`, `N`, `P` and `⌘V` doing nothing over the HUD while it listens for a new song's key
- Keep the HUD the same size while it listens to a new song, instead of moving the record away from the pointer
- Pause the listen while the song is paused, instead of showing *Nothing playing*

## Improvements

- Keys like `Space`, `N`, `P` and `⌘V` work over the HUD while it shows *Nothing playing*

# 1.1.0

**[Download Muskey 1.1.0 →](https://files.lowtechguys.com/releases/Muskey-1.1.0.dmg)**
## Features

- **Play songs from files and links** by dropping them on the HUD, pasting them with `⌘V`, or with *Open File* (`⌘O`) and *Open URL* (`⌘L`)
    > Links to web pages are downloaded with yt-dlp, which Muskey can install for you

![Open URL](https://files.lowtechguys.com/changelog/muskey/1.1.0-open-url.png)

- **Playback controls** on the record, and a two-finger swipe to skip songs

![playback controls](https://files.lowtechguys.com/changelog/muskey/1.1.0-playback-controls-v3.png)

- **Save Song** with the changed key, tempo and instruments, as M4A, MP3 or WAV (`⌘S`)
    > Songs from other players are saved by recording them from start to end

![Save Song](https://files.lowtechguys.com/changelog/muskey/1.1.0-save-song.png)

- **Tempo** of the song in BPM, under the key
- **Change the tempo** with `[` and `]` without changing the key
    > Songs from other players can only be slowed down, to as low as 50%

![tempo](https://files.lowtechguys.com/changelog/muskey/1.1.0-tempo.png)

- **Instant muting** of instruments and vocals in songs opened in Muskey
- **Volume for each instrument** with a scroll over its circle

![instruments and vocals](https://files.lowtechguys.com/changelog/muskey/1.1.0-instruments.png)

- **Seek and skip** from the keyboard
    > Move 5 seconds back or ahead with `←` `→`
    >
    > Start the song over with `0`
    >
    > Jump to 10% to 90% of the song with `1` to `9` over the record or in karaoke
    >
    > Play the next or previous song with `N` `P`

- **Shortcuts** for every key and gesture, with `?`

![Shortcuts](https://files.lowtechguys.com/changelog/muskey/1.1.0-shortcuts-v2.png)

- **Re-detect key** with a click on the key
- **Reset the key, tempo and instruments** at once with `⌘⌫`
- **More synced lyrics** from lrc.red, NetEase Cloud Music and the AMLL TTML DB
- Option to **Cut sound adjustments after pausing music**
- **Cache cleanup** for separated instruments and downloaded songs

![Settings > General](https://files.lowtechguys.com/changelog/muskey/1.1.0-settings-general.jpeg)

- **About** pane in Settings, with ways to sponsor the projects that Muskey is built on

![About](https://files.lowtechguys.com/changelog/muskey/1.1.0-about.jpeg)

## Fixes

- Fixed a possible freeze when a key change stops or the output device changes while instruments or vocals are muted
- Fix right clicks doing nothing near the HUD
- Fix Settings opening behind other windows after `⌘,` in the menu bar menu
- Fix the HUD not moving when dragged while it listens
- Fix the HUD showing a key heard over two songs when the song changes during a listen
- Don't flip the keys to the other mode when Option is held while the pointer is away from the HUD

## Improvements

- A song whose key was detected before shows its key instantly, without listening again
- The HUD stays open until it is closed, unless **Auto-hide** is enabled in Settings > HUD
- The HUD opens where it was last dragged
- Scroll over the time bar to move the song
- Karaoke starts the song over after a short countdown
- Karaoke opens with `⌘K` from the HUD
- **Vocals** pill under the key in karaoke, which mutes or plays the vocals (`V`)
- Karaoke goes back to the start of the song with a fade
- **Fade** rewind effect, next to *Scratch*
- New colours for the instruments and vocals, which light up as each one gets louder
- Muted instruments are striped, with a faint red ring
- Lyrics are looked up again when the Mac is back online
- The key in the menu bar is as tall as the icons next to it

# 1.0.1

**[Download Muskey 1.0.1 →](https://files.lowtechguys.com/releases/Muskey-1.0.1.dmg)**
## Improvements

- Make **Online key lookup** opt-in, for key detection that stays on the Mac (Settings > Listening)

# 1.0.0

**[Download Muskey 1.0.0 →](https://files.lowtechguys.com/releases/Muskey-1.0.0.dmg)**
## Features

- **Find the key** of the song that plays on the Mac with `Control` `Command` `M`
- **Change the key** with a click or the `A` to `G` keys, at the same tempo
- **Lock Key** to move every next song to the same key
- **Mute instruments and vocals** while the song plays, or `Option`-click one to hear only that part
- **Lyrics** that scroll along with the song (`L`)
- **Karaoke** with the lyrics full screen and the vocals muted (`Return`)
- **Card layout** with the keys on the circle of fifths (`S`)
- **The key in the menu bar**, and **Always listening** to find the key of every song that starts playing
