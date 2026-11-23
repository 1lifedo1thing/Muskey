# 1.2.1

**[Download Muskey 1.2.1 →](https://files.lowtechguys.com/releases/Muskey-1.2.1.dmg)**
## Features

- **Recents** on the back of the record when nothing plays
    > Pick a song with `↑` `↓` and `Return`

![Recents](https://files.lowtechguys.com/changelog/muskey/1.2.1-recents.png)

- **Open folders** from *Open File*, *Add Files to Queue*, a drop or a paste

- **Loop the whole song** with `⇧R`

- **On the record** layout for the mini player, with the song's title, artist and album drawn on the record

![On the record layout](https://files.lowtechguys.com/changelog/muskey/1.2.1-mini-on-record.png)

## Fixes

- Fix the notes line falling half a second behind the song after every loop pass
- Fix the song sometimes playing past a region loop that was just set
- Fix a seek or a pause in Spotify sometimes clearing the region loop or changing the key
- Fix the instruments of a song from a link being separated again every time the link opens
- Fix region loops breaking while the save or open panel is open
- Make sure saved M4A files get the `.m4a` extension when a name is typed without one
- Fix the Settings window staying in window switchers after it was closed

## Improvements

- New keys over the waveform:
    > Seek 5 seconds with `←` `→`
    >
    > Go to the start of the region loop with `0`
    >
    > Go to a numbered bar of the zoomed waveform with `1` to `9`
- Pinch over the waveform zooms it while another app is in front
- **Transcribe notes** works on the region loop when one is set
- The *Transcribe notes* picker starts on the instrument that plays the most
- The key and the tempo in the notes window's status bar can be changed with a click or a scroll
- **Save Song** saves only the region loop when one is set
- Saved M4A and MP3 files keep the song's title, artist, album and cover
- Songs opened in Muskey get their key from the whole file at once, instead of from a listen
- Play at the end of a song starts it over, as music apps do

# 1.2.0

**[Download Muskey 1.2.0 →](https://files.lowtechguys.com/releases/Muskey-1.2.0.dmg)**
## Features

- **Transcribe notes** of any instrument into tab, sheet music or piano roll, with a local state of the art AI model (`T`)
    > Save the notes as MusicXML, MIDI or text tab

![Transcribe notes](https://files.lowtechguys.com/changelog/muskey/1.2.0-transcribe-notes-v2.png)

- **Waveform** of the whole song under the key row (`W`)

![waveform](https://files.lowtechguys.com/changelog/muskey/1.2.0-waveform-v2.png)

- **One waveform per instrument** (`⌥W`)

![one waveform per instrument](https://files.lowtechguys.com/changelog/muskey/1.2.0-instrument-lanes-v2.png)

- **Region loop** with `R`
    > The ends snap to the beat, or to the notes once they are transcribed
    >
    > Nudge an end with `←` `→` while the pointer is over its tab

![region loop](https://files.lowtechguys.com/changelog/muskey/1.2.0-region-loop-v2.png)

- **Queue** on the back of the record (`Q`)
    > Drop files on the HUD to play them now or add them to the queue

![queue](https://files.lowtechguys.com/changelog/muskey/1.2.0-queue-v2.png)

- **Mini player** that floats over other windows (`M`)

![mini player](https://files.lowtechguys.com/changelog/muskey/1.2.0-mini-player-v3.png)

- **Chords** over the lyrics and in karaoke, for songs opened in Muskey
    > Transpose them with `←` `→`, or set a capo with `⌥←` `⌥→`

![chords](https://files.lowtechguys.com/changelog/muskey/1.2.0-chords-v2.png)

- **Fix timing** for lyrics that show early or late, detected through a local AI model running on the vocals
    > Move the lines half a second at a time with the arrows over the timing pill

![Fix timing](https://files.lowtechguys.com/changelog/muskey/1.2.0-fix-timing.png)

![timing arrows](https://files.lowtechguys.com/changelog/muskey/1.2.0-fix-timing-arrows.png)

## Fixes

- Stop recording the Mac's sound while the song is paused during a listen
- Fix the HUD going on from where the song was when the song that plays is opened again
- Fix the keys over the HUD not working after a listen that heard silence or found no key
- Fix the keys over the HUD stopping when the HUD changes size under a pointer that stays still
- Fix songs from direct links showing a cache file name as their title

## Improvements

- The HUD moves back to the bottom centre with `⌘⌥C`
- The selected key has a ring and a soft glow, to stand apart from the related keys
- Much lower CPU and energy use while the HUD shows a song that plays
- Record rotation speed can be changed in Settings > HUD
- Holding `⇧` over the HUD highlights the sharp and flat keys that a letter picks
- Lyrics without times follow the singing more closely
- Seeking works while the instruments are separated as the song plays
- Songs play untouched at their original key, without the pitch shifter in between
- Titles that end in a file extension like `.mp4` show without it
- The `⋯` menu lists every action that has a key
- Settings open with `⌘,` while the pointer is over the HUD
- Links and network files show their download progress in the HUD, with Cancel (`esc`) and Continue in Background (`⌫`)

![opening a link](https://files.lowtechguys.com/changelog/muskey/1.2.0-opening-link.png)

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
