// The web remote of Muskey: the songs of Recents and the song that plays on the Mac, with the HUD's key row, tempo
// and instruments. A song of Recents is played on the Mac or rendered with its changes and heard here, and its notes
// are drawn by the sheet of the notes window. The song that plays on the Mac changes at once.
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
    const shown = (n) => (n < 0 ? `\u2212${-n}` : signed(n));
    const clock = (s) => `${Math.floor(s / 60)}:${String(Math.floor(s % 60)).padStart(2, "0")}`;

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

    // MARK: Requests

    async function api(path, body) {
        const response = await fetch(path, body === undefined ? { cache: "no-store" } : {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify(body),
        });
        if (!response.ok) throw new Error((await response.text()) || response.statusText);
        return response.status === 204 ? null : response.json();
    }

    /** Asks how a job goes until it is done, showing its step in `status`, and gives its last answer. */
    async function follow(job, status) {
        const token = {};
        status.token = token;
        while (!job.done) {
            showStep(status, job);
            await new Promise((resolve) => setTimeout(resolve, 400));
            if (status.token !== token) throw new Error("Stopped");
            job = await api(`/api/job/${job.job}`);
        }
        showStep(status, null);
        if (job.error) throw new Error(job.error[0].toUpperCase() + job.error.slice(1));
        return job;
    }

    function showStep(status, job) {
        const step = job?.step;
        status.classList.remove("error");
        status.textContent = step ? (job.progress != null ? `${step} ${Math.round(job.progress * 100)}%` : step) : "";
        if (status === $("status")) {
            $("progress").hidden = !(step && job.progress != null);
            if (step && job.progress != null) $("progress").firstElementChild.style.width = `${job.progress * 100}%`;
        }
    }

    /** A failed action: its button turns red and reads Retry, and the error shows in its status line. */
    function fail(button, status, error) {
        const label = button.querySelector("span:last-child") || button;
        if (!button.dataset.label) button.dataset.label = label.textContent;
        label.textContent = "Retry";
        const glyph = button.querySelector(".icon");
        if (glyph && !button.dataset.symbol) {
            button.dataset.symbol = glyph.style.getPropertyValue("--symbol");
            glyph.style.setProperty("--symbol", symbol("arrow.clockwise"));
        }
        button.classList.add("failed");
        if (button.classList.contains("primary")) {
            button.classList.remove("primary");
            button.dataset.primary = "1";
        }
        status.textContent = error.message;
        status.classList.add("error");
        if (status === $("status")) $("progress").hidden = true;
    }

    function clearFailures() {
        for (const button of document.querySelectorAll(".button.failed")) {
            const label = button.querySelector("span:last-child") || button;
            label.textContent = button.dataset.label;
            delete button.dataset.label;
            button.classList.remove("failed");
            if (button.dataset.symbol) button.querySelector(".icon").style.setProperty("--symbol", button.dataset.symbol);
            delete button.dataset.symbol;
            if (button.dataset.primary) button.classList.add("primary");
            delete button.dataset.primary;
        }
        for (const status of document.querySelectorAll(".status.error")) {
            status.classList.remove("error");
            status.textContent = "";
        }
    }

    // MARK: State

    let songs = [];
    let state = null;
    /** "file" for a song of Recents, "live" for the song that plays on the Mac. */
    let mode = null;
    let song = null;
    let shift = 0;
    let relative = false;
    let speed = 1;
    let muted = new Set();
    let notesStem = "auto";
    /** The changes of the audio that plays here, so the sheet's line lands on the same moment of the song. */
    let heard = null;
    let sheet = null;
    /** A change made here a moment ago, which the next answers about the Mac's state don't undo. */
    let touched = 0;

    const original = () => parseKey(mode === "live" ? state?.key : song?.key);

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
            const image = document.createElement("img");
            image.className = "cover";
            image.alt = "";
            image.loading = "lazy";
            if (item.cover) image.src = `/api/cover/${item.id}`;
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
            row.append(image, texts, pills, chevron);
            row.onclick = () => openSong(item);
            return row;
        }));
    }

    async function refreshState() {
        const asked = performance.now();
        try {
            const next = await api("/api/state");
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
        for (const toggle of document.querySelectorAll(".mac-sound")) toggle.checked = state.muted === false;
        // A Mac without a sound output has nothing to mute, and the song view has the switch only for a live song.
        document.querySelector("#now-card .mac-sound").closest(".row").hidden = state.muted == null;
        $("live-sound").hidden = state.muted == null || mode !== "live";
        if (mode === "live") drawLive();
        // The second row follows Settings > HUD on the Mac.
        if (mode && state.relativeKeys !== relativeKeys) drawKeys();
        relativeKeys = state.relativeKeys;
    }
    let relativeKeys = null;
    let stateAt = 0;
    let transportAt = 0;

    /** The player and the key and tempo that the Mac plays. The song view leaves out the two that its rows show. */
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

    let coverTitle = null;
    function drawNow() {
        const playing = Boolean(state?.title);
        $("now").disabled = !playing;
        $("now-chevron").hidden = !playing;
        $("now-title").textContent = playing ? state.title : "Nothing playing";
        $("now-artist").textContent = playing ? state.artist || "" : "";
        if (playing) nowPills($("now-pills"));
        else $("now-pills").replaceChildren();
        const cover = state?.cover ? `/api/nowcover?song=${encodeURIComponent(state.title || "")}` : "";
        if (cover !== coverTitle) {
            coverTitle = cover;
            if (cover) $("now-cover").src = cover;
            else $("now-cover").removeAttribute("src");
        }
    }

    const heardOf = (key, by, other) => (other ? relativeOf(transpose(key, by)) : transpose(key, by));

    // MARK: Song views

    function show(view) {
        $("home").hidden = view !== "home";
        $("song").hidden = view !== "song";
        scrollTo(0, 0);
    }

    function openSong(item) {
        mode = "file";
        song = item;
        reset();
        $("song-title").textContent = $("bar-title").textContent = item.title;
        $("song-artist").textContent = item.artist || "";
        $("song-pills").replaceChildren();
        setCover($("song-cover"), item.cover ? `/api/cover/${item.id}` : null);
        $("part-row").hidden = false;
        $("notes-section").hidden = false;
        $("file-actions").hidden = false;
        $("transport").hidden = true;
        $("live-sound").hidden = true;
        drawAll();
        show("song");
        history.pushState({ song: item.id }, "");
        centerKeys();
    }

    function openLive() {
        if (!state?.title) return;
        mode = "live";
        song = null;
        reset();
        shift = state.shift;
        relative = state.relative;
        speed = state.speed;
        $("part-row").hidden = true;
        $("notes-section").hidden = true;
        $("file-actions").hidden = true;
        $("transport").hidden = false;
        $("live-sound").hidden = state.muted == null;
        drawLive();
        drawAll();
        show("song");
        history.pushState({ live: true }, "");
        centerKeys();
    }

    function drawLive() {
        $("song-title").textContent = $("bar-title").textContent = state.title || "Nothing playing";
        $("song-artist").textContent = state.artist || "";
        nowPills($("song-pills"), false);
        drawTransport();
        setCover($("song-cover"), state.cover ? `/api/nowcover?song=${encodeURIComponent(state.title || "")}` : null);
        // The Mac's state wins, unless a change was just made here and the Mac hasn't applied it yet.
        if (Date.now() - touched > 3000) {
            const changed = shift !== state.shift || relative !== state.relative || Math.abs(speed - state.speed) > 0.001;
            shift = state.shift;
            relative = state.relative;
            speed = state.speed;
            if (changed) drawAll();
        }
    }

    function setCover(image, source) {
        image.style.visibility = source ? "visible" : "hidden";
        if (source && image.getAttribute("src") !== source) image.src = source;
    }

    function reset() {
        stopAudio();
        closeSheet();
        clearFailures();
        shift = 0;
        relative = false;
        speed = 1;
        muted = new Set();
        heard = null;
        $("from").value = "";
        $("to").value = "";
        $("status").textContent = "";
        $("progress").hidden = true;
        $("player").hidden = true;
    }

    function closeSong() {
        $("status").token = null;
        stopAudio();
        closeSheet();
        mode = null;
        song = null;
        show("home");
        loadSongs();
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
        const both = Boolean(key && state?.relativeKeys);
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
        if (mode === "live") {
            const key = original();
            // A number keeps the mode on the Mac, and a key's name moves to its mode.
            const sent = key && relative !== previousRelative ? ascii(heardOf(key, shift, relative)) : signed(shift);
            live({ key: sent });
        }
    }

    // MARK: Tempo

    const fastest = () => (mode === "live" && state?.app !== "Muskey Player" ? 1 : 1.5);

    function drawSpeed() {
        const percent = Math.round(speed * 100);
        $("speed-value").textContent = `${percent}%`;
        $("speed-down").disabled = speed <= 0.5;
        $("speed-up").disabled = speed >= fastest() - 0.001;
        const bpm = mode === "live" ? state?.bpm : song?.bpm;
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
        if (mode === "live") live({ speed });
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
        if (mode === "live") live({ stems: STEMS.map((s) => s.name).filter((n) => !muted.has(n)) });
    }

    // MARK: The song that plays on the Mac

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
                await follow(await api("/api/live", body), $("status"));
                $("status").textContent = "";
                touched = Date.now();
                refreshState();
            } catch (error) {
                if (error.message === "Stopped") return;
                $("status").textContent = error.message;
                $("status").classList.add("error");
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

    let macSeeking = false;
    function drawTransport() {
        if (mode !== "live" || !state) return;
        $("mac-play-icon").style.setProperty("--symbol", symbol(state.playing ? "pause.fill" : "play.fill"));
        $("mac-play").setAttribute("aria-label", state.playing ? "Pause" : "Play");
        const position = macPosition();
        const duration = state.duration || 0;
        const known = position != null && duration > 0;
        $("transport").classList.toggle("unknown", !known);
        for (const id of ["mac-seek", "mac-back", "mac-forward"]) $(id).disabled = !known || !state.seekable;
        if (!known) return;
        if (!macSeeking) $("mac-seek").value = String(Math.round((position / duration) * 1000));
        const shownAt = macSeeking ? (Number($("mac-seek").value) / 1000) * duration : position;
        $("mac-elapsed").textContent = clock(shownAt);
        $("mac-left").textContent = `\u2212${clock(duration - shownAt)}`;
    }

    async function transport(body) {
        transportAt = performance.now();
        try {
            await api("/api/transport", body);
        } finally {
            setTimeout(refreshState, 300);
        }
    }

    // MARK: Notes

    function drawNotesPicker() {
        const options = [{ name: "auto", label: "Auto" }, ...STEMS.filter((s) => s.name !== "drums")];
        const picked = options.find((o) => o.name === notesStem);
        if (!$("transcribe").classList.contains("failed")) $("transcribe").textContent = notesStem === "auto" ? "Transcribe" : `Transcribe ${picked.label.toLowerCase()}`;
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

    function part() {
        const seconds = (text) => {
            const parts = text.trim().split(":");
            if (!text.trim() || parts.length > 3 || parts.some((p) => !/^\d+(\.\d+)?$/.test(p))) return undefined;
            return parts.reduce((total, p) => total * 60 + Number(p), 0);
        };
        return { from: seconds($("from").value), to: seconds($("to").value) };
    }

    function changes() {
        return {
            song: song.id,
            key: shift === 0 ? undefined : signed(shift),
            speed: speed === 1 ? undefined : speed,
            stems: muted.size ? STEMS.map((s) => s.name).filter((n) => !muted.has(n)) : undefined,
            ...part(),
        };
    }

    async function transcribe() {
        const button = $("transcribe");
        if (button.classList.contains("failed")) clearFailures();
        button.disabled = true;
        try {
            const job = await follow(await api("/api/write", { song: song.id, notes: notesStem, format: "json", ...part() }), $("notes-status"));
            const data = await (await fetch(job.file)).json();
            closeSheet();
            $("sheet").hidden = false;
            const { from, to } = part();
            sheet = MuskeySheet.mount($("sheet"), data, {
                shift,
                relative,
                transcribed: from !== undefined || to !== undefined ? [from ?? 0, to ?? data.duration] : undefined,
                onSeek: (time) => {
                    if (heard) $("audio").currentTime = Math.max(0, (time - heard.from) / heard.speed);
                },
                // A key picked on the sheet is the key of the next render.
                onChange: (next) => {
                    if (next.shift !== shift || next.relative !== relative) setKey(next.shift, next.relative);
                },
            });
            syncSheet();
            $("sheet").scrollIntoView({ block: "start", behavior: "smooth" });
        } catch (error) {
            if (error.message !== "Stopped") fail(button, $("notes-status"), error);
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

    // MARK: Playing

    async function playOnMac() {
        const button = $("play-mac");
        clearFailures();
        button.disabled = true;
        try {
            const job = await follow(await api("/api/play", changes()), $("status"));
            $("status").textContent = job.message || "";
        } catch (error) {
            if (error.message !== "Stopped") fail(button, $("status"), error);
        } finally {
            button.disabled = false;
        }
    }

    async function listenHere() {
        const button = $("listen");
        clearFailures();
        button.disabled = true;
        const wanted = changes();
        const at = heard ? songTime() : null;
        try {
            let source;
            if (!wanted.key && !wanted.speed && !wanted.stems && wanted.from === undefined && wanted.to === undefined) {
                source = `/api/song/${song.id}`;
            } else {
                source = (await follow(await api("/api/write", { ...wanted, format: "m4a" }), $("status"))).file;
            }
            const audio = $("audio");
            heard = { speed: wanted.speed || 1, from: wanted.from || 0 };
            audio.src = source;
            $("player").hidden = false;
            if (at !== null) {
                audio.addEventListener("loadedmetadata", () => { audio.currentTime = Math.max(0, (at - heard.from) / heard.speed); }, { once: true });
            }
            audio.play().catch(() => {});
        } catch (error) {
            if (error.message !== "Stopped") fail(button, $("status"), error);
        } finally {
            button.disabled = false;
        }
    }

    const songTime = () => heard.from + $("audio").currentTime * heard.speed;

    function stopAudio() {
        const audio = $("audio");
        audio.pause();
        audio.removeAttribute("src");
        audio.load();
    }

    function drawPlayer() {
        const audio = $("audio");
        $("play-icon").style.setProperty("--symbol", symbol(audio.paused ? "play.fill" : "pause.fill"));
        $("play-pause").setAttribute("aria-label", audio.paused ? "Play" : "Pause");
        const duration = Number.isFinite(audio.duration) ? audio.duration : 0;
        if (!seeking) $("seek").value = String(duration ? Math.round((audio.currentTime / duration) * 1000) : 0);
        $("clock").textContent = `${clock(audio.currentTime)} / ${clock(duration)}`;
        syncSheet();
    }

    function syncSheet() {
        if (!sheet || !heard) return;
        sheet.setTime(songTime());
        sheet.setPlaying(!$("audio").paused, heard.speed);
    }

    let seeking = false;

    // MARK: Spotify

    async function playSpotify(event) {
        event.preventDefault();
        const button = $("spotify-play");
        const link = $("spotify-link").value.trim();
        if (!link) return $("spotify-link").focus();
        clearFailures();
        button.disabled = true;
        try {
            await follow(await api("/api/spotify", { link }), $("spotify-status"));
            $("spotify-link").value = "";
            await refreshState();
            openLive();
        } catch (error) {
            if (error.message !== "Stopped") fail(button, $("spotify-status"), error);
        } finally {
            button.disabled = !$("spotify-link").value.trim();
        }
    }

    // MARK: Wiring

    $("now").onclick = openLive;
    $("close").onclick = () => history.back();
    addEventListener("popstate", () => { if (mode) closeSong(); });
    $("key-down").onclick = () => setKey(shift - 1, relative);
    $("key-up").onclick = () => setKey(shift + 1, relative);
    $("speed-down").onclick = () => setSpeed(speed - 0.05);
    $("speed-up").onclick = () => setSpeed(speed + 0.05);
    $("speed-value").onclick = () => setSpeed(1);
    $("play-all").onclick = () => setStems(new Set());
    $("from").oninput = $("to").oninput = clearFailures;
    $("spotify-link").oninput = () => {
        clearFailures();
        $("spotify-play").disabled = !$("spotify-link").value.trim();
    };
    $("spotify-play").disabled = true;
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
    $("mac-back").onclick = () => transport({ action: "back" });
    $("mac-forward").onclick = () => transport({ action: "forward" });
    $("mac-seek").oninput = () => {
        macSeeking = true;
        drawTransport();
    };
    $("mac-seek").onchange = () => {
        const seconds = (Number($("mac-seek").value) / 1000) * (state.duration || 0);
        state.position = seconds;
        stateAt = performance.now();
        macSeeking = false;
        transport({ action: "seek", seconds });
    };
    setInterval(() => { if (mode === "live" && document.visibilityState === "visible") drawTransport(); }, 250);
    // The bar's title shows once the song's name scrolls under it, as a large title does.
    new IntersectionObserver(([entry]) => $("top").classList.toggle("scrolled", !entry.isIntersecting), { rootMargin: "-60px 0px 0px 0px" })
        .observe($("head"));
    $("transcribe").onclick = transcribe;
    $("play-mac").onclick = playOnMac;
    $("listen").onclick = listenHere;
    $("spotify-form").onsubmit = playSpotify;
    $("play-pause").onclick = () => {
        const audio = $("audio");
        audio.paused ? audio.play().catch(() => {}) : audio.pause();
    };
    $("seek").oninput = () => {
        seeking = true;
        const audio = $("audio");
        if (Number.isFinite(audio.duration)) audio.currentTime = (Number($("seek").value) / 1000) * audio.duration;
    };
    $("seek").onchange = () => { seeking = false; };
    for (const name of ["play", "pause", "timeupdate", "seeked", "loadedmetadata", "ratechange"]) $("audio").addEventListener(name, drawPlayer);
    for (const toggle of document.querySelectorAll(".mac-sound")) {
        toggle.onchange = async () => {
            for (const other of document.querySelectorAll(".mac-sound")) other.checked = toggle.checked;
            try {
                await api("/api/mute", { muted: !toggle.checked });
            } finally {
                refreshState();
            }
        };
    }

    // The song view's symbols are fetched while the home view shows, so that its icons are there when a song opens.
    for (const name of [...STEMS.map((s) => s.symbol), "chevron.left", "chevron.right", "play.fill", "pause.fill", "macbook", "headphones", "speaker.wave.2.fill", "minus", "plus", "gobackward.5", "goforward.5", "arrow.clockwise"]) {
        new Image().src = `/api/symbol/${name}`;
    }

    loadSongs();
    refreshState();
    setInterval(() => { if (document.visibilityState === "visible") refreshState(); }, 1500);
    document.addEventListener("visibilitychange", () => { if (document.visibilityState === "visible") refreshState(); });
})();
