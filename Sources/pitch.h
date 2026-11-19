#pragma once

#include <CoreAudio/CoreAudioTypes.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Shifts the pitch of a process tap's stream with Rubber Band (R3 engine, real-time mode) and writes it to the
// output device, at the same tempo. The tap and callback plumbing is adapted from PitchTap
// (github.com/gkudva96/pitchtap, GPL-3.0).
//
// Create and destroy off the audio thread. ps_process runs on the IOProc's real-time thread, with every buffer
// it uses sized at creation; ps_set_semitones may be called from any thread and applies on the next process call.
typedef struct PSShifter PSShifter;

// `tapIsPlanar`: the tap delivers left and right in two buffers instead of one interleaved buffer.
// `recordSeconds` > 0 keeps the first seconds of the shifter's input and output, for checking a live run.
PSShifter *ps_create(double sampleRate, int tapIsPlanar, double recordSeconds);
void ps_destroy(PSShifter *shifter);

// A change starts a second stretcher at the new pitch, and about 0.2 s later crossfades to it over 0.2 s. A new
// pitch set during a crossfade starts once that crossfade ends.
void ps_set_semitones(PSShifter *shifter, float semitones);

// The pitch heard while no crossfade runs, or NaN while one is under way.
float ps_playing_semitones(PSShifter *shifter);

// `input` is the aggregate device's input: any input streams of the output device, then the tap's stream(s).
// `output` gets the shifted left and right on its first two channels, or their average on a mono device.
void ps_process(PSShifter *shifter, const AudioBufferList *input, AudioBufferList *output);

// Frames of non-silent audio received from the tap so far.
uint64_t ps_frames_heard(PSShifter *shifter);

// Callbacks that ran out of shifted audio and played silence, after the output first started.
uint64_t ps_underruns(PSShifter *shifter);

// Stems: bass, drums, other, vocals, guitar, piano, in the order of the separation model, then the winds, which the
// winds model finds in the song and takes out of the Other stem (silent without that model).
#define PS_STEMS 7

// While the stems are on, the output plays the separated stems, mixed by their gains, a few seconds behind the song,
// in place of the tap's audio. Until the first block is separated the song plays as it is, and then the output
// crossfades into the stems. Turning them off crossfades back to the song as it plays. Any thread.
void ps_stems_enable(PSShifter *shifter, int on);
// The player paused the song (1) or plays it again (0). Once the tap is silent too, the stems are held where they
// are and the silence isn't captured, so the pause and the resume are heard at once despite the stems' delay.
void ps_set_paused(PSShifter *shifter, int paused);
// The song changed or moved while it was paused: the stems start over, and the song plays as it is until the first
// block of the new song is separated.
void ps_stems_restart(PSShifter *shifter);
void ps_stems_set_gain(PSShifter *shifter, int stem, float gain);
// The volume of a stem on top of its gain, from 0 to 1.5, which glides to the new value over about 15 ms.
void ps_stems_set_volume(PSShifter *shifter, int stem, float volume);
// The level of a stem as it plays, for a meter.
float ps_stems_level(PSShifter *shifter, int stem);
// Seconds that the output plays behind the song, 0 while the stems are off.
double ps_stems_delay(PSShifter *shifter);
// How long the next mute or unmute of a stem takes, in seconds.
void ps_stems_set_fade(PSShifter *shifter, double seconds);
// Karaoke that starts the song over. 1 fades the output out while the player moves the song to its start, and the
// stems don't start until a restart from ps_stems_restart_back; after it, the song fades in from its start as it
// plays, and the stems step back to that start once they are separated. 0 ends the wait. The dip lasts 15 seconds at
// most. Any thread.
void ps_stems_await_seek(PSShifter *shifter, int on);
// 1 steps back in the song with a fade out and a fade in, 0 with a backspin. Any thread.
void ps_set_step_fade(PSShifter *shifter, int fade);
// Starts the stems over as ps_stems_restart does, from `seconds` before the moment that plays, within the frames
// captured since the stems were turned on.
void ps_stems_restart_back(PSShifter *shifter, double seconds);
// How many backspins the output has played: one each time it stepped back in the song.
uint32_t ps_spins(PSShifter *shifter);
// While the stems are on and the song still plays as it is, waiting for the first separated block: the seconds
// since the stems were turned on. -1 otherwise, and while the delay below waits.
double ps_stems_waiting(PSShifter *shifter);
// 1 while the stems are on and their first block plays.
int ps_stems_started(PSShifter *shifter);

// Plays the song `seconds` behind itself, or the stems when they are on, for lyrics written by ear. Raising it leaves
// the output as it is until that many seconds are captured, then steps back to the moment it was raised. 0 plays the
// song as it is again, or the stems at their own lag. Pauses hold it as they hold the stems. Any thread.
void ps_set_delay(PSShifter *shifter, double seconds);
// Seconds until a delay that was raised steps back, or -1 when none waits. A pause stops the count.
double ps_delay_waiting(PSShifter *shifter);

// For the separation thread. Each start of the stems is a new generation, which starts at a frame of the captured
// audio. The thread reads the captured audio from that frame on, calls ps_stems_begin once per generation, then
// writes the stems in order: PS_STEMS * 2 planes, left and right of each stem.
uint64_t ps_stems_generation(PSShifter *shifter, uint64_t *start);
size_t ps_captured_read(PSShifter *shifter, uint64_t *position, float *left, float *right, size_t max);
// How many captured frames from `position` on the thread may separate before its stems would overwrite stems that
// the output has yet to play.
size_t ps_stems_room(PSShifter *shifter, uint64_t position);
void ps_stems_begin(PSShifter *shifter, uint64_t generation, uint64_t start);
void ps_stems_write(PSShifter *shifter, const float *const *planes, size_t frames);
// The newest captured frame, and the frame of the stems that the output plays.
uint64_t ps_captured_written(PSShifter *shifter);
uint64_t ps_stems_played(PSShifter *shifter);

