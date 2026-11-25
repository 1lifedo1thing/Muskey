# Developing Muskey

## How it works

### Listening

Muskey listens through a Core Audio process tap on the whole system mix. The tap needs the **System Audio Recording** permission, and no loopback driver.

### Finding the key

Muskey finds the key with [Essentia](https://essentia.upf.edu)'s KeyExtractor and the `shaath` profile. It runs the KeyExtractor once a second over everything that it heard so far.

### Changing the key

A second process tap mutes every app except Muskey. Muskey sends that audio through [Rubber Band](https://breakfastquay.com/rubberband/)'s R3 engine and a limiter, then plays the result on the default output.

While Muskey Player plays the song, the tap hears and mutes only Muskey Player, so other sounds play as they are. Muskey builds the tap again when the song moves between Muskey Player and another player, which starts the stems over. A tap of Muskey Player that is made while its song starts stalls its sound for 5 to 15 seconds, so when the pitch change already runs, the tap of every app stays until the new song has been heard for a second.

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

A link to an audio or video file is downloaded directly. Muskey downloads any other link with [yt-dlp](https://github.com/yt-dlp/yt-dlp), from Homebrew, pipx or Muskey's folder. Without yt-dlp, the HUD offers **Install yt-dlp**, which downloads the official build for macOS from yt-dlp's GitHub releases and checks it against the SHA-256 sums published with it. When a download with that copy fails, Muskey updates it once with `yt-dlp -U` and tries again.

yt-dlp takes only the audio. With ffmpeg, it converts any audio to M4A. Without ffmpeg, it takes M4A, MP3 or MP4, and Muskey copies the audio into a new M4A, since AVFoundation reads the DASH M4A of YouTube as twice as long as it is. Muskey keeps up to 2 GB of downloaded songs in `~/Library/Caches/Muskey/Links`, so a link opened again plays at once.

The HUD opens at once on a link, and on a file on a network volume, and shows the step that runs until the song plays:

| Step | What runs |
|---|---|
| Reading | yt-dlp reads the page until it names the song. For a file on a network volume, Muskey Player reads the file until it can play it |
| Downloading | The download, with the part done as a percent while the size is known |
| Converting | yt-dlp's post-processing (ffmpeg takes the audio out), then Muskey's copy into an M4A and the download of the cover |
| Installing yt-dlp | The download of yt-dlp, then its checks |
| Updating yt-dlp | `yt-dlp -U`, after a download with Muskey's copy failed |

Under the step, the HUD names the song as the record shows it once it plays. Before a download, yt-dlp prints the page's title, track, artist and channel as JSON, and Muskey cleans them the way it cleans them for Now Playing: `Artist - Song (Official Video)` shows as the song with its artist under it. A link to a file shows the name of the file.

While nothing plays, the step shows beside an empty platter, and a ring around the platter fills with the part done. While a song plays, in Muskey Player or in another app, its record stays and keeps turning: the step takes the side of the key in the wide layout and the part under the record on the card. Muskey doesn't draw a ring around that record, since a ring would read as the progress of the song that plays, and a bar under the name fills instead. The glass keeps the size that it had with the record, so the record doesn't move.

**Cancel**, and Escape, stop the step that runs: they end yt-dlp, the download or the install, and tell Muskey Player to drop a file that it still reads (`cancel` on its stdin). The song that plays goes on. **Continue in Background** and Backspace leave the song to open in the pill at the top right of the screen, and the HUD opens again when it plays. Over a song that plays with changes (a pitch or tempo change, stems, a loop, karaoke or the key picker), the HUD goes back to that song. Otherwise it closes, as the ✕ of the HUD does. On the card, a small line under the record of the playing song names it. A failure shows in the place of the step as a red pill with **Retry** or **Install yt-dlp**, and Escape dismisses it. A song of the queue that starts to download when the one before it ends doesn't open a closed HUD.

### Names of songs

A song is named by its title tag. A file without one is named by its file name, and `Artist - Title` gives both. A link to a file without a title tag is named by the file in the link, with the percent escapes decoded and without the extension (`SongName.link`), never by the file in Muskey's cache: Muskey hands that name to Muskey Player with the song.

Browsers and video players often report the name of a file as the title, like `concert.mp4`. A title from Now Playing loses the extension of a media file where the helper's report is decoded (`NowPlaying.Track.decode`), so the record, the lyrics search and the key lookup all get `concert`. A title that ends in anything else stays whole.

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

The pitch change hears every app, so the correction applies only while macOS shows Muskey Player as the app that plays. The stems and the lyrics delay play the song seconds after the tap heard it, and after a step back they play some of it again, so the shifter keeps each correction with the frame of the captured song that it starts at (`ps_set_correction`, eight changes kept). The voices get the correction of the part that they are fed: the newest one for the song as it plays, and the one of the frame that the stems or the delay play otherwise, asked for as a step back starts to fade or spin so that the new voice is ready when the stems come in. A correction applied at once played the song at its old speed up to 25 % too high, for as long as the stems were behind. The self-test `tempo correction` checks it with the lyrics delay and with stems that start after the change. A listen during a speed change reads the audio at the tap's rate divided by the speed, which finds the key and the tempo of the song at 100 %. The lyrics aren't timed by ear while the speed isn't 100 %.

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

### Notes

Muskey turns one stem of a song into notes with the transcriber of [Dettato](https://kobi.music/research/dettato) (Apache-2.0). Its network is converted to Core ML and cut at its three GRUs into four models, because Core ML runs those GRUs much slower than Accelerate does. The GRUs run with Accelerate between the four models. The spectrogram before the network and the peak picking after it are ported from Dettato's Python.

The network hears 8 seconds at 16 kHz at a time, and a window starts every 2 seconds. Each 20 ms frame of the song gets the mean of the windows over it, weighted by a Hann taper. Notes are then picked from the onset, frame and offset maps of two voices on each of the 88 keys.

Muskey downloads the model (33 MB) from lowtechguys.com into `~/Library/Application Support/Muskey/Models/Dettato`. The command `make dettato-model` makes it from Dettato's weights. Dettato's drum transcriber isn't part of Muskey, so the Drums stem has no notes.

**T** over the HUD shows the stems in place of the key column, for a song that plays in Muskey Player. Return separates the whole song into stems if the cache doesn't have them yet, transcribes the picked stem, and opens the notes window. The notes of each song and stem are kept in `~/Library/Caches/Muskey/Notes`, so they open at once the next time.

The notes are placed on the beats that Essentia finds in the song, which also place the chords over the lyrics. Dettato finds no metre and no downbeat, so every bar has four beats and the first beat starts the first bar. Each note is rounded to a sixteenth. Bass and guitar get a string and a fret on the lowest frets that keep the hand near one place, and the notes of a chord go on separate strings within reach of one hand, and their staff is written an octave above where they sound, as is usual for both.

The window holds the notes still, as pages of tab, sheet music or a piano roll, and a line moves through them as the song plays. The page is split into a top half and a bottom half: once the line reaches the bottom half, the top half turns to the next page, and the bottom half turns once the line reaches the top again. A click on the notes moves the song to that beat, and a drag across them sets the region loop. The notes follow the pitch change, and ← → in the window changes it. The window takes the shape of a portrait page when it is taller than wide, and of a landscape page otherwise, and its page button switches between the two.

### Whisper

Muskey uses [whisper.cpp](https://github.com/ggml-org/whisper.cpp) with the large-v3-turbo model on the GPU, or a server with a `POST /v1/audio/transcriptions` endpoint. Muskey sends one phrase of the vocals at a time, cut at the pauses in the singing.

A server receives the audio of the song. Use only a server that you trust.

### Timing lyrics by ear

Muskey transcribes the song on the Mac with Apple's speech model, through the Speech framework's `SpeechTranscriber`. macOS downloads the model from Apple the first time.

Some languages work only with `DictationTranscriber`. For those, Muskey times the lyrics with Whisper when it is set up in Settings, and with `DictationTranscriber` when it isn't.

When Whisper fails on three clips in a row, Muskey times the rest of the lyrics with Apple's model. Lyrics that Whisper was writing show a Retry button instead.

Muskey matches the heard words to the lyrics in order, so a chorus that repeats is matched to the right verse. The heard words and the lyrics added by hand are kept in `~/Library/Application Support/Muskey/lyrics.json`.

### Timing lyrics from the vocals of the whole song

For a song that Muskey Player plays, Muskey can time the lyrics before they are sung. It needs the lyrics timing model from Settings > Instruments and vocals, and the stems of the whole song in the cache.

The model is Meta's [omniASR CTC model](https://github.com/facebookresearch/omnilingual-asr) of 300 million weights (Apache-2.0), converted to Core ML. It reads the vocals 30 seconds at a time and gives, for every 20 ms, how likely each character is. It writes the characters of over 1600 languages, so Muskey doesn't need a dictionary or the language of the lyrics.

Muskey lays the letters of the lyrics over those frames in order, along the path that the model finds most likely. A line that nobody sings can be left out, at a price for each of its letters. The lyrics are fitted twice, with a high and a lower price, and a line counts as found when both fits start it within 0.3 seconds of each other.

- Lyrics without times take the fit's time for every line that it found, when it found at least one line in five. The other lines are still timed by ear, and a heard line counts only when it falls between the found lines around it. Muskey stops listening when the fit found nine lines in ten. It separates the stems of the whole song for the fit when the cache doesn't have them, and times every line by ear until the fit is done.
- Lyrics with times are only checked for an offset. Muskey separates the stems of the whole song for the check when the cache doesn't have them. When the fit found at least half of the lines, and those agree that the lyrics are off as a whole by 0.8 seconds or more, the **Fix timing** pill beside the source of the lyrics turns honey amber with that offset. The lines move by it only after a click on the pill, and a second click restores their own times. Below 0.8 seconds, the fit can't tell an offset from the habit of starting a line a few tenths of a second before its first word.
- A click on **Fix timing** before the check is done shows the separation and the fit as they go, and moves the lines as soon as the offset is found. The pill then reads On time when the times were right, and No fix found when the fit found too few lines or lines that are off by different amounts.
- With the pointer over the pill, it shows the shift of the lines between two arrows, and each arrow moves the lines by half a second. That works for every song with lyrics with times, whether a check runs or not. An ✕ in the pill's corner removes what was saved for the song, and Settings > Lyrics > Saved timings removes it for every song.
- The checks that start without a click follow Settings > Lyrics > Timing detection conditions: always, not in Low Power Mode (the default), or only on the power adapter. A click on **Fix timing** checks in every case.

The times of the fit, the offset and the shift of the lines are kept in `lyrics.json`, apart for each file or player and for each text of the lyrics, so the next play has them from the start. The same song in another file or from another player keeps its own, since its audio can start earlier or later.

### Timing the lyrics of songs from other apps

Muskey can't read a song from Spotify, Music or a browser ahead, so it fits the lyrics onto the vocals of the part that has played. It needs the lyrics timing model and the model that separates the stems, and Settings > Lyrics > Run lyrics timing detection when live listening turned on (the default). The vocals come from the live separation, a few seconds behind the song, and Muskey keeps them in memory while the lyrics show.

- **Lyrics with times** are checked once for each song and player. Muskey hears the vocals without transcribing them. After 30 seconds, once 8 lines were sung, it fits the lines whose times are near the part that it heard. When the found lines agree that the lyrics are off as a whole by 0.8 seconds or more, the **Fix timing** pill turns honey amber with that offset, as it does for a song in Muskey Player, and the lines move only after a click on it. An offset also needs 8 found lines, and the earlier half and the later half of them within a quarter of a second of each other. When the found lines agree that the times hold, the pill reads On time. When they don't agree, Muskey checks again after 25 more seconds and 6 more lines, four times at most, and then the pill shows that no fix was found. Muskey stops hearing the song as soon as it has an answer. Until then the pill reads Timing, and its arrows still move the lines, since a click can't start this check.
- **Lyrics without times** are heard and timed by ear as before. When the play ends, Muskey fits the lyrics onto everything it heard in that play, and keeps the found lines when the fit found at least one line in five. In the next play those lines take the fit's time from the start, and the heard words time the other lines. Muskey doesn't fit while the song plays: the heard words come seconds before a fit of the same part could, so the fit wouldn't change which line is highlighted.

A part of a song can start and end at any line, and a chorus that repeats fits it in more than one place. Three things keep a part in its place:

- The fit knows where each line is expected: at its time, for lyrics with times, and otherwise where the heard words and the estimate have it. Starting or ending far from there costs a little for each second.
- A part that starts with the song holds the first line of the lyrics, and a part that ends with the song holds the last line.
- For lyrics without times, in a part that doesn't start with the song, a line found more than 3 seconds from where a heard word has it is left out. Nothing of the part is used when fewer than 3 of its lines are near their heard words, or when more lines are far from them than near them.

Muskey keeps the result of a fit in `lyrics.json` for the song, the lyrics and the player: the offset of lyrics with times, or the found lines with the parts of the song that were fitted. The next play of the song in that player starts with them. A play is fitted when it heard at least 45 seconds of the song that no earlier play had fitted.

The model is loaded for each fit and unloaded after it, and one fit runs at a time. A song that is slowed down isn't fitted, since Muskey plays it behind the player.

Muskey downloads the model (289 MB) from lowtechguys.com into `~/Library/Application Support/Muskey/Models/Aligner`. The command `make aligner-model` makes it from Meta's weights and checks it against PyTorch on the CPU, the GPU and the Neural Engine. Muskey runs it on the GPU, where it stays the closest to the original.

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

### Error reports

While **Send error reports** is on in Settings > General, Muskey sends its crashes, its uncaught exceptions and the hangs of its main thread that last longer than 30 seconds to [Sentry](https://sentry.io). It also sends one event the first time each version launches. A report carries an anonymous ID, a hash of the Mac's serial number, which Settings shows as Machine ID. The addresses of web requests stay out of the reports, since the lookups of lyrics and keys put song titles in them. Builds made with `make` send their events to a `dev` environment, without crashes or hangs.

`make build` keeps the dSYMs of the release in `build/dSYMs`, and `make upload` sends them to Sentry after a full release, so that the reports name Muskey's functions.

### Logs

Muskey writes its log to the unified log of macOS, under the subsystem `com.lowtechguys.Muskey`. Each line has a category named after the source file that wrote it, like `App`, `FilePlayer`, `LyricsSync` or `WebRemote`.

To follow the log while Muskey runs:

```sh
log stream --predicate 'subsystem == "com.lowtechguys.Muskey"' --level debug
```

To read the last 10 minutes of it:

```sh
log show --predicate 'subsystem == "com.lowtechguys.Muskey"' --info --debug --last 10m
```

Add `AND category == "SlowStream"` to the predicate to read a single file's lines. To see the lines in the terminal that runs `Muskey.app/Contents/MacOS/Muskey` with a flag for testing, set `OS_ACTIVITY_DT_MODE=YES` in its environment.

Each line has a level:

- **Debug** for lines that come often: the reports of every second or two, every request of the web remote, the timing of the stem windows, and the lines of `--log-keys` and the other flags for testing.
- **Info** for routine events, like a song that opens or the lyrics that show.
- **Notice** for changes that a bug report needs, like a song change, the key that a listen found, or the pitch change starting and stopping.
- **Error** for failures.

macOS writes the notice and error lines to disk, and keeps the debug and info lines in memory for a short while. There are three ways to have it keep them on disk as well:

- Builds made with `make` or `make install` keep them, through `OSLogPreferences` in their Info.plist.
- **Keep debug logs** in Settings > General keeps them for a chosen time, from 1 hour to Always. The first time, it asks for an administrator password and installs a LaunchDaemon, `/Library/LaunchDaemons/com.lowtechguys.Muskey.keep-debug-logs.plist`. The daemon runs `log config --subsystem com.lowtechguys.Muskey --mode level:debug,persist:debug`. It checks the time once a minute, and when the time is up, it resets the setting and removes itself. Its program is a root-owned copy of the `muskey` tool, which hands its arguments to `/bin/sh`, so that System Settings lists the daemon under Muskey.
- `muskey logs persist on` changes the same setting from a terminal through `sudo`, with no end time. `muskey logs persist off` puts it back, and `muskey logs persist status` prints it.

With `--log-keys`, each line of the app delegate ends with the host time in seconds (`@1234.567`, from `CACurrentMediaTime`), to line up a screen recording with the keys.

### Command line

The `muskey` tool lives in `Contents/Helpers`, and Settings > Remote links it into `~/.local/bin`. It reaches the app through a message port named `com.lowtechguys.Muskey.cli`, which only processes of the same user can open. Requests and answers are JSON, from `Shared/MuskeyIPC.swift`, which both are built with. When the port is missing, the tool opens Muskey in the background and waits up to 20 seconds for it.

- Without `-o`, a request plays its inputs in the HUD, or listens to the song that plays, and applies the changes once the song plays and its key is known.
- With `-o`, the app starts a job that writes into `~/Library/Caches/Muskey/CLI/<job>/`. Jobs run one at a time, with a stems separation of their own, so a job never takes over the separation of the song in the HUD. The tool asks how the job goes four times a second, prints its step, and moves the file into place. Ctrl-C stops the job.
- A job takes the key of the song from the HUD (a remembered key, a key heard since launch, or Noiseblend's), then from the notes kept for the song, and only then reads it from 30 seconds of the file. Notes that the notes window kept are cut to `--from` and `--to` without a new separation.
- A job needs an input, so the tool never records the song that another app plays.

#### Spotify links

A Spotify link (`spotify:track:…` or `https://open.spotify.com/…/track/…`, and the same for albums, playlists, artists and episodes) is played by Spotify's AppleScript command `play track`, after Muskey opens Spotify when it isn't running. Muskey then listens to the song as the hotkey does and applies the changes. The first time, macOS shows a dialog to allow Muskey to control Spotify. Nobody may be at the Mac to click it, so the job fails at once with a message and the dialog stays on the Mac's screen.

A link sent by the tool over SSH (`SSH_CONNECTION` is set) mutes the Mac's sound output first: the device's mute, or its volume set to zero when it has no mute. The process tap still hears the song. The hotkey unmutes it, since it means that someone is at the Mac. The HUD closing doesn't, since nobody may be there to hear it. The web remote leaves the sound output to its **Output** control.

Spotify plays on the device that Spotify Connect has picked. When that is another device, the Mac plays nothing and Muskey doesn't find a key.

#### Links

`--link` copies the file into `~/Library/Caches/Muskey/Shared/<token>/`, where the token is 128 random bits, and prints `http://<address>:25471/l/<token>/<name>`. The address is the one picked in Settings > Remote > Address. **Automatic** picks Tailscale's when it is up, or else the local network's, and so does a picked address that is gone for now.

The Address menu lists each private address with the name of its network (from System Settings > Network and > VPN), the DNS name that leads back to each one (Tailscale's MagicDNS name, or a router's), and the Mac's local hostname (`<name>.local`). A name is listed only when its forward lookup gives one of the Mac's addresses again.

The server in `WebServer.swift` listens on port 25471 of each private address of the Mac, and never on all of them: RFC 1918 and link-local IPv4, 100.64/10 on a tunnel interface only (on Wi-Fi it is a carrier's shared range), IPv6 unique-local, and 127.0.0.1. A request names only a token, so no path from the network reaches the disk. Files go out with byte ranges, which Safari needs to play audio. The links keep working after a restart, and the folder's date ends them after three days.

#### Web remote

While **Web remote** is on in Settings > Remote, the same server answers a page at `/` for paired devices. The pairing link (`/pair/<key>`, with 128 random bits) sets a cookie with `SameSite=Lax`, Settings shows the link as a QR code, and **Reset Link** makes a new key, which unpairs every device. Safari sends a Lax cookie after a QR code scan or a link from another app, and never with a request from another site. The cookie belongs to the host in the link, so a device pairs again after the address changes. The server also refuses a request when:

- its Host isn't one of the Mac's addresses or the DNS name picked in Settings (exactly that one), which stops a web page elsewhere from reaching the remote through a DNS name that resolves to the Mac
- it changes something, and its Origin isn't the address of the remote

The page (`Web/remote.html`, `remote.js` and `remote.css`) has the HUD's key row with both modes, tempo and instruments, drawn with the HUD's colours and with SF Symbols that the app renders as PNG masks (`/api/symbol/<name>`, from a fixed list). It asks for the HUD's state every 1.5 seconds: the song that plays, its position, its key, the change, the tempo and the muted instruments. A change to the song that plays is sent at once, as a play without an input. The buttons under the song send `/api/transport`, which plays, pauses and seeks the way Space, ← and → do over the HUD.

The Mac always plays. A tap on a song of Recents plays it there through `CLIService`, the way the tool does, and the song view shows the song that plays. The page lists Recents by an ID made from each song's URL, never by a path. The notes come from a write job in JSON, and `Web/sheet.js` draws them as the notes window does, with its line on the Mac's position.

The home view opens songs on the Mac in three more ways:

- A link of Spotify or of any site that yt-dlp reads is sent to `/api/open`. Its job follows the download in Muskey Player, so the phone shows its steps and its failure.
- A file from the phone is the body of `POST /api/upload`. The server checks the pairing and the origin on the headers alone, then writes the body straight into `~/Library/Caches/Muskey/Uploads/<token>/` as it arrives, up to 2 GB. Uploads are deleted after a week.
- `/api/files` lists the songs in the folders that Settings > Remote names. The folders are walked off the main thread, and the list is kept for a minute. The walk leaves out the Music app's library, which would bring up a prompt for access, and stops at 20 000 songs.

**Output** picks where the song is heard. With **Phone**, the page opens `/api/stream`, and the Mac mutes its sound output and keeps the pitch change running. The pitch change copies its output into a ring (`ps_stream_*` in `pitch.cpp`), written on the audio thread without locks, and `WebStream` sends the frames to every listening phone every 20 ms, at the rate in the `X-Sample-Rate` header. A page that has WebCodecs' `AudioDecoder` asks for `/api/stream?format=aac`: `ADTSEncoder` encodes the frames into AAC-LC at 160 kbps with AudioToolbox, and each packet of 1024 frames is sent behind a 7-byte ADTS header, which the page uses to find the packets and decode them. That is about 70 MB an hour, and a pause costs about 5 kbps. Other browsers get 16-bit stereo PCM, about 1.5 Mbps, and so does a page whose decoder failed once. The encoder holds back about 60 ms of audio. The page plays the audio with Web Audio about a quarter of a second behind the Mac, so a change of key, tempo or instruments is heard on the phone as it is on the Mac. While the pitch change doesn't run, the stream carries silence at the same pace. A phone that falls 2 MB behind is sent away and connects again, and so is one that listens at another rate after the output device changed. Four seconds after the last phone leaves, the Mac's sound output is back as it was. For a player other than Muskey Player, the pitch change hears the whole Mac, so the phone hears every sound that the Mac plays.

The bar at the bottom draws the waveform from `/api/waveform`, the levels that the HUD keeps (50 a second, one byte each), and fetches it again when `wave` in the state changes. A tap on it seeks, a drag across it sets the region loop, and the A and B tabs move the ends (`/api/loop` with `set`, `move` or `press`, which works as R does). A tapped tab is picked, and the buttons beside play then move its end by 20 ms. Save and Transcribe take the loop once it has an end, as write jobs with `from` and `to`. The output button on the right of the bar opens a menu with the Mac and this phone.

While the song view shows, the page asks for the state with `view=song`, and Muskey loads the stems model as it does for a pointer over the HUD, so a tap on an instrument doesn't wait for it. The position on the phone is the one that is heard, which runs behind the player while the stems play, as the lyrics do.

The page reports what goes wrong on the phone to `/api/log`, which writes it into Muskey's log as `remote page:` lines (at most 30 a minute), and every 10 seconds while it listens, the seconds of audio received, their peak level and how far ahead the phone plays.

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
| `--lyrics-align FILE --lyrics-ref LYRICS` | Time the lyrics of a song file by the heard words, by the fit onto the vocals, and by both together as the lyrics show them. Print how far each lands from the times in LYRICS (TTML or LRC), and quit. The last line is the offset that LYRICS would be moved by. |
| `--lyrics-heard mix`, `--lyrics-heard none` | For `--lyrics-align`: let the speech model hear the whole song instead of the vocals, or skip it |
| `--lyrics-part A-B,C-D` | For `--lyrics-align`: also fit each of those parts of the song alone, in seconds, as a song from another app is fitted. `--lyrics-shift S` moves the lyrics with times by S seconds first |
| `--lyrics-live FILE --lyrics-ref LYRICS` | Play a song file through the lyrics code as a song from another app, ten times faster than real time. Print how far the lines land from the times in LYRICS when each line was highlighted, at the end of the play and at the start of the next play, and quit. `--plays` sets the plays as for `--lyrics-replay` |
| `--lyrics-synced FILE` | For `--lyrics-live`: show the lyrics of FILE with their times (`ref` for LYRICS itself), moved by `--lyrics-shift S` seconds, and print what the check of their times says |
| `--live-fit off`, `--live-listener off` | For `--lyrics-live`: leave out the lyrics timing model, or the speech model |
| `--live-speed N` | For `--lyrics-live`: play N times faster than real time. The words come from the speech model about as late in real time at any speed, so the lines are highlighted later at a high speed than in a real play |
| `--live-jitter B,J` | For `--lyrics-live`: report the song's position B seconds off, with up to J seconds more that change every 5 seconds |
| `--lyrics-vocals FILE` | For `--lyrics-align` and `--lyrics-live`: take the vocals from an audio file instead of separating the song. `--lyrics-live` hands them over late and in pieces, as the live separation does |
| `--lyrics-align-out FILE` | For `--lyrics-align` and `--lyrics-live`: write the time of every line and word as JSON |
| `--aligner-model DIR` | Keep the lyrics timing model in DIR instead of the models folder |
| `--aligner-install ZIP` | Install the lyrics timing model from a zip |

### Notes

| Flag | Action |
|---|---|
| `--transcribe FILE` | Turn an audio file into notes with Dettato, print the first notes and how long it took, and quit. `--stem NAME` gives the notes the instrument of that stem |
| `--notes-headless FILE` | Separate the song into stems when the cache doesn't have them, turn the stem of `--stem NAME` (bass by default) into notes, write them to `--notes-out DIR` as JSON, MusicXML, MIDI and text tab, and quit |
| `--notes-file FIXTURE` | Open the notes window on the notes that `--notes-headless` wrote, without a song |
| `--notes-render FIXTURE --notes-out DIR` | Write a PNG of the notes window in each view on a tall and a wide page, and quit. `--notes-at S` draws the line at S seconds into the song, `--notes-loop A-B` shows a region loop, `--notes-shift N` transposes, `--notes-fold F` stops each half in a page turn with the fold at F (1 is the right edge, 0 the left), and `--light` renders in light mode |
| `--dettato-check DIR` | Compare the spectrogram and the network's maps with the ones that `make dettato-model` saved in DIR, and quit |
| `--dettato-install ZIP`, `--dettato-download` | Install the transcription model from a zip, or download it the way Settings does |
| `--chords FILE` | Print the beats and the chords that the lyrics would show over the file, and quit. `--key Em` fits the chords to that key, and `--chord-step N` finds a chord every N beats instead of every 2 |

### Files and links

| Flag | Action |
|---|---|
| `--open PATH_OR_LINK` | Play a file or a link, as a drop on the HUD does |
| `--install-yt-dlp` | Press **Install yt-dlp**, as for a link that needs it |
| `--no-yt-dlp` | Look for yt-dlp only in Muskey's folder, as on a Mac without Homebrew's or pipx's copy |
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
| `--test-sentry` | Send one event to the `dev` environment of Muskey's Sentry project, print its ID, and quit |
| `--test-hang S` | Block the main thread for S seconds, 3 seconds after launch, and report hangs to Sentry from 2 seconds on |

Muskey writes each result to its log, which [Logs](#logs) explains how to read.
