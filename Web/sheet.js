// Muskey's notes sheet in a browser: the transcription of one stem drawn as tab, sheet music or a piano roll, the way
// Muskey's notes window draws it, with the key, the capo and the pages that the window has. It has no audio of its own.
// The same file runs inlined in the page that `muskey --notes` exports, in a live page that follows the playing song,
// and under node for the parity test, so it uses no imports or exports and puts its one name on the global object.
//
// The model below is a port of Score and Spelling in Notation.swift and of NotesModel.rebuild, NotesStaff and
// NotesLayout in NotesWindow.swift, in the same order and with the same arithmetic, so that a note lands on the same
// bar, string and fret, and gets the same name, as in the window.

(() => {
    "use strict";

    // MARK: Model

    const BEATS_PER_BAR = 4;

    /** Swift's `rounded()`: halves round away from zero, where `Math.round` rounds them up. */
    const round = (x) => (x < 0 ? -Math.round(-x) : Math.round(x));
    const trunc = Math.trunc;
    const numeric = (a, b) => a - b;

    const STEMS = ["bass", "drums", "other", "vocals", "guitar", "piano", "winds"];
    const STEM_NAMES = { bass: "Bass", drums: "Drums", other: "Other", vocals: "Vocals", guitar: "Guitar", piano: "Piano", winds: "Winds" };
    const VIEWS = ["tab", "sheet", "roll"];
    const VIEW_NAMES = { tab: "Tab", sheet: "Sheet", roll: "Piano roll" };

    /** The stem of a fixture by its name, bass when the name is unknown, as `NotesFixture.stemValue` does. */
    function stemOf(name) {
        const lower = String(name ?? "").toLowerCase();
        return STEMS.includes(lower) ? lower : "bass";
    }

    const hasTab = (stem) => stem === "bass" || stem === "guitar";

    /** `NotesView.preferred(for:)`. */
    function preferredView(stem) {
        if (hasTab(stem)) return "tab";
        if (stem === "piano" || stem === "vocals" || stem === "winds") return "sheet";
        return "roll";
    }

    const MAJOR_NAMES = ["C", "D♭", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"];
    const MINOR_NAMES = ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "G♯", "A", "B♭", "B"];

    /** `DetectedKey`: a tonic and a mode. */
    class Key {
        constructor(pitchClass, minor) {
            this.pitchClass = pitchClass;
            this.minor = minor;
        }

        /** A key written like `Cm`, `F#` or `Bbm`, the way a fixture stores it. */
        static parse(name) {
            if (typeof name !== "string" || name.length === 0) return null;
            const letters = "C D EF G A B";
            const letter = name[0];
            if (letter === " ") return null;
            let pitchClass = letters.indexOf(letter);
            if (pitchClass < 0) return null;
            let rest = name.slice(1);
            if (rest.length > 0 && "#♯b♭".includes(rest[0])) {
                pitchClass += "#♯".includes(rest[0]) ? 1 : -1;
                rest = rest.slice(1);
            }
            if (rest !== "" && rest !== "m") return null;
            return new Key((pitchClass + 12) % 12, rest === "m");
        }

        transposed(semitones) {
            return new Key((((this.pitchClass + semitones) % 12) + 12) % 12, this.minor);
        }

        /** The same notes in the other mode: a minor third up from minor, down from major. */
        get relative() {
            return new Key((this.pitchClass + (this.minor ? 3 : 9)) % 12, !this.minor);
        }

        get tonic() {
            return (this.minor ? MINOR_NAMES : MAJOR_NAMES)[this.pitchClass];
        }

        get name() {
            return `${this.tonic} ${this.minor ? "minor" : "major"}`;
        }

        get short() {
            return this.tonic + (this.minor ? "m" : "");
        }

        /** `DetectedKey.code`, the name that a fixture stores. */
        get code() {
            return ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"][this.pitchClass] + (this.minor ? "m" : "");
        }
    }

    /**
     * The notes of one stem placed on the song's beats: each note gets a bar and a place in it, rounded to a
     * sixteenth, and a string and a fret for tab. Every bar has four beats and the first beat that the beat tracker
     * found starts the first bar, as in the window.
     */
    class Score {
        constructor(raw, stem, beats, bpm, key, duration, capo = 0) {
            this.stem = stem;
            this.key = key;
            this.bpm = bpm;
            this.capo = capo;
            this.tuning = Score.tuning(stem);
            /** Bars that stand for a run of bars without notes, and how many bars each one stands for. */
            this.rests = new Map();
            /** The number in the song of each bar, while rests stand for several bars. */
            this.numbers = [];
            let latest = 0;
            for (const note of raw) latest = Math.max(latest, note.end);
            const grid = Score.grid(beats, bpm, Math.max(duration, raw.length ? latest : 0) + 2);
            this.beats = grid;
            const barCount = Math.max(1, trunc((grid.length - 1) / BEATS_PER_BAR));
            this.bars = [];
            for (let index = 0; index < barCount; index++) {
                this.bars.push({
                    index,
                    start: grid[index * BEATS_PER_BAR],
                    end: grid[Math.min(grid.length - 1, (index + 1) * BEATS_PER_BAR)],
                });
            }
            const placed = [];
            for (const note of raw) {
                const start = round(Score.position(note.start, grid) * 4) / 4;
                const end = round(Score.position(note.end, grid) * 4) / 4;
                if (!(start >= 0)) continue;
                const bar = trunc(trunc(start) / BEATS_PER_BAR);
                if (bar >= barCount) continue;
                placed.push({
                    pitch: note.pitch,
                    start: note.start,
                    end: note.end,
                    drum: !!note.drum,
                    program: note.program,
                    bar,
                    beat: start - bar * BEATS_PER_BAR,
                    length: Math.max(0.25, end - start),
                    string: null,
                    fret: null,
                });
            }
            this.notes = hasTab(stem)
                ? Score.fret(placed, this.tuning.map((open) => open + capo), Math.max(12, 20 - capo))
                : placed;
            this._byBar = null;
        }

        static tuning(stem) {
            return stem === "bass" ? [28, 33, 38, 43] : [40, 45, 50, 55, 59, 64];
        }

        /** The beats with the gaps that the tracker left filled at the song's tempo, from the start of the song to its end. */
        static grid(beats, bpm, end) {
            const gaps = [];
            for (let i = 1; i < beats.length; i++) gaps.push(beats[i] - beats[i - 1]);
            gaps.sort(numeric);
            let interval = gaps.length ? gaps[trunc(gaps.length / 2)] : bpm > 0 ? 60 / bpm : 0.5;
            // Beats that repeat would make a gap of nothing, and the loops below would never end.
            if (!(interval > 0)) interval = bpm > 0 ? 60 / bpm : 0.5;
            const grid = beats.length ? beats.slice() : [0];
            // Bars before the first beat, so that notes in a pickup have a place.
            while (grid[0] - interval * BEATS_PER_BAR > -interval / 2) {
                const first = grid[0];
                grid.unshift(first - interval * 4, first - interval * 3, first - interval * 2, first - interval * 1);
            }
            while (grid[grid.length - 1] < end) grid.push(grid[grid.length - 1] + interval);
            while ((grid.length - 1) % BEATS_PER_BAR !== 0) grid.push(grid[grid.length - 1] + interval);
            return grid;
        }

        /** The place of `time` in beats from the first beat of the grid. */
        static position(time, grid) {
            if (grid.length <= 1) return 0;
            if (time <= grid[0]) return (time - grid[0]) / (grid[1] - grid[0]);
            let low = 0;
            let high = grid.length - 1;
            while (high - low > 1) {
                const middle = trunc((low + high) / 2);
                if (grid[middle] <= time) low = middle;
                else high = middle;
            }
            const span = grid[high] - grid[low];
            return low + (span > 0 ? Math.min(1, (time - grid[low]) / span) : 0);
        }

        /**
         * A string and a fret for every note, keeping the hand near where it was. The notes that start together get
         * the strings that keep them within reach of one hand. A note that no free string can play gets no fret.
         */
        static fret(notes, tuning, highest = 20) {
            const result = [];
            let hand = 3.0;
            const groups = new Map();
            notes.forEach((note, index) => {
                const key = note.bar * 64 + trunc(note.beat * 4);
                if (!groups.has(key)) groups.set(key, []);
                groups.get(key).push(index);
            });
            for (const key of [...groups.keys()].sort(numeric)) {
                // The highest notes first, and no more of them than there are strings.
                const sorted = groups.get(key).slice().sort((a, b) => notes[b].pitch - notes[a].pitch);
                const playable = sorted.slice(0, tuning.length);
                let best = null;
                const picks = [];
                const used = new Set();
                const cost = () => {
                    const fretted = picks.filter((pick) => pick !== null).map((pick) => pick.fret).filter((fret) => fret > 0);
                    const skipped = picks.filter((pick) => pick === null).length;
                    if (fretted.length === 0) return skipped * 12;
                    const low = Math.min(...fretted);
                    const high = Math.max(...fretted);
                    const center = fretted.reduce((sum, fret) => sum + fret, 0) / fretted.length;
                    return Math.abs(center - hand) + Math.max(0, high - low - 3) * 4 + center * 0.08 + skipped * 12;
                };
                const search = (index, skips) => {
                    if (index >= playable.length) {
                        const total = cost();
                        if (total < (best ? best.cost : Infinity)) best = { cost: total, picks: picks.slice() };
                        return;
                    }
                    const pitch = notes[playable[index]].pitch;
                    for (let string = 0; string < tuning.length; string++) {
                        if (used.has(string)) continue;
                        const fret = pitch - tuning[string];
                        if (fret < 0 || fret > highest) continue;
                        used.add(string);
                        picks.push({ string, fret });
                        search(index + 1, skips);
                        picks.pop();
                        used.delete(string);
                    }
                    // A note may go without a string only when the others can't all be placed.
                    if (skips > 0) {
                        picks.push(null);
                        search(index + 1, skips - 1);
                        picks.pop();
                    }
                };
                search(0, 0);
                if (best === null) search(0, playable.length);
                sorted.forEach((index, position) => {
                    const note = { ...notes[index] };
                    const pick = best && position < playable.length ? best.picks[position] : null;
                    if (pick) {
                        note.string = pick.string;
                        note.fret = pick.fret;
                    }
                    result.push(note);
                });
                const fretted = (best ? best.picks : []).filter((pick) => pick !== null).map((pick) => pick.fret).filter((fret) => fret > 0);
                if (fretted.length) hand = hand * 0.6 + (fretted.reduce((sum, fret) => sum + fret, 0) / fretted.length) * 0.4;
            }
            return result.sort((a, b) => a.bar - b.bar || a.beat - b.beat || a.pitch - b.pitch);
        }

        /**
         * The score as the window shows it: each run of two or more bars where no note sounds becomes one bar of rest,
         * whose four beats are spread over the whole run. Times map to it as to the score.
         */
        collapsingRests() {
            const bars = this.bars;
            const sounding = new Array(bars.length).fill(false);
            for (const note of this.notes) {
                const first = Math.max(0, note.bar);
                let bar = first;
                while (bar < bars.length && (bar === first || bars[bar].start < note.end - 0.01)) {
                    sounding[bar] = true;
                    bar += 1;
                }
            }
            const grid = [];
            const rests = new Map();
            const numbers = [];
            let bar = 0;
            while (bar < bars.length) {
                let run = 0;
                while (bar + run < bars.length && !sounding[bar + run]) run += 1;
                if (run >= 2) {
                    const start = bars[bar].start;
                    const end = bars[bar + run - 1].end;
                    rests.set(numbers.length, run);
                    numbers.push(bar + 1);
                    for (let beat = 0; beat < BEATS_PER_BAR; beat++) grid.push(start + ((end - start) * beat) / BEATS_PER_BAR);
                    bar += run;
                } else {
                    numbers.push(bar + 1);
                    for (let beat = 0; beat < BEATS_PER_BAR; beat++) grid.push(this.beats[bar * BEATS_PER_BAR + beat]);
                    bar += 1;
                }
            }
            if (rests.size === 0) return this;
            grid.push(this.beats[bars.length * BEATS_PER_BAR]);
            const raw = this.notes.map((note) => ({ start: note.start, end: note.end, pitch: note.pitch, program: note.program, drum: note.drum }));
            const shown = new Score(raw, this.stem, grid, this.bpm, this.key, 0, this.capo);
            shown.rests = rests;
            shown.numbers = numbers;
            return shown;
        }

        /** The number in the song of a bar, from 1. */
        number(bar) {
            return bar >= 0 && bar < this.numbers.length ? this.numbers[bar] : bar + 1;
        }

        /** The time of a place in beats, the opposite of `position`. */
        time(position) {
            const beats = this.beats;
            if (beats.length <= 1) return 0;
            const index = Math.max(0, Math.min(beats.length - 2, Math.floor(position)));
            return beats[index] + (beats[index + 1] - beats[index]) * (position - index);
        }

        /** The bar that plays at `time`, and how far into it, from 0 to 1. */
        place(time) {
            const position = Score.position(time, this.beats);
            if (!(position >= 0)) return null;
            const bar = trunc(trunc(position) / BEATS_PER_BAR);
            if (bar >= this.bars.length) return null;
            return { bar, fraction: (position - bar * BEATS_PER_BAR) / BEATS_PER_BAR };
        }

        /** The notes of each bar. */
        get notesByBar() {
            if (!this._byBar) {
                const byBar = this.bars.map(() => []);
                for (const note of this.notes) if (note.bar >= 0 && note.bar < byBar.length) byBar[note.bar].push(note);
                this._byBar = byBar;
            }
            return this._byBar;
        }

        /** The width that the busiest bars need, so that the fret numbers and notes of neighbouring places don't overlap. */
        get busiestBarWidth() {
            const widths = [];
            for (const notes of this.notesByBar) {
                const places = [...new Set(notes.map((note) => round(note.beat * 4)))].sort(numeric);
                if (places.length <= 1) {
                    if (places.length === 1) widths.push(0);
                    continue;
                }
                let closest = Infinity;
                for (let i = 1; i < places.length; i++) closest = Math.min(closest, places[i] - places[i - 1]);
                widths.push((16 / Math.max(1, closest)) * 15 + 24);
            }
            widths.sort(numeric);
            if (widths.length === 0) return 0;
            return widths[Math.min(widths.length - 1, trunc((widths.length * 4) / 5))];
        }

        /** A region from `start` to `end` in beats, widened so that no note crosses either end. */
        encompassing(start, end) {
            const spans = this.notes.map((note) => {
                const from = note.bar * BEATS_PER_BAR + note.beat;
                return [from, from + note.length];
            });
            for (let i = 0; i < 8; i++) {
                let earlier = start;
                let later = end;
                for (const [from, to] of spans) {
                    if (from < start - 0.01 && to > start + 0.01) earlier = Math.min(earlier, from);
                    if (from < end - 0.01 && to > end + 0.01) later = Math.max(later, to);
                }
                if (earlier === start && later === end) break;
                start = earlier;
                end = later;
            }
            return [Math.max(0, start), end];
        }
    }

    const SHARP_ORDER = [6, 1, 8, 3, 10, 5, 0];
    const FLAT_ORDER = [10, 3, 8, 1, 6, 11, 4];
    /** The pitch class of each letter without a sharp or a flat, from C to B. */
    const NATURALS = [0, 2, 4, 5, 7, 9, 11];
    const LETTERS = ["C", "D", "E", "F", "G", "A", "B"];

    /** Note names in the key of the song: its key signature, and the letter, accidental and staff step of each pitch. */
    class Spelling {
        constructor(key) {
            // The major key with the same notes: the relative major of a minor key.
            const major = key ? (key.minor ? (key.pitchClass + 3) % 12 : key.pitchClass) : 0;
            const sharps = { 0: 0, 7: 1, 2: 2, 9: 3, 4: 4, 11: 5, 6: 6 };
            const flats = { 5: 1, 10: 2, 3: 3, 8: 4, 1: 5 };
            if (major in sharps) {
                this.flats = false;
                this.signature = SHARP_ORDER.slice(0, sharps[major]);
            } else {
                this.flats = true;
                this.signature = FLAT_ORDER.slice(0, flats[major] ?? 0);
            }
            const letters = NATURALS.slice();
            for (const pitchClass of this.signature) {
                // A flat lowers the letter above its pitch class, and a sharp raises the letter under it.
                const letter = NATURALS.indexOf((pitchClass + (this.flats ? 1 : 11)) % 12);
                letters[letter] = pitchClass;
            }
            this.letterPitches = letters;
            this.leadingTone = null;
            const tonic = key && key.minor ? letters.indexOf(key.pitchClass) : -1;
            if (tonic >= 0) {
                const letter = (tonic + 6) % 7;
                const pitchClass = (key.pitchClass + 11) % 12;
                // A leading tone two semitones over its letter would need a double sharp.
                const over = (pitchClass - NATURALS[letter] + 12) % 12;
                if (over <= 1) this.leadingTone = { pitchClass, letter };
            }
        }

        /** The staff step of `pitch` (its octave times 7 plus its letter) and the accidental that it needs in this key. */
        spell(pitch) {
            const pitchClass = ((pitch % 12) + 12) % 12;
            const [letter, accidental] = this.letterOf(pitchClass);
            // A B♯ is written in the octave under its sound, and a C♭ in the octave over it.
            let octave = Math.floor(pitch / 12) - 1;
            if (letter === 6 && pitchClass < 3) octave -= 1;
            if (letter === 0 && pitchClass > 9) octave += 1;
            return { step: octave * 7 + letter, accidental };
        }

        letterOf(pitchClass) {
            const inKey = this.letterPitches.indexOf(pitchClass);
            if (inKey >= 0) return [inKey, null];
            const lead = this.leadingTone;
            if (lead && lead.pitchClass === pitchClass) return [lead.letter, pitchClass === NATURALS[lead.letter] ? "♮" : "♯"];
            // A white key that the signature changes needs a natural sign.
            const natural = NATURALS.indexOf(pitchClass);
            if (natural >= 0) return [natural, "♮"];
            if (this.flats) return [NATURALS.indexOf((pitchClass + 1) % 12), "♭"];
            return [NATURALS.indexOf((pitchClass + 11) % 12), "♯"];
        }

        /** The name of a note as it is written in this key, with the flat or sharp that the signature gives it. */
        name(pitch) {
            const { step, accidental } = this.spell(pitch);
            const letter = LETTERS[((step % 7) + 7) % 7];
            if (accidental === "♮") return letter;
            if (accidental === null) {
                const sign = this.keySign(step);
                return sign === "♮" ? letter : letter + sign;
            }
            return letter + accidental;
        }

        /** The sign that brings a staff step back to the key after another accidental on it in the same bar. */
        keySign(step) {
            const letter = ((step % 7) + 7) % 7;
            switch ((this.letterPitches[letter] - NATURALS[letter] + 12) % 12) {
                case 1:
                    return "♯";
                case 11:
                    return "♭";
                default:
                    return "♮";
            }
        }
    }

    /**
     * `NotesModel.rebuild`: the notes moved by the shift, in the key that the song plays in after it, named in the
     * mode that the HUD names it. The capo counts only for tab. Runs of bars without notes collapse into rests.
     */
    function buildScores(data, state) {
        const stem = stemOf(data.stem);
        const notes = Array.isArray(data.notes) ? data.notes : [];
        const shift = state.shift | 0;
        const moved = shift === 0 ? notes : notes.map((note) => ({ ...note, pitch: note.pitch + shift }));
        const key = Key.parse(data.key);
        const shown = key ? (state.relative ? key.transposed(shift).relative : key.transposed(shift)) : null;
        const bpm = data.bpm > 0 ? data.bpm : 120;
        const full = new Score(moved, stem, Array.isArray(data.beats) ? data.beats : [], bpm, shown, data.duration || 0, hasTab(stem) ? state.capo | 0 : 0);
        return { stem, key, shown, full, score: notes.length ? full.collapsingRests() : full };
    }

    // MARK: Layout

    const TAB_GAP = 11;
    const STAFF_GAP = 7;
    const ROW_HEIGHT = 4;
    /** The gap between the two staves of a grand staff. */
    const GRAND_GAP = 44;
    const MARGIN = 16;

    /** The heights inside one line of notes, which depend on the view and the stem. */
    class Staff {
        constructor(view, score) {
            this.view = view;
            this.strings = score.tuning.length;
            this.grand = score.stem === "piano";
            const pitches = score.notes.filter((note) => !note.drum).map((note) => note.pitch).sort(numeric);
            const median = pitches.length ? pitches[trunc(pitches.length / 2)] : 60;
            this.bassClef = score.stem === "bass" || (score.stem !== "guitar" && median < 55);
            let low = pitches.length ? pitches[0] : 48;
            let high = pitches.length ? pitches[pitches.length - 1] : 72;
            low -= 1;
            high += 1;
            // At least two octaves, and at most four, around the middle of the notes.
            while (high - low < 24) {
                low -= 1;
                high += 1;
            }
            if (high - low > 48) {
                low = Math.max(low, median - 24);
                high = low + 48;
            }
            this.low = low;
            this.high = high;
        }

        /** From the top of a line to the top of its staff lines, past the bar numbers and the notes above the staff. */
        get linesTop() {
            return this.view === "tab" ? 18 : this.view === "sheet" ? 32 : 16;
        }

        /** The staff lines, or the rows of the piano roll: the part that the moving line covers. */
        get linesHeight() {
            if (this.view === "tab") return TAB_GAP * (this.strings - 1);
            if (this.view === "sheet") return this.grand ? STAFF_GAP * 8 + GRAND_GAP : STAFF_GAP * 4;
            return ROW_HEIGHT * (this.high - this.low + 1);
        }

        /** The whole line, with the room under the staff and the gap to the next line. */
        get height() {
            if (this.view === "tab") return this.linesTop + this.linesHeight + 24 + 14;
            if (this.view === "sheet") return this.linesTop + this.linesHeight + 26 + 10;
            return this.linesTop + this.linesHeight + 16;
        }
    }

    /**
     * Where every bar, note and moment of a score sits on the pages. A page holds as many lines as fit, split into a
     * top half and a bottom half that turn one at a time.
     */
    class Layout {
        constructor(score, view, size) {
            this.size = size;
            this.staff = new Staff(view, score);
            this.bars = score.bars.length;
            this.x0 = view === "tab" ? 40 : view === "sheet" ? 40 + new Spelling(score.key).signature.length * 7 : 32;
            const landscape = size.width > size.height * 1.05;
            const shortest = view === "roll" ? 60 : Math.min(420, Math.max(96, score.busiestBarWidth));
            const fit = trunc((size.width - this.x0 - MARGIN) / shortest);
            this.barsPerLine = Math.max(1, Math.min(landscape ? 8 : 4, fit));
            this.linesPerPage = Math.max(2, trunc((size.height - MARGIN * 2) / this.staff.height));
            this.topLines = trunc((this.linesPerPage + 1) / 2);
            this.lines = Math.max(1, trunc((this.bars + this.barsPerLine - 1) / this.barsPerLine));
            this.pages = Math.max(1, trunc((this.lines + this.linesPerPage - 1) / this.linesPerPage));
        }

        get barWidth() {
            return Math.max(10, (this.size.width - this.x0 - MARGIN) / this.barsPerLine);
        }

        /** The top of a line of a page, from the top of the page. */
        top(row) {
            return MARGIN + row * this.staff.height;
        }

        /** Where the top half of the page ends and the bottom half starts. */
        get middle() {
            return this.top(this.topLines) - 4;
        }

        rows(top) {
            return top ? [0, this.topLines] : [this.topLines, this.linesPerPage];
        }

        /** The page, the line on it, the bar on the line and the x of the moment `time`. */
        spot(time, score) {
            const place = score.place(time);
            if (!place) return null;
            const line = trunc(place.bar / this.barsPerLine);
            const slot = place.bar % this.barsPerLine;
            return {
                page: trunc(line / this.linesPerPage),
                row: line % this.linesPerPage,
                slot,
                x: this.x((slot + place.fraction) * BEATS_PER_BAR),
            };
        }

        /** The margin that the notes keep after the bar line at the start of a bar. */
        get notePad() {
            return this.staff.view === "tab" ? 10 : this.staff.view === "sheet" ? 14 : 0;
        }

        /**
         * The x of a place `beats` from the start of a line, where its notes are drawn. In the last sixteenth of a bar
         * the place crosses the margins at the bar line, so that the moving line never jumps.
         */
        x(beats) {
            const perBar = BEATS_PER_BAR;
            const last = perBar - 0.25;
            const slot = Math.min(this.barsPerLine - 1, Math.max(0, Math.floor(beats / perBar)));
            const beat = Math.min(perBar, Math.max(0, beats - slot * perBar));
            const start = this.x0 + slot * this.barWidth;
            const pad = this.notePad;
            const content = this.barWidth - pad * 1.6;
            if (beat <= last) return start + pad + (beat / perBar) * content;
            const lastX = start + pad + (last / perBar) * content;
            const next = slot === this.barsPerLine - 1 ? start + this.barWidth : start + this.barWidth + pad;
            return lastX + (next - lastX) * ((beat - last) / 0.25);
        }

        /** The place in beats from the start of a line at `x`, the opposite of `x(beats)`. */
        beats(x) {
            const perBar = BEATS_PER_BAR;
            const last = perBar - 0.25;
            const pad = this.notePad;
            const content = Math.max(1, this.barWidth - pad * 1.6);
            let slot = Math.floor((x - this.x0) / this.barWidth);
            if (slot > 0 && slot < this.barsPerLine && x < this.x0 + slot * this.barWidth + pad) slot -= 1;
            slot = Math.min(this.barsPerLine - 1, Math.max(0, slot));
            const start = this.x0 + slot * this.barWidth;
            const lastX = start + pad + (last / perBar) * content;
            let beat;
            if (x <= lastX) {
                beat = Math.max(0, ((x - start - pad) / content) * perBar);
            } else {
                const next = slot === this.barsPerLine - 1 ? start + this.barWidth : start + this.barWidth + pad;
                beat = last + Math.min(1, (x - lastX) / Math.max(1, next - lastX)) * 0.25;
            }
            return slot * perBar + Math.min(perBar - 0.001, beat);
        }

        /** The row of the half that a point is over. */
        row(point, top) {
            const [lower, upper] = this.rows(top);
            return Math.min(upper - 1, Math.max(lower, Math.floor((point.y - MARGIN) / this.staff.height)));
        }

        /**
         * The page in each half while the song is at `time`: the top half shows the next page once the song reaches
         * the bottom half, so the eyes never wait for a turn.
         */
        pagesShown(time, score) {
            const spot = time === null || time === undefined ? null : this.spot(time, score);
            if (!spot) return { top: 0, bottom: 0 };
            if (spot.row < this.topLines) return { top: spot.page, bottom: spot.page };
            return { top: Math.min(this.pages - 1, spot.page + 1), bottom: spot.page };
        }

        /** The place in beats under a point of the half that shows `page`. */
        position(point, page, top) {
            const line = page * this.linesPerPage + this.row(point, top);
            return Math.min(this.bars * BEATS_PER_BAR, line * this.barsPerLine * BEATS_PER_BAR + this.beats(point.x));
        }
    }

    // MARK: Colours

    /** A colour in OKLab with an opacity, which mixes the way SwiftUI's perceptual mix does. */
    class Tone {
        constructor(L, a, b, alpha = 1) {
            this.L = L;
            this.a = a;
            this.b = b;
            this.alpha = alpha;
        }

        static srgb(r, g, b) {
            const linear = (c) => (c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4));
            const [lr, lg, lb] = [linear(r), linear(g), linear(b)];
            const l = Math.cbrt(0.4122214708 * lr + 0.5363325363 * lg + 0.0514459929 * lb);
            const m = Math.cbrt(0.2119034982 * lr + 0.6806995451 * lg + 0.1073969566 * lb);
            const s = Math.cbrt(0.0883024619 * lr + 0.2817188376 * lg + 0.6299787005 * lb);
            return new Tone(
                0.2104542553 * l + 0.793617785 * m - 0.0040720468 * s,
                1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s,
                0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s,
            );
        }

        static oklch(L, chroma, hue) {
            const radians = (hue * Math.PI) / 180;
            return new Tone(L, chroma * Math.cos(radians), chroma * Math.sin(radians));
        }

        opacity(alpha) {
            return new Tone(this.L, this.a, this.b, this.alpha * alpha);
        }

        mix(other, amount) {
            const t = Math.min(1, Math.max(0, amount));
            const lerp = (from, to) => from + (to - from) * t;
            return new Tone(lerp(this.L, other.L), lerp(this.a, other.a), lerp(this.b, other.b), lerp(this.alpha, other.alpha));
        }

        get css() {
            const f = (value) => value.toFixed(4);
            return `oklab(${f(this.L)} ${f(this.a)} ${f(this.b)} / ${f(this.alpha)})`;
        }
    }

    /** The window's ink and paper, and the notes window's accent with the glow and the hot colour of a lit note. */
    const THEMES = {
        light: {
            dark: false,
            ink: Tone.srgb(0.13, 0.08, 0.1),
            muted: Tone.srgb(0.29, 0.2, 0.24),
            paper: Tone.srgb(0.99, 0.975, 0.955),
            accent: Tone.oklch(0.58, 0.24, 16),
            glow: Tone.oklch(0.7, 0.2, 16),
            hot: Tone.oklch(0.6, 0.26, 20),
        },
        dark: {
            dark: true,
            ink: Tone.srgb(1, 0.97, 0.96),
            muted: Tone.srgb(0.91, 0.85, 0.86),
            paper: Tone.srgb(0.11, 0.094, 0.098),
            accent: Tone.oklch(0.76, 0.18, 62),
            glow: Tone.oklch(0.78, 0.19, 60),
            hot: Tone.oklch(0.86, 0.18, 76),
        },
    };
    const BLACK_KEY = Tone.srgb(0.1, 0.09, 0.094);
    const WHITE_KEY = Tone.srgb(0.91, 0.89, 0.85);
    const SHADE = Tone.srgb(0, 0, 0);

    // MARK: Drawing

    const ROUNDED = 'ui-rounded, "SF Pro Rounded", system-ui, -apple-system, "Segoe UI", Roboto, sans-serif';
    const SYSTEM = 'system-ui, -apple-system, "Segoe UI", Roboto, sans-serif';
    // The window draws the clefs with Apple Symbols. Other systems have the same characters in these fonts.
    const SYMBOLS = '"Apple Symbols", "Noto Music", "Segoe UI Symbol", "Noto Sans Symbols 2", serif';

    /** How far below the middle of a line of text its baseline sits, found once for each font. */
    const baselines = new Map();

    /**
     * Text centred on a point the way SwiftUI's `context.draw(text, at:)` centres it: on the middle of the line box,
     * which runs from the font's ascent to its descent.
     */
    function text(ctx, string, x, y, { size, weight = 700, color, anchor = "center", family = ROUNDED }) {
        const font = `${weight} ${size}px ${family}`;
        ctx.font = font;
        let offset = baselines.get(font);
        if (offset === undefined) {
            const metrics = ctx.measureText("Hg");
            const ascent = metrics.fontBoundingBoxAscent;
            const descent = metrics.fontBoundingBoxDescent;
            offset = Number.isFinite(ascent) && Number.isFinite(descent) ? (ascent - descent) / 2 : size * 0.36;
            baselines.set(font, offset);
        }
        ctx.fillStyle = color.css;
        ctx.textAlign = anchor === "leading" ? "left" : anchor === "trailing" ? "right" : "center";
        ctx.textBaseline = "alphabetic";
        ctx.fillText(string, x, y + offset);
    }

    function stroke(ctx, x1, y1, x2, y2, color, width = 1) {
        ctx.beginPath();
        ctx.moveTo(x1, y1);
        ctx.lineTo(x2, y2);
        ctx.strokeStyle = color.css;
        ctx.lineWidth = width;
        ctx.stroke();
    }

    function roundedRect(ctx, x, y, width, height, radius) {
        ctx.beginPath();
        if (ctx.roundRect) ctx.roundRect(x, y, width, height, Math.min(radius, width / 2, height / 2));
        else ctx.rect(x, y, width, height);
    }

    /** Draws the lines of a page: tab, a staff or a piano roll, as `NotesPainter` does. */
    class Painter {
        constructor(score, layout, theme, { until = Infinity, from = 0 } = {}) {
            this.score = score;
            this.layout = layout;
            this.byBar = score.notesByBar;
            this.theme = theme;
            this.ink = theme.ink;
            this.paper = theme.paper;
            this.accent = theme.accent;
            this.until = until;
            this.from = from;
            this.spelling = new Spelling(score.key);
        }

        get staff() {
            return this.layout.staff;
        }

        draw(ctx, page, rows) {
            for (let row = rows[0]; row < rows[1]; row++) {
                const line = page * this.layout.linesPerPage + row;
                const first = line * this.layout.barsPerLine;
                if (first >= this.score.bars.length) break;
                const bars = [first, Math.min(this.score.bars.length, first + this.layout.barsPerLine)];
                const top = this.layout.top(row);
                this.rests(ctx, bars, top + this.staff.linesTop);
                if (this.staff.view === "tab") this.tab(ctx, bars, top);
                else if (this.staff.view === "sheet") this.sheet(ctx, bars, top);
                else this.roll(ctx, bars, top);
            }
        }

        barX(bar, first) {
            return this.layout.x0 + (bar - first) * this.layout.barWidth;
        }

        /** The x of a place in a bar, inside the padding of the bar. */
        noteX(bar, first, beat, pad = 10) {
            return this.barX(bar, first) + pad + (beat / BEATS_PER_BAR) * (this.layout.barWidth - pad * 1.6);
        }

        faint(bar) {
            const span = this.score.bars[bar];
            return span.start > this.until || span.end <= this.from;
        }

        /** A bar that stands for a run of bars without notes: the thick bar of a multi-bar rest, with the count over it. */
        rests(ctx, [first, end], top) {
            const middle = top + this.staff.linesHeight / 2;
            for (let bar = first; bar < end; bar++) {
                const count = this.score.rests.get(bar);
                if (!count) continue;
                const inset = Math.min(24, this.layout.barWidth * 0.18);
                const left = this.barX(bar, first) + inset;
                const right = this.barX(bar + 1, first) - inset;
                if (!(right > left + 8)) continue;
                const alpha = this.faint(bar) ? 0.25 : 1;
                ctx.fillStyle = this.ink.opacity(0.7 * alpha).css;
                ctx.fillRect(left, middle - 2.5, right - left, 5);
                for (const x of [left, right]) ctx.fillRect(x - 0.75, middle - 7, 1.5, 14);
                text(ctx, String(count), (left + right) / 2, middle - 15, { size: 11, weight: 800, color: this.ink.opacity(0.75 * alpha) });
            }
        }

        barLines(ctx, [first, end], top, bottom) {
            for (let bar = first; bar < end; bar++) {
                const x = this.barX(bar, first);
                stroke(ctx, x, top, x, bottom, this.ink.opacity(0.42));
                text(ctx, String(this.score.number(bar)), x + 2, top - 9, { size: 7.5, color: this.ink.opacity(0.45), anchor: "leading" });
            }
            const x = this.barX(end, first);
            stroke(ctx, x, top, x, bottom, this.ink.opacity(0.42));
        }

        // MARK: Tab

        tab(ctx, bars, lineTop) {
            const [first, end] = bars;
            const gap = TAB_GAP;
            const top = lineTop + this.staff.linesTop;
            const count = this.staff.strings;
            const bottom = top + gap * (count - 1);
            const right = this.barX(end, first);
            const names = this.score.tuning.map((open) => ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"][open % 12]);
            // The highest string at the top, as tab is written.
            for (let index = 0; index < count; index++) {
                const y = top + gap * index;
                stroke(ctx, this.layout.x0 - 12, y, right, y, this.ink.opacity(0.3));
                text(ctx, names[count - 1 - index], this.layout.x0 - 18, y, { size: 7, color: this.ink.opacity(0.4) });
            }
            ["T", "A", "B"].forEach((letter, index) => {
                text(ctx, letter, 8, (top + bottom) / 2 + (index - 1) * 9.5, { size: 8.5, weight: 800, color: this.ink.opacity(0.55) });
            });
            this.barLines(ctx, bars, top, bottom);
            for (let bar = first; bar < end; bar++) {
                const alpha = this.faint(bar) ? 0.25 : 1;
                const onsets = [];
                for (const note of this.byBar[bar]) {
                    if (note.string === null || note.fret === null) continue;
                    const x = this.noteX(bar, first, note.beat);
                    const y = top + gap * (count - 1 - note.string);
                    const label = String(note.fret);
                    const width = label.length > 1 ? 13 : 9;
                    ctx.fillStyle = this.paper.css;
                    ctx.fillRect(x - width / 2, y - 5.5, width, 11);
                    text(ctx, label, x, y, { size: 9.5, weight: 800, color: this.ink.opacity(alpha) });
                    if (!onsets.some((onset) => Math.abs(onset.x - x) < 0.5)) onsets.push({ x, length: note.length, beat: note.beat });
                }
                this.rhythm(ctx, onsets.sort((a, b) => a.x - b.x), bottom + 6, alpha);
            }
        }

        /** The rhythm under the tab: a stem for each onset, beams joining the eighths and sixteenths of one beat. */
        rhythm(ctx, onsets, top, alpha) {
            const color = this.ink.opacity(0.55 * alpha);
            for (const onset of onsets) stroke(ctx, onset.x, top, onset.x, top + (onset.length >= 2 ? 7 : 11), color);
            const byBeat = new Map();
            for (const onset of onsets) {
                if (onset.length > 0.5) continue;
                const beat = trunc(onset.beat);
                if (!byBeat.has(beat)) byBeat.set(beat, []);
                byBeat.get(beat).push(onset);
            }
            for (const group of byBeat.values()) {
                const sorted = group.slice().sort((a, b) => a.x - b.x);
                const firstOnset = sorted[0];
                const lastOnset = sorted[sorted.length - 1];
                if (sorted.length > 1) {
                    stroke(ctx, firstOnset.x, top + 11, lastOnset.x, top + 11, color, 2);
                    if (sorted.every((onset) => onset.length <= 0.25)) stroke(ctx, firstOnset.x, top + 7.5, lastOnset.x, top + 7.5, color, 2);
                } else {
                    stroke(ctx, firstOnset.x, top + 11, firstOnset.x + 5, top + 7, color, 1.5);
                }
            }
        }

        // MARK: Sheet

        /** The staves of a line whose top staff line is at `top`: one, or the treble and the bass of a grand staff. */
        clefs(top) {
            const gap = STAFF_GAP;
            if (this.staff.grand) {
                return [
                    { bottom: top + gap * 4, step: 30, bass: false },
                    { bottom: top + gap * 8 + GRAND_GAP, step: 18, bass: true },
                ];
            }
            return [{ bottom: top + gap * 4, step: this.staff.bassClef ? 18 : 30, bass: this.staff.bassClef }];
        }

        /** Guitar and bass are written an octave above where they sound. */
        get lift() {
            return hasTab(this.score.stem) ? 12 : 0;
        }

        /** The notes of a bar's onset that go on the staff at `index`: the piano splits them at middle C. */
        static onStaff(notes, clefs, index) {
            return notes.filter((note) => clefs.length === 1 || note.pitch >= 60 === (index === 0));
        }

        /** The notes of a bar grouped by the sixteenth they start on, in order. */
        static onsets(notes) {
            const groups = new Map();
            for (const note of notes) {
                const place = round(note.beat * 4);
                if (!groups.has(place)) groups.set(place, []);
                groups.get(place).push(note);
            }
            return [...groups.keys()].sort(numeric).map((place) => [place, groups.get(place)]);
        }

        sheet(ctx, bars, lineTop) {
            const [first, end] = bars;
            const gap = STAFF_GAP;
            const top = lineTop + this.staff.linesTop;
            const right = this.barX(end, first);
            const clefs = this.clefs(top);
            for (const clef of clefs) {
                for (let index = 0; index < 5; index++) {
                    const y = clef.bottom - gap * index;
                    stroke(ctx, 8, y, right, y, this.ink.opacity(0.32));
                }
                this.clefGlyph(ctx, clef);
                this.signature(ctx, clef);
            }
            const bottom = clefs[clefs.length - 1].bottom;
            stroke(ctx, 8, top, 8, bottom, this.ink.opacity(0.42));
            this.barLines(ctx, bars, top, bottom);
            for (let bar = first; bar < end; bar++) {
                const alpha = this.faint(bar) ? 0.25 : 1;
                const shown = new Map();
                for (const [place, notes] of Painter.onsets(this.byBar[bar])) {
                    const x = this.noteX(bar, first, place / 4, 14);
                    clefs.forEach((clef, index) => {
                        const staffNotes = Painter.onStaff(notes, clefs, index);
                        if (staffNotes.length) this.chord(ctx, staffNotes, x, clef, shown, alpha);
                    });
                }
            }
        }

        clefGlyph(ctx, clef) {
            const gap = STAFF_GAP;
            // The treble clef curls around the G line, the second from the bottom, and the bass clef's dots sit around
            // the F line, the second from the top.
            const y = clef.bass ? clef.bottom - gap * 2.6 : clef.bottom - gap * 1.6;
            text(ctx, clef.bass ? "\u{1D122}" : "\u{1D11E}", 21, y, { size: clef.bass ? gap * 4.2 : gap * 5.6, weight: 400, color: this.ink, family: SYMBOLS });
        }

        signature(ctx, clef) {
            const signature = this.spelling.signature;
            if (signature.length === 0) return;
            // The steps of the sharps and the flats on the treble clef, in the order they are added; two octaves lower
            // on the bass clef.
            const steps = this.spelling.flats ? [34, 37, 33, 36, 32, 35, 31] : [38, 35, 39, 36, 33, 37, 34];
            signature.forEach((_, index) => {
                const step = steps[index] - (clef.bass ? 14 : 0);
                const y = clef.bottom - ((step - clef.step) * STAFF_GAP) / 2;
                text(ctx, this.spelling.flats ? "♭" : "♯", 38 + index * 7, y, { size: 12, weight: 400, color: this.ink, family: SYSTEM });
            });
        }

        /**
         * The accidentals of the notes that start together on one staff, which also brings the signs that the bar
         * already showed up to date. A sign shows once per step in a bar, and a note in the key on a step that had
         * another sign in the bar takes the key's sign again.
         */
        accidentals(spelled, shown) {
            const columns = [];
            const signs = [];
            const order = spelled.map((_, index) => index).sort((a, b) => spelled[b].step - spelled[a].step);
            for (const index of order) {
                const note = spelled[index];
                let sign = note.accidental;
                if (sign === null && shown.has(note.step)) sign = this.spelling.keySign(note.step);
                if (sign === null || shown.get(note.step) === sign) continue;
                shown.set(note.step, sign);
                let column = columns.findIndex((steps) => steps.every((step) => Math.abs(step - note.step) > 5));
                if (column < 0) {
                    column = columns.length;
                    columns.push([]);
                }
                columns[column].push(note.step);
                signs.push({ index, sign, column });
            }
            return signs;
        }

        /**
         * The notes that start together on one staff: heads, accidentals, ledger lines, one stem and the flags of the
         * shortest note. A lit chord takes the colour of its light and glows; `draw` false only keeps the
         * accidentals of the bar up to date.
         */
        chord(ctx, notes, x, clef, shown, alpha, light = null, draw = true) {
            const gap = STAFF_GAP;
            const color = light ? light.tint : this.ink.opacity(alpha);
            const spelled = notes.map((note) => ({ ...this.spelling.spell(note.pitch + this.lift), length: note.length }));
            const length = Math.min(...spelled.map((note) => note.length));
            const ys = spelled.map((note) => clef.bottom - ((note.step - clef.step) * gap) / 2);
            // Notes under the middle line take a stem up on their right, the others a stem down on their left.
            const middle = clef.bottom - gap * 2;
            const low = Math.max(...ys);
            const high = Math.min(...ys);
            const up = ys.length === 0 ? true : (low + high) / 2 > middle;
            // Two notes a step apart can't share a column: one moves to the other side of the stem.
            const shift = 7.6;
            const side = spelled.map(() => 0);
            const order = spelled.map((_, index) => index).sort((a, b) => (up ? spelled[a].step - spelled[b].step : spelled[b].step - spelled[a].step));
            for (let n = 1; n < order.length; n++) {
                const index = order[n];
                const before = order[n - 1];
                if (Math.abs(spelled[index].step - spelled[before].step) === 1 && side[before] === 0) side[index] = up ? shift : -shift;
            }
            const left = side.some((value) => value < 0) ? shift : 0;
            const right = side.some((value) => value > 0) ? shift : 0;
            const signs = this.accidentals(spelled, shown);
            if (!draw) return;
            if (light) this.halo(ctx, x, (low + high) / 2, 10 + 7 * Math.min(1.35, light.level) + (low - high) / 2, light);
            spelled.forEach((note, index) => {
                const y = ys[index];
                // Ledger lines under and over the staff, wide enough for a head moved to either side. A lit chord keeps
                // the ones that the page draws.
                const from = x - 7 - left;
                const to = x + 7 + right;
                if (!light && note.step < clef.step - 1) {
                    for (let step = clef.step - 2; step >= note.step; step -= 2) {
                        const ly = clef.bottom - ((step - clef.step) * gap) / 2;
                        stroke(ctx, from, ly, to, ly, this.ink.opacity(0.45 * alpha));
                    }
                } else if (!light && note.step > clef.step + 9) {
                    for (let step = clef.step + 10; step <= note.step; step += 2) {
                        const ly = clef.bottom - ((step - clef.step) * gap) / 2;
                        stroke(ctx, from, ly, to, ly, this.ink.opacity(0.45 * alpha));
                    }
                }
                ctx.save();
                ctx.translate(x + side[index], y);
                ctx.rotate(-0.35);
                ctx.beginPath();
                ctx.ellipse(0, 0, 4.2, 3.1, 0, 0, Math.PI * 2);
                ctx.restore();
                if (length >= 2) {
                    ctx.strokeStyle = color.css;
                    ctx.lineWidth = 1.3;
                    ctx.stroke();
                } else {
                    ctx.fillStyle = color.css;
                    ctx.fill();
                }
                if (length === 0.75 || length === 1.5 || length === 3) {
                    ctx.beginPath();
                    ctx.arc(x + 6 + right + 1.2, y, 1.2, 0, Math.PI * 2);
                    ctx.fillStyle = color.css;
                    ctx.fill();
                }
            });
            for (const { index, sign, column } of signs) {
                text(ctx, sign, x - 10 - left - column * 7, ys[index], { size: 11, weight: 400, color, family: SYSTEM });
            }
            if (!(length < 4) || ys.length === 0) return;
            const stemX = up ? x + 3.8 : x - 3.8;
            const tip = up ? high - gap * 3.5 : low + gap * 3.5;
            stroke(ctx, stemX, up ? low : high, stemX, tip, color, 1.1);
            const flags = length <= 0.25 ? 2 : length <= 0.75 ? 1 : 0;
            for (let index = 0; index < flags; index++) {
                const y = tip + index * (up ? 5 : -5);
                ctx.beginPath();
                ctx.moveTo(stemX, y);
                ctx.quadraticCurveTo(stemX + 6, y + (up ? 3 : -3), stemX + 5, y + (up ? 10 : -10));
                ctx.strokeStyle = color.css;
                ctx.lineWidth = 1.2;
                ctx.stroke();
            }
        }

        // MARK: Piano roll

        roll(ctx, bars, lineTop) {
            const [first, end] = bars;
            const rowHeight = ROW_HEIGHT;
            const top = lineTop + this.staff.linesTop;
            const rows = this.staff.high - this.staff.low + 1;
            const right = this.barX(end, first);
            const sharps = new Set([1, 3, 6, 8, 10]);
            for (let index = 0; index < rows; index++) {
                const pitch = this.staff.high - index;
                const y = top + index * rowHeight;
                const isBlack = sharps.has(((pitch % 12) + 12) % 12);
                ctx.fillStyle = (isBlack ? BLACK_KEY : WHITE_KEY).css;
                ctx.fillRect(4, y, 22, rowHeight);
                stroke(ctx, 4, y + rowHeight, 26, y + rowHeight, SHADE.opacity(0.35), 0.4);
                ctx.fillStyle = this.ink.opacity(isBlack ? 0.025 : 0.05).css;
                ctx.fillRect(this.layout.x0, y, right - this.layout.x0, rowHeight);
                if (pitch % 12 === 0) {
                    text(ctx, `C${trunc(pitch / 12) - 1}`, this.layout.x0 - 3, y + rowHeight / 2, { size: 6, color: this.ink.opacity(0.5), anchor: "trailing" });
                }
            }
            const bottom = top + rows * rowHeight;
            for (let bar = first; bar < end; bar++) {
                for (let beat = 1; beat < BEATS_PER_BAR; beat++) {
                    const x = this.barX(bar, first) + (this.layout.barWidth * beat) / BEATS_PER_BAR;
                    stroke(ctx, x, top, x, bottom, this.ink.opacity(0.07));
                }
            }
            this.barLines(ctx, bars, top, bottom);
            for (let bar = first; bar < end; bar++) {
                const alpha = this.faint(bar) ? 0.25 : 1;
                for (const note of this.byBar[bar]) {
                    const rect = this.rollRect(note, bar, first, top, right);
                    roundedRect(ctx, rect.x, rect.y, rect.width, rect.height, 1.5);
                    ctx.fillStyle = this.accent.opacity(alpha).css;
                    ctx.fill();
                }
            }
        }

        rollRect(note, bar, first, top, right) {
            const pitch = Math.min(this.staff.high, Math.max(this.staff.low, note.pitch));
            const x = this.barX(bar, first) + this.layout.barWidth * (note.beat / BEATS_PER_BAR);
            const width = Math.max(3, Math.min(right - x, this.layout.barWidth * (note.length / BEATS_PER_BAR)) - 1.5);
            const y = top + (this.staff.high - pitch) * ROW_HEIGHT;
            return { x: x + 0.5, y: y + 0.4, width, height: ROW_HEIGHT - 0.8 };
        }

        // MARK: Note names

        /**
         * The note drawn nearest to a point of a line, if the point is on it: on its head, its fret number or its bar
         * in the piano roll. `reach` widens the target for a finger.
         */
        note(point, page, row, reach = 1) {
            const line = page * this.layout.linesPerPage + row;
            const first = line * this.layout.barsPerLine;
            if (first >= this.score.bars.length) return null;
            const top = this.layout.top(row) + this.staff.linesTop;
            const clefs = this.staff.view === "sheet" ? this.clefs(top) : [];
            let best = null;
            const end = Math.min(this.score.bars.length, first + this.layout.barsPerLine);
            for (let bar = first; bar < end; bar++) {
                if (this.faint(bar)) continue;
                for (const note of this.byBar[bar]) {
                    if (note.drum) continue;
                    let center;
                    let target;
                    if (this.staff.view === "tab") {
                        if (note.string === null) continue;
                        center = { x: this.noteX(bar, first, note.beat), y: top + TAB_GAP * (this.staff.strings - 1 - note.string) };
                        target = { width: 7 * reach, height: 5.5 * reach };
                    } else if (this.staff.view === "sheet") {
                        const clef = clefs.length === 1 || note.pitch >= 60 ? clefs[0] : clefs[1];
                        const step = this.spelling.spell(note.pitch + this.lift).step;
                        center = { x: this.noteX(bar, first, note.beat, 14), y: clef.bottom - ((step - clef.step) * STAFF_GAP) / 2 };
                        target = { width: 6 * reach, height: 3.5 * reach };
                    } else {
                        const pitch = Math.min(this.staff.high, Math.max(this.staff.low, note.pitch));
                        const x = this.barX(bar, first) + this.layout.barWidth * (note.beat / BEATS_PER_BAR);
                        const width = Math.max(3, this.layout.barWidth * (note.length / BEATS_PER_BAR) - 1.5);
                        // The bar of a note is a target along its whole length, and its name shows over the pointer.
                        if (point.x < x - reach || point.x > x + width + reach) continue;
                        center = { x: point.x, y: top + (this.staff.high - pitch + 0.5) * ROW_HEIGHT };
                        target = { width: reach, height: (ROW_HEIGHT / 2 + 1) * reach };
                    }
                    const dx = Math.abs(center.x - point.x);
                    const dy = Math.abs(center.y - point.y);
                    if (dx > target.width || dy > target.height) continue;
                    const distance = Math.hypot(dx, dy);
                    if (best && distance >= best.distance) continue;
                    const named = { center, name: this.spelling.name(note.pitch), fret: null };
                    if (this.staff.view === "sheet" && note.string !== null && note.fret !== null) {
                        named.fret = `string ${this.staff.strings - note.string} · fret ${note.fret}`;
                    }
                    best = { distance, note: named };
                }
            }
            return best ? best.note : null;
        }

        // MARK: Light

        /** A note lights from ink to the accent, and then towards the hot colour when it's brightest. */
        light(level, base) {
            if (!(level > 0.01)) return null;
            const { accent } = this;
            const { hot, glow, dark } = this.theme;
            const amount = Math.min(1, level);
            let tint;
            if (base === accent) tint = accent.mix(hot, amount * (dark ? 0.75 : 0.5));
            else if (amount < 0.5) tint = base.mix(accent, amount / 0.5);
            else tint = accent.mix(hot, ((amount - 0.5) / 0.5) * (dark ? 0.6 : 0.35));
            return { tint, glow, level, dark };
        }

        /** The light around a lit note, which adds to the dark page and tints the light one. */
        halo(ctx, x, y, radius, light) {
            const alpha = (light.dark ? 0.34 : 0.3) * Math.min(1.35, light.level);
            const gradient = ctx.createRadialGradient(x, y, 0, x, y, radius);
            gradient.addColorStop(0, light.glow.opacity(Math.min(1, alpha * 1.8)).css);
            gradient.addColorStop(0.22, light.glow.opacity(alpha * 0.9).css);
            gradient.addColorStop(0.55, light.glow.opacity(alpha * 0.35).css);
            gradient.addColorStop(1, light.glow.opacity(0).css);
            ctx.save();
            if (light.dark) ctx.globalCompositeOperation = "lighter";
            ctx.fillStyle = gradient;
            ctx.beginPath();
            ctx.arc(x, y, radius, 0, Math.PI * 2);
            ctx.fill();
            ctx.restore();
        }

        /** How far left of a note's centre the line touches it: about half a fret number or a note head. */
        get reach() {
            return this.staff.view === "roll" ? 0 : 4;
        }

        /** Draws the notes of a page half that the line lights, over the page. `level` says how lit an onset is. */
        drawLight(ctx, page, rows, level) {
            for (let row = rows[0]; row < rows[1]; row++) {
                const line = page * this.layout.linesPerPage + row;
                const first = line * this.layout.barsPerLine;
                if (first >= this.score.bars.length) break;
                const end = Math.min(this.score.bars.length, first + this.layout.barsPerLine);
                const top = this.layout.top(row) + this.staff.linesTop;
                if (this.staff.view === "tab") {
                    // The halos first, so that no halo lies over a lit number next to it.
                    const lit = [];
                    for (let bar = first; bar < end; bar++) {
                        for (const note of this.byBar[bar]) {
                            if (note.string === null || note.fret === null) continue;
                            const x = this.noteX(bar, first, note.beat);
                            const light = this.light(level({ key: bar * 64 + round(note.beat * 4), line, x: x - this.reach }), this.ink);
                            if (light) lit.push({ x, y: top + TAB_GAP * (this.staff.strings - 1 - note.string), fret: note.fret, light });
                        }
                    }
                    for (const note of lit) this.halo(ctx, note.x, note.y, 9 + 7 * Math.min(1.35, note.light.level), note.light);
                    for (const note of lit) text(ctx, String(note.fret), note.x, note.y, { size: 9.5, weight: 800, color: note.light.tint });
                } else if (this.staff.view === "sheet") {
                    const clefs = this.clefs(top);
                    for (let bar = first; bar < end; bar++) {
                        const onsets = Painter.onsets(this.byBar[bar]);
                        const lights = onsets.map(([place]) =>
                            this.light(level({ key: bar * 64 + place, line, x: this.noteX(bar, first, place / 4, 14) - this.reach }), this.ink),
                        );
                        // A bar with nothing lit is skipped; in a lit bar every chord runs, for the accidentals of the bar.
                        if (!lights.some((light) => light)) continue;
                        const shown = new Map();
                        onsets.forEach(([place, notes], index) => {
                            const x = this.noteX(bar, first, place / 4, 14);
                            clefs.forEach((clef, staffIndex) => {
                                const staffNotes = Painter.onStaff(notes, clefs, staffIndex);
                                if (staffNotes.length) this.chord(ctx, staffNotes, x, clef, shown, 1, lights[index], lights[index] !== null);
                            });
                        });
                    }
                } else {
                    const right = this.barX(end, first);
                    for (let bar = first; bar < end; bar++) {
                        for (const note of this.byBar[bar]) {
                            const x = this.barX(bar, first) + this.layout.barWidth * (note.beat / BEATS_PER_BAR);
                            const light = this.light(level({ key: bar * 64 + round(note.beat * 4), line, x }), this.accent);
                            if (!light) continue;
                            const rect = this.rollRect(note, bar, first, top, right);
                            this.halo(ctx, rect.x + Math.min(rect.width / 2, 8), rect.y + rect.height / 2, 8 + 6 * Math.min(1.35, light.level), light);
                            roundedRect(ctx, rect.x, rect.y, rect.width, rect.height, 1.5);
                            ctx.fillStyle = light.tint.css;
                            ctx.fill();
                        }
                    }
                }
            }
        }

        /**
         * How lit an onset is with the line at `x` on `line`: a faint warm-up just before the touch, then the flash
         * and an afterglow that fades over about a second of the song, timed from the moment the line touched it.
         */
        static phosphor(onset, time, line, x, layout, score) {
            if (!(onset.line < line || (onset.line === line && onset.x <= x))) {
                if (onset.line !== line) return 0;
                const span = layout.barWidth * 0.14;
                const distance = onset.x - x;
                return distance < span ? 0.16 * Math.pow(1 - distance / span, 3) : 0;
            }
            const beats = onset.line * layout.barsPerLine * BEATS_PER_BAR + layout.beats(onset.x);
            const age = time - score.time(beats);
            if (!(age >= 0 && age < 5)) return 0;
            return Math.exp(-age / 1.1) * (1 + 0.45 * Math.exp(-age / 0.09));
        }
    }

    // MARK: Sheet

    /** The timing curve of the window's page turn. */
    function bezier(x1, y1, x2, y2) {
        const curve = (a, b, t) => 3 * a * (1 - t) * (1 - t) * t + 3 * b * (1 - t) * t * t + t * t * t;
        return (x) => {
            let low = 0;
            let high = 1;
            for (let i = 0; i < 24; i++) {
                const middle = (low + high) / 2;
                if (curve(x1, x2, middle) < x) low = middle;
                else high = middle;
            }
            return curve(y1, y2, (low + high) / 2);
        };
    }
    const turnCurve = bezier(0.42, 0.05, 0.3, 1);

    const ICONS = {
        left: '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M10 3.5 5.5 8l4.5 4.5"/></svg>',
        right: '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M6 3.5 10.5 8 6 12.5"/></svg>',
        minus: '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M3.5 8h9"/></svg>',
        plus: '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M3.5 8h9M8 3.5v9"/></svg>',
        swap: '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M3 5.5h10M10.5 3 13 5.5 10.5 8M13 10.5H3M5.5 8 3 10.5 5.5 13"/></svg>',
    };

    function element(tag, className, properties = {}) {
        const node = document.createElement(tag);
        if (className) node.className = className;
        for (const [name, value] of Object.entries(properties)) {
            if (name === "text") node.textContent = value;
            else if (name === "icon") node.innerHTML = ICONS[value];
            else node.setAttribute(name, value);
        }
        return node;
    }

    function keycap(label) {
        return element("kbd", "ms-keycap", { text: label });
    }

    /** `Shift.short`: −2 or +2. */
    const shiftText = (semitones) => (semitones < 0 ? `−${-semitones}` : `+${semitones}`);
    /** `NotesTime.time`: minutes and seconds. */
    function clock(seconds) {
        const total = Math.max(0, Math.floor(seconds));
        return `${trunc(total / 60)}:${String(total % 60).padStart(2, "0")}`;
    }
    /** `FifthsRing.fold`: a shift folded into the row of keys from −6 to +5. */
    const fold = (shift) => ((((shift + 6) % 12) + 12) % 12) - 6;

    const SHIFT_RANGE = [-12, 12];
    const HIGHEST_CAPO = 11;

    class Sheet {
        constructor(root, data, options) {
            this.root = root;
            this.data = data || {};
            this.stem = stemOf(this.data.stem);
            this.views = hasTab(this.stem) ? VIEWS : VIEWS.filter((view) => view !== "tab");
            const view = VIEWS.includes(options.view) && this.views.includes(options.view) ? options.view : preferredView(this.stem);
            this.state = {
                view,
                shift: Math.max(SHIFT_RANGE[0], Math.min(SHIFT_RANGE[1], options.shift | 0)),
                relative: !!options.relative,
                capo: Math.max(0, Math.min(HIGHEST_CAPO, options.capo | 0)),
            };
            this.onSeek = typeof options.onSeek === "function" ? options.onSeek : null;
            this.onChange = typeof options.onChange === "function" ? options.onChange : null;
            this.keys = options.keys !== false;
            this.faintSpan = Array.isArray(options.transcribed) ? { from: options.transcribed[0], until: options.transcribed[1] } : { from: 0, until: Infinity };
            /** The song's time, from the last `setTime`, and how fast it moves while it plays. Null for a page with no song. */
            this.clock = null;
            this.page = Math.max(0, options.page | 0);
            this.shown = { top: this.page, bottom: this.page };
            this.turns = { top: null, bottom: null };
            this.pinned = null;
            this.pageAsked = null;
            this.placed = false;
            this.hover = null;
            this.option = false;
            this.frame = 0;
            this.lastFollow = 0;
            this.cleanups = [];
            this.reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
            this.build();
            this.rebuild();
            this.listen();
        }

        // MARK: DOM

        build() {
            const root = this.root;
            root.classList.add("muskey-sheet");
            root.textContent = "";

            const top = element("header", "ms-top");
            const titles = element("div", "ms-titles");
            titles.append(element("h1", "ms-title", { text: this.data.title || "" }));
            titles.append(element("p", "ms-subtitle", { text: [STEM_NAMES[this.stem], this.data.artist].filter(Boolean).join(" · ") }));
            top.append(titles);
            this.viewSwitch = element("div", "ms-views", { role: "group", "aria-label": "View" });
            this.viewButtons = {};
            for (const view of this.views) {
                const button = element("button", "ms-view", { type: "button", text: VIEW_NAMES[view], title: "Next view (⇥)" });
                button.addEventListener("click", (event) => {
                    this.release(event);
                    this.setView(view);
                });
                this.viewButtons[view] = button;
                this.viewSwitch.append(button);
            }
            top.append(this.viewSwitch);

            this.pageElement = element("div", "ms-page", { role: "img", "aria-label": "Notes" });
            this.paper = element("canvas", "ms-paper");
            this.overlay = element("canvas", "ms-overlay");
            this.hoverLine = element("div", "ms-hover-line");
            this.hoverTime = element("div", "ms-hover-time");
            this.pill = element("div", "ms-pill");
            this.pillName = element("span", "ms-pill-name");
            this.pillFret = element("span", "ms-pill-fret");
            this.pill.append(this.pillName, this.pillFret);
            this.pageElement.append(this.paper, this.overlay, this.hoverLine, this.hoverTime, this.pill);
            // In Display P3, like the window, so that the accent isn't clipped to sRGB where the screen shows more.
            const context = (canvas) => {
                try {
                    return canvas.getContext("2d", { colorSpace: "display-p3" }) || canvas.getContext("2d");
                } catch {
                    return canvas.getContext("2d");
                }
            };
            this.paperContext = context(this.paper);
            this.overlayContext = context(this.overlay);

            const footer = element("div", "ms-footer");
            this.pager = element("div", "ms-pager");
            this.previous = element("button", "ms-arrow", { type: "button", icon: "left", "aria-label": "Previous page", title: "Previous page (←)" });
            this.next = element("button", "ms-arrow", { type: "button", icon: "right", "aria-label": "Next page", title: "Next page (→)" });
            this.pageLabel = element("span", "ms-page-label", { "aria-live": "polite" });
            this.previous.addEventListener("click", (event) => {
                this.release(event);
                this.goToPage(this.page - 1);
            });
            this.next.addEventListener("click", (event) => {
                this.release(event);
                this.goToPage(this.page + 1);
            });
            this.pager.append(this.previous, this.pageLabel, this.next);
            footer.append(this.pager);

            const status = element("div", "ms-status");
            this.hints = element("div", "ms-hints", { "aria-hidden": "true" });
            this.stateRow = element("div", "ms-state");
            this.keyControl = this.buildKeyControl();
            this.tempo = element("div", "ms-item ms-tempo");
            this.capoControl = this.buildCapo();
            this.stateRow.append(this.keyControl, this.tempo, this.capoControl);
            status.append(this.hints, this.stateRow);

            this.picker = this.buildPicker();
            root.append(top, this.pageElement, footer, status, this.picker);
        }

        /** The key in the status bar, with the shift beside it, the arrows that move it a semitone, and the relative key over it. */
        buildKeyControl() {
            const control = element("div", "ms-item ms-key");
            this.keyDown = element("button", "ms-step", { type: "button", icon: "left", "aria-label": "Semitone down", title: "Semitone down (↓)" });
            this.keyUp = element("button", "ms-step", { type: "button", icon: "right", "aria-label": "Semitone up", title: "Semitone up (↑)" });
            this.keyButton = element("button", "ms-key-name", { type: "button", "aria-haspopup": "dialog", title: "Pick a key (⌥-click for the relative key)" });
            this.keyName = element("span", "");
            this.keyShift = element("span", "ms-shift");
            this.keyButton.append(this.keyName, this.keyShift);
            this.relativePill = element("div", "ms-relative", { "aria-hidden": "true" });
            this.relativeName = element("span", "");
            this.relativeMark = element("span", "ms-relative-mark");
            this.relativePill.append(this.relativeName, this.relativeMark);
            this.keyDown.addEventListener("click", (event) => {
                this.release(event);
                this.transpose(-1);
            });
            this.keyUp.addEventListener("click", (event) => {
                this.release(event);
                this.transpose(1);
            });
            // The press on the key closes an open picker before the click arrives, so the click must not open it again.
            this.keyButton.addEventListener("pointerdown", () => {
                this.pickerWasOpen = this.pickerOpen;
            });
            this.keyButton.addEventListener("click", (event) => {
                this.release(event);
                const wasOpen = this.pickerWasOpen || this.pickerOpen;
                this.pickerWasOpen = false;
                if (!this.model.key) return;
                if (event.altKey) this.update({ relative: !this.state.relative });
                else this.togglePicker(!wasOpen);
            });
            control.append(this.keyDown, this.keyButton, this.keyUp, this.relativePill);
            return control;
        }

        buildCapo() {
            const control = element("div", "ms-item ms-capo", { title: "Capo (⌥↑ ⌥↓)" });
            this.capoDown = element("button", "ms-round", { type: "button", icon: "minus", "aria-label": "Capo down" });
            this.capoUp = element("button", "ms-round", { type: "button", icon: "plus", "aria-label": "Capo up" });
            this.capoLabel = element("span", "ms-capo-label");
            this.capoDown.addEventListener("click", (event) => {
                this.release(event);
                this.update({ capo: this.state.capo - 1 });
            });
            this.capoUp.addEventListener("click", (event) => {
                this.release(event);
                this.update({ capo: this.state.capo + 1 });
            });
            control.append(this.capoDown, this.capoLabel, this.capoUp);
            return control;
        }

        /** The keys to pick from: the song's mode in the first row, and the same notes in the other mode under it. */
        buildPicker() {
            const picker = element("div", "ms-picker", { role: "dialog", "aria-label": "Key" });
            this.native = Object.prototype.hasOwnProperty.call(HTMLElement.prototype, "popover");
            if (this.native) picker.setAttribute("popover", "auto");
            else picker.hidden = true;
            picker.addEventListener("toggle", () => {
                this.keyControl.classList.toggle("ms-picking", this.pickerOpen);
                this.keyButton.setAttribute("aria-expanded", String(this.pickerOpen));
                this.placePicker();
            });
            return picker;
        }

        fillPicker() {
            const picker = this.picker;
            picker.textContent = "";
            const original = this.model.key;
            if (!original) return;
            const { shift, relative } = this.state;
            const column = fold(shift);
            const rows = element("div", "ms-picker-rows");
            for (const second of [false, true]) {
                const row = element("div", second ? "ms-chips ms-chips-other" : "ms-chips");
                if (!second) {
                    const down = element("button", "ms-step ms-picker-step", { type: "button", icon: "left", "aria-label": "Semitone down", title: "Semitone down (↓)" });
                    down.disabled = shift <= SHIFT_RANGE[0];
                    down.addEventListener("click", () => this.transpose(-1));
                    row.append(down);
                } else {
                    row.append(element("span", "ms-picker-step"));
                }
                for (let offset = -6; offset <= 5; offset++) {
                    const moved = original.transposed(offset);
                    const key = second ? moved.relative : moved;
                    const inColumn = offset === column;
                    const chip = element("button", "ms-chip", { type: "button", text: key.short, "aria-label": key.name });
                    if (inColumn && relative === second) chip.classList.add("ms-selected");
                    if (inColumn && relative !== second) chip.classList.add("ms-partner");
                    if (offset === 0 && !second) chip.classList.add("ms-original");
                    chip.setAttribute("aria-pressed", String(inColumn && relative === second));
                    // The column of the selected key keeps the shift, which can be an octave away from the column, so a
                    // click there changes only the mode.
                    chip.addEventListener("click", () => this.update({ shift: inColumn ? shift : offset, relative: second }));
                    row.append(chip);
                }
                if (!second) {
                    const up = element("button", "ms-step ms-picker-step", { type: "button", icon: "right", "aria-label": "Semitone up", title: "Semitone up (↑)" });
                    up.disabled = shift >= SHIFT_RANGE[1];
                    up.addEventListener("click", () => this.transpose(1));
                    row.append(up);
                } else {
                    row.append(element("span", "ms-picker-step"));
                }
                rows.append(row);
            }
            picker.append(rows);
        }

        get pickerOpen() {
            if (this.native) return this.picker.matches(":popover-open");
            return !this.picker.hidden;
        }

        togglePicker(open = !this.pickerOpen) {
            if (open) this.fillPicker();
            if (this.native) {
                if (open && !this.pickerOpen) {
                    this.picker.showPopover();
                    // The toggle event comes a moment later, after the picker would have painted in the corner.
                    this.placePicker();
                }
                else if (!open && this.pickerOpen) this.picker.hidePopover();
            } else {
                this.picker.hidden = !open;
                this.keyControl.classList.toggle("ms-picking", open);
                this.keyButton.setAttribute("aria-expanded", String(open));
                this.placePicker();
            }
        }

        /** Over the key, and kept inside the window. */
        placePicker() {
            if (!this.pickerOpen) return;
            const anchor = this.keyControl.getBoundingClientRect();
            const box = this.picker.getBoundingClientRect();
            const width = document.documentElement.clientWidth;
            const left = Math.min(Math.max(8, anchor.left + anchor.width / 2 - box.width / 2), Math.max(8, width - box.width - 8));
            this.picker.style.left = `${left}px`;
            this.picker.style.top = `${Math.max(8, anchor.top - box.height - 8)}px`;
        }

        /** A pointer click leaves no focus on the button, so the keys keep working on the sheet. */
        release(event) {
            if (event && event.detail > 0 && event.currentTarget && event.currentTarget.blur) event.currentTarget.blur();
        }

        // MARK: State

        /** The first bar of the page that the bottom half shows. */
        firstBar() {
            return this.layout ? this.shown.bottom * this.layout.linesPerPage * this.layout.barsPerLine : 0;
        }

        update(change, { notify = true } = {}) {
            const next = { ...this.state, ...change };
            next.shift = Math.max(SHIFT_RANGE[0], Math.min(SHIFT_RANGE[1], next.shift | 0));
            next.capo = Math.max(0, Math.min(HIGHEST_CAPO, next.capo | 0));
            if (!this.views.includes(next.view)) next.view = this.state.view;
            next.relative = !!next.relative;
            const changed = Object.keys(next).some((name) => next[name] !== this.state[name]);
            if (!changed) return;
            const modelChanged = next.shift !== this.state.shift || next.relative !== this.state.relative || next.capo !== this.state.capo;
            // The page keeps showing the bar that was at its top.
            const firstBar = this.firstBar();
            this.state = next;
            if (modelChanged) this.rebuild({ firstBar });
            else this.relayout({ firstBar });
            if (this.pickerOpen) this.fillPicker();
            if (notify) this.changed();
        }

        changed() {
            if (this.onChange) this.onChange({ ...this.state, page: this.page });
        }

        setView(view) {
            this.update({ view });
        }

        transpose(amount) {
            this.update({ shift: this.state.shift + amount });
        }

        rebuild({ firstBar = null } = {}) {
            this.model = buildScores(this.data, this.state);
            this.relayout({ firstBar });
        }

        get theme() {
            const scheme = getComputedStyle(this.root).colorScheme || "";
            return THEMES[/dark/.test(scheme) && !/light/.test(scheme.replace("only", "")) ? "dark" : "light"];
        }

        relayout({ firstBar = null } = {}) {
            const rect = this.pageElement.getBoundingClientRect();
            const size = { width: Math.max(1, rect.width), height: Math.max(1, rect.height) };
            const score = this.model.score;
            this.layout = new Layout(score, this.state.view, size);
            this.painter = new Painter(score, this.layout, this.theme, this.faintSpan);
            const ratio = window.devicePixelRatio || 1;
            for (const canvas of [this.paper, this.overlay]) {
                const width = Math.round(size.width * ratio);
                const height = Math.round(size.height * ratio);
                if (canvas.width !== width || canvas.height !== height) {
                    canvas.width = width;
                    canvas.height = height;
                }
            }
            this.ratio = ratio;
            this.size = size;
            const barsPerPage = this.layout.linesPerPage * this.layout.barsPerLine;
            // A hundredth of a second into the page, so that the rounding of a player never lands on the page before.
            this.pageStarts = [];
            for (let page = 0; page < this.layout.pages; page++) this.pageStarts.push(score.time(page * barsPerPage * BEATS_PER_BAR) + 0.01);
            this.pinned = null;
            this.turns = { top: null, bottom: null };
            if (this.now() === null) {
                const page = firstBar === null ? this.page : trunc(firstBar / barsPerPage);
                this.page = Math.min(this.layout.pages - 1, Math.max(0, page));
                this.shown = { top: this.page, bottom: this.page };
            } else {
                this.shown = this.layout.pagesShown(this.now(), score);
                this.page = this.shown.bottom;
            }
            this.hover = null;
            this.refreshControls();
            this.drawPaper();
            this.drawOverlay();
            this.showHover();
        }

        refreshControls() {
            const { view, shift, relative, capo } = this.state;
            for (const [name, button] of Object.entries(this.viewButtons)) {
                button.setAttribute("aria-pressed", String(name === view));
                button.classList.toggle("ms-on", name === view);
            }
            this.pageLabel.textContent = `Page ${this.page + 1} of ${this.layout.pages}`;
            this.previous.disabled = this.page <= 0;
            this.next.disabled = this.page >= this.layout.pages - 1;
            const shown = this.model.shown;
            this.keyControl.hidden = !(this.model.key || shift !== 0);
            this.keyName.textContent = shown ? shown.name : "";
            this.keyShift.textContent = shift !== 0 ? shiftText(shift) : "";
            this.keyDown.disabled = shift <= SHIFT_RANGE[0];
            this.keyUp.disabled = shift >= SHIFT_RANGE[1];
            this.relativeName.textContent = shown ? shown.relative.name : "";
            this.relativeMark.textContent = "";
            this.relativeMark.append(this.option ? element("span", "ms-swap", { icon: "swap" }) : keycap("⌥"));
            this.relativePill.classList.toggle("ms-option", this.option);
            this.tempo.textContent = `${Math.round(this.model.score.bpm)} BPM`;
            const capoShown = view === "tab" && hasTab(this.stem);
            this.capoControl.hidden = !capoShown;
            this.capoLabel.textContent = capo === 0 ? "No capo" : `Capo ${capo}`;
            this.capoLabel.classList.toggle("ms-muted", capo === 0);
            this.capoDown.disabled = capo === 0;
            this.capoUp.disabled = capo >= HIGHEST_CAPO;
            this.fillHints(capoShown);
        }

        /** The keys and what they do, like the hints along the bottom of the window, for a keyboard and a pointer. */
        fillHints(capo) {
            const list = [
                [["⇥"], "view"],
                [["←", "→"], "page"],
                [["↑", "↓"], "transpose"],
            ];
            if (capo) list.push([["⌥", "↑", "↓"], "capo"]);
            this.hints.textContent = "";
            for (const [keys, name] of list) {
                const hint = element("span", "ms-hint");
                const caps = element("span", "ms-caps");
                for (const key of keys) caps.append(keycap(key));
                hint.append(caps, element("span", "", { text: name }));
                this.hints.append(hint);
            }
        }

        // MARK: Pages

        goToPage(target) {
            if (!this.layout || target < 0 || target >= this.layout.pages || target === this.page) return;
            if (this.now() !== null && this.onSeek) {
                // The song moves to the first bar of the page, which turns the pages to it once the player reports the seek.
                this.page = target;
                this.pageAsked = { page: target, at: performance.now() };
                this.refreshControls();
                this.onSeek(this.pageStarts[target]);
            } else {
                this.page = target;
                this.refreshControls();
                this.show({ top: target, bottom: target }, true);
            }
            this.changed();
        }

        /** Shows a page in each half, turning the halves that change. */
        show(pages, animated) {
            const now = performance.now();
            for (const half of ["top", "bottom"]) {
                if (pages[half] === this.shown[half]) continue;
                this.turns[half] = animated ? { from: this.turns[half] ? this.turns[half].to : this.shown[half], to: pages[half], start: now } : null;
            }
            this.shown = { ...pages };
            this.hover = null;
            this.showHover();
            this.drawPaper();
            this.schedule();
        }

        /** The pages that the song is on, as the window's `turn` finds them, run on every new time and while the song plays. */
        follow(animated = true) {
            const time = this.now();
            if (time === null || !this.layout) return;
            const pages = this.layout.pagesShown(time, this.model.score);
            if (this.pageAsked) {
                this.pinned = null;
                if (pages.bottom !== this.pageAsked.page && performance.now() - this.pageAsked.at < 1500) return;
                this.pageAsked = null;
            }
            const placed = this.placed;
            this.placed = true;
            if (this.page !== pages.bottom) {
                this.page = pages.bottom;
                this.refreshControls();
            }
            if (this.pinned) {
                const spot = this.layout.spot(time, this.model.score);
                if (spot && this.keeps(this.pinned, spot)) return;
                this.pinned = null;
            }
            if (pages.top === this.shown.top && pages.bottom === this.shown.bottom) return;
            this.show(pages, animated && placed);
        }

        /**
         * The pages that a click left in place stay while the song plays on a line that they show, and turn once the song
         * reaches the last line of its half when the other half doesn't show what plays next.
         */
        keeps(pin, spot) {
            const layout = this.layout;
            const inTop = spot.row < layout.topLines;
            if (spot.page !== (inTop ? pin.top : pin.bottom)) return false;
            const nextShown = inTop ? pin.bottom === spot.page : pin.top === Math.min(layout.pages - 1, spot.page + 1);
            return nextShown || spot.row !== (inTop ? layout.topLines - 1 : layout.linesPerPage - 1);
        }

        // MARK: Time

        now() {
            if (!this.clock) return null;
            if (!this.clock.playing) return this.clock.time;
            return this.clock.time + ((performance.now() - this.clock.at) / 1000) * this.clock.rate;
        }

        setTime(seconds) {
            if (!Number.isFinite(seconds)) return;
            const motion = this.clock || this.motion || { playing: false, rate: 1 };
            this.clock = { time: seconds, at: performance.now(), playing: motion.playing, rate: motion.rate };
            this.follow(true);
            this.drawOverlay();
            this.schedule();
        }

        setPlaying(playing, rate = 1) {
            const motion = { playing: !!playing, rate: rate > 0 ? rate : 1 };
            // Before the first time arrives there is no place to play from, so the state waits for it.
            if (!this.clock) {
                this.motion = motion;
                return;
            }
            this.clock = { time: this.now(), at: performance.now(), ...motion };
            this.drawOverlay();
            this.schedule();
        }

        schedule() {
            if (this.frame) return;
            this.frame = requestAnimationFrame((stamp) => this.tick(stamp));
        }

        tick(stamp) {
            this.frame = 0;
            let again = false;
            if (this.clock && this.clock.playing) {
                // The pages are checked ten times a second, as in the window; the line moves on every frame.
                if (stamp - this.lastFollow >= 100) {
                    this.lastFollow = stamp;
                    this.follow(true);
                }
                again = true;
            }
            if (this.turns.top || this.turns.bottom) {
                this.drawPaper();
                again = true;
            }
            this.drawOverlay();
            if (again) this.schedule();
        }

        // MARK: Painting

        /** The two halves of the page, each with the page it shows, and a page that turns over the next one. */
        drawPaper() {
            const ctx = this.paperContext;
            const { width, height } = this.size;
            const layout = this.layout;
            ctx.setTransform(this.ratio, 0, 0, this.ratio, 0, 0);
            ctx.clearRect(0, 0, width, height);
            const theme = this.painter.theme;
            const now = performance.now();
            const reduce = this.reduceMotion.matches;
            const duration = reduce ? 200 : 500;
            for (const half of ["top", "bottom"]) {
                const isTop = half === "top";
                const y0 = isTop ? 0 : layout.middle;
                const y1 = isTop ? layout.middle : height;
                const rows = layout.rows(isTop);
                ctx.save();
                ctx.beginPath();
                ctx.rect(0, y0, width, Math.max(0, y1 - y0));
                ctx.clip();
                const turn = this.turns[half];
                const progress = turn ? Math.min(1, (now - turn.start) / duration) : 1;
                if (turn && progress >= 1) this.turns[half] = null;
                if (!turn || progress >= 1) {
                    this.painter.draw(ctx, this.shown[half], rows);
                } else {
                    // Forwards, the page read so far folds away to the left over the next one. Backwards, the earlier
                    // page lies down again from the left over the later one.
                    const forward = turn.to > turn.from;
                    const eased = turnCurve(progress);
                    const fold = forward ? 1 - eased : eased;
                    const under = forward ? turn.to : turn.from;
                    const over = forward ? turn.from : turn.to;
                    const edge = fold * width;
                    const lift = Math.sin(Math.PI * (1 - fold));
                    this.painter.draw(ctx, under, rows);
                    ctx.save();
                    if (reduce) {
                        ctx.globalAlpha = fold;
                        ctx.fillStyle = theme.paper.css;
                        ctx.fillRect(0, y0, width, y1 - y0);
                    } else {
                        ctx.beginPath();
                        ctx.rect(0, y0, edge, y1 - y0);
                        ctx.clip();
                        ctx.fillStyle = theme.paper.css;
                        ctx.fillRect(0, y0, edge, y1 - y0);
                    }
                    this.painter.draw(ctx, over, rows);
                    ctx.restore();
                    if (!reduce && lift > 0.001) {
                        // The shadow that the lifting page casts on the page beneath, along the fold.
                        const reach = 22 + 34 * lift;
                        const shade = ctx.createLinearGradient(edge, 0, edge + reach, 0);
                        shade.addColorStop(0, SHADE.opacity((theme.dark ? 0.45 : 0.22) * lift).css);
                        shade.addColorStop(1, SHADE.opacity(0).css);
                        ctx.fillStyle = shade;
                        ctx.fillRect(edge, y0, reach, y1 - y0);
                    }
                }
                ctx.restore();
            }
            stroke(ctx, 12, layout.middle + 0.5, width - 12, layout.middle + 0.5, theme.ink.opacity(0.08));
            // While the top half already shows the next page, each half says which page it is.
            if (this.shown.top !== this.shown.bottom) {
                this.pageTag(ctx, this.shown.top, 4);
                this.pageTag(ctx, this.shown.bottom, layout.middle + 6);
            }
        }

        pageTag(ctx, page, y) {
            const theme = this.painter.theme;
            const label = `Page ${page + 1}`;
            ctx.font = `700 9.5px ${ROUNDED}`;
            const width = ctx.measureText(label).width + 12;
            const x = this.size.width - 10 - width;
            roundedRect(ctx, x, y, width, 15, 7.5);
            ctx.fillStyle = theme.paper.opacity(0.9).css;
            ctx.fill();
            text(ctx, label, x + width / 2, y + 7.5, { size: 9.5, color: theme.muted });
        }

        /** The bar that plays, the moving line and the notes that it lights, on a page half that lies flat. */
        drawOverlay() {
            const ctx = this.overlayContext;
            const { width, height } = this.size;
            ctx.setTransform(this.ratio, 0, 0, this.ratio, 0, 0);
            ctx.clearRect(0, 0, width, height);
            const time = this.now();
            if (time === null) return;
            const layout = this.layout;
            const score = this.model.score;
            const spot = layout.spot(time, score);
            if (!spot) return;
            const theme = this.painter.theme;
            const line = spot.page * layout.linesPerPage + spot.row;
            for (const isTop of [true, false]) {
                const half = isTop ? "top" : "bottom";
                if (this.turns[half]) continue;
                ctx.save();
                ctx.beginPath();
                ctx.rect(0, isTop ? 0 : layout.middle, width, isTop ? layout.middle : height - layout.middle);
                ctx.clip();
                this.painter.drawLight(ctx, this.shown[half], layout.rows(isTop), (onset) => Painter.phosphor(onset, time, line, spot.x, layout, score));
                ctx.restore();
            }
            const inTop = spot.row < layout.topLines;
            if (spot.page !== (inTop ? this.shown.top : this.shown.bottom) || this.turns[inTop ? "top" : "bottom"]) return;
            const top = layout.top(spot.row) + layout.staff.linesTop - 7;
            const lineHeight = layout.staff.linesHeight + 14;
            // The bar that plays gets a faint wash of the accent.
            roundedRect(ctx, layout.x0 + spot.slot * layout.barWidth, top, layout.barWidth, lineHeight, 5);
            ctx.fillStyle = theme.accent.opacity(theme.dark ? 0.06 : 0.05).css;
            ctx.fill();
            // The glow is a band of the accent that fades out on both sides.
            const band = ctx.createLinearGradient(spot.x - 7, 0, spot.x + 7, 0);
            band.addColorStop(0, theme.accent.opacity(0).css);
            band.addColorStop(0.5, theme.accent.opacity(theme.dark ? 0.32 : 0.24).css);
            band.addColorStop(1, theme.accent.opacity(0).css);
            roundedRect(ctx, spot.x - 7, top, 14, lineHeight, 6);
            ctx.fillStyle = band;
            ctx.fill();
            roundedRect(ctx, spot.x - 1, top, 2, lineHeight, 1);
            ctx.fillStyle = theme.accent.css;
            ctx.fill();
        }

        // MARK: Pointer

        point(event) {
            const rect = this.pageElement.getBoundingClientRect();
            return { x: event.clientX - rect.left, y: event.clientY - rect.top };
        }

        /** The note under a point of the page, with a wider reach for a finger. */
        noteAt(point, touch = false) {
            const layout = this.layout;
            const top = point.y < layout.middle;
            const page = top ? this.shown.top : this.shown.bottom;
            if (this.turns[top ? "top" : "bottom"]) return null;
            return this.painter.note(point, page, layout.row(point, top), touch ? 2.4 : 1);
        }

        /**
         * Where a click at a point moves the song: the place under it, or the start of a note drawn within 7 points of
         * it, so that a click on a note plays it from its start. Null past the last line.
         */
        target(point) {
            const layout = this.layout;
            const top = point.y < layout.middle;
            const row = layout.row(point, top);
            const line = (top ? this.shown.top : this.shown.bottom) * layout.linesPerPage + row;
            if (line >= layout.lines) return null;
            const first = line * layout.barsPerLine;
            let beats = layout.beats(point.x);
            const byBar = this.model.score.notesByBar;
            let nearest = 7;
            for (let bar = first; bar < Math.min(byBar.length, first + layout.barsPerLine); bar++) {
                for (const note of byBar[bar]) {
                    const place = (bar - first) * BEATS_PER_BAR + note.beat;
                    const distance = Math.abs(layout.x(place) - point.x);
                    if (distance <= nearest) {
                        nearest = distance;
                        beats = place;
                    }
                }
            }
            const position = Math.min(layout.bars * BEATS_PER_BAR, first * BEATS_PER_BAR + beats);
            return { x: layout.x(beats), row, position };
        }

        /** The name of the note under the pointer in a pill above it, and with a song, the line where a click moves it. */
        showHover() {
            const hover = this.hover;
            const named = hover ? this.noteAt(hover.point, hover.touch) : null;
            if (named) {
                this.pillName.textContent = named.name;
                this.pillFret.textContent = named.fret || "";
                this.pillFret.hidden = !named.fret;
                this.pill.classList.add("ms-shown");
                const half = this.pill.offsetWidth / 2;
                const x = Math.min(Math.max(named.center.x, half + 4), this.size.width - half - 4);
                this.pill.style.transform = `translate(${x}px, ${named.center.y - 17}px) translate(-50%, -50%)`;
            } else {
                this.pill.classList.remove("ms-shown");
            }
            const spot = hover && !hover.touch && this.onSeek && this.now() !== null ? this.target(hover.point) : null;
            if (spot) {
                const layout = this.layout;
                const top = layout.top(spot.row) + layout.staff.linesTop - 7;
                this.hoverLine.style.transform = `translate(${spot.x - 0.75}px, ${top}px)`;
                this.hoverLine.style.height = `${layout.staff.linesHeight + 14}px`;
                this.hoverLine.classList.add("ms-shown");
                // Over a note, its name takes the place of the time.
                if (!named) {
                    this.hoverTime.textContent = clock(this.model.score.time(spot.position));
                    this.hoverTime.style.transform = `translate(${spot.x}px, ${top - 9}px) translate(-50%, -50%)`;
                    this.hoverTime.classList.add("ms-shown");
                } else {
                    this.hoverTime.classList.remove("ms-shown");
                }
            } else {
                this.hoverLine.classList.remove("ms-shown");
                this.hoverTime.classList.remove("ms-shown");
            }
        }

        listen() {
            const on = (target, type, handler, options) => {
                target.addEventListener(type, handler, options);
                this.cleanups.push(() => target.removeEventListener(type, handler, options));
            };
            const page = this.pageElement;
            let press = null;
            on(page, "pointerdown", (event) => {
                press = { x: event.clientX, y: event.clientY, type: event.pointerType, at: performance.now() };
            });
            on(page, "pointermove", (event) => {
                if (event.pointerType !== "mouse") return;
                this.hover = { point: this.point(event), touch: false };
                this.showHover();
            });
            on(page, "pointerleave", (event) => {
                if (event.pointerType !== "mouse") return;
                this.hover = null;
                this.showHover();
            });
            on(page, "pointercancel", () => {
                press = null;
            });
            on(page, "pointerup", (event) => {
                if (!press) return;
                const dx = event.clientX - press.x;
                const dy = event.clientY - press.y;
                const touch = press.type !== "mouse";
                press = null;
                // A swipe to the side turns the page, the way a book does.
                if (touch && Math.abs(dx) > 40 && Math.abs(dx) > Math.abs(dy) * 1.5) {
                    this.goToPage(this.page + (dx < 0 ? 1 : -1));
                    return;
                }
                if (Math.hypot(dx, dy) > (touch ? 10 : 4)) return;
                const point = this.point(event);
                if (touch) {
                    // A tap on a note keeps its name up until the next tap.
                    const named = this.noteAt(point, true);
                    this.hover = named ? { point, touch: true } : null;
                    this.showHover();
                }
                if (this.onSeek && this.now() !== null) {
                    const target = this.target(point);
                    if (target) {
                        this.pinned = { ...this.shown };
                        this.onSeek(Math.max(0, this.model.score.time(target.position) + 0.01));
                    }
                }
            });
            // A phone that turns keeps the bar that was at the top of the page in sight.
            const resize = new ResizeObserver(() => this.relayout({ firstBar: this.firstBar() }));
            resize.observe(page);
            this.cleanups.push(() => resize.disconnect());
            const schemes = window.matchMedia("(prefers-color-scheme: dark)");
            on(schemes, "change", () => this.relayout());
            const theme = new MutationObserver(() => this.relayout());
            theme.observe(this.root, { attributes: true, attributeFilter: ["data-theme"] });
            theme.observe(document.documentElement, { attributes: true, attributeFilter: ["data-theme"] });
            this.cleanups.push(() => theme.disconnect());
            on(window, "resize", () => this.placePicker());
            on(this.keyControl, "pointerenter", (event) => {
                if (event.pointerType === "mouse") this.keyControl.classList.add("ms-hovering");
            });
            on(this.keyControl, "pointerleave", () => this.keyControl.classList.remove("ms-hovering"));
            if (!this.native) {
                on(document, "pointerdown", (event) => {
                    if (this.pickerOpen && !this.picker.contains(event.target) && !this.keyControl.contains(event.target)) this.togglePicker(false);
                });
            }
            const setOption = (held) => {
                if (held === this.option) return;
                this.option = held;
                this.refreshControls();
            };
            on(window, "keyup", (event) => setOption(event.altKey && !event.metaKey));
            on(window, "blur", () => setOption(false));
            on(window, "keydown", (event) => {
                setOption(event.altKey && !event.metaKey);
                if (this.keys) this.key(event);
            });
        }

        key(event) {
            if (event.metaKey || event.ctrlKey || event.defaultPrevented) return;
            const active = document.activeElement;
            const inPicker = this.picker.contains(active);
            const onControl = active && active !== document.body && active !== this.root && !this.pageElement.contains(active);
            switch (event.key) {
                case "Escape":
                    if (this.pickerOpen && !this.native) this.togglePicker(false);
                    else if (this.hover) {
                        this.hover = null;
                        this.showHover();
                    } else return;
                    break;
                case "ArrowLeft":
                case "PageUp":
                    if (inPicker) return;
                    this.goToPage(this.page - 1);
                    break;
                case "ArrowRight":
                case "PageDown":
                    if (inPicker) return;
                    this.goToPage(this.page + 1);
                    break;
                case "ArrowUp":
                case "ArrowDown": {
                    const amount = event.key === "ArrowUp" ? 1 : -1;
                    if (event.altKey) {
                        if (hasTab(this.stem)) this.update({ capo: this.state.capo + amount });
                    } else this.transpose(amount);
                    break;
                }
                case "Tab": {
                    // As in the window, ⇥ switches the view while no control has the focus.
                    if (onControl || inPicker) return;
                    const index = this.views.indexOf(this.state.view);
                    this.setView(this.views[(index + (event.shiftKey ? this.views.length - 1 : 1)) % this.views.length]);
                    break;
                }
                default:
                    return;
            }
            event.preventDefault();
        }

        destroy() {
            cancelAnimationFrame(this.frame);
            for (const cleanup of this.cleanups) cleanup();
            this.cleanups = [];
            if (this.pickerOpen) this.togglePicker(false);
            this.root.textContent = "";
            this.root.classList.remove("muskey-sheet");
        }

        get handle() {
            const sheet = this;
            return {
                setTime: (seconds) => sheet.setTime(seconds),
                setPlaying: (playing, rate) => sheet.setPlaying(playing, rate),
                get onSeek() {
                    return sheet.onSeek;
                },
                set onSeek(handler) {
                    sheet.onSeek = typeof handler === "function" ? handler : null;
                },
                get onChange() {
                    return sheet.onChange;
                },
                set onChange(handler) {
                    sheet.onChange = typeof handler === "function" ? handler : null;
                },
                get state() {
                    return { ...sheet.state, page: sheet.page, pages: sheet.layout.pages };
                },
                set: (change) => {
                    const { page, ...rest } = change || {};
                    sheet.update(rest, { notify: false });
                    if (Number.isInteger(page)) {
                        const target = Math.min(sheet.layout.pages - 1, Math.max(0, page));
                        sheet.page = target;
                        sheet.refreshControls();
                        sheet.show({ top: target, bottom: target }, false);
                    }
                },
                /** The page's layout, for tests that compare it with the window's. */
                layout: () => {
                    const { layout } = sheet;
                    return { width: layout.size.width, height: layout.size.height, barsPerLine: layout.barsPerLine, linesPerPage: layout.linesPerPage, pages: layout.pages, shown: { ...sheet.shown } };
                },
                /** The name of the note at a point of the page, as the pill shows it, and shows it there. */
                hoverAt: (x, y, touch = false) => {
                    sheet.hover = { point: { x, y }, touch };
                    sheet.showHover();
                    const named = sheet.noteAt({ x, y }, touch);
                    return named ? { ...named } : null;
                },
                destroy: () => sheet.destroy(),
            };
        }
    }

    /** Draws a transcription in `element`, with its controls, and returns the handle that a live page drives it with. */
    function mount(target, data, options = {}) {
        return new Sheet(target, data, options).handle;
    }

    globalThis.MuskeySheet = {
        mount,
        model: { Key, Score, Spelling, Staff, Layout, Painter, buildScores, stemOf, hasTab, preferredView, round },
    };
})();