// Stems from a cache of the whole song, for a song that Muskey Player plays. The writer has the stems of every moment,
// so it writes them ahead of the song, lined up frame for frame with the captured song, and the output plays them at
// the moment that plays: once they are there, they take over at once with a short crossfade, with no backspin. The
// writer calls ps_stems_begin_cached in place of ps_stems_begin for such a generation.
void ps_stems_begin_cached(PSShifter *shifter, uint64_t generation, uint64_t start);
// 1 while the stems of the current generation come from the cache, whether they play yet or not.
int ps_stems_cached(PSShifter *shifter);
// Takes back the stems written from `from` on, so that the writer writes them again, after the song moved or its speed
// changed: never closer than `guard` frames to the frame that the output plays, which the output may be reading. Returns
// the frame that the writer carries on from, or 0 when `generation` isn't the one written.
uint64_t ps_stems_rewrite(PSShifter *shifter, uint64_t generation, uint64_t from, uint64_t guard);
// The app moved the song while cached stems play (any thread): the output goes silent at once, and stays silent until the
// writer answered with the frame from which the stems are of the new place, for 3 seconds at most. Returns the number of
// the move, which the answer names.
uint32_t ps_stems_seek(PSShifter *shifter);
// The moves asked for so far, and in `answered` the last one that the writer answered.
uint32_t ps_stems_seeks(PSShifter *shifter, uint32_t *answered);
void ps_stems_seek_answer(PSShifter *shifter, uint32_t seek, uint64_t from);
// Pauses so far, and the last one: the captured song left out its silence, and from captured frame `to` on, it carries
// on from frame `from`. The writer of cached stems writes them again from `to`, then calls ps_stems_skip_mapped with the
// count, and until then the output reads no stems from `to` on.
uint32_t ps_stems_skips(PSShifter *shifter, uint64_t *from, uint64_t *to);
void ps_stems_skip_mapped(PSShifter *shifter, uint32_t skips);

// Slowing down a song from another player. The player plays at its own speed, so the tap's audio waits in a backlog
// that the output reads back slower, resampled as a record played slower is: lower as well, which the voices undo by
// the correction that the app adds to the semitones, as for a song that Muskey Player plays slower. Everything after
// the slowing (the stems, the delay, the pauses, the voices) hears the slowed song as if a player played it.
//
// ps_slow_prepare sets aside the backlog, `seconds` long, once, off the audio thread; nothing slows down before it.
// ps_slow_enable starts or stops reading through the backlog, with a 5 ms crossfade either way. Any thread.
void ps_slow_prepare(PSShifter *shifter, double seconds);
void ps_slow_enable(PSShifter *shifter, int on);
// The speed that the backlog is read at, from 0.25 to 2. Above 1 the reader catches up with the player.
void ps_slow_set_speed(PSShifter *shifter, double speed);
// The reader jumps to the newest audio with a 10 ms crossfade: after the song moved or changed.
void ps_slow_flush(PSShifter *shifter);
// The player played a moment again, after the app moved it back: backlog frame `to` holds the same moment of the song
// as frame `from`. When the reader reaches `from` it steps to `to`, with a 5 ms crossfade, so nothing is heard twice.
// A reader already at `before` (where the audio of the move starts) has heard the move, and the splice is dropped.
void ps_slow_splice(PSShifter *shifter, uint64_t from, uint64_t to, uint64_t before);

typedef struct {
    int engaged;          // the output reads through the backlog
    uint64_t written;     // backlog frames written so far, counted from an arbitrary start
    uint64_t reading;     // the frame that the reader is at
    double clock;         // frames of the song that the reader has played: the song's time, apart from moves
    uint32_t splices;     // splices that the reader stepped through
    uint32_t missed;      // splices that came after the reader had passed them
    uint32_t flushes;     // flushes that the reader carried out
} PSSlowState;
PSSlowState ps_slow_state(PSShifter *shifter);
// Copies backlog frames from `position` on, at most `max`, for finding a splice. Returns how many were copied; frames
// already overwritten are skipped, and `position` moves past them.
size_t ps_slow_read(PSShifter *shifter, uint64_t *position, float *left, float *right, size_t max);

// What was recorded so far as interleaved (input, output) pairs of the left channel, and how many frames.
size_t ps_recording(PSShifter *shifter, const float **pairs);

// For saving a song: changes the tempo and the pitch of stereo audio offline with Rubber Band's R3 engine, then limits
// its peaks as the live output does. `timeRatio` 1.25 makes it a quarter longer, and `pitchScale` 2 makes it an octave
// higher. With both at 1, only the limiter runs. `progress` gets the part done, from 0 to 1, and stops the render when
// it returns 0. Returns the frames written to the two buffers, which go back through ps_render_free, or 0 when stopped.
// Any thread but the IOProc's.
size_t ps_render(const float *left, const float *right, size_t frames, double rate, double timeRatio, double pitchScale,
                 float **outLeft, float **outRight, int (*progress)(void *context, double done), void *context);
void ps_render_free(float *samples);

#ifdef __cplusplus
}
#endif
