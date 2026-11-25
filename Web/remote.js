// The web remote of Muskey. The Mac always plays: a song of Recents or a link is played there, and the song view shows
// the song that the Mac plays, with the HUD's key row, tempo and instruments, a transport, and the notes of the notes
// window. Output picks where it is heard: the Mac, or this phone, which then gets the Mac's output as a live stream
// played with Web Audio, so every change is heard on the phone as it is on the Mac.
(() => {
    "use strict";

    const $ = (id) => document.getElementById(id);
    const symbol = (name) => `url(/api/symbol/${name})`;
    const mod = (n, m) => ((n % m) + m) % m;

    // The stems in the order of the HUD, with its symbols and hues.
    const STEMS = [
        { name: "bass", label: "Bass", symbol: "hifispeaker.fill", hue: 70 },
        { name: "drums", label: "Drums", symbol: "metronome.fill", hue: 45 },
        { name: "guitar", label: "Guitar", symbol: "guitars.fill", hue: 95 },
        { name: "piano", label: "Piano", symbol: "pianokeys", hue: 30 },
        { name: "vocals", label: "Vocals", symbol: "music.mic", hue: 20 },
        { name: "winds", label: "Winds", symbol: "wind", hue: 82 },
        { name: "other", label: "Other", symbol: "music.quarternote.3", hue: 58 },
    ];

    // MARK: Keys, as DetectedKey names and moves them

    const MAJOR = ["C", "D♭", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"];
    const MINOR = ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "G♯", "A", "B♭", "B"];
    const LETTERS = { C: 0, D: 2, E: 4, F: 5, G: 7, A: 9, B: 11 };

    function parseKey(code) {
        const match = /^([A-G])([#b♯♭]?)(m?)$/.exec(code || "");
        if (!match) return null;
        const accidental = match[2] === "#" || match[2] === "♯" ? 1 : match[2] ? -1 : 0;
        return { pitch: mod(LETTERS[match[1]] + accidental, 12), minor: match[3] === "m" };
    }
    const transpose = (key, by) => ({ pitch: mod(key.pitch + by, 12), minor: key.minor });
    const relativeOf = (key) => ({ pitch: mod(key.pitch + (key.minor ? 3 : 9), 12), minor: !key.minor });
    const tonic = (key) => (key.minor ? MINOR : MAJOR)[key.pitch];
    const ascii = (key) => tonic(key).replace("♯", "#").replace("♭", "b") + (key.minor ? "m" : "");
    /** A shift folded into the row's columns, from −6 to 5. */
    const fold = (shift) => mod(shift + 6, 12) - 6;
    /** Steps on the circle of fifths: 1 for a fourth or a fifth, 2 for a whole step. */
    const harmony = (semitones) => {
        const steps = mod(semitones * 7, 12);
        return Math.min(steps, 12 - steps);
    };
    const signed = (n) => (n > 0 ? `+${n}` : `${n}`);
    /** A shift as the HUD writes it, with a real minus sign. */
    const shown = (n) => (n < 0 ? `−${-n}` : signed(n));
    const clock = (s) => `${Math.floor(s / 60)}:${String(Math.floor(s % 60)).padStart(2, "0")}`;
    const heardOf = (key, by, other) => (other ? relativeOf(transpose(key, by)) : transpose(key, by));

    /** The tonic with its sharp or flat faded, and a small m for minor, as the HUD writes a key. */
    function keyName(key) {
        const span = document.createElement("span");
        span.className = "kn";
        for (const character of tonic(key)) {
            const part = document.createElement("span");
            if ("♯♭".includes(character)) part.className = "acc";
            part.textContent = character;
            span.append(part);
        }
        if (key.minor) {
            const m = document.createElement("span");
            m.className = "m";
            m.textContent = "m";
            span.append(m);
        }
        return span;
    }

    function pill(content, className = "") {
        const span = document.createElement("span");
        span.className = `pill ${className}`;
        span.append(content);
        return span;
    }

    function icon(name) {
        const span = document.createElement("span");
        span.className = "icon";
        span.style.setProperty("--symbol", symbol(name));
        return span;
    }

    /** A cover, or a note on a plain tile when the song has none or its picture doesn't load. */
    function cover(source, large = false) {
        const placeholder = () => {
            const tile = document.createElement("span");
            tile.className = `cover empty${large ? " large" : ""}`;
            tile.append(icon("music.note"));
            return tile;
        };
        if (!source) return placeholder();
        const image = document.createElement("img");
        image.className = `cover${large ? " large" : ""}`;
        image.alt = "";
        image.decoding = "async";
        image.onerror = () => image.replaceWith(placeholder());
        image.src = source;
        return image;
    }

    // MARK: Requests

    /** A line in Muskey's log on the Mac, for what goes wrong on the phone, where nobody can read the console. */
    function report(message) {
        fetch("/api/log", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ message: String(message) }) }).catch(() => {});
    }
    addEventListener("error", (event) => report(`script error: ${event.message} at ${event.filename}:${event.lineno}`));
    addEventListener("unhandledrejection", (event) => report(`unhandled: ${event.reason?.message || event.reason}`));

    // The tests on a simulator open the page with ?testmute, which keeps the stream at zero volume, so that the Mac
    // running the simulator stays quiet. iOS decides whether the sound may start before the volume matters.
    const testMute = (() => {
        try {
            if (new URLSearchParams(location.search).has("testmute")) sessionStorage.setItem("testmute", "1");
            return sessionStorage.getItem("testmute") === "1";
        } catch {
            return false;
        }
    })();

    async function api(path, body) {
        let response;
        try {
            response = await fetch(path, body === undefined ? { cache: "no-store" } : {
                method: "POST",
                headers: { "Content-Type": "application/json" },
                body: JSON.stringify(body),
            });
        } catch (error) {
            if (!path.startsWith("/api/state")) report(`${path} unreachable: ${error.message}`);
            throw error;
        }
        if (!response.ok) {
            const text = (await response.text()) || response.statusText;
            report(`${path} answered ${response.status}: ${text}`);
            throw new Error(text);
        }
        return response.status === 204 ? null : response.json();
    }

    /** Asks how a job goes until it is done, showing its progress in `button`, and gives its last answer. */
    async function follow(job, button) {
        const token = {};
        if (button) button.token = token;
        while (!job.done) {
            if (button) progress(button, job.progress);
            await new Promise((resolve) => setTimeout(resolve, 400));
            if (button && button.token !== token) throw new Error("Stopped");
            job = await api(`/api/job/${job.job}`);
        }
        if (button) progress(button, null);
        if (job.error) {
            report(`job failed: ${job.error}`);
            throw new Error(job.error[0].toUpperCase() + job.error.slice(1));
        }
        return job;
    }

    /** A job's progress as a fill inside the button that started it, or a moving shine while its share is unknown. */
    function progress(button, share) {
        button.classList.toggle("working", share !== null);
        button.classList.toggle("unknown", share === undefined);
        button.style.setProperty("--done", share == null ? "0%" : `${Math.round(share * 100)}%`);
    }

    /** A failed action: its button turns red and reads Retry, and the error shows under it. */
    function fail(button, line, error) {
        const label = button.querySelector(".label-text") || button;
        if (!button.dataset.label) button.dataset.label = label.textContent;
        label.textContent = "Retry";
        button.classList.add("failed");
        progress(button, null);
        if (line) {
            line.textContent = error.message;
            line.hidden = false;
        }
    }

    function clearFailures() {
        for (const button of document.querySelectorAll("button.failed")) {
            const label = button.querySelector(".label-text") || button;
            if (button.dataset.label) label.textContent = button.dataset.label;
            delete button.dataset.label;
            button.classList.remove("failed");
        }
        for (const line of document.querySelectorAll(".error-line")) {
            line.textContent = "";
            line.hidden = true;
        }
    }

    // MARK: State

    let songs = [];
    let state = null;
    let stateAt = 0;
    /** The song view is open. */
    let open = false;
    let shift = 0;
    let relative = false;
    let speed = 1;
    let muted = new Set();
    let notesStem = "auto";
    let sheet = null;
    /** A change made here a moment ago, which the next answers about the Mac's state don't undo. */
    let touched = 0;
    let transportAt = 0;

    const original = () => parseKey(state?.key);

    // MARK: Home

    async function loadSongs() {
        try {
            songs = await api("/api/songs");
        } catch {
            songs = [];
        }
        const list = $("songs");
        if (!songs.length) {
            const empty = document.createElement("div");
            empty.className = "empty";
            empty.textContent = "Play a song in Muskey to list it here";
            list.replaceChildren(empty);
            return;
        }
        list.replaceChildren(...songs.map((item) => {
            const row = document.createElement("button");
            row.className = "row song-row";
            const texts = document.createElement("div");
            texts.className = "grow";
            const title = document.createElement("div");
            title.className = "song-title";
            title.textContent = item.title;
            const artist = document.createElement("div");
            artist.className = "song-artist";
            artist.textContent = item.artist || "";
            texts.append(title, artist);
            const pills = document.createElement("div");
            pills.className = "pills";
            const key = parseKey(item.key);
            if (key) pills.append(pill(keyName(key)));
            const chevron = icon("chevron.right");
            chevron.classList.add("chevron");
            row.append(cover(item.cover ? `/api/cover/${item.id}` : null), texts, pills, chevron);
            row.onclick = () => playSong(item, row);
            return row;
        }));
    }

    /** A song of Recents plays on the Mac, and the song view opens on it once it plays. */
    async function playSong(item, row) {
        if (row.classList.contains("working")) return;
        clearFailures();
        const artist = row.querySelector(".song-artist");
        try {
            await follow(await api("/api/play", { song: item.id }), row);
            await refreshState();
            openSong();
        } catch (error) {
            if (error.message === "Stopped") return;
            progress(row, null);
            row.classList.add("failed");
            artist.dataset.artist = artist.textContent;
            artist.textContent = error.message;
            setTimeout(() => {
                row.classList.remove("failed");
                artist.textContent = artist.dataset.artist;
            }, 6000);
        }
    }

    async function refreshState() {
        const asked = performance.now();
        try {
            // The song view asks with view=song, which loads the stems model on the Mac for a tap on an instrument.
            const next = await api(open ? "/api/state?view=song" : "/api/state");
            // An answer to a request sent before the last play, pause or seek doesn't know about it yet.
            if (asked < transportAt && state && next.title === state.title) {
                next.playing = state.playing;
                next.position = macPosition();
            }
            state = next;
            stateAt = performance.now();
        } catch {
            $("mac").classList.add("offline");
            return;
        }
        $("mac").hidden = false;
        $("mac").classList.remove("offline");
        $("mac-name").textContent = state.mac;
        drawNow();
        if (open) drawSong();
    }

    /** The player, the key and the tempo that the Mac plays. The song view leaves out the two that its rows show. */
    function nowPills(target, full = true) {
        target.replaceChildren();
        if (state.app) target.append(pill(state.app));
        if (state.listening) target.append(pill("Listening", "listening"));
        if (!full) return;
        const key = parseKey(state.key);
        if (key) {
            const heardKey = heardOf(key, state.shift, state.relative);
            const content = document.createElement("span");
            content.style.display = "inline-flex";
            content.style.gap = "4px";
            content.append(keyName(heardKey));
            if (state.shift) {
                const badge = document.createElement("span");
                badge.className = "shift";
                badge.textContent = shown(state.shift);
                content.append(badge);
            }
            target.append(pill(content, state.shift || state.relative ? "honey" : ""));
        }
        if (state.bpm) target.append(pill(`${Math.round(state.bpm * state.speed)} BPM`, state.speed < 0.999 ? "blue" : state.speed > 1.001 ? "honey" : ""));
    }

    let nowCover;
    function drawNow() {
        const playing = Boolean(state?.title);
        $("now").disabled = !playing;
        $("now-chevron").hidden = !playing;
        $("now-title").textContent = playing ? state.title : "Nothing playing";
        $("now-artist").textContent = playing ? state.artist || "" : "";
        if (playing) nowPills($("now-pills"));
        else $("now-pills").replaceChildren();
        const source = state?.cover ? `/api/nowcover?song=${encodeURIComponent(state.title || "")}` : null;
        if (source !== nowCover) {
            nowCover = source;
            $("now-cover").replaceChildren(cover(source));
        }
    }

    // MARK: Song view

    function show(view) {
        for (const name of ["home", "files", "song"]) $(name).hidden = view !== name;
        scrollTo(0, 0);
    }

    let songCover;
    function openSong() {
        if (!state?.title) return;
        open = true;
        closeSheet();
        clearFailures();
        shift = state.shift;
        relative = state.relative;
        speed = state.speed;
        muted = new Set(state.mutedStems || []);
        touched = 0;
        songCover = undefined;
        $("save-link").hidden = true;
        pickedEnd = null;
        drawSong();
        drawAll();
        show("song");
        if (history.state?.song !== true) history.pushState({ song: true }, "");
        centerKeys();
    }

    /** Back to the view that opened the song: the home view or the files of the Mac. */
    function closeSong() {
        open = false;
        closeSheet();
        if (history.state?.files === true) return show("files");
        show("home");
        loadSongs();
    }

    function drawSong() {
        $("song-title").textContent = $("bar-title").textContent = state.title || "Nothing playing";
        $("song-artist").textContent = state.artist || "";
        nowPills($("song-pills"), false);
        const source = state.cover ? `/api/nowcover?song=${encodeURIComponent(state.title || "")}` : null;
        if (source !== songCover) {
            songCover = source;
            $("song-cover").replaceChildren(cover(source, true));
        }
        // The notes need the song's file, which links and files have, and other players' songs don't.
        $("notes-section").hidden = $("save-section").hidden = !state.song;
        drawTransport();
        drawOutput();
        // The Mac's state wins, unless a change was just made here and the Mac hasn't applied it yet.
        if (Date.now() - touched > 3000) {
            const stems = new Set(state.mutedStems || []);
            const changed = shift !== state.shift || relative !== state.relative || Math.abs(speed - state.speed) > 0.001
                || stems.size !== muted.size || [...stems].some((name) => !muted.has(name));
            shift = state.shift;
            relative = state.relative;
            speed = state.speed;
            muted = stems;
            if (changed) drawAll();
        }
    }

    function drawAll() {
        drawKeys();
        drawSpeed();
        drawStems();
        drawNotesPicker();
    }

    // MARK: Key

    function drawKeys() {
        const key = original();
        // Both rows always: a phone has no Option key to reach the other mode.
        const both = Boolean(key);
        const row = $("keys");
        row.classList.toggle("both", both);
        row.replaceChildren();
        const selected = fold(shift);
        for (let offset = -6; offset <= 5; offset++) {
            row.append(chip(key, offset, false, selected));
            if (both) row.append(chip(key, offset, true, selected));
        }
        $("key-down").disabled = shift <= -12;
        $("key-up").disabled = shift >= 12;
        // The key of the song, and the key that plays once it changed.
        const change = $("change-pill");
        change.hidden = !key;
        change.classList.toggle("honey", Boolean(key) && (shift !== 0 || relative));
        if (key && shift === 0 && !relative) change.replaceChildren(keyName(key));
        else if (key) {
            const content = document.createElement("span");
            content.style.display = "inline-flex";
            content.style.gap = "4px";
            content.style.alignItems = "baseline";
            content.append(keyName(key), " → ", keyName(heardOf(key, shift, relative)));
            if (shift) {
                const badge = document.createElement("span");
                badge.className = "shift";
                badge.textContent = shown(shift);
                content.append(badge);
            }
            change.replaceChildren(content);
        }
    }

    function chip(key, offset, second, selectedOffset) {
        const button = document.createElement("button");
        button.className = "chip";
        const inColumn = offset === selectedOffset;
        if (!key) {
            button.textContent = shown(offset);
            if (inColumn) button.classList.add("selected");
            if (offset === 0) button.classList.add("original");
        } else {
            const transposed = transpose(key, offset);
            const face = second ? relativeOf(transposed) : transposed;
            button.append(keyName(face));
            const isSelected = inColumn && relative === second;
            const partner = inColumn && relative !== second;
            if (second) button.classList.add("second");
            if (offset === 0 && !second) button.classList.add("original");
            if (isSelected) button.classList.add("selected");
            else if (partner) button.classList.add("partner");
            else {
                const steps = harmony(offset - shift);
                if (steps === 1) button.classList.add("strong");
                else if (steps === 2) button.classList.add("light");
            }
            button.setAttribute("aria-label", `${tonic(face)} ${face.minor ? "minor" : "major"}`);
        }
        button.setAttribute("aria-pressed", String(key ? inColumn && relative === second : inColumn));
        // The column of the selected key keeps the shift, which can be an octave away from its offset.
        button.onclick = () => setKey(inColumn ? shift : offset, second);
        return button;
    }

    function centerKeys() {
        requestAnimationFrame(() => $("keys").querySelector(".selected")?.scrollIntoView({ inline: "center", block: "nearest" }));
    }

    function setKey(newShift, newRelative) {
        const previousRelative = relative;
        shift = Math.max(-12, Math.min(12, newShift));
        relative = Boolean(newRelative);
        clearFailures();
        drawKeys();
        centerKeys();
        if (sheet && (sheet.state.shift !== shift || sheet.state.relative !== relative)) sheet.set({ shift, relative });
        const key = original();
        // A number keeps the mode on the Mac, and a key's name moves to its mode.
        live({ key: key && relative !== previousRelative ? ascii(heardOf(key, shift, relative)) : signed(shift) });
    }

    // MARK: Tempo

    /** Muskey Player plays a song faster too, and another player's song can only be slowed down. */
    const fastest = () => (state?.app === "Muskey Player" ? 1.5 : 1);

    function drawSpeed() {
        const percent = Math.round(speed * 100);
        $("speed-value").textContent = `${percent}%`;
        $("speed-down").disabled = speed <= 0.5;
        $("speed-up").disabled = speed >= fastest() - 0.001;
        const bpm = state?.bpm;
        $("bpm-pill").hidden = !bpm;
        if (bpm) {
            $("bpm-pill").textContent = `${Math.round(bpm * speed)} BPM`;
            $("bpm-pill").className = `pill ${speed < 0.999 ? "blue" : speed > 1.001 ? "honey" : ""}`;
        }
    }

    function setSpeed(value) {
        speed = Math.round(Math.max(0.5, Math.min(fastest(), value)) * 20) / 20;
        clearFailures();
        drawSpeed();
        live({ speed });
    }

    // MARK: Instruments

    /** The circles are made once and updated in place, so a hold that plays one stem keeps its button under the finger. */
    function drawStems() {
        const row = $("stems");
        if (!row.children.length) row.append(...STEMS.map(stemButton));
        for (const button of row.children) {
            const on = !muted.has(button.dataset.stem);
            button.classList.toggle("muted", !on);
            button.setAttribute("aria-pressed", String(on));
        }
        $("play-all").hidden = muted.size === 0;
    }

    function stemButton(stem) {
        const button = document.createElement("button");
        button.className = "stem";
        button.dataset.stem = stem.name;
        button.style.setProperty("--hue", stem.hue);
        button.setAttribute("aria-label", stem.label);
        const disc = document.createElement("span");
        disc.className = "disc";
        disc.append(icon(stem.symbol));
        const name = document.createElement("span");
        name.className = "name";
        name.textContent = stem.label;
        button.append(disc, name);
        // A tap mutes or plays the stem, and holding it plays only that stem, as Option-click does in the HUD.
        let held = null;
        let solo = false;
        button.onpointerdown = () => {
            solo = false;
            held = setTimeout(() => {
                solo = true;
                setStems(new Set(STEMS.map((s) => s.name).filter((n) => n !== stem.name)));
                navigator.vibrate?.(10);
            }, 450);
        };
        const release = () => clearTimeout(held);
        button.onpointerup = release;
        button.onpointerleave = release;
        button.onpointercancel = release;
        button.oncontextmenu = (event) => event.preventDefault();
        button.onclick = () => {
            if (solo) {
                solo = false;
                return;
            }
            const next = new Set(muted);
            next.has(stem.name) ? next.delete(stem.name) : next.add(stem.name);
            // Every stem muted plays nothing, so the last one stays on.
            if (next.size === STEMS.length) return;
            setStems(next);
        };
        return button;
    }

    function setStems(next) {
        muted = next;
        clearFailures();
        drawStems();
        live({ stems: STEMS.map((s) => s.name).filter((n) => !muted.has(n)) });
    }

    // MARK: Changes to the song that plays on the Mac

    let liveTimer = null;
    let livePending = {};
    /** Sends a change to the Mac a moment after the last tap, so a run of taps sends one request. */
    function live(change) {
        touched = Date.now();
        livePending = { ...livePending, ...change };
        clearTimeout(liveTimer);
        liveTimer = setTimeout(async () => {
            const body = livePending;
            livePending = {};
            try {
                await follow(await api("/api/live", body));
                touched = Date.now();
                refreshState();
            } catch (error) {
                if (error.message === "Stopped") return;
                $("song-error").textContent = error.message;
                $("song-error").hidden = false;
            }
        }, 250);
    }

    // MARK: Play, pause and seek on the Mac

    /** The player's position, moved on from the last state by the time since, while the song plays. */
    function macPosition() {
        if (state?.position == null) return null;
        const since = state.playing ? ((performance.now() - stateAt) / 1000) * (state.speed || 1) : 0;
        return Math.min(state.position + since, state.duration ?? Infinity);
    }

    function drawTransport() {
        if (!open || !state) return;
        $("mac-play-icon").style.setProperty("--symbol", symbol(state.playing ? "pause.fill" : "play.fill"));
        $("mac-play").setAttribute("aria-label", state.playing ? "Pause" : "Play");
        const position = macPosition();
        const duration = songDuration();
        const known = position != null && duration > 0;
        $("transport").classList.toggle("unknown", !known);
        for (const id of ["mac-back", "mac-forward", "loop-button"]) $(id).disabled = !known || !state.seekable;
        if (known) {
            $("mac-elapsed").textContent = clock(position);
            $("mac-left").textContent = `−${clock(Math.max(0, duration - position))}`;
        }
        drawLoopControls();
        loadWave();
        drawWave();
        if (sheet) {
            sheet.setTime(Math.max(0, (position ?? 0) - (output === "phone" ? player.lag() : 0)));
            sheet.setPlaying(Boolean(state.playing), speed);
        }
    }

    async function transport(body) {
        transportAt = performance.now();
        try {
            await api("/api/transport", body);
        } finally {
            setTimeout(refreshState, 300);
        }
    }

    // MARK: Waveform and region loop

    /** The levels of the song as the HUD keeps them: 50 a second, one byte each, 0 for a moment not heard yet. */
    let wave = null;
    let waveVersion = null;
    let waveLoading = false;
    const songDuration = () => state?.duration || wave?.duration || 0;

    async function loadWave() {
        if (waveLoading || !state || (state.wave ?? null) === waveVersion) return;
        const version = state.wave ?? null;
        if (version === null) {
            wave = null;
            waveVersion = null;
            return;
        }
        waveLoading = true;
        try {
            const answer = await api("/api/waveform");
            const text = atob(answer.levels);
            const levels = new Uint8Array(text.length);
            for (let i = 0; i < text.length; i++) levels[i] = text.charCodeAt(i);
            wave = { duration: answer.duration, rate: answer.rate, levels };
            waveVersion = version;
            drawWave(true);
        } catch {
            // The waveform stays as it was, and the next state asks again.
        } finally {
            waveLoading = false;
        }
    }

    /** A loop changed here a moment ago, which answers about the Mac's state from before the change don't undo. */
    let loopOverride = null;
    function currentLoop() {
        if (loopOverride && performance.now() - loopOverride.at < 2500) return loopOverride.loop;
        return state?.loop ?? null;
    }
    function changeLoop(loop) {
        loopOverride = { at: performance.now(), loop };
        drawLoopControls();
        drawWave(true);
    }

    /** The end of the loop whose tab was tapped: the buttons beside play move it while it is picked. */
    let pickedEnd = null;
    /** Moves an end as far as the Mac lets it: inside the song, and a quarter of a second from the other end. */
    function clampEnd(loop, end, time) {
        const duration = songDuration();
        return end === "start" ? Math.min(Math.max(0, time), (loop.end ?? duration) - 0.25) : Math.max(Math.min(duration, time), loop.start + 0.25);
    }

    const precise = (t) => `${Math.floor(t / 60)}:${(t % 60).toFixed(2).padStart(5, "0")}`;

    function drawLoopControls() {
        const loop = currentLoop();
        // An end that went away can't stay picked.
        if (!loop || (pickedEnd === "end" && loop.end == null)) pickedEnd = null;
        const button = $("loop-button");
        button.classList.toggle("started", Boolean(loop && loop.end == null));
        button.classList.toggle("on", Boolean(loop && loop.end != null));
        button.setAttribute("aria-label", !loop ? "Start loop" : loop.end == null ? "End loop" : "Clear loop");
        // The buttons beside play move the picked end of the loop, or the song by 5 seconds.
        $("back-icon").style.setProperty("--symbol", symbol(pickedEnd ? "chevron.left" : "gobackward.5"));
        $("forward-icon").style.setProperty("--symbol", symbol(pickedEnd ? "chevron.right" : "goforward.5"));
        const name = pickedEnd === "start" ? "loop start" : "loop end";
        $("mac-back").setAttribute("aria-label", pickedEnd ? `Move ${name} earlier` : "Back 5 seconds");
        $("mac-forward").setAttribute("aria-label", pickedEnd ? `Move ${name} later` : "Forward 5 seconds");
        const time = loop && pickedEnd ? (pickedEnd === "start" ? loop.start : loop.end) : null;
        $("loop-time").textContent = time != null
            ? `${pickedEnd === "start" ? "A" : "B"} ${precise(time)}`
            : loop?.end != null ? `${clock(loop.start)} – ${clock(loop.end)}` : "";
        drawSaveAndNotes();
    }

    /** Every frame while the song view shows: the playhead, the clocks and the bars that changed colour. */
    function tick() {
        if (!state) return;
        const position = macPosition();
        const duration = songDuration();
        if (position != null && duration > 0) {
            $("mac-elapsed").textContent = clock(position);
            $("mac-left").textContent = `−${clock(Math.max(0, duration - position))}`;
        }
        drawWave();
    }

    /** A failed loop or output action: the icon button turns red, and the error shows over the bar. */
    function failIcon(button, error) {
        button.classList.add("failed");
        $("song-error").textContent = error.message;
        $("song-error").hidden = false;
        setTimeout(() => button.classList.remove("failed"), 6000);
    }

    let drawnBars = null;
    /** The waveform as bars, the part played in ink and the rest faded, with the loop in honey. The canvas is drawn
     * again only when a bar changes colour, the loop moves, or `force` asks. */
    function drawWave(force = false) {
        const canvas = $("wave-canvas");
        const box = $("wave").getBoundingClientRect();
        const duration = songDuration();
        if (!box.width || !duration) return;
        const position = macPosition() ?? 0;
        $("playhead").style.transform = `translateX(${(Math.min(position, duration) / duration) * box.width}px)`;
        drawEnds(box.width, duration);
        const ratio = window.devicePixelRatio || 1;
        const width = Math.round(box.width * ratio), height = Math.round(box.height * ratio);
        const step = 3 * ratio, barWidth = 2 * ratio;
        const count = Math.floor(width / step);
        const played = Math.floor((position / duration) * count);
        const loop = currentLoop();
        const key = `${width}x${height} ${played} ${waveVersion} ${loop?.start} ${loop?.end}`;
        if (!force && key === drawnBars) return;
        drawnBars = key;
        if (canvas.width !== width || canvas.height !== height) {
            canvas.width = width;
            canvas.height = height;
        }
        const context = canvas.getContext("2d");
        context.clearRect(0, 0, width, height);
        const css = getComputedStyle(document.documentElement);
        const ink = css.getPropertyValue("--ink").trim(), muted = css.getPropertyValue("--muted").trim(), honey = css.getPropertyValue("--honey").trim();
        const looped = loop?.end != null ? [loop.start / duration, loop.end / duration] : null;
        if (looped) {
            context.globalAlpha = 0.16;
            context.fillStyle = honey;
            context.fillRect(looped[0] * width, 0, (looped[1] - looped[0]) * width, height);
        }
        const levels = wave?.levels;
        for (let i = 0; i < count; i++) {
            let level = 0;
            if (levels?.length) {
                const a = Math.floor((i / count) * levels.length), b = Math.max(a + 1, Math.floor(((i + 1) / count) * levels.length));
                for (let j = a; j < b && j < levels.length; j++) level = Math.max(level, levels[j]);
            }
            const share = (i + 0.5) / count;
            const inLoop = looped && share >= looped[0] && share <= looped[1];
            const bar = level ? Math.max(2 * ratio, ((level - 1) / 254) * height) : 1.5 * ratio;
            context.fillStyle = inLoop ? honey : i < played ? ink : muted;
            context.globalAlpha = !level ? 0.18 : inLoop ? (i < played ? 1 : 0.6) : i < played ? 0.85 : looped ? 0.18 : 0.3;
            context.fillRect(i * step, (height - bar) / 2, barWidth, bar);
        }
        context.globalAlpha = 1;
    }

    function drawEnds(width, duration) {
        const loop = currentLoop();
        for (const end of ["start", "end"]) {
            const element = $(`end-${end}`);
            const time = loop ? (end === "start" ? loop.start : loop.end) : null;
            element.hidden = time == null;
            if (time == null) continue;
            element.style.left = `${(time / duration) * width}px`;
            element.classList.toggle("selected", pickedEnd === end);
        }
    }

    let moveTimer = 0;
    let moveSentAt = 0;
    /** Moves an end here at once, and on the Mac at most every 150 ms while a finger drags it, then where it stops. */
    function moveEnd(end, time, final) {
        const loop = currentLoop();
        if (!loop || (end === "end" && loop.end == null)) return;
        const seconds = clampEnd(loop, end, time);
        changeLoop({ ...loop, [end]: seconds });
        clearTimeout(moveTimer);
        const send = () => {
            moveSentAt = performance.now();
            api("/api/loop", { action: "move", which: end, seconds }).catch(() => {});
        };
        if (final || performance.now() - moveSentAt > 150) send();
        else moveTimer = setTimeout(send, 150);
    }

    function timeAt(clientX) {
        const box = $("wave").getBoundingClientRect();
        return Math.min(1, Math.max(0, (clientX - box.left) / box.width)) * songDuration();
    }

    // A tap moves the song there, a drag across the waveform makes a loop of the part it covers, and a drag on a tab
    // moves that end. A tap on a tab picks it for the buttons beside play, and a second tap lets it go.
    let gesture = null;
    $("wave").addEventListener("pointerdown", (event) => {
        if (!state?.seekable || !songDuration() || event.button > 0) return;
        const end = event.target.closest(".loop-end")?.dataset.end ?? null;
        $("wave").setPointerCapture(event.pointerId);
        gesture = { id: event.pointerId, x: event.clientX, end, moved: false };
        event.preventDefault();
    });
    $("wave").addEventListener("pointermove", (event) => {
        if (!gesture || event.pointerId !== gesture.id) return;
        if (!gesture.moved && Math.abs(event.clientX - gesture.x) < 6) return;
        gesture.moved = true;
        if (gesture.end) return moveEnd(gesture.end, timeAt(event.clientX), false);
        const box = $("wave").getBoundingClientRect();
        const a = Math.max(box.left, Math.min(gesture.x, event.clientX)), b = Math.min(box.right, Math.max(gesture.x, event.clientX));
        const selection = $("wave-selection");
        selection.hidden = false;
        selection.style.left = `${a - box.left}px`;
        selection.style.width = `${b - a}px`;
    });
    const endGesture = (event, cancelled) => {
        if (!gesture || event.pointerId !== gesture.id) return;
        const { x, end, moved } = gesture;
        gesture = null;
        $("wave-selection").hidden = true;
        if (cancelled) return;
        if (end) {
            if (moved) return moveEnd(end, timeAt(event.clientX), true);
            pickedEnd = pickedEnd === end ? null : end;
            return drawTransport();
        }
        if (moved) {
            const a = timeAt(Math.min(x, event.clientX)), b = timeAt(Math.max(x, event.clientX));
            if (b - a < 0.25) return;
            pickedEnd = null;
            changeLoop({ start: a, end: b });
            api("/api/loop", { action: "set", start: a, end: b }).catch((error) => failIcon($("loop-button"), error));
            return;
        }
        pickedEnd = null;
        const seconds = timeAt(event.clientX);
        state.position = seconds;
        stateAt = performance.now();
        drawTransport();
        transport({ action: "seek", seconds });
    };
    $("wave").addEventListener("pointerup", (event) => endGesture(event, false));
    $("wave").addEventListener("pointercancel", (event) => endGesture(event, true));
    addEventListener("resize", () => drawWave(true));

    /** The loop button works as R does on the Mac: it starts the loop where the song is, ends it, then clears it. */
    function pressLoop() {
        const loop = currentLoop();
        const position = macPosition() ?? 0;
        if (!loop) changeLoop({ start: position, end: null });
        else if (loop.end == null) changeLoop({ ...loop, end: Math.max(position, loop.start + 0.25) });
        else {
            pickedEnd = null;
            changeLoop(null);
        }
        api("/api/loop", { action: "press" }).catch((error) => failIcon($("loop-button"), error));
    }

    /** The buttons beside play: 5 seconds back or forward, or while a tab is picked, its end by 20 ms, again and again
     * while the finger stays down. */
    function stepButton(id, direction) {
        const button = $(id);
        let delay = 0;
        let repeat = 0;
        const stop = () => {
            clearTimeout(delay);
            clearInterval(repeat);
        };
        const nudge = () => {
            const loop = currentLoop();
            if (!loop || !pickedEnd) return stop();
            const time = pickedEnd === "start" ? loop.start : loop.end;
            moveEnd(pickedEnd, time + direction * 0.02, false);
        };
        button.addEventListener("pointerdown", () => {
            if (!pickedEnd || button.disabled) return;
            nudge();
            delay = setTimeout(() => (repeat = setInterval(nudge, 60)), 400);
        });
        for (const name of ["pointerup", "pointerleave", "pointercancel"]) {
            button.addEventListener(name, () => {
                if (!delay && !repeat) return;
                stop();
                delay = repeat = 0;
                const loop = currentLoop();
                if (loop && pickedEnd) moveEnd(pickedEnd, pickedEnd === "start" ? loop.start : loop.end, true);
            });
        }
        button.addEventListener("click", () => {
            if (!pickedEnd) transport({ action: direction < 0 ? "back" : "forward" });
        });
    }

    // MARK: Output: the Mac, or this phone through a live stream of the Mac's output

    let output = "mac";

    /** Plays /api/stream: 16-bit stereo PCM read from one long request and scheduled about a quarter of a second ahead
     * in an AudioContext, which starts inside the tap, as iOS asks. */
    const player = (() => {
        let context = null;
        let gain = null;
        let abort = null;
        let playAt = 0;
        let generation = 0;
        // What arrived since the last report, for the Mac's log: seconds of audio and their loudest sample.
        let receivedSeconds = 0;
        let peak = 0;
        setInterval(() => {
            if (!context || abort === null) return;
            const db = peak > 0 ? Math.round(20 * Math.log10(peak)) : -Infinity;
            report(`stream: ${receivedSeconds.toFixed(1)} s received in 10 s, peak ${db} dB, ${Math.round((playAt - context.currentTime) * 1000)} ms ahead`);
            receivedSeconds = 0;
            peak = 0;
        }, 10000);

        function ensureContext() {
            if (!context) {
                if (navigator.audioSession) navigator.audioSession.type = "playback";
                context = new AudioContext();
                gain = context.createGain();
                gain.gain.value = testMute ? 0 : 1;
                gain.connect(context.destination);
            }
            return context.resume();
        }

        async function run(mine) {
            while (mine === generation) {
                abort = new AbortController();
                try {
                    const response = await fetch("/api/stream", { cache: "no-store", signal: abort.signal });
                    if (!response.ok) throw new Error(`the stream answered ${response.status}`);
                    const rate = Number(response.headers.get("X-Sample-Rate")) || 48000;
                    report(`stream connected at ${rate} Hz, the context runs at ${context.sampleRate} Hz (${context.state})`);
                    const reader = response.body.getReader();
                    let carry = new Uint8Array(0);
                    playAt = 0;
                    for (;;) {
                        const { value, done } = await reader.read();
                        if (done || mine !== generation) break;
                        const bytes = new Uint8Array(carry.length + value.length);
                        bytes.set(carry);
                        bytes.set(value, carry.length);
                        const usable = bytes.length - (bytes.length % 4);
                        carry = bytes.slice(usable);
                        schedule(new DataView(bytes.buffer, 0, usable), usable / 4, rate);
                    }
                } catch (error) {
                    if (mine !== generation) return;
                    report(`stream: ${error.message}`);
                }
                // The Mac closes the stream when its output changes rate, and the page connects again at once.
                if (mine === generation) await new Promise((resolve) => setTimeout(resolve, 300));
            }
        }

        function schedule(view, frames, rate) {
            if (!frames || !context) return;
            const buffer = context.createBuffer(2, frames, rate);
            const left = buffer.getChannelData(0);
            const right = buffer.getChannelData(1);
            let loudest = 0;
            for (let i = 0; i < frames; i++) {
                left[i] = view.getInt16(i * 4, true) / 32768;
                right[i] = view.getInt16(i * 4 + 2, true) / 32768;
                loudest = Math.max(loudest, Math.abs(left[i]), Math.abs(right[i]));
            }
            receivedSeconds += frames / rate;
            peak = Math.max(peak, loudest);
            const now = context.currentTime;
            // Too close to the speaker after a gap, or too far after a burst: start again a quarter second ahead.
            if (playAt < now + 0.03 || playAt > now + 1.2) playAt = now + 0.25;
            const source = context.createBufferSource();
            source.buffer = buffer;
            source.connect(gain);
            source.start(playAt);
            playAt += buffer.duration;
        }

        return {
            /** Called from the tap on Phone. */
            start() {
                const mine = ++generation;
                const resumed = ensureContext();
                run(mine);
                return resumed;
            },
            stop() {
                generation++;
                abort?.abort();
                abort = null;
                context?.suspend();
            },
            /** Seconds between the Mac playing a moment and this phone playing it. */
            lag() {
                return context && playAt ? Math.max(0, playAt - context.currentTime) + 0.05 : 0;
            },
        };
    })();

    function setOutput(next) {
        if (next === output) return;
        output = next;
        clearFailures();
        if (output === "phone") {
            // Inside the tap: iOS lets Web Audio start only from one.
            player.start().catch((error) => {
                report(`audio refused: ${error.name} ${error.message}`);
                player.stop();
                output = "mac";
                drawOutput();
                failIcon($("output-button"), new Error("This phone refused to play the sound. Tap the output button to try again"));
            });
        } else {
            player.stop();
        }
        drawOutput();
        setTimeout(refreshState, 400);
    }

    function drawOutput() {
        $("out-mac").setAttribute("aria-checked", String(output === "mac"));
        $("out-phone").setAttribute("aria-checked", String(output === "phone"));
        $("output-icon").style.setProperty("--symbol", symbol(output === "phone" ? "iphone" : "macbook"));
        $("output-button").classList.toggle("phone", output === "phone");
        $("output-button").setAttribute("aria-label", output === "phone" ? "Output: this phone" : "Output: Mac");
    }

    function showOutputMenu(shown) {
        $("output-menu").hidden = !shown;
        $("output-button").setAttribute("aria-expanded", String(shown));
    }

    // MARK: Save

    /** Save and Transcribe take the loop once it has an end, and the whole song otherwise. */
    function drawSaveAndNotes() {
        const looped = currentLoop()?.end != null;
        const save = $("save");
        if (!save.classList.contains("failed") && !save.classList.contains("working")) {
            save.querySelector(".label-text").textContent = looped ? "Save loop" : "Save song";
        }
        drawTranscribeLabel();
    }

    /** The song as it plays on the Mac, with its key, tempo and instruments, or only its loop, written on the Mac
     * and offered here as a download. */
    async function save() {
        const button = $("save");
        if (!state?.song || button.classList.contains("working")) return;
        clearFailures();
        $("save-link").hidden = true;
        const loop = currentLoop();
        const body = {
            song: state.song,
            format: "m4a",
            key: signed(shift),
            speed,
            stems: muted.size ? STEMS.map((s) => s.name).filter((n) => !muted.has(n)) : undefined,
            ...(loop?.end != null ? { from: loop.start, to: loop.end } : {}),
        };
        try {
            const job = await follow(await api("/api/write", body), button);
            const link = $("save-link");
            link.href = job.file;
            link.setAttribute("download", "");
            link.hidden = false;
        } catch (error) {
            if (error.message !== "Stopped") fail(button, $("save-error"), error);
        }
    }

    // MARK: Notes

    const NOTES_OPTIONS = [{ name: "auto", label: "Auto" }, ...STEMS.filter((s) => s.name !== "drums")];

    /** Transcribe names the instrument picked, and the loop once it has an end. */
    function drawTranscribeLabel() {
        const button = $("transcribe");
        if (button.classList.contains("failed") || button.classList.contains("working")) return;
        const picked = NOTES_OPTIONS.find((o) => o.name === notesStem);
        const looped = currentLoop()?.end != null;
        const what = notesStem === "auto" ? "Transcribe" : `Transcribe ${picked.label.toLowerCase()}`;
        const label = looped ? (notesStem === "auto" ? "Transcribe loop" : `${what} in loop`) : what;
        if (button.textContent !== label) button.textContent = label;
    }

    function drawNotesPicker() {
        const options = NOTES_OPTIONS;
        drawTranscribeLabel();
        $("notes-stem").replaceChildren(...options.map((option) => {
            const button = document.createElement("button");
            button.setAttribute("aria-pressed", String(option.name === notesStem));
            button.setAttribute("aria-label", option.label);
            if (option.symbol) button.append(icon(option.symbol));
            else button.textContent = option.label;
            button.onclick = () => {
                notesStem = option.name;
                clearFailures();
                drawNotesPicker();
            };
            return button;
        }));
    }

    async function transcribe() {
        const button = $("transcribe");
        if (button.classList.contains("failed")) clearFailures();
        if (!state?.song) return;
        button.disabled = true;
        try {
            const loop = currentLoop();
            const part = loop?.end != null ? { from: loop.start, to: loop.end } : {};
            const job = await follow(await api("/api/write", { song: state.song, notes: notesStem, format: "json", ...part }), button);
            const data = await (await fetch(job.file)).json();
            closeSheet();
            $("sheet").hidden = false;
            sheet = MuskeySheet.mount($("sheet"), data, {
                shift,
                relative,
                onSeek: (time) => {
                    if (state?.seekable) transport({ action: "seek", seconds: Math.max(0, time) });
                },
                onChange: (next) => {
                    if (next.shift !== shift || next.relative !== relative) setKey(next.shift, next.relative);
                },
            });
            drawTransport();
            $("sheet").scrollIntoView({ block: "start", behavior: "smooth" });
        } catch (error) {
            if (error.message !== "Stopped") fail(button, $("notes-error"), error);
        } finally {
            button.disabled = false;
        }
    }

    function closeSheet() {
        sheet?.destroy();
        sheet = null;
        $("sheet").replaceChildren();
        $("sheet").hidden = true;
    }

    // MARK: Open

    /** A link of Spotify or of any site that yt-dlp reads plays on the Mac. */
    async function playLink(event) {
        event.preventDefault();
        const button = $("link-play");
        let link = $("link").value.trim();
        if (!link) return $("link").focus();
        // A link copied without its scheme, like youtube.com/watch?v=…, is a web link.
        if (!/^[a-z][a-z0-9+.-]*:/i.test(link) && /^[\w-]+(\.[\w-]+)+(\/|$)/.test(link)) link = `https://${link}`;
        clearFailures();
        button.disabled = true;
        try {
            await follow(await api("/api/open", { link }), button);
            $("link").value = "";
            await refreshState();
            openSong();
        } catch (error) {
            if (error.message !== "Stopped") fail(button, $("open-error"), error);
        } finally {
            button.disabled = !$("link").value.trim();
        }
    }

    /** The file of the last upload that failed, which Retry sends again. */
    let uploadFile = null;

    function chooseFile() {
        const row = $("upload");
        if (row.classList.contains("working")) return;
        if (row.classList.contains("failed") && uploadFile) return sendFile(uploadFile);
        $("upload-file").value = "";
        $("upload-file").click();
    }

    /** A file of this phone is sent to the Mac, with its progress as a fill in the row, and plays there. */
    async function sendFile(file) {
        const row = $("upload");
        uploadFile = file;
        clearFailures();
        progress(row, 0);
        report(`sending ${file.name} (${(file.size / 1e6).toFixed(1)} MB)`);
        try {
            const job = await new Promise((resolve, reject) => {
                const request = new XMLHttpRequest();
                request.open("POST", "/api/upload");
                request.setRequestHeader("Content-Type", "application/octet-stream");
                request.setRequestHeader("X-File-Name", encodeURIComponent(file.name));
                request.upload.onprogress = (event) => {
                    if (event.lengthComputable) progress(row, event.loaded / event.total);
                };
                request.onload = () => {
                    if (request.status === 200) return resolve(JSON.parse(request.responseText));
                    reject(new Error(request.responseText || `The Mac answered ${request.status}`));
                };
                request.onerror = () => reject(new Error("The file didn't reach the Mac"));
                request.send(file);
            });
            progress(row, undefined);
            await follow(job, row);
            uploadFile = null;
            await refreshState();
            openSong();
        } catch (error) {
            if (error.message === "Stopped") return;
            report(`sending ${file.name} failed: ${error.message}`);
            fail(row, $("open-error"), error);
        }
    }

    // MARK: Files on the Mac

    let filesQuery = null;
    let filesTimer = 0;

    function openFiles() {
        clearFailures();
        show("files");
        if (history.state?.files !== true) history.pushState({ files: true }, "");
        loadFiles();
    }

    async function loadFiles() {
        const query = $("files-search").value.trim();
        filesQuery = query;
        const list = $("files-list");
        let answer;
        try {
            answer = await api(`/api/files?q=${encodeURIComponent(query)}`);
        } catch (error) {
            answer = { folders: -1, files: [], more: false, error: error.message };
        }
        if (query !== filesQuery) return;
        $("files-more").hidden = !answer.more;
        if (!answer.files.length) {
            const empty = document.createElement("div");
            empty.className = "empty";
            empty.textContent = answer.error ?? (answer.folders === 0 ? "Add folders in Muskey's Settings > Remote to list their songs here" : "No songs match");
            list.replaceChildren(empty);
            return;
        }
        list.replaceChildren(...answer.files.map((file) => {
            const row = document.createElement("button");
            row.className = "row song-row file-row";
            const texts = document.createElement("div");
            texts.className = "grow";
            const title = document.createElement("div");
            title.className = "song-title";
            title.textContent = file.title;
            const folder = document.createElement("div");
            folder.className = "song-artist";
            folder.textContent = file.folder;
            texts.append(title, folder);
            row.append(icon("music.note"), texts);
            row.onclick = () => playSong(file, row);
            return row;
        }));
    }

    // MARK: Wiring

    $("now").onclick = openSong;
    $("close").onclick = $("top-close").onclick = () => history.back();
    addEventListener("popstate", () => {
        if (open && history.state?.song !== true) closeSong();
        else if (!open && history.state?.files !== true && !$("files").hidden) {
            show("home");
            loadSongs();
        }
    });
    $("files-close").onclick = () => history.back();
    $("key-down").onclick = () => setKey(shift - 1, relative);
    $("key-up").onclick = () => setKey(shift + 1, relative);
    $("speed-down").onclick = () => setSpeed(speed - 0.05);
    $("speed-up").onclick = () => setSpeed(speed + 0.05);
    $("speed-value").onclick = () => setSpeed(1);
    $("play-all").onclick = () => setStems(new Set());
    $("transcribe").onclick = transcribe;
    $("link-form").onsubmit = playLink;
    // Return in the link field plays the link, as in a single-line field.
    $("link").addEventListener("keydown", (event) => {
        if (event.key !== "Enter") return;
        event.preventDefault();
        $("link-form").requestSubmit();
    });
    $("link").oninput = () => {
        clearFailures();
        $("link-play").disabled = !$("link").value.trim();
    };
    $("link-play").disabled = true;
    $("upload").onclick = chooseFile;
    $("upload-file").onchange = () => {
        const file = $("upload-file").files[0];
        if (file) sendFile(file);
    };
    $("mac-files").onclick = openFiles;
    $("files-search").oninput = () => {
        clearTimeout(filesTimer);
        filesTimer = setTimeout(loadFiles, 200);
    };
    $("out-mac").onclick = () => {
        showOutputMenu(false);
        setOutput("mac");
    };
    $("out-phone").onclick = () => {
        showOutputMenu(false);
        $("output-button").classList.remove("failed");
        setOutput("phone");
    };
    $("output-button").onclick = (event) => {
        event.stopPropagation();
        showOutputMenu($("output-menu").hidden);
    };
    document.addEventListener("pointerdown", (event) => {
        if (!$("output-menu").hidden && !event.target.closest("#output-menu, #output-button")) showOutputMenu(false);
    });
    $("loop-button").onclick = pressLoop;
    stepButton("mac-back", -1);
    stepButton("mac-forward", 1);
    $("save").onclick = save;
    $("mac-play").onclick = () => {
        if (!state) return;
        // The glyph changes at once, and the next state from the Mac confirms it.
        const action = state.playing ? "pause" : "play";
        state.position = macPosition();
        state.playing = !state.playing;
        stateAt = performance.now();
        drawTransport();
        transport({ action });
    };
    // The playhead moves on every frame while the song view shows; the bars draw again only when one changes colour.
    const frame = () => {
        if (open && document.visibilityState === "visible") tick();
        requestAnimationFrame(frame);
    };
    requestAnimationFrame(frame);
    setInterval(() => { if (open && document.visibilityState === "visible") drawTransport(); }, 500);
    // A compact bar with the song's name and a back button shows once the song's head scrolls away.
    new IntersectionObserver(([entry]) => $("top").classList.toggle("scrolled", !entry.isIntersecting), { rootMargin: "-20px 0px 0px 0px" })
        .observe($("head"));

    // The song view's symbols are fetched while the home view shows, so that its icons are there when a song opens.
    for (const name of [...STEMS.map((s) => s.symbol), "chevron.left", "chevron.right", "play.fill", "pause.fill", "macbook", "iphone", "music.note", "minus", "plus", "gobackward.5", "goforward.5", "repeat", "checkmark", "exclamationmark.triangle.fill", "square.and.arrow.down"]) {
        new Image().src = `/api/symbol/${name}`;
    }

    // A reload keeps the history entry of the view that was open, and the page always starts on the home view.
    if (history.state !== null) history.replaceState(null, "");
    loadSongs();
    refreshState();
    setInterval(() => { if (document.visibilityState === "visible") refreshState(); }, 1500);
    document.addEventListener("visibilitychange", () => { if (document.visibilityState === "visible") refreshState(); });
})();
