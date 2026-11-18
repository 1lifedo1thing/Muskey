# Developing Muskey

## How it works

### Listening

Muskey listens through a Core Audio process tap on the whole system mix. The tap needs the **System Audio Recording** permission, and no loopback driver.

### Finding the key

Muskey finds the key with [Essentia](https://essentia.upf.edu)'s KeyExtractor and the `shaath` profile. It runs the KeyExtractor once a second over everything that it heard so far.

### Changing the key

A second process tap mutes every app except Muskey. Muskey sends that audio through [Rubber Band](https://breakfastquay.com/rubberband/)'s R3 engine and a limiter, then plays the result on the default output.

The tap is private to Muskey. When Muskey quits or crashes, the Mac plays its audio unchanged again.

### Now Playing

macOS has no public API for Now Playing. Muskey reads it from the private MediaRemote framework, through a small helper.

Since macOS 15.4, only code signed with an Apple identifier can read MediaRemote. For that reason, the helper is signed as `com.apple.controlcenter.Muskey`.

The helper also sends two commands to the player: play or pause, for Space over the HUD, and a move to the start of the song, for karaoke.

### Playing files and links

Muskey plays the songs that are opened in it: dropped on the HUD, pasted with Command-V over it, picked with **Open File…** or **Open Location…** in the menu, or opened with Muskey in Finder. A small app inside Muskey, Muskey Player, plays them and tells Now Playing about them. Muskey's taps leave out the audio that the Muskey app plays, so the player is a separate app. The key, the pitch change, the stems and the lyrics then work as they do with any other player. Before a song plays, Muskey pauses the song that another app plays.

A link to an audio or video file is downloaded directly. Muskey downloads any other link with [yt-dlp](https://github.com/yt-dlp/yt-dlp), from Homebrew, pipx or Muskey's folder. Without yt-dlp, the pill at the top right of the screen offers **Install yt-dlp**, which downloads the official build for macOS from yt-dlp's GitHub releases and checks it against the SHA-256 sums published with it. When a download with that copy fails, Muskey updates it once with `yt-dlp -U` and tries again.

yt-dlp takes only the audio. With ffmpeg, it converts any audio to M4A. Without ffmpeg, it takes M4A, MP3 or MP4, and Muskey copies the audio into a new M4A, since AVFoundation reads the DASH M4A of YouTube as twice as long as it is. Muskey keeps up to 2 GB of downloaded songs in `~/Library/Caches/Muskey/Links`, so a link opened again plays at once.

Several files opened together play one after another. **Stop Playing**, in the menu bar menu and in the File menu while a song plays in Muskey Player, quits the player.

### Controls on the record

A click on the record plays or pauses the song, as Space does. With the pointer over the record, buttons for the previous and the next song show beside it. A two-finger swipe across the HUD skips too: fingers moving left play the next song, and fingers moving right play the previous one. Only a trackpad swipe that is mostly sideways counts. Scrolling the lyrics or turning the wheel of a mouse doesn't change the song. These controls send the commands of the media keys to the app that plays the song, so they work with any player.

### Hotkey

The hotkey is registered with Carbon's `RegisterEventHotKey`, which works without the Accessibility permission.

### Keys from Noiseblend

With **Online key lookup** turned on in Settings, Muskey asks [Noiseblend](https://www.noiseblend.com) for the key of a song that it hasn't heard before. Muskey sends the title, artist, album and length of the song, and Noiseblend answers with the key that Spotify lists for it.

Muskey asks once for each song. The listen still runs, and when the listen finds another key, Muskey uses that key.

The setting is off by default, for people who want every key found on their own Mac.

### Lyrics

While the lyrics show, Muskey looks the song up once, on these services at the same time:

- [LRCLIB](https://lrclib.net), with the title, artist, album and length of the song
- [lrc.red](https://lrc.red) and [NetEase Cloud Music](https://music.163.com), with the artist and the title
- the [AMLL TTML DB](https://github.com/amll-dev/amll-ttml-db), for word-timed lyrics, once NetEase gives its number for the song

Synced lyrics of the version that plays come first: the same title, the same first artist and a length within two seconds. LRCLIB's lyrics are used as soon as they come, and the lyrics of another service wait a moment for a service that comes before it. The name of the service shows under the lyrics, with a link to it.

When no service has that version, Muskey takes the synced lyrics of the version with the closest length, such as the album version of a music video with an intro. Muskey then listens to the song, and the lines move to where it hears them sung.

### Stems

Muskey separates the song into six stems with [BS-RoFormer](https://arxiv.org/abs/2309.02612). It uses the BS-Roformer-SW checkpoint, converted to Core ML and run on the GPU.

Muskey separates the song in windows of 4.5 seconds that overlap by a second, and crossfades the windows. It plays the mix of the stems that are on, with the same pitch change as the song.

The first window is separated a few seconds after a stem is muted. Until then the song plays as it is, and then Muskey steps back to the moment of the mute, with a backspin or a fade (**Rewind effect** in Settings). Karaoke counts down to that step back. With **Restart song in karaoke**, the player first moves the song to its start, and Muskey then steps back to the start of the song.

The Winds stem comes from a second model: the woodwind and brass heads of [MVSep](https://mvsep.com)'s 53-stem BS-RoFormer. Muskey runs it on the same windows, and takes the winds that it finds out of the Other stem.

Muskey downloads both models from lowtechguys.com into `~/Library/Application Support/Muskey/Models`. The commands `make stems-model` and `make winds-model` make them from the checkpoints.

### Whisper

Muskey uses [whisper.cpp](https://github.com/ggml-org/whisper.cpp) with the large-v3-turbo model on the GPU, or a server with a `POST /v1/audio/transcriptions` endpoint. Muskey sends one phrase of the vocals at a time, cut at the pauses in the singing.

A server receives the audio of the song. Use only a server that you trust.

### Timing lyrics by ear

Muskey transcribes the song on the Mac with Apple's speech model, through the Speech framework's `SpeechTranscriber`. macOS downloads the model from Apple the first time.

Some languages work only with `DictationTranscriber`. For those, Muskey times the lyrics with Whisper when it is set up in Settings, and with `DictationTranscriber` when it isn't.

When Whisper fails on three clips in a row, Muskey times the rest of the lyrics with Apple's model. Lyrics that Whisper was writing show a Retry button instead.

Muskey matches the heard words to the lyrics in order, so a chorus that repeats is matched to the right verse. The heard words and the lyrics added by hand are kept in `~/Library/Application Support/Muskey/lyrics.json`.

## Limitations

- A pitch change moves every note by the same amount, so a major song stays major. Muskey reaches a key in the other mode through its relative, which has the same notes: from A major, C minor plays as E♭ major.
- A screen recording that includes system audio records both the original song and the shifted one. To record only the shifted song, use a recorder that captures per-app audio, and leave out the app that plays the song.

## Flags for testing

Builds made with `make` or `make install` take these flags, and release builds ignore them. Pass them with `open -a Muskey --args …`.

### Listening and the pitch change

| Flag | Action |
|---|---|
| `--listen` | Start a listen at launch |
| `--seconds N` | Listen for N seconds |
| `--wav PATH` | Save what the listen heard as a mono WAV |
| `--pick` | Open the key picker on a sample key |
| `--shift N` | Start a pitch change of N semitones |
| `--keep KEY` | Lock a key like `Cm`, `F#` or `Eb` |
| `--shift-wav PATH` | Save the first 10 seconds of a pitch change as a stereo WAV, with the input on the left and the output on the right |
| `--shift-wav-seconds N` | Save N seconds instead of 10 |

### Instruments and vocals

| Flag | Action |
|---|---|
| `--stems-only NAMES` | Play only the stems in NAMES, like `guitar,vocals` |
| `--stems-after N` | Start the stems after N seconds (3 by default, and 0 starts with a cold model) |
| `--stems-file PATH --stems-out DIR` | Separate a song file into DIR and print how long it took |
| `--stems-install ZIP`, `--winds-install ZIP` | Install a separation model from a zip |
| `--stems-download`, `--winds-download`, `--whisper-download` | Download a model the way Settings does |

### Keys and the HUD

| Flag | Action |
|---|---|
| `--key-lookup "Title\|Artist\|Album\|Seconds"` | Ask Noiseblend for the key of that song, print the answer and quit |
| `--render DIR` | Write a PNG of each HUD state and quit |
| `--log-keys` | Log every key and click that reaches the HUD, with the host time of each line |

### Lyrics

| Flag | Action |
|---|---|
| `--lyrics-test FILE` | Play a made-up song with the lyrics in FILE (LRC, or plain text for estimated timing) and open the lyrics. Whisper's lyrics for it are kept in `/tmp/muskey-lyrics-test.json`, apart from the real ones. |
| `--lyrics-at N` | Start that song N seconds in |
| `--lyrics-since T` | Start it at the Unix time T, to line it up with a file that `afplay` plays |
| `--lyrics-replay FILE --whisper-server URL` | Play a song file through the lyrics code four times faster than real time, as a song with no lyrics. Each play prints what it sent to Whisper, and the saved parts of the song are kept in `/tmp/muskey-lyrics-replay.json`. |
| `--plays LIST` | The plays of `--lyrics-replay`, like `0-60,0-end`, or `0-40+100-140` for a seek |
| `--lyrics-lookup "Title\|Artist\|Album\|Seconds"` | Look up the lyrics of that song the way the lyrics panel does, print the service, the timing and the first lines, and quit |
| `--lyrics-source NAME` | Ask only one lyrics service: `lrclib`, `lrcred`, `netease` or `amll` |
| `--lyrics-plain` | Drop the times of synced lyrics, time them by listening, and log how far the heard times are from the dropped ones. With `--pick`, the lyrics show from the start. |

### Files and links

| Flag | Action |
|---|---|
| `--open PATH_OR_LINK` | Play a file or a link, as a drop on the HUD does |
| `--install-yt-dlp` | Press **Install yt-dlp**, as on the pill of a link that needs it |
| `--menu TITLE` | Pick the item of the menu bar menu with this title, as a click on it does. No automation can open that menu on macOS 27. |
| `--menu-after SECONDS` | How long after launch `--menu` picks its item (3 seconds by default) |

### Tests

| Flag | Action |
|---|---|
| `--selftest` | Send a 440 Hz tone through the pitch shifter, check the pitch, gaps, timing and level that come out, and quit |

Muskey writes each result to `~/Library/Logs/Muskey.log`.
