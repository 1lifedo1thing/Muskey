# Developing Muskey

## How it works

### Listening

Muskey listens through a Core Audio process tap on the whole system mix. The tap needs the **System Audio Recording** permission, and no loopback driver.

### Finding the key

Muskey finds the key with [Essentia](https://essentia.upf.edu)'s KeyExtractor and the `shaath` profile. It runs the KeyExtractor once a second over everything that it heard so far.

### Changing the key

A second process tap mutes every app except Muskey. Muskey sends that audio through [Rubber Band](https://breakfastquay.com/rubberband/)'s R3 engine and a limiter, then plays the result on the default output.

While Muskey Player plays the song, the tap hears and mutes only Muskey Player, so other sounds play as they are. Muskey builds the tap again when the song moves between Muskey Player and another player, which starts the stems over.

The tap is private to Muskey. When Muskey quits or crashes, the Mac plays its audio unchanged again.

### Now Playing

macOS has no public API for Now Playing. Muskey reads it from the private MediaRemote framework, through a small helper.

Since macOS 15.4, only code signed with an Apple identifier can read MediaRemote. For that reason, the helper is signed as `com.apple.controlcenter.Muskey`.

The helper also sends two commands to the player: play or pause, for Space over the HUD, and a move to another place in the song, for karaoke and the seek keys.

With the lyrics showing, the keys `←` and `→` seek 5 seconds back or ahead, and in karaoke the keys `0` to `9` move the song to its start or to a tenth of its length. While karaoke's stems show, the number keys stay with the stems. `N` and `P` play the next and the previous song in every layout.

The seek keys and their hints exist only while a seek is instant. While the stems are separated live, a seek would start their countdown again, and while the lyrics play behind the song, it would start the lyrics delay over. In both cases the arrows and the keys `1` to `9` do nothing. The key `0` in karaoke still starts the song over, the same way as Start song from beginning does while the stems play. A song in Muskey Player whose stems are in the cache (see Stems) keeps the seek keys with the stems on, since the stems of every moment of it are there already.

Players differ in the move they take, so Muskey tries three in turn:

1. The elapsed time that Now Playing shows, which Spotify, Music and Safari take.
2. The seek command, sent to the player's process the way Control Center's scrubber sends it, when the song hasn't moved 2.5 seconds after the first.
3. The player's AppleScript, for Spotify, Music, TV, Swinsian and VLC. macOS asks for the Automation permission the first time Muskey scripts a player, so a player that takes an earlier move never asks.

The move that worked is kept for the player's next seeks until Muskey quits. A player that took none of them, or that Muskey isn't allowed to script, is left alone by the seek keys until Muskey quits. Karaoke's start in Muskey Player always takes the elapsed time, since Now Playing reports that move at once and karaoke waits for the report.

### Playing files and links

Muskey plays the songs that are opened in it: dropped on the HUD, pasted with Command-V over it, picked with **Open File…** or **Open URL…** in the menu, or opened with Muskey in Finder. A small app inside Muskey, Muskey Player, plays them and tells Now Playing about them. Muskey's taps leave out the audio that the Muskey app plays, so the player is a separate app. The key, the pitch change, the stems and the lyrics then work as they do with any other player. Before a song plays, Muskey pauses the song that another app plays.

A link to an audio or video file is downloaded directly. Muskey downloads any other link with [yt-dlp](https://github.com/yt-dlp/yt-dlp), from Homebrew, pipx or Muskey's folder. Without yt-dlp, the pill at the top right of the screen offers **Install yt-dlp**, which downloads the official build for macOS from yt-dlp's GitHub releases and checks it against the SHA-256 sums published with it. When a download with that copy fails, Muskey updates it once with `yt-dlp -U` and tries again.

yt-dlp takes only the audio. With ffmpeg, it converts any audio to M4A. Without ffmpeg, it takes M4A, MP3 or MP4, and Muskey copies the audio into a new M4A, since AVFoundation reads the DASH M4A of YouTube as twice as long as it is. Muskey keeps up to 2 GB of downloaded songs in `~/Library/Caches/Muskey/Links`, so a link opened again plays at once.

**Open URL…** shows a field for a link or the path of a file, in a glass bar like the HUD's, with the songs downloaded from links before listed under it. Several files opened together play one after another. **Stop Playing**, in the menu bar menu and in the File menu while a song plays in Muskey Player, quits the player.

### Controls on the record

A click on the record plays or pauses the song, as Space does. With the pointer over the record, its cover shrinks a little, the previous and next glyphs show on the rim, at its sides, and a white play or pause glyph with a shadow shows in the middle of the cover, which is dimmed and blurred a little under it. The pointer over the cover dims and blurs it more, and a click on the cover plays or pauses the song. A two-finger swipe across the HUD skips too: fingers moving right play the next song, and fingers moving left play the previous one. **Natural swiping** in Settings > General turns that round. Only a trackpad swipe that is mostly sideways counts. Scrolling the lyrics or turning the wheel of a mouse doesn't change the song. These controls send the commands of the media keys to the app that plays the song, so they work with any player.

### Hotkey

The hotkey is registered with Carbon's `RegisterEventHotKey`, which works without the Accessibility permission.

### Keys from Noiseblend

With **Online key lookup** turned on in Settings, Muskey asks [Noiseblend](https://www.noiseblend.com) for the key of a song that it hasn't heard before. Muskey sends the title, artist, album and length of the song, and Noiseblend answers with the key and the tempo that Spotify lists for it.

Muskey asks once for each song. The listen still runs, and when the listen finds another key, Muskey uses that key.

The setting is off by default, for people who want every key found on their own Mac.

### Tempo

At the end of a listen, Muskey finds the tempo of what it heard with Essentia's RhythmExtractor2013, and shows it in a pill under the key, as in `124 BPM`. The tempo is remembered with the key of the song.

Spotify measures the tempo over the whole song, while a listen hears 10 to 30 seconds of it. A listen sometimes counts half or double the beats that people count along to. So when Noiseblend knows the tempo of the song, and the listen found the same tempo or half, double, a third or three times of it, the pill shows Spotify's tempo.

A song that plays in Muskey Player can be played slower or faster. The keys `[` and `]` (or the keycaps at the ends of the tempo pill) change its speed by 5 %, from 50 % to 150 %, and `=` (or the pill of the speed) plays it at 100 % again. A scroll over the tempo pill changes the speed by 1 % for every 6 points that the fingers move, up for faster. Muskey Player changes the speed with AVPlayer's varispeed, which changes the pitch with it, and Muskey's pitch change moves the pitch back by `−12 × log2(speed)` semitones, on top of any key change. The tempo pill shows the tempo at the speed that the song plays.

The pitch change hears every app, so the correction applies only while macOS shows Muskey Player as the app that plays. A listen during a speed change reads the audio at the tap's rate divided by the speed, which finds the key and the tempo of the song at 100 %. The lyrics aren't timed by ear while the speed isn't 100 %.

### Slowing down songs from other players

A song from another player, such as Music or Spotify, can be slowed down to 50 % with the same keys, pills and scroll, but it can't be sped up. The player keeps playing at its own speed, so Muskey's pitch change keeps the player's audio in a backlog of 80 seconds and plays it back slower. It reads the backlog the way a record played slower sounds, with a windowed-sinc resampler, which lowers the pitch too, and the same correction as for Muskey Player moves the pitch back. Everything after it (the stems, the lyrics delay, the pauses and the key change) hears the slowed song as if a player played it.

While the output plays slower, it gets further and further behind the player, so Muskey keeps the two in step:

1. When the output is 30 seconds behind, Muskey moves the player back to 6 seconds ahead of the moment that is heard. Muskey then looks for the old audio that the output is about to play in the audio that the player plays again, by correlation, first at an eighth of the rate and then at the full rate within 50 ms of the best match. When the output reaches that moment, it steps over to the same moment in the new audio with a 5 ms crossfade, so nothing is heard twice.
2. Players skip a moment of the song when they play again after a pause (Music skips about 160 ms), so after a pause Muskey moves the player back 2 seconds and steps over the audio played again in the same way.
3. A song that the player starts after the one that is heard plays once the output reaches it, and the HUD, the key, the lyrics and the time on the record stay with the song that is heard until then. A song that the player skips to, and a move made in the player, are heard at once.
4. The seek keys and karaoke's start move the player and jump the output to the move.
5. Back at 100 %, Muskey moves the player to 3.5 seconds ahead of the output, steps over to it, and plays 5 % faster until the output has caught up. Then the output plays the player's audio as it comes again.

The first move in a player that hasn't moved a song for Muskey yet comes once the output is 8 seconds behind. When the audio after a move isn't found twice in a row, the slowing stops and the song plays at 100 %. A save from another player records the song at 100 % and slows it down in the file, and the slowing comes back after the save.

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

The first window is separated a few seconds after a stem is muted. Until then the song plays as it is, and then Muskey steps back to the moment of the mute, with a backspin or a fade (**Rewind effect** in Settings). Karaoke counts down to that step back. With **Start song from beginning** (in the Karaoke section of Settings > Lyrics), the player first moves the song to its start, and Muskey then steps back to the start of the song.

The Winds stem comes from a second model: the woodwind and brass heads of [MVSep](https://mvsep.com)'s 53-stem BS-RoFormer. Muskey runs it on the same windows, and takes the winds that it finds out of the Other stem.

Muskey downloads both models from lowtechguys.com into `~/Library/Application Support/Muskey/Models`. The commands `make stems-model` and `make winds-model` make them from the checkpoints.

#### Stems from the cache

The first time that the stems are used on a song that Muskey Player plays, Muskey also separates the whole song in the background and keeps its stems in `~/Library/Caches/Muskey/Stems`. The stems are kept as 16-bit samples, about 1.2 MB for each second of the song, and the folder keeps up to 2 GB, the songs played longest ago going first. While the stems also play live, the separation of the whole song waits as long as each window took, so that the live stems keep up.

From then on, the stems of that song come from the cache. Muskey finds where the song is in the cache by correlation: it compares the last 100 ms that the tap heard with the song as the cache has it, read at the speed that Muskey Player plays it, around the place that Muskey Player reports. The stems are then written a second ahead of the song, lined up with what the tap hears, and they take over at once with a short crossfade, with no step back and no countdown. Every half second, Muskey checks that the song is still where it expects, and follows a change of speed or a gap in the tap with a 10 ms crossfade.

A seek, karaoke's start over and a move during a pause are silent until the stems of the new place are written and play. The first of these moves after the cache is ready, while the stems are still separated as the song plays, starts the stems over from the cache. When the song can't be found where the cache has it for 3 seconds, the stems are separated as the song plays again.

Muskey Player tells Muskey of every move of its song, including the ones from Control Center's scrubber and from Previous, which starts the song over. Now Playing reports some of these moves seconds later, and the stems would look for the song in the wrong place until then.

### Whisper

Muskey uses [whisper.cpp](https://github.com/ggml-org/whisper.cpp) with the large-v3-turbo model on the GPU, or a server with a `POST /v1/audio/transcriptions` endpoint. Muskey sends one phrase of the vocals at a time, cut at the pauses in the singing.

A server receives the audio of the song. Use only a server that you trust.

### Timing lyrics by ear

Muskey transcribes the song on the Mac with Apple's speech model, through the Speech framework's `SpeechTranscriber`. macOS downloads the model from Apple the first time.

Some languages work only with `DictationTranscriber`. For those, Muskey times the lyrics with Whisper when it is set up in Settings, and with `DictationTranscriber` when it isn't.

When Whisper fails on three clips in a row, Muskey times the rest of the lyrics with Apple's model. Lyrics that Whisper was writing show a Retry button instead.

Muskey matches the heard words to the lyrics in order, so a chorus that repeats is matched to the right verse. The heard words and the lyrics added by hand are kept in `~/Library/Application Support/Muskey/lyrics.json`.

### Saving songs

**Save Song** writes the song with its changes to a file: the key, the tempo, and the stems with their volumes. It is in the menu bar menu, in the File menu, on the HUD, and on `⌘S` over the HUD, and it shows only while something is changed. The changes are taken at the press, so a change made while the save panel is open doesn't go in the file.

A song in Muskey Player is rendered from its file, faster than it plays:

1. The stems are separated from the whole song with the model of the live stems, and mixed by their levels. While the stems also play live, this separation waits as long as each window took, so that the live stems keep up. A song whose stems are in the cache is mixed from there.
2. [Rubber Band](https://breakfastquay.com/rubberband/)'s R3 engine changes the tempo and the key in its offline mode, which reads the whole song first. Muskey Player's speed changes the pitch too, which the live output undoes with an extra shift. A file at that speed needs only the time stretch.
3. The limiter of the live output holds the peaks under −1 dBFS.
4. M4A is AAC at 256 kbit/s, WAV is 16-bit, and MP3 is 320 kbit/s from [LAME](https://lame.sourceforge.io), with the LAME tag that tells players how much padding the encoder added.

A song from another player is recorded first, as it plays from its start to its end:

1. When Muskey doesn't know yet which move the player takes (see Now Playing), it moves the playing song to its start and checks it, since a paused player reports no time to check against.
2. The player pauses, a process tap starts recording, the song moves to its start, and the player plays it.
3. The tap hears the processes of the player and of its helpers, which Core Audio lists by bundle ID, so other sounds stay out of the recording. When Core Audio lists none, the tap hears every app but Muskey, and the save panel says that other sounds are recorded too.
4. The recording starts at the first sound and ends at the song's length. A pause, a seek or another song stops the save, with Retry in the pill.
5. The recording is kept in memory, 15 minutes at most, and goes away once the song is rendered from it as a file in Muskey Player would be. The original song is never written to a file.

Muskey writes the song to a temporary file, which replaces the chosen one once it is whole. The pill at the top right of the screen shows the progress, then the saved song with **Show in Finder**, or a red pill with **Retry**.

## Limitations

- A pitch change moves every note by the same amount, so a major song stays major. Muskey reaches a key in the other mode through its relative, which has the same notes: from A major, C minor plays as E♭ major.
- While a song from another player is slowed down, every other sound that the Mac plays is slowed down and delayed with it, since the pitch change hears every app.
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
| `--stems-cache PATH` | Separate a song file whole into the cache, play it through the pitch change as Muskey Player would at `--speed S`, with the vocals muted, two moves and a pause, print how far the stems from the cache were from the song, and quit |
| `--stems-cache-dir DIR` | Keep the stems of whole songs in DIR instead of the cache folder |
| `--stems-install ZIP`, `--winds-install ZIP` | Install a separation model from a zip |
| `--stems-download`, `--winds-download`, `--whisper-download` | Download a model the way Settings does |

### Stem volumes

A scroll over a stem changes its volume, from 0 to 150 %, by 1 % for every 3 points that the fingers move, up for louder. The engine glides each stem's volume to the new value over about 15 ms, on top of the gain that mutes it. A stem at another volume than 100 % plays the stems in place of the song, as a muted one does, and shows its volume in place of its name. **Play all** and `0` play every stem at 100 % again. The thing that a scroll adjusts grows a little, and rides up or down with the fingers while its contents ride a little further, until the fingers lift.

### Keys and the HUD

| Flag | Action |
|---|---|
| `--key-lookup "Title\|Artist\|Album\|Seconds"` | Ask Noiseblend for the key of that song, print the answer and quit |
| `--glyph-sheet` | Open a window of live records with the play and pause glyph over flat covers and the images of `--glyph-covers A,B,…`, as the pointer over the record shows it and as the pointer over the cover does |
| `--open-menu-after S` | Open the menu bar menu after S seconds, so that a posted key reaches the open menu |
| `--speed S` | Play the first song at speed S, with the pitch correction: one in Muskey Player from 0.5 to 1.5, one from another player from 0.5 to 1 |
| `--slow-behind S` | Move the player back once a slowed song's output is S seconds behind it, instead of 30 |
| `--log-slow` | Log the backlog, the time heard and the player's time every 2 seconds while a song from another player is slowed down |
| `--slow-dump DIR` | Save the backlog around each move whose audio wasn't found, as raw 32-bit floats at 48 kHz, one channel |
| `--splice-dump FILE --splice-old S --splice-move S` | Run the search for the old audio on a file saved by `--slow-dump`, with the old audio S seconds into it and the move at S, then quit |
| `--seek-path elapsed\|command\|script` | Send every seek through that path alone, without trying the others |
| `--seek-ignore elapsed,command` | Send nothing through those paths, the way a player that ignores them would have it, to test the paths after them |
| `--tempo FILE` | Print the tempo of the part of FILE that a listen would hear, and quit. `--tempo-at S` moves the start from 45 seconds, and `--seconds S` sets the length |
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
| `--render-song PATH` | Render a song as Save Song does, write it to `--render-out PATH` (M4A, MP3 or WAV by its extension), print how long each part took, and quit |
| `--render-semitones N`, `--render-speed S`, `--render-mute vocals,drums` | The changes of `--render-song`: the key, the speed, and the stems that are muted |
| `--record-everything` | Record every app but Muskey when a song from another player is saved, as for a player that Core Audio doesn't list |
| `--save-pick m4a\|mp3\|wav` | Pick that format a second after the save panel opens, as the Format picker does, since the panel takes neither posted clicks nor accessibility |

### Tests

| Flag | Action |
|---|---|
| `--selftest` | Send a 440 Hz tone through the pitch shifter, check the pitch, gaps, timing and level that come out, and quit |

Muskey writes each result to `~/Library/Logs/Muskey.log`.
