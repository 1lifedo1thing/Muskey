# Developing Muskey

## How it works

- **Listening**: a Core Audio process tap on the whole system mix, which needs the **System Audio Recording** permission and no loopback driver.
- **Finding the key**: [Essentia](https://essentia.upf.edu)'s KeyExtractor with the `shaath` profile, run once a second over everything heard so far.
- **Changing the key**: a second tap mutes every app except Muskey. Muskey runs that audio through [Rubber Band](https://breakfastquay.com/rubberband/)'s R3 engine and a limiter, then plays the result on the default output. The tap is private to Muskey, so when Muskey quits or crashes, the Mac plays its audio unchanged again.
- **Now Playing**: macOS has no public API for the song that plays, so a small helper reads it from the private MediaRemote framework. Since macOS 15.4, MediaRemote answers only code signed with an Apple identifier, so the helper is signed as `com.apple.controlcenter.Muskey`.
- **Hotkey**: Carbon's `RegisterEventHotKey`, which works without the Accessibility permission.
- **Keys from NoiseBlend**: when a listen starts on a song that Muskey hasn't heard before, Muskey sends the title, artist, album and length of the song to [NoiseBlend](https://www.noiseblend.com), which answers with the key that Spotify lists for it. Each song is asked for once. The listen still runs, and the key that it finds counts over NoiseBlend's.
- **Lyrics**: while the lyrics show, Muskey sends the title, artist, album and length of the song to [LRCLIB](https://lrclib.net) to find them, once per song.
- **Stems**: [BS-RoFormer](https://arxiv.org/abs/2309.02612) in the BS-Roformer-SW checkpoint, which gives six stems, converted to Core ML and run on the GPU. Muskey separates the song in windows of 4.5 seconds that overlap by a second, crossfades them, and plays the mix of the stems that are on through the same pitch change. The Winds stem comes from the woodwind and brass heads of [MVSep](https://mvsep.com)'s 53-stem BS-RoFormer, which run on the same windows of the song, and what they find is taken out of the Other stem. The models download from lowtechguys.com into `~/Library/Application Support/Muskey/Models`, and `make stems-model` and `make winds-model` make them from the checkpoints.
- **Whisper**: [whisper.cpp](https://github.com/ggml-org/whisper.cpp) with the large-v3-turbo model on the GPU, or a server that answers `POST /v1/audio/transcriptions`. Muskey sends it a phrase of the vocals at a time, cut at the pauses in the singing. A server gets the audio of the song, so pick one that you trust.
- **Timing lyrics by ear**: Apple's speech model transcribes the song on the Mac, through the Speech framework's `SpeechTranscriber`. For languages that only `DictationTranscriber` knows, Whisper times the lyrics when it is set up in Settings, and `DictationTranscriber` when it isn't. After three failed clips in a row, Whisper stops: lyrics that it was timing go back to Apple's model, and lyrics that it was writing end with a Retry button. Muskey matches the heard words to the lyrics in order, so a chorus that repeats lands on the right verse. macOS downloads the model once, from Apple, when it isn't on the Mac yet. The heard words and the lyrics added by hand stay in `~/Library/Application Support/Muskey/lyrics.json`.

## Limitations

- A pitch change moves every note by the same amount, so a major song stays major. A key in the other mode is reached through its relative, which has the same notes: from A major, C minor plays as E♭ major.
- A screen recording with system audio hears both the original song and the shifted one. To record only the shifted song, use a recorder that captures audio per app, and leave out the app that plays the song.

## Flags for testing

Builds made with `make` or `make install` take these flags, and release builds ignore them. Pass them with `open -a Muskey --args …`:

- `--listen` starts a listen at launch, `--seconds N` changes its length, and `--wav PATH` saves what it heard as a mono WAV
- `--pick` opens the key picker on a sample key, `--shift N` starts a pitch change of N semitones, and `--keep KEY` locks a key like `Cm`, `F#` or `Eb`
- `--shift-wav PATH` saves the first 10 seconds of a pitch change as a stereo WAV, with the input on the left and the output on the right, and `--shift-wav-seconds N` saves N seconds
- `--stems-only NAMES` plays only the stems in NAMES, like `guitar,vocals`, after `--stems-after N` seconds (3 by default, 0 starts with a cold model)
- `--stems-file PATH` separates a song file into `--stems-out DIR` and prints how fast it went, `--stems-install ZIP` and `--winds-install ZIP` install the separation models from a zip, and `--stems-download`, `--winds-download` and `--whisper-download` download the models the way Settings does
- `--key-lookup "Title|Artist|Album|Seconds"` asks NoiseBlend for the key of that song, prints the answer and quits
- `--render DIR` writes a PNG of each HUD state and quits
- `--log-keys` logs every key and click that reaches the HUD, with the host time of each line
- `--lyrics-test FILE` plays a made-up song with the lyrics in FILE (LRC, or plain text for estimated timing) from `--lyrics-at N` seconds, or from the Unix time in `--lyrics-since T` to line it up with a file that `afplay` plays, and opens the lyrics. The lyrics that Whisper writes for it are kept in `/tmp/muskey-lyrics-test.json`, apart from the real ones
- `--lyrics-replay FILE --whisper-server URL` plays a song file through the lyrics code four times faster than real time, once for each play in `--plays` (like `0-60,0-end`, or `0-40+100-140` for a seek), as a song that has no lyrics. It prints what each play sent to Whisper and the parts of the song that it saved, in `/tmp/muskey-lyrics-replay.json`
- `--lyrics-plain` drops the times of synced lyrics, so they get timed by listening, and logs how far the heard times are from the dropped ones. With `--pick`, the lyrics show from the start
- `--selftest` runs a 440 Hz tone through the pitch shifter, checks the pitch, gaps, timing and level that come out, and quits

Muskey writes each result to `~/Library/Logs/Muskey.log`.

