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

    /** A line in Muskey's log on the Mac, for what goes wrong on the phone, where nobody can read the console. A failure
     * is logged as an error, which macOS keeps on disk; `level` is "info" or "debug" for anything else. */
    function report(message, level = "error") {
        fetch("/api/log", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ message: String(message), level }) }).catch(() => {});
    }
    addEventListener("error", (event) => report(`script error: ${event.message} at ${event.filename}:${event.lineno}`));
    // The page doesn't zoom (touch-action in the CSS), but Safari on iOS zooms on its own gesture events regardless.
    for (const type of ["gesturestart", "gesturechange"]) document.addEventListener(type, (event) => event.preventDefault(), { passive: false });
    addEventListener("unhandledrejection", (event) => report(`unhandled: ${event.reason?.message || event.reason}`));

    // MARK: Installed app

    // Installed from the Home Screen. `display-mode: standalone` is false inside an installed iOS app, so
    // navigator.standalone counts too, which only iOS sets.
    const standalone = navigator.standalone === true || matchMedia("(display-mode: standalone)").matches;
    if (standalone) document.documentElement.dataset.standalone = "";

    // WebKit doesn't set env(safe-area-inset-*) until the viewport geometry changes, so an installed app's cold launch
    // reads 0 and the transport slides under the home indicator. A probe measures them instead, and the CSS keeps
    // env() for every other browser.
    const measureInset = (side) => {
        const probe = document.createElement("div");
        probe.style.cssText = `position:fixed;top:0;left:0;visibility:hidden;pointer-events:none;width:0;height:env(safe-area-inset-${side}, 0px)`;
        document.body.append(probe);
        const value = probe.offsetHeight;
        probe.remove();
        return value;
    };
    const syncInsets = () => {
        const insets = { top: measureInset("top"), bottom: measureInset("bottom") };
        for (const [side, value] of Object.entries(insets)) document.documentElement.style.setProperty(`--safe-${side}`, `${value}px`);
        return insets;
    };
    // Flipping viewport-fit for a frame counts as the geometry change that WebKit waits for. Zero can also be the
    // truth (a phone without a notch), so it only nudges and measures again.
    if (Object.values(syncInsets()).every((value) => value === 0) && standalone) {
        const meta = document.querySelector('meta[name="viewport"]');
        const original = meta?.getAttribute("content") || "";
        if (original.includes("viewport-fit=cover")) {
            meta.setAttribute("content", original.replace("viewport-fit=cover", "viewport-fit=auto"));
            requestAnimationFrame(() => meta.setAttribute("content", original));
            setTimeout(syncInsets, 120);
            setTimeout(syncInsets, 600);
        }
    }
    addEventListener("orientationchange", () => setTimeout(syncInsets, 300));
    screen.orientation?.addEventListener("change", () => setTimeout(syncInsets, 300));
    // A cold launch can give the first reading before the app has its final size, as Cling's page found.
    addEventListener("resize", syncInsets);
    addEventListener("pageshow", syncInsets);

    // The offline page of the installed app needs HTTPS, which the Mac serves only on its Tailscale name.
    if (location.protocol === "https:" && "serviceWorker" in navigator) navigator.serviceWorker.register("/sw.js").catch(() => {});

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
        preferPhone();
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
        drawNowPlaying();
        if (open) drawSong();
    }

    // MARK: Now Playing on the phone

    /** What the phone shows on its lock screen and in Control Center while it plays the Mac's sound: the song, its
     * cover and its position. The buttons there play, pause and move the song on the Mac. */
    let sessionSong = null;
    function drawNowPlaying() {
        const session = navigator.mediaSession;
        if (!session || typeof MediaMetadata !== "function" || !state) return;
        const song = `${state.title}\n${state.artist}\n${Boolean(state.cover)}`;
        if (song !== sessionSong) {
            sessionSong = song;
            // The cover of the song that plays now, whatever the query says: the query only makes a new song a new URL.
            const artwork = state.cover
                ? [{ src: new URL(`/api/nowcover?song=${encodeURIComponent(state.title || "")}`, location.href).href, sizes: "512x512", type: "image/jpeg" }]
                : [{ src: new URL("/icon-512.png", location.href).href, sizes: "512x512", type: "image/png" }];
            try {
                session.metadata = state.title ? new MediaMetadata({ title: state.title, artist: state.artist || "", artwork }) : null;
            } catch {
                // A browser that refuses the artwork shows the page's title instead.
            }
        }
        session.playbackState = !state.title ? "none" : state.playing ? "playing" : "paused";
        const duration = songDuration();
        const position = macPosition();
        if (!session.setPositionState || !(duration > 0) || position == null) return;
        try {
            const heard = position - (output === "phone" ? player.lag() : 0);
            session.setPositionState({ duration, position: Math.min(duration, Math.max(0, heard)), playbackRate: state.speed || 1 });
        } catch {
            // A position past the end, or a rate of 0, is refused, and the last one stays.
        }
    }

    /** A button on the lock screen or in Control Center, sent to the Mac like the same button on the page. */
    function sessionAction(action, seconds) {
        if (!state) return;
        if (action === "play" || action === "pause") {
            state.position = macPosition();
            state.playing = action === "play";
            stateAt = performance.now();
            drawTransport();
        }
        drawNowPlaying();
        transport(seconds == null ? { action } : { action, seconds });
    }
    if (navigator.mediaSession) {
        const handlers = {
            play: () => sessionAction("play"),
            pause: () => sessionAction("pause"),
            seekbackward: () => sessionAction("back"),
            seekforward: () => sessionAction("forward"),
            seekto: (details) => details.seekTime != null && sessionAction("seek", Math.max(0, details.seekTime)),
        };
        for (const [name, handler] of Object.entries(handlers)) {
            try {
                navigator.mediaSession.setActionHandler(name, handler);
            } catch {
                // The browser doesn't offer this button.
            }
        }
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
        drawInstall();
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
        volumes = { ...(state.stemVolumes || {}) };
        touched = 0;
        songCover = undefined;
        shared = null;
        pickedEnd = null;
        setDock(0, false);
        drawSong();
        drawAll();
        show("song");
        if (history.state?.song !== true) history.pushState({ song: true }, "");
        measureDock();
    }

    /** Back to the view that opened the song: the home view or the files of the Mac. */
    function closeSong() {
        open = false;
        closeSheet();
        setDock(0, false);
        if (history.state?.files === true) return show("files");
        show("home");
        loadSongs();
    }

    // The marks of the sites whose links Muskey opens, drawn here rather than fetched.
    const SOURCE_MARKS = {
        spotify: `<svg viewBox="0 0 26 26" aria-hidden="true"><rect width="26" height="26" fill="#1ed760"/><g fill="none" stroke="#000" stroke-linecap="round"><path d="M6.6 9.6c4.4-1.4 9.4-1 13 1.1" stroke-width="2.3"/><path d="M7.4 13.3c3.7-1.1 7.8-.7 10.8 1" stroke-width="1.9"/><path d="M8.2 16.7c3-.8 6.2-.5 8.5.9" stroke-width="1.6"/></g></svg>`,
        youtube: `<svg viewBox="0 0 26 26" aria-hidden="true"><rect width="26" height="26" fill="#ff0033"/><path d="M10.4 8.6v8.8l7.2-4.4z" fill="#fff"/></svg>`,
    };
    // The ring's colour for each source; another app's comes from its icon.
    const SOURCE_RINGS = { spotify: "#1ed760", youtube: "#ff0033", file: "rgb(228 88 96)", link: "rgb(228 88 96)" };

    /** The badge on the cover and the colour of its ring, drawn again only when the source changes. */
    function drawSource() {
        const wrap = $("cover-wrap");
        const badge = $("source-badge");
        wrap.classList.toggle("listening", Boolean(state.listening));
        const kind = state.source || "";
        const key = kind === "app" ? `app:${state.sourceApp}` : kind;
        if (badge.dataset.key === key) return;
        badge.dataset.key = key;
        badge.replaceChildren();
        wrap.style.setProperty("--ring", SOURCE_RINGS[kind] || "rgb(228 88 96)");
        if (SOURCE_MARKS[kind]) {
            badge.innerHTML = SOURCE_MARKS[kind];
        } else if (kind === "app" && state.sourceApp) {
            const image = document.createElement("img");
            image.alt = "";
            image.onload = () => {
                const color = iconColor(image);
                if (color && badge.dataset.key === key) wrap.style.setProperty("--ring", color);
            };
            image.onerror = () => {
                badge.hidden = true;
            };
            image.src = `/api/appicon/${encodeURIComponent(state.sourceApp)}`;
            badge.append(image);
        }
        badge.hidden = !badge.firstChild;
    }

    /** The most colourful tone of an app's icon, for its ring: each pixel counts by how saturated it is. */
    function iconColor(image) {
        try {
            const canvas = document.createElement("canvas");
            canvas.width = canvas.height = 24;
            const context = canvas.getContext("2d", { willReadFrequently: true });
            context.drawImage(image, 0, 0, 24, 24);
            const pixels = context.getImageData(0, 0, 24, 24).data;
            let r = 0, g = 0, b = 0, total = 0;
            for (let i = 0; i < pixels.length; i += 4) {
                if (pixels[i + 3] < 200) continue;
                const max = Math.max(pixels[i], pixels[i + 1], pixels[i + 2]), min = Math.min(pixels[i], pixels[i + 1], pixels[i + 2]);
                const weight = max ? ((max - min) / max) ** 2 : 0;
                r += pixels[i] * weight;
                g += pixels[i + 1] * weight;
                b += pixels[i + 2] * weight;
                total += weight;
            }
            return total > 1 ? `rgb(${Math.round(r / total)} ${Math.round(g / total)} ${Math.round(b / total)})` : null;
        } catch {
            return null;
        }
    }

    function drawSong() {
        const song = `${state.title}\n${state.artist}`;
        if (song !== zoomSong) {
            zoomSong = song;
            zoom = 1;
            zoomAnimation = null;
            autoZoomed = false;
        }
        // The Song title setting picks one of these places, and the others stay hidden.
        const title = state.title || "Nothing playing", artist = state.artist || "";
        for (const id of ["song-title", "bar-title", "disc-title", "groove-title"]) $(id).textContent = title;
        for (const id of ["song-artist", "bar-artist", "disc-artist", "groove-artist"]) $(id).textContent = artist;
        drawSource();
        const source = state.cover ? `/api/nowcover?song=${encodeURIComponent(state.title || "")}` : null;
        if (source !== songCover) {
            songCover = source;
            drawCover(source);
        }
        // The notes need the song's file, which links and files have, and other players' songs don't.
        $("notes-section").hidden = !state.song;
        drawSaveAndNotes();
        drawTransport();
        drawOutput();
        // The Mac's state wins, unless a change was just made here and the Mac hasn't applied it yet.
        if (Date.now() - touched > 3000) {
            const stems = new Set(state.mutedStems || []);
            const levels = state.stemVolumes || {};
            const sameLevels = STEMS.every((s) => Math.abs((levels[s.name] ?? 1) - volumeOf(s.name)) < 0.001);
            const changed = shift !== state.shift || relative !== state.relative || Math.abs(speed - state.speed) > 0.001
                || stems.size !== muted.size || [...stems].some((name) => !muted.has(name)) || drawnKey !== (state.key ?? null) || !sameLevels;
            shift = state.shift;
            relative = state.relative;
            speed = state.speed;
            muted = stems;
            volumes = { ...levels };
            if (changed) drawAll();
        }
    }

    /** The cover as the record's label, as the whole disc for the On cover title, and as the colours of the glow. */
    function drawCover(source) {
        $("song-cover").replaceChildren(cover(source, true));
        const record = $("cover-wrap");
        record.style.setProperty("--cover", source ? `url("${source}")` : "none");
        record.classList.toggle("no-cover", !source);
        const glow = $("glow");
        glow.classList.remove("on");
        if (!source) return;
        const image = new Image();
        image.onload = () => {
            const colors = coverColors(image);
            if (songCover !== source || !colors) return;
            glow.style.setProperty("--c1", colors[0]);
            glow.style.setProperty("--c2", colors[1]);
            glow.classList.add("on");
        };
        image.src = source;
    }

    /** The cover's most colourful tone and its average tone, for the glow behind the record. */
    function coverColors(image) {
        try {
            const canvas = document.createElement("canvas");
            canvas.width = canvas.height = 16;
            const context = canvas.getContext("2d", { willReadFrequently: true });
            context.drawImage(image, 0, 0, 16, 16);
            const pixels = context.getImageData(0, 0, 16, 16).data;
            const vivid = [0, 0, 0, 0], plain = [0, 0, 0, 0];
            for (let i = 0; i < pixels.length; i += 4) {
                const [r, g, b] = [pixels[i], pixels[i + 1], pixels[i + 2]];
                const max = Math.max(r, g, b), min = Math.min(r, g, b);
                const weight = max ? ((max - min) / max) ** 2 * (max / 255) : 0;
                vivid[0] += r * weight;
                vivid[1] += g * weight;
                vivid[2] += b * weight;
                vivid[3] += weight;
                plain[0] += r;
                plain[1] += g;
                plain[2] += b;
                plain[3] += 1;
            }
            const css = ([r, g, b, total]) => `rgb(${Math.round(r / total)} ${Math.round(g / total)} ${Math.round(b / total)})`;
            const average = css(plain);
            return [vivid[3] > 2 ? css(vivid) : average, average];
        } catch {
            return null;
        }
    }

    function drawAll() {
        drawKeys();
        drawSpeed();
        drawStems();
        drawSaveAndNotes();
    }

    // MARK: Key

    /** The song's key that the ring shows, which a new song or a listen changes. */
    let drawnKey = null;
    const SVG = "http://www.w3.org/2000/svg";

    function svgElement(name, attributes = {}) {
        const element = document.createElementNS(SVG, name);
        for (const [attribute, value] of Object.entries(attributes)) element.setAttribute(attribute, value);
        return element;
    }

    /** A key's name for the ring, with its sharp or flat faded and a small m for minor, as the HUD writes it. */
    function keyText(text, key, x, y) {
        text.setAttribute("x", x);
        text.setAttribute("y", y);
        for (const character of tonic(key)) {
            const part = svgElement("tspan", "♯♭".includes(character) ? { class: "acc" } : {});
            part.textContent = character;
            text.append(part);
        }
        if (key.minor) {
            const m = svgElement("tspan", { class: "m", dx: "0.5" });
            m.textContent = "m";
            text.append(m);
        }
    }

    /**
     * The circle of fifths, as the HUD's ring draws it: the song's mode on the outer ring and the relatives on the
     * inner one, the song's key at the top with a dot, and a fifth up for each step clockwise. The selected key is
     * filled, keys a fourth or a fifth from it are red, keys a whole step from it are sage, and the relative of the
     * selected key is outlined. A song without a key shows the shifts in semitones on the outer ring only.
     */
    function drawKeys() {
        drawnKey = state?.key ?? null;
        const key = original();
        const ring = $("fifths");
        ring.replaceChildren();
        const c = 153, outer = [132, 19], inner = [96, 13];
        const point = (r, angle) => [c + Math.sin(angle) * r, c - Math.cos(angle) * r];
        const at = (r, angle) => point(r, angle).map((n) => n.toFixed(2)).join(" ");
        const slice = (mid, from, to) => {
            const half = Math.PI / 12;
            return `M${at(to, mid - half)}A${to} ${to} 0 0 1 ${at(to, mid + half)}L${at(from, mid + half)}A${from} ${from} 0 0 0 ${at(from, mid - half)}Z`;
        };
        const selected = fold(shift);
        for (let step = 0; step < 12; step++) {
            const angle = (step * Math.PI) / 6;
            const offset = fold(step * 7);
            for (const second of key ? [false, true] : [false]) {
                const [r, band] = second ? inner : outer;
                const inColumn = offset === selected;
                const isSelected = key ? inColumn && relative === second : inColumn;
                const classes = ["rk"];
                if (second) classes.push("in");
                if (offset === 0 && !second) classes.push("orig");
                if (isSelected) classes.push("sel");
                else if (inColumn) classes.push("partner");
                else {
                    const steps = harmony(offset - shift);
                    if (steps === 1) classes.push("h1");
                    else if (steps === 2) classes.push("h2");
                }
                const slot = svgElement("g", { class: classes.join(" "), role: "button" });
                slot.append(svgElement("path", { d: slice(angle, r - band, r + band) }));
                const [x, y] = point(r, angle);
                const text = svgElement("text");
                if (key) {
                    const transposed = transpose(key, offset);
                    const face = second ? relativeOf(transposed) : transposed;
                    keyText(text, face, x.toFixed(2), y.toFixed(2));
                    slot.setAttribute("aria-label", `${tonic(face)} ${face.minor ? "minor" : "major"}`);
                } else {
                    text.setAttribute("x", x.toFixed(2));
                    text.setAttribute("y", y.toFixed(2));
                    text.textContent = shown(offset);
                    slot.setAttribute("aria-label", `${shown(offset)} semitones`);
                }
                slot.append(text);
                if (offset === 0 && !second) slot.append(svgElement("circle", { class: "odot", cx: x.toFixed(2), cy: (y + 11).toFixed(2), r: 2 }));
                slot.setAttribute("aria-pressed", String(isSelected));
                // The column of the selected key keeps the shift, which can be an octave away from its offset.
                slot.addEventListener("click", () => setKey(inColumn ? shift : offset, second));
                ring.append(slot);
            }
        }
        // The key of the song, and the key that plays once it changed.
        const change = $("change-pill");
        change.hidden = !key;
        $("key-reset").hidden = shift === 0 && !relative;
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

    function setKey(newShift, newRelative) {
        const previousRelative = relative;
        shift = Math.max(-12, Math.min(12, newShift));
        relative = Boolean(newRelative);
        clearFailures();
        drawKeys();
        if (sheet && (sheet.state.shift !== shift || sheet.state.relative !== relative)) sheet.set({ shift, relative });
        const key = original();
        // A number keeps the mode on the Mac, and a key's name moves to its mode.
        live({ key: key && relative !== previousRelative ? ascii(heardOf(key, shift, relative)) : signed(shift) });
    }

    // MARK: Tempo

    /** Muskey Player plays a song faster too, and another player's song can only be slowed down. */
    const fastest = () => (state?.app === "Muskey Player" ? 1.5 : 1);
    /** A speed as a multiple of the song's tempo: 0.9x, 1x, 1.25x. */
    const times = (value) => `${Number(value.toFixed(2))}x`;

    /** The tempo in BPM inside the stepper, or the speed when the song's BPM isn't known, and the speed above it. */
    function drawSpeed() {
        const bpm = state?.bpm;
        const tone = speed < 0.999 ? "blue" : speed > 1.001 ? "honey" : "";
        $("speed-reset").hidden = Math.abs(speed - 1) < 0.001;
        const speedPill = $("speed-pill");
        speedPill.hidden = !bpm;
        speedPill.textContent = times(speed);
        speedPill.className = `pill ${tone}`;
        $("bpm-value").textContent = bpm ? String(Math.round(bpm * speed)) : times(speed);
        $("bpm-unit").hidden = !bpm;
        const value = $("speed-value");
        value.dataset.tone = tone;
        value.setAttribute("aria-valuetext", bpm ? `${Math.round(bpm * speed)} BPM, ${times(speed)}` : times(speed));
        for (const button of $("wide-step").querySelectorAll("button[data-step]")) {
            button.disabled = Number(button.dataset.step) < 0 ? speed <= 0.5 + 0.001 : speed >= fastest() - 0.001;
        }
    }

    function setSpeed(value) {
        const next = Math.round(Math.max(0.5, Math.min(fastest(), value)) * 100) / 100;
        if (Math.abs(next - speed) < 0.001) return;
        speed = next;
        clearFailures();
        drawSpeed();
        live({ speed });
    }

    /** A slide left or right over the tempo changes it by 1% for every 6 points. */
    function tempoSlider() {
        const value = $("speed-value");
        let slide = null;
        value.addEventListener("pointerdown", (event) => {
            if (event.button > 0) return;
            value.setPointerCapture(event.pointerId);
            slide = { x: event.clientX, speed };
            value.classList.add("sliding");
        });
        value.addEventListener("pointermove", (event) => {
            if (!slide) return;
            setSpeed(slide.speed + (event.clientX - slide.x) / 600);
        });
        const end = () => {
            slide = null;
            value.classList.remove("sliding");
        };
        value.addEventListener("pointerup", end);
        value.addEventListener("pointercancel", end);
        value.addEventListener("keydown", (event) => {
            const step = { ArrowLeft: -0.01, ArrowDown: -0.01, ArrowRight: 0.01, ArrowUp: 0.01 }[event.key];
            if (!step) return;
            event.preventDefault();
            setSpeed(speed + step);
        });
    }

    // MARK: Instruments

    /** Volumes of the instruments that don't play at 100%, from 0 to 150%, as a scroll over a circle sets them in the HUD. */
    let volumes = {};
    const volumeOf = (name) => volumes[name] ?? 1;
    // The ring around a circle sweeps 270° from 0 to 150%, with a tick at 100%, as in the HUD.
    const SWEEP = 0.75, RADIUS = 21, AROUND = 2 * Math.PI * RADIUS;

    /** The circles are made once and updated in place, so a hold or a slide keeps its button under the finger. */
    function drawStems() {
        const row = $("stems");
        if (!row.children.length) row.append(...STEMS.map(stemButton));
        for (const button of row.children) {
            const stem = STEMS.find((s) => s.name === button.dataset.stem);
            const on = !muted.has(stem.name);
            const volume = volumeOf(stem.name);
            button.classList.toggle("muted", !on);
            button.setAttribute("aria-pressed", String(on));
            button.setAttribute("aria-label", `${stem.label} ${Math.round(volume * 100)}%`);
            button.querySelector(".arc").setAttribute("stroke-dasharray", `${(Math.min(1.5, volume) / 1.5) * SWEEP * AROUND} ${AROUND}`);
            const percent = button.classList.contains("adjusting") || Math.abs(volume - 1) > 0.001;
            button.querySelector(".name").textContent = percent ? `${Math.round(volume * 100)}%` : stem.label;
        }
        $("play-all").hidden = muted.size === 0;
        drawTranscribeLabel();
    }

    function stemButton(stem) {
        const button = document.createElement("button");
        button.className = "stem";
        button.dataset.stem = stem.name;
        button.style.setProperty("--hue", stem.hue);
        const box = document.createElement("span");
        box.className = "vbox";
        const ring = svgElement("svg", { class: "vring", viewBox: "0 0 48 48", "aria-hidden": "true" });
        ring.append(svgElement("circle", { class: "track", cx: 24, cy: 24, r: RADIUS, transform: "rotate(135 24 24)", "stroke-dasharray": `${SWEEP * AROUND} ${AROUND}` }));
        ring.append(svgElement("circle", { class: "arc", cx: 24, cy: 24, r: RADIUS, transform: "rotate(135 24 24)" }));
        const tick = ((135 + 270 / 1.5) * Math.PI) / 180;
        ring.append(svgElement("line", { class: "tick", x1: 24 + Math.cos(tick) * 18.5, y1: 24 + Math.sin(tick) * 18.5, x2: 24 + Math.cos(tick) * 23.5, y2: 24 + Math.sin(tick) * 23.5 }));
        const disc = document.createElement("span");
        disc.className = "disc";
        disc.append(icon(stem.symbol));
        box.append(ring, disc);
        const name = document.createElement("span");
        name.className = "name";
        name.textContent = stem.label;
        button.append(box, name);
        // A tap mutes or plays the stem, a slide up or down changes its volume, and holding it plays only that stem,
        // as Option-click does in the HUD.
        let press = null;
        let skipClick = false;
        button.addEventListener("pointerdown", (event) => {
            if (event.button > 0) return;
            button.setPointerCapture(event.pointerId);
            press = { y: event.clientY, volume: volumeOf(stem.name), sliding: false, solo: false };
            press.timer = setTimeout(() => {
                if (!press || press.sliding) return;
                press.solo = true;
                setStems(new Set(STEMS.map((s) => s.name).filter((n) => n !== stem.name)));
                navigator.vibrate?.(10);
            }, 450);
        });
        button.addEventListener("pointermove", (event) => {
            if (!press || press.solo) return;
            if (!press.sliding) {
                if (Math.abs(press.y - event.clientY) < 8) return;
                press.sliding = true;
                press.y = event.clientY;
                clearTimeout(press.timer);
                button.classList.add("adjusting");
            }
            // 150 points of travel for 100%, and a catch at 100% on the way through.
            let volume = Math.round(Math.max(0, Math.min(1.5, press.volume + (press.y - event.clientY) / 150)) * 100) / 100;
            if (Math.abs(volume - 1) < 0.03) volume = 1;
            if (volume === volumeOf(stem.name)) return;
            if (volume === 1) delete volumes[stem.name];
            else volumes[stem.name] = volume;
            drawStems();
            sendVolume(stem.name);
        });
        const release = () => {
            if (!press) return;
            clearTimeout(press.timer);
            skipClick = press.sliding || press.solo;
            press = null;
            button.classList.remove("adjusting");
            drawStems();
        };
        button.addEventListener("pointerup", release);
        button.addEventListener("pointercancel", release);
        button.oncontextmenu = (event) => event.preventDefault();
        button.onclick = () => {
            if (skipClick) {
                skipClick = false;
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

    const volumeTimers = {};
    /** Sends an instrument's volume at most every 120 ms while a finger slides over it. */
    function sendVolume(name) {
        touched = Date.now();
        drawSaveAndNotes();
        if (volumeTimers[name]) return;
        volumeTimers[name] = setTimeout(async () => {
            volumeTimers[name] = null;
            try {
                await api("/api/volume", { stem: name, volume: volumeOf(name) });
                touched = Date.now();
            } catch (error) {
                $("song-error").textContent = error.message;
                $("song-error").hidden = false;
            }
        }, 120);
    }

    // MARK: Changes to the song that plays on the Mac

    let liveTimer = null;
    let livePending = {};
    /** Sends changes to the Mac at most every 250 ms, so a run of taps or a slide sends a few requests. */
    function live(change) {
        touched = Date.now();
        drawSaveAndNotes();
        livePending = { ...livePending, ...change };
        if (liveTimer) return;
        liveTimer = setTimeout(async () => {
            liveTimer = null;
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
    /** Where a finger that slides over the waveform shows the song, until it lifts and the song moves there. */
    let scrubTime = null;
    function macPosition() {
        if (scrubTime != null) return scrubTime;
        if (state?.position == null) return null;
        const since = state.playing ? ((performance.now() - stateAt) / 1000) * (state.speed || 1) : 0;
        return Math.min(state.position + since, state.duration ?? Infinity);
    }

    function drawTransport() {
        if (!open || !state) return;
        $("mac-play-icon").style.setProperty("--symbol", symbol(state.playing ? "pause.fill" : "play.fill"));
        $("mac-play").setAttribute("aria-label", state.playing ? "Pause" : "Play");
        $("cover-wrap").classList.toggle("playing", Boolean(state.playing));
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

    function bytes(base64) {
        const text = atob(base64);
        const levels = new Uint8Array(text.length);
        for (let i = 0; i < text.length; i++) levels[i] = text.charCodeAt(i);
        return levels;
    }

    /** The waveform grows to fit the instruments' waveforms, and names each one. */
    function drawLaneNames() {
        const lanes = wave?.lanes ?? [];
        const element = $("wave");
        element.classList.toggle("lanes-2", lanes.length === 2);
        element.classList.toggle("lanes-3", lanes.length === 3);
        const names = $("wave-lanes");
        const key = lanes.map((lane) => lane.name).join(",");
        if (names.dataset.lanes === key) return;
        names.dataset.lanes = key;
        names.replaceChildren(...lanes.map((lane, index) => {
            const stem = STEMS.find((s) => s.name === lane.name);
            const pill = document.createElement("span");
            pill.className = "lane-name";
            pill.textContent = stem.label;
            pill.style.setProperty("--hue", stem.hue);
            // Each pill sits at the top of its waveform: the waveforms share the height, with 4 points between them.
            pill.style.top = `calc((100% - ${(lanes.length - 1) * 4}px) / ${lanes.length} * ${index} + ${index * 4 + 2}px)`;
            return pill;
        }));
    }

    async function loadWave() {
        if (waveLoading || !state || (state.wave ?? null) === waveVersion) return;
        const version = state.wave ?? null;
        if (version === null) {
            wave = null;
            waveVersion = null;
            drawLaneNames();
            return;
        }
        waveLoading = true;
        try {
            const answer = await api("/api/waveform");
            const levels = bytes(answer.levels);
            // One waveform per instrument while some are muted, in the order of the instruments' circles.
            const order = STEMS.map((stem) => stem.name);
            const lanes = (answer.lanes ?? [])
                .filter((lane) => order.includes(lane.name))
                .sort((a, b) => order.indexOf(a.name) - order.indexOf(b.name))
                .map((lane) => ({ ...lane, levels: bytes(lane.levels) }));
            wave = { duration: answer.duration, rate: answer.rate, levels, lanes };
            waveVersion = version;
            drawLaneNames();
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

    // MARK: Zoom

    /** How many times the waveform is magnified, 1 for the whole song. A close-up follows the playhead and holds still
     * around a loop that fits in it, as the HUD's does. */
    let zoom = 1;
    let zoomAnimation = null;
    /** The zoom came from a loop made here, and clearing the loop shows the whole song again. */
    let autoZoomed = false;
    let zoomSong = null;
    /** Where the close-up stays while a finger works on the waveform, so the bars don't slide under it, and where it
     * slides back from once the finger lifts. */
    let frozenFrom = null;
    let released = null;
    /** The shortest part of the song that a close-up shows, in seconds. */
    const SHORTEST_VIEW = 2;
    const easeOut = (t) => 1 - (1 - t) ** 3;

    function currentZoom() {
        if (!zoomAnimation) return zoom;
        const t = (performance.now() - zoomAnimation.at) / 300;
        if (t >= 1) {
            zoomAnimation = null;
            return zoom;
        }
        // On a logarithmic scale, so that each doubling takes the same time.
        return Math.exp(Math.log(zoomAnimation.from) + (Math.log(zoom) - Math.log(zoomAnimation.from)) * easeOut(t));
    }

    function setZoom(value, animated) {
        const next = Math.min(Math.max(1, songDuration() / SHORTEST_VIEW), Math.max(1, value));
        if (animated && Math.abs(next - zoom) > 0.01) zoomAnimation = { from: currentZoom(), at: performance.now() };
        zoom = next;
        drawWave(true);
    }

    /** The part of the song that the waveform shows: its start and its length, in seconds. */
    function viewRange() {
        const duration = songDuration();
        const factor = currentZoom();
        if (factor <= 1.001 || !duration) return { from: 0, span: duration };
        const span = duration / factor;
        let from = frozenFrom;
        if (from == null) {
            const loop = currentLoop();
            from = loop?.end != null && loop.end - loop.start <= span * 0.9
                ? (loop.start + loop.end) / 2 - span / 2
                : (macPosition() ?? 0) - span / 2;
            if (released) {
                const t = (performance.now() - released.at) / 350;
                if (t >= 1) released = null;
                else from = released.from + (from - released.from) * easeOut(t);
            }
        }
        return { from: Math.min(Math.max(0, from), duration - span), span };
    }

    /** A loop of 2 seconds or more made here fills most of the waveform, since a loop that long was made on purpose. */
    function zoomToLoop(loop) {
        const duration = songDuration();
        if (!duration || loop?.end == null || loop.end - loop.start < 2) return;
        const target = duration / ((loop.end - loop.start) / 0.8);
        if (target < 1.25) return;
        autoZoomed = true;
        setZoom(target, true);
    }

    function zoomOut() {
        autoZoomed = false;
        setZoom(1, true);
    }

    let drawnStrip = null;
    /** The strip of the whole song under a close-up, like the HUD's: the bars of the whole song, the part played in
     * honey, the loop, and a box around the part that the close-up shows. Its bars are drawn again only when one of
     * them changes colour or the loop moves. */
    function drawZoomMap(from, span, duration, position, loop) {
        const map = $("zoom-map");
        const zoomed = span < duration - 0.01;
        map.classList.toggle("on", zoomed);
        if (!zoomed) return;
        const box = map.getBoundingClientRect();
        if (!box.width) return;
        // The box covers only the part of the song in the close-up, and stays wide enough to see.
        const boxWidth = Math.min(box.width, Math.max(6, (span / duration) * box.width));
        const left = Math.min(Math.max(0, (from / duration) * box.width), box.width - boxWidth);
        $("zoom-window").style.left = `${left}px`;
        $("zoom-window").style.width = `${boxWidth}px`;
        const canvas = $("zoom-canvas");
        const ratio = window.devicePixelRatio || 1;
        const width = Math.round(box.width * ratio), height = Math.round(box.height * ratio);
        const step = 3 * ratio, barWidth = 1.6 * ratio;
        const count = Math.max(1, Math.floor(width / step));
        const played = Math.floor((position / duration) * count);
        const key = `${width}x${height} ${played} ${waveVersion} ${loop?.start} ${loop?.end}`;
        if (key === drawnStrip) return;
        drawnStrip = key;
        if (canvas.width !== width || canvas.height !== height) {
            canvas.width = width;
            canvas.height = height;
        }
        const context = canvas.getContext("2d");
        context.clearRect(0, 0, width, height);
        const css = getComputedStyle(document.documentElement);
        const ink = css.getPropertyValue("--ink").trim(), honey = css.getPropertyValue("--honey").trim();
        if (loop?.end != null) {
            const a = (loop.start / duration) * width, b = (loop.end / duration) * width;
            context.globalAlpha = 0.22;
            context.fillStyle = honey;
            context.fillRect(a, 0, Math.max(1, b - a), height);
        }
        const levels = wave?.levels;
        for (let k = 0; k < count; k++) {
            let level = 0;
            if (levels?.length) {
                const a = Math.floor((k / count) * levels.length), b = Math.max(a + 1, Math.floor(((k + 1) / count) * levels.length));
                for (let j = a; j < b && j < levels.length; j++) level = Math.max(level, levels[j]);
            }
            if (!level) continue;
            const bar = Math.max(ratio, ((level - 1) / 254) * height);
            context.fillStyle = k <= played ? honey : ink;
            context.globalAlpha = k <= played ? 0.8 : 0.2;
            context.fillRect(Math.round(k * step + (step - barWidth) / 2), (height - bar) / 2, barWidth, bar);
        }
        context.globalAlpha = 1;
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
     * again only when a bar changes colour, the loop or the close-up moves, or `force` asks. A bar stands for the same
     * moment of the song while a close-up slides, so the bars move with the song instead of changing in place. */
    function drawWave(force = false) {
        const canvas = $("wave-canvas");
        const box = $("wave").getBoundingClientRect();
        const duration = songDuration();
        if (!box.width || !duration) return;
        const { from, span } = viewRange();
        const xOf = (time) => ((time - from) / span) * box.width;
        const position = macPosition() ?? 0;
        const head = xOf(Math.min(position, duration));
        $("playhead").style.transform = `translateX(${head}px)`;
        $("playhead").style.visibility = head < -1 || head > box.width + 1 ? "hidden" : "";
        drawEnds(box.width, xOf);
        if (force) drawnStrip = null;
        drawZoomMap(from, span, duration, position, currentLoop());
        const ratio = window.devicePixelRatio || 1;
        const width = Math.round(box.width * ratio), height = Math.round(box.height * ratio);
        const step = 3 * ratio, barWidth = 2 * ratio;
        const count = Math.max(1, Math.floor(width / step));
        const slot = span / count;
        const played = Math.floor(position / slot);
        const loop = currentLoop();
        const key = `${width}x${height} ${played} ${from.toFixed(3)} ${span.toFixed(3)} ${waveVersion} ${loop?.start} ${loop?.end}`;
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
        const looped = loop?.end != null ? [loop.start, loop.end] : null;
        if (looped) {
            const a = Math.max(0, xOf(looped[0]) * ratio), b = Math.min(width, xOf(looped[1]) * ratio);
            context.globalAlpha = 0.16;
            context.fillStyle = honey;
            if (b > a) context.fillRect(a, 0, b - a, height);
        }
        // The whole song in one waveform, or one waveform per instrument sharing the height, 4 points apart.
        const rows = wave?.lanes?.length ? wave.lanes : [null];
        const gap = rows.length > 1 ? 4 * ratio : 0;
        const rowHeight = (height - gap * (rows.length - 1)) / rows.length;
        const first = Math.floor(from / slot), last = Math.ceil((from + span) / slot);
        rows.forEach((lane, index) => {
            const levels = lane ? lane.levels : wave?.levels;
            const top = index * (rowHeight + gap);
            for (let k = first; k < last; k++) {
                const start = k * slot;
                if (start >= duration) break;
                const bar = levels?.length ? barHeight(levels, lane, start / duration, (start + slot) / duration, rowHeight, ratio) : 0;
                const middle = start + slot / 2;
                const inLoop = looped && middle >= looped[0] && middle <= looped[1];
                const shown = bar || 1.5 * ratio;
                context.fillStyle = inLoop ? honey : k < played ? ink : muted;
                context.globalAlpha = !bar ? 0.18 : inLoop ? (k < played ? 1 : 0.6) : k < played ? 0.85 : looped ? 0.18 : 0.3;
                context.fillRect(Math.round(((start - from) / span) * width), top + (rowHeight - shown) / 2, barWidth, shown);
            }
        });
        context.globalAlpha = 1;
    }

    /** The height of the bar for the part of the song between `a` and `b` (shares of its length), or 0 for a moment
     * that wasn't heard yet or an instrument that is silent there. The whole song shows its loudest moment. An instrument
     * shows mostly its average, stretched between the quiet and the loud parts of all the instruments, as the HUD's
     * lanes do, so the bleed of the others under it draws as silence. */
    function barHeight(levels, lane, a, b, height, ratio) {
        const from = Math.floor(a * levels.length), to = Math.min(levels.length, Math.max(from + 1, Math.floor(b * levels.length)));
        let loudest = 0, sum = 0, heard = 0;
        for (let j = from; j < to; j++) {
            if (!levels[j]) continue;
            loudest = Math.max(loudest, levels[j]);
            sum += levels[j];
            heard++;
        }
        if (!heard) return 0;
        if (!lane) return Math.max(2 * ratio, ((loudest - 1) / 254) * height);
        const level = (0.8 * sum) / heard + 0.2 * loudest;
        const stretched = Math.min(1, Math.max(0, (level - lane.low) / Math.max(1, lane.high - lane.low)));
        return stretched > 0 ? Math.max(2 * ratio, stretched ** 1.25 * height) : 0;
    }

    function drawEnds(width, xOf) {
        const loop = currentLoop();
        for (const end of ["start", "end"]) {
            const element = $(`end-${end}`);
            const time = loop ? (end === "start" ? loop.start : loop.end) : null;
            const x = time == null ? null : xOf(time);
            element.hidden = x == null || x < -2 || x > width + 2;
            if (element.hidden) continue;
            element.style.left = `${x}px`;
            element.classList.toggle("flip", end === "start" ? x < 24 : x > width - 24);
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
        const { from, span } = viewRange();
        return Math.min(songDuration(), from + Math.min(1, Math.max(0, (clientX - box.left) / box.width)) * span);
    }

    // A tap moves the song there, and so does a slide, with the playhead under the finger until it lifts. Holding still
    // for a moment and then sliding makes a loop of the part that the finger covers. A drag on a tab moves that end,
    // and a tap on a tab picks it for the buttons beside play, and a second tap lets it go.
    let gesture = null;
    const HOLD_TO_LOOP = 400;
    function showSelection(from, to) {
        const box = $("wave").getBoundingClientRect();
        const a = Math.max(box.left, Math.min(from, to)), b = Math.min(box.right, Math.max(from, to));
        const selection = $("wave-selection");
        selection.hidden = false;
        selection.style.left = `${a - box.left}px`;
        selection.style.width = `${Math.max(2, b - a)}px`;
    }
    // Fingers on the waveform and on the strip of the whole song under a close-up, by touch identifier, or the mouse.
    // A phone's fingers come from touch events, whose list of touches is always whole. With pointer events, the waveform
    // on an iPhone missed the lift of a finger that left it during a pinch (WebKit bug 220196 is about the same capture),
    // and that finger stayed counted, so every later touch read as the second finger of a pinch.
    // Two fingers zoom the waveform in or out, and stop whatever the first finger was doing. The second finger counts
    // wherever it lands while the first is on the waveform, since a pinch rarely fits in the waveform's height.
    const fingers = new Map();
    let pinch = null;
    const fingerDistance = () => {
        const [a, b] = [...fingers.values()];
        return Math.max(24, Math.hypot(a.x - b.x, a.y - b.y));
    };
    const onStrip = (target) => Boolean(target?.closest?.("#zoom-map"));
    const onWave = (target) => Boolean(target?.closest?.("#wave, #zoom-map"));

    /** The moment of the song under `clientX` on the strip of the whole song. */
    function stripTimeAt(clientX) {
        const box = $("zoom-map").getBoundingClientRect();
        return songDuration() * Math.min(1, Math.max(0, (clientX - box.left) / Math.max(1, box.width)));
    }

    function fingerDown(id, x, y, target) {
        if (!songDuration()) return false;
        fingers.set(id, { x, y });
        if (fingers.size === 2) {
            if (gesture) {
                clearTimeout(gesture.hold);
                gesture = null;
                scrubTime = null;
                $("wave-selection").hidden = true;
            }
            frozenFrom = null;
            released = null;
            zoomAnimation = null;
            pinch = { distance: fingerDistance(), zoom };
            drawWave(true);
            return true;
        }
        if (fingers.size > 2 || pinch || !state?.seekable) return true;
        // The strip moves the song over its whole length, as the HUD's does, and the close-up follows.
        if (onStrip(target)) {
            gesture = { id, x, end: null, moved: false, mode: "strip", hold: 0 };
            scrubTime = stripTimeAt(x);
            tick();
            return true;
        }
        const end = target?.closest?.(".loop-end")?.dataset.end ?? null;
        if (currentZoom() > 1.001) frozenFrom = viewRange().from;
        gesture = { id, x, end, moved: false, mode: end ? "end" : "tap", hold: 0 };
        if (!end) {
            const mine = gesture;
            mine.hold = setTimeout(() => {
                if (gesture !== mine || mine.mode !== "tap") return;
                mine.mode = "select";
                showSelection(mine.x, mine.x);
            }, HOLD_TO_LOOP);
        }
        return true;
    }

    function fingerMove(id, x, y) {
        const finger = fingers.get(id);
        if (!finger) return;
        finger.x = x;
        finger.y = y;
        if (pinch) {
            if (fingers.size < 2) return;
            autoZoomed = false;
            return setZoom((pinch.zoom * fingerDistance()) / pinch.distance, false);
        }
        if (!gesture || id !== gesture.id) return;
        if (gesture.mode === "strip") {
            scrubTime = stripTimeAt(x);
            return tick();
        }
        if (!gesture.moved && Math.abs(x - gesture.x) < 6) return;
        gesture.moved = true;
        if (gesture.mode === "end") return moveEnd(gesture.end, timeAt(x), false);
        if (gesture.mode === "tap") {
            clearTimeout(gesture.hold);
            gesture.mode = "scrub";
        }
        if (gesture.mode === "select") return showSelection(gesture.x, x);
        scrubTime = timeAt(x);
        tick();
    }

    function fingerUp(id, x, cancelled) {
        if (!fingers.delete(id)) return;
        if (pinch) {
            if (fingers.size < 2) {
                pinch = null;
                // A pinch that barely zoomed shows the whole song.
                if (zoom < 1.1) setZoom(1, true);
            }
            return;
        }
        if (!gesture || id !== gesture.id) return;
        const { x: startX, end, moved, mode, hold } = gesture;
        gesture = null;
        clearTimeout(hold);
        if (frozenFrom != null) {
            released = { from: frozenFrom, at: performance.now() };
            frozenFrom = null;
        }
        scrubTime = null;
        $("wave-selection").hidden = true;
        if (cancelled) return drawWave(true);
        if (mode === "end") {
            if (moved) return moveEnd(end, timeAt(x), true);
            pickedEnd = pickedEnd === end ? null : end;
            return drawTransport();
        }
        if (mode === "select") {
            const a = timeAt(Math.min(startX, x)), b = timeAt(Math.max(startX, x));
            if (b - a < 0.25) return;
            pickedEnd = null;
            changeLoop({ start: a, end: b });
            zoomToLoop({ start: a, end: b });
            api("/api/loop", { action: "set", start: a, end: b }).catch((error) => failIcon($("loop-button"), error));
            return;
        }
        pickedEnd = null;
        const seconds = mode === "strip" ? stripTimeAt(x) : timeAt(x);
        state.position = seconds;
        stateAt = performance.now();
        drawTransport();
        transport({ action: "seek", seconds });
    }

    // A finger that the screen no longer has lifted where the page heard nothing of it.
    function forgetLifted(touches) {
        const down = new Set([...touches].map((touch) => touch.identifier));
        for (const [id, finger] of [...fingers]) if (id !== "mouse" && !down.has(id)) fingerUp(id, finger.x, true);
    }
    function touchStart(event) {
        forgetLifted(event.touches);
        let used = false;
        for (const touch of event.changedTouches) {
            if (fingers.has(touch.identifier) || (!onWave(touch.target) && fingers.size !== 1)) continue;
            used = fingerDown(touch.identifier, touch.clientX, touch.clientY, touch.target) || used;
        }
        if (used) event.preventDefault();
        followTouches(fingers.size > 0);
    }
    function touchMove(event) {
        let ours = false;
        for (const touch of event.changedTouches) {
            if (!fingers.has(touch.identifier)) continue;
            ours = true;
            fingerMove(touch.identifier, touch.clientX, touch.clientY);
        }
        if (ours) event.preventDefault();
    }
    function touchEnd(event) {
        for (const touch of event.changedTouches) fingerUp(touch.identifier, touch.clientX, event.type === "touchcancel");
        forgetLifted(event.touches);
        if (!fingers.size) followTouches(false);
    }
    // The whole page's touches are followed only while a finger is on the waveform, so that scrolling elsewhere never
    // waits for the page.
    let following = false;
    function followTouches(on) {
        if (on === following) return;
        following = on;
        const method = on ? "addEventListener" : "removeEventListener";
        document[method]("touchstart", touchStart, { capture: true, passive: false });
        document[method]("touchmove", touchMove, { capture: true, passive: false });
        document[method]("touchend", touchEnd, { capture: true });
        document[method]("touchcancel", touchEnd, { capture: true });
    }
    for (const element of [$("wave"), $("zoom-map")]) {
        element.addEventListener("touchstart", touchStart, { passive: false });
        // A mouse or a pen: one pointer, held by the element that it pressed.
        element.addEventListener("pointerdown", (event) => {
            if (event.pointerType === "touch" || event.button > 0) return;
            if (!fingerDown("mouse", event.clientX, event.clientY, event.target)) return;
            element.setPointerCapture(event.pointerId);
            event.preventDefault();
        });
        element.addEventListener("pointermove", (event) => { if (event.pointerType !== "touch") fingerMove("mouse", event.clientX, event.clientY); });
        element.addEventListener("pointerup", (event) => { if (event.pointerType !== "touch") fingerUp("mouse", event.clientX, false); });
        element.addEventListener("pointercancel", (event) => { if (event.pointerType !== "touch") fingerUp("mouse", event.clientX, true); });
    }
    addEventListener("resize", () => drawWave(true));

    /** A long press on the loop button loops the whole song, which repeats it. */
    function loopWholeSong() {
        const duration = songDuration();
        if (!duration) return;
        // A hair before the end, so that another player loops before it moves on to the next song.
        const end = Math.max(0.3, duration - 0.1);
        pickedEnd = null;
        changeLoop({ start: 0, end });
        api("/api/loop", { action: "set", start: 0, end }).catch((error) => failIcon($("loop-button"), error));
    }

    function loopButton() {
        const button = $("loop-button");
        let held = 0;
        let wholeSong = false;
        button.addEventListener("pointerdown", () => {
            if (button.disabled) return;
            wholeSong = false;
            clearTimeout(held);
            held = setTimeout(() => {
                wholeSong = true;
                loopWholeSong();
            }, 500);
        });
        for (const name of ["pointerup", "pointercancel", "pointerleave"]) button.addEventListener(name, () => clearTimeout(held));
        button.addEventListener("contextmenu", (event) => event.preventDefault());
        button.addEventListener("click", () => {
            if (wholeSong) {
                wholeSong = false;
                return;
            }
            pressLoop();
        });
    }

    /** The loop button works as R does on the Mac: it starts the loop where the song is, ends it, then clears it. */
    function pressLoop() {
        const loop = currentLoop();
        const position = macPosition() ?? 0;
        if (!loop) changeLoop({ start: position, end: null });
        else if (loop.end == null) {
            const ended = { ...loop, end: Math.max(position, loop.start + 0.25) };
            changeLoop(ended);
            zoomToLoop(ended);
        } else {
            pickedEnd = null;
            changeLoop(null);
            if (autoZoomed) zoomOut();
        }
        api("/api/loop", { action: "press" }).catch((error) => failIcon($("loop-button"), error));
    }

    /** The buttons beside play: 5 seconds back or forward, or while a tab is picked, its end by 20 ms, again and again
     * while the finger stays down. */
    function stepButton(id, direction) {
        const button = $(id);
        let delay = 0;
        let repeat = 0;
        // The finger that holds the button, and when it went down. Any release stops the nudges: on the button, after
        // it moved off the button, or one that the page never heard because the page went away.
        let finger = null;
        let since = 0;
        const stop = () => {
            clearTimeout(delay);
            clearInterval(repeat);
            delay = repeat = 0;
        };
        const release = (event) => {
            if (finger == null || (event?.pointerId != null && event.pointerId !== finger)) return;
            finger = null;
            stop();
            const loop = currentLoop();
            if (loop && pickedEnd) moveEnd(pickedEnd, pickedEnd === "start" ? loop.start : loop.end, true);
        };
        const nudge = () => {
            const loop = currentLoop();
            if (finger == null || !loop || !pickedEnd || performance.now() - since > 15000) return release();
            const time = pickedEnd === "start" ? loop.start : loop.end;
            moveEnd(pickedEnd, time + direction * 0.02, false);
        };
        button.addEventListener("pointerdown", (event) => {
            if (!pickedEnd || button.disabled) return;
            stop();
            finger = event.pointerId;
            since = performance.now();
            button.setPointerCapture?.(event.pointerId);
            nudge();
            delay = setTimeout(() => (repeat = setInterval(nudge, 60)), 400);
        });
        for (const name of ["pointerup", "pointercancel", "lostpointercapture"]) button.addEventListener(name, release);
        for (const name of ["pointerup", "pointercancel"]) addEventListener(name, release);
        for (const name of ["touchend", "touchcancel", "blur"]) addEventListener(name, () => release());
        document.addEventListener("visibilitychange", () => release());
        button.addEventListener("contextmenu", (event) => event.preventDefault());
        button.addEventListener("click", () => {
            if (!pickedEnd) transport({ action: direction < 0 ? "back" : "forward" });
        });
    }

    // MARK: Output: the Mac, or this phone through a live stream of the Mac's output

    let output = "mac";

    /** WebCodecs decodes the compressed stream without a delay, and browsers offer it only on secure pages: HTTPS, or
     * this device's own address. Safari has `AudioDecoder` on a plain HTTP page as well, where it decodes nothing, so
     * the page asks the decoder, and a decoder that fails once makes the page ask for PCM from then on. */
    let webCodecs = window.isSecureContext && typeof AudioDecoder === "function";
    const decodesAAC = (async () => {
        try {
            if (!webCodecs) return false;
            return (await AudioDecoder.isConfigSupported({ codec: "mp4a.40.2", sampleRate: 48000, numberOfChannels: 2 })).supported === true;
        } catch {
            return false;
        }
    })();
    decodesAAC.then((supported) => {
        webCodecs = supported;
        if (!$("settings").hidden) drawSettings();
    });
    const STREAM_KEY = "muskey:stream";

    /** The stream picked in Settings: compressed by default where WebCodecs decodes it, uncompressed otherwise, since the
     * audio element plays the compressed stream seconds behind the Mac. */
    function streamChoice() {
        try {
            const picked = localStorage.getItem(STREAM_KEY);
            if (picked === "compressed" || picked === "uncompressed") return picked;
        } catch {}
        return webCodecs ? "compressed" : "uncompressed";
    }

    /** The output that was picked by hand in the output menu, kept for the next visits. Without one, a phone plays every
     * new song itself: a song of Recents or Files, a link, an upload, Play on a paused song, or the playing song that
     * the Now row opens. */
    const OUTPUT_KEY = "muskey:output";
    function pickedOutput() {
        try {
            return localStorage.getItem(OUTPUT_KEY);
        } catch {
            return null;
        }
    }
    function pickOutput(next) {
        try {
            localStorage.setItem(OUTPUT_KEY, next);
        } catch {}
        setOutput(next);
    }
    /** This page plays new songs on the phone: a touch screen, and Mac never picked by hand. */
    function phoneByDefault() {
        return pickedOutput() !== "mac" && matchMedia("(pointer: coarse)").matches;
    }
    /** Called first in a tap that starts a song, since iOS lets Web Audio start only inside one. */
    function preferPhone() {
        if (output !== "phone" && phoneByDefault()) setOutput("phone");
    }

    /** Plays /api/stream, read from one long request and scheduled about a quarter of a second ahead in an AudioContext,
     * which starts inside the tap, as iOS asks. The stream is AAC that WebCodecs decodes here, about 70 MB an hour, or
     * 16-bit stereo PCM, ten times that, in a browser without the decoder. */
    const player = (() => {
        let context = null;
        let gain = null;
        let abort = null;
        let playAt = 0;
        let generation = 0;
        // What arrived since the last report, for the Mac's log: seconds of audio, their loudest sample, and the data.
        let receivedSeconds = 0;
        let receivedBytes = 0;
        let peak = 0;
        let format = "pcm";
        setInterval(() => {
            if (!context || abort === null) return;
            const db = peak > 0 ? Math.round(20 * Math.log10(peak)) : -Infinity;
            report(`stream: ${receivedSeconds.toFixed(1)} s received in 10 s as ${format} (${Math.round(receivedBytes / 1000)} kB), peak ${db} dB, ${Math.round((playAt - context.currentTime) * 1000)} ms ahead`, "debug");
            receivedSeconds = 0;
            receivedBytes = 0;
            peak = 0;
        }, 10000);

        let aacFailed = false;

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
                    const asked = !aacFailed && streamChoice() === "compressed" && (await decodesAAC);
                    const response = await fetch(asked ? "/api/stream?format=aac" : "/api/stream", { cache: "no-store", signal: abort.signal });
                    if (!response.ok) throw new Error(`the stream answered ${response.status}`);
                    // The Mac sends PCM when it can't encode AAC at its output's rate.
                    const aac = (response.headers.get("Content-Type") || "").startsWith("audio/aac");
                    const rate = Number(response.headers.get("X-Sample-Rate")) || 48000;
                    format = aac ? "aac" : "pcm";
                    report(`stream connected at ${rate} Hz as ${format}, the context runs at ${context.sampleRate} Hz (${context.state})`, "info");
                    const reader = response.body.getReader();
                    playAt = 0;
                    if (aac) {
                        await readAAC(reader, rate, mine);
                    } else {
                        let carry = new Uint8Array(0);
                        for (;;) {
                            const { value, done } = await reader.read();
                            if (done || mine !== generation) break;
                            receivedBytes += value.length;
                            const bytes = new Uint8Array(carry.length + value.length);
                            bytes.set(carry);
                            bytes.set(value, carry.length);
                            const usable = bytes.length - (bytes.length % 4);
                            carry = bytes.slice(usable);
                            schedule(new DataView(bytes.buffer, 0, usable), usable / 4, rate);
                        }
                    }
                } catch (error) {
                    if (mine !== generation) return;
                    report(`stream: ${error.message}`);
                }
                // The Mac closes the stream when its output changes rate, and the page connects again at once.
                if (mine === generation) await new Promise((resolve) => setTimeout(resolve, 300));
            }
        }

        /** Splits the stream into its ADTS frames, which carry their length, and decodes them in order. */
        async function readAAC(reader, rate, mine) {
            let failed = null;
            const decoder = new AudioDecoder({
                output: (data) => {
                    try {
                        scheduleDecoded(data);
                    } finally {
                        data.close();
                    }
                },
                error: (error) => (failed = error),
            });
            decoder.configure({ codec: "mp4a.40.2", sampleRate: rate, numberOfChannels: 2 });
            let carry = new Uint8Array(0);
            let timestamp = 0;
            try {
                for (;;) {
                    const { value, done } = await reader.read();
                    if (done || mine !== generation) break;
                    if (failed) {
                        aacFailed = true;
                        throw new Error(`the AAC decoder failed (${failed.message}), switching to PCM`);
                    }
                    receivedBytes += value.length;
                    const bytes = new Uint8Array(carry.length + value.length);
                    bytes.set(carry);
                    bytes.set(value, carry.length);
                    let at = 0;
                    while (bytes.length - at >= 7) {
                        // A frame starts with 12 bits set; anything else is skipped until the next one.
                        if (bytes[at] !== 0xff || (bytes[at + 1] & 0xf0) !== 0xf0) {
                            at++;
                            continue;
                        }
                        const length = ((bytes[at + 3] & 0x03) << 11) | (bytes[at + 4] << 3) | (bytes[at + 5] >> 5);
                        if (length < 7) {
                            at++;
                            continue;
                        }
                        if (bytes.length - at < length) break;
                        decoder.decode(new EncodedAudioChunk({ type: "key", timestamp, data: bytes.slice(at, at + length) }));
                        timestamp += (1024 / rate) * 1e6;
                        at += length;
                    }
                    carry = bytes.slice(at);
                }
            } finally {
                if (decoder.state !== "closed") decoder.close();
            }
        }

        function scheduleDecoded(data) {
            const frames = data.numberOfFrames;
            if (!frames || !context) return;
            const buffer = context.createBuffer(2, frames, data.sampleRate);
            for (let channel = 0; channel < 2; channel++) {
                data.copyTo(buffer.getChannelData(channel), { planeIndex: Math.min(channel, data.numberOfChannels - 1), format: "f32-planar" });
            }
            let loudest = 0;
            for (const samples of [buffer.getChannelData(0), buffer.getChannelData(1)]) {
                for (let i = 0; i < frames; i++) loudest = Math.max(loudest, Math.abs(samples[i]));
            }
            queue(buffer, loudest);
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
            queue(buffer, loudest);
        }

        function queue(buffer, loudest) {
            receivedSeconds += buffer.duration;
            peak = Math.max(peak, loudest);
            const now = context.currentTime;
            // Too close to the speaker after a gap: start again a quarter second ahead. Too far ahead after a burst, like
            // the first frames out of the AAC decoder or a stall on Wi-Fi: leave this part out, so that the phone stays
            // close to the Mac. Moving playAt back instead would play two parts over each other.
            if (playAt < now + 0.03) playAt = now + 0.25;
            else if (playAt > now + 0.45) return;
            const source = context.createBufferSource();
            source.buffer = buffer;
            source.connect(gain);
            source.start(playAt);
            playAt += buffer.duration;
        }

        /** The compressed stream without WebCodecs: the browser's audio element plays it, a few seconds behind the Mac,
         * since it buffers a compressed stream before it starts. iOS lets an element play only after a tap played it,
         * so the tap of an upload primes one for the stream that starts once the file is picked. */
        let element = null;
        let primed = null;
        let elementAt = 0;
        /** Seconds from asking for the stream to hearing it, which is how far the element plays behind the Mac. */
        let elementDelay = 0;
        const elementMode = () => streamChoice() === "compressed" && !webCodecs;

        function startElement(mine) {
            element = primed ?? new Audio();
            primed = null;
            element.muted = testMute;
            element.src = `/api/stream?format=aac&t=${Date.now()}`;
            elementAt = performance.now();
            format = "aac in the audio element";
            const started = element;
            started.addEventListener("playing", () => {
                if (mine !== generation) return;
                elementDelay = (performance.now() - elementAt) / 1000 - started.currentTime;
                report(`stream: the audio element plays, ${elementDelay.toFixed(1)} s after it asked`, "info");
            }, { once: true });
            started.addEventListener("error", () => {
                if (mine === generation) report(`stream: the audio element failed (${started.error?.code ?? "unknown"})`);
            });
            return started.play();
        }

        return {
            /** Called from the tap on Phone. */
            start() {
                const mine = ++generation;
                if (elementMode()) return startElement(mine);
                const resumed = ensureContext();
                run(mine);
                return resumed;
            },
            /** Called from a tap that may start the stream later, outside of it. */
            unlock() {
                if (!elementMode()) return ensureContext().catch(() => {});
                primed = primed ?? new Audio();
                primed.play().catch(() => {});
            },
            stop() {
                generation++;
                abort?.abort();
                abort = null;
                context?.suspend();
                if (element) {
                    element.pause();
                    element.removeAttribute("src");
                    element.load();
                    element = null;
                }
            },
            /** Seconds between the Mac playing a moment and this phone playing it. */
            lag() {
                // The element's clock tells when it fell further behind. A muted element in the iOS simulator never
                // moves it (an unmuted one does), so the delay at the start stands in until the clock moves.
                if (element) return element.currentTime > 0.5 ? Math.max(0, (performance.now() - elementAt) / 1000 - element.currentTime) : elementDelay;
                // The encoder on the Mac holds back about 60 ms of AAC.
                return context && playAt ? Math.max(0, playAt - context.currentTime) + (format === "aac" ? 0.11 : 0.05) : 0;
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
    /** What a save would write: the key, the tempo, the instruments and the loop. */
    function saveSettings() {
        const loop = currentLoop();
        return JSON.stringify([shift, speed, [...muted].sort(), loop?.end != null ? [loop.start, loop.end] : null]);
    }
    /** The song that the last save wrote, which Share offers until the key, tempo, instruments or loop change. */
    let shared = null;

    /** Share in the top row writes the song as it plays, or its loop, and then shares the file that it wrote. */
    function drawSaveAndNotes() {
        const looped = currentLoop()?.end != null;
        const save = $("save");
        const busy = save.classList.contains("failed") || save.classList.contains("working");
        if (shared && shared.settings !== saveSettings()) shared = null;
        save.hidden = !state?.song;
        save.classList.toggle("ready", Boolean(shared));
        if (!busy) save.setAttribute("aria-label", shared ? "Share" : looped ? "Save loop" : "Save song");
        drawTranscribeLabel();
    }

    /** The song as it plays on the Mac, with its key, tempo and instruments, or only its loop, written on the Mac
     * and then shared from the phone, or downloaded where the browser can't share files. */
    async function save() {
        const button = $("save");
        if (!state?.song || button.classList.contains("working")) return;
        if (shared) return share(shared);
        clearFailures();
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
            const settings = saveSettings();
            const job = await follow(await api("/api/write", body), button);
            // The file is fetched now, because sharing it has to happen inside the next tap.
            let file = null;
            try {
                const response = await fetch(job.file);
                const name = /filename\*=UTF-8''([^;]+)/.exec(response.headers.get("Content-Disposition") || "")?.[1];
                const blob = await response.blob();
                file = new File([blob], name ? decodeURIComponent(name) : "Song.m4a", { type: blob.type || "audio/mp4" });
            } catch (error) {
                report(`share: ${error.message}`);
            }
            shared = { settings, url: job.file, file };
            drawSaveAndNotes();
        } catch (error) {
            if (error.message !== "Stopped") fail(button, $("save-error"), error);
        }
    }

    function share({ url, file }) {
        if (file && navigator.canShare?.({ files: [file] })) {
            navigator.share({ files: [file] }).catch((error) => {
                if (error.name !== "AbortError" && error.name !== "NotAllowedError") report(`share: ${error.name} ${error.message}`);
            });
            return;
        }
        const link = document.createElement("a");
        link.href = url;
        link.download = file?.name || "";
        link.click();
    }

    // MARK: Notes

    /** The instrument that Transcribe writes: the only one that plays, since its stem is already separated. While
     * several play, Muskey picks the one with the most notes. Drums have no notes. */
    function notesTarget() {
        const playing = STEMS.filter((s) => !muted.has(s.name));
        return playing.length === 1 && playing[0].name !== "drums" ? playing[0] : null;
    }

    /** Transcribe names the instrument that plays alone, and the loop once it has an end. */
    function drawTranscribeLabel() {
        const button = $("transcribe");
        const target = notesTarget();
        const art = target && (target.name === "guitar" || target.name === "bass") ? "tab" : "staff";
        if (button.dataset.art !== art) {
            button.dataset.art = art;
            drawTranscribeArt();
        }
        if (button.classList.contains("failed") || button.classList.contains("working")) return;
        const looped = currentLoop()?.end != null;
        const what = target ? `Transcribe ${target.label.toLowerCase()}` : "Transcribe";
        const label = looped ? (target ? `${what} in loop` : "Transcribe loop") : what;
        if ($("transcribe-label").textContent !== label) $("transcribe-label").textContent = label;
        $("transcribe-sub").textContent = "long press an instrument to transcribe";
        $("transcribe-sub").hidden = Boolean(target);
    }

    // The made-up notes on the button: a staff for most instruments and a tab for guitar and bass. They light up
    // with the notes window's glow as the transcription passes them.
    const ART_NOTES = (() => {
        let seed = 7;
        const next = () => (seed = (seed * 1103515245 + 12345) % 2147483648) / 2147483648;
        return Array.from({ length: 30 }, (_, i) => ({ x: (i + 0.5 + (next() - 0.5) * 0.4) / 30, place: Math.floor(next() * 9), string: Math.floor(next() * 6), fret: Math.floor(next() * 13) }));
    })();
    const art = { shown: 0, passed: new Map(), running: false };

    function drawTranscribeArt() {
        const canvas = $("transcribe-art");
        const button = $("transcribe");
        const width = canvas.clientWidth, height = canvas.clientHeight;
        if (!width || !height) return;
        const scale = devicePixelRatio || 1;
        if (canvas.width !== Math.round(width * scale) || canvas.height !== Math.round(height * scale)) {
            canvas.width = Math.round(width * scale);
            canvas.height = Math.round(height * scale);
        }
        const ctx = canvas.getContext("2d");
        ctx.setTransform(scale, 0, 0, scale, 0, 0);
        ctx.clearRect(0, 0, width, height);
        const dark = matchMedia("(prefers-color-scheme: dark)").matches;
        const working = button.classList.contains("working");
        // Without a share of the work done, a light sweeps across the notes again and again.
        const unknown = working && (button.classList.contains("unknown") || !(parseFloat(button.style.getPropertyValue("--done")) > 0));
        const sweep = (performance.now() % 2600) / 2600;
        const ink = dark ? "255 247 245" : "33 20 26";
        const theme = dark
            ? { accent: [0.76, 0.18, 62], hot: [0.86, 0.18, 76], glow: "oklch(0.78 0.19 60" }
            : { accent: [0.58, 0.24, 16], hot: [0.6, 0.26, 20], glow: "oklch(0.7 0.2 16" };
        const edge = 18;
        const done = working ? edge + art.shown * (width - 2 * edge) : -1;
        const tint = dark ? "oklch(0.66 0.13 74 / 0.2)" : "oklch(0.74 0.13 74 / 0.2)";
        if (unknown) {
            const x = edge + sweep * (width - 2 * edge);
            const band = ctx.createLinearGradient(x - 90, 0, x, 0);
            band.addColorStop(0, "transparent");
            band.addColorStop(1, tint);
            ctx.fillStyle = band;
            ctx.fillRect(x - 90, 0, 90, height);
        } else if (working) {
            ctx.fillStyle = tint;
            ctx.fillRect(0, 0, done, height);
        }
        const tab = button.dataset.art === "tab";
        const lines = tab ? 6 : 5;
        const gap = Math.min(tab ? 7 : 8, (height - 14) / (lines - 1));
        const top = (height - gap * (lines - 1)) / 2;
        ctx.strokeStyle = `rgb(${ink} / 0.12)`;
        ctx.lineWidth = 1;
        for (let line = 0; line < lines; line++) {
            ctx.beginPath();
            ctx.moveTo(edge, Math.round(top + line * gap) + 0.5);
            ctx.lineTo(width - edge, Math.round(top + line * gap) + 0.5);
            ctx.stroke();
        }
        const now = performance.now();
        let flashing = false;
        ctx.font = `700 ${Math.round(gap * 1.35)}px ui-rounded, system-ui, sans-serif`;
        ctx.textAlign = "center";
        ctx.textBaseline = "middle";
        ART_NOTES.forEach((note, index) => {
            const x = edge + 6 + note.x * (width - 2 * edge - 12);
            let color = `rgb(${ink} / 0.2)`;
            let flash = 0;
            const reached = unknown || (working && x <= done);
            if (reached) {
                if (!art.passed.has(index)) art.passed.set(index, now);
                // A sweep lights each note when it passes it, and the note fades until the next sweep.
                const age = unknown ? ((sweep - (x - edge) / (width - 2 * edge) + 1) % 1) * 2.6 : (now - art.passed.get(index)) / 1000;
                flash = Math.min(1.35, Math.exp(-age / 0.7) * (1 + 0.45 * Math.exp(-age / 0.09)));
                if (flash > 0.02) flashing = true;
                const [l, c, h] = theme.accent.map((value, i) => value + (theme.hot[i] - value) * Math.min(1, flash) * (dark ? 0.75 : 0.5));
                color = `oklch(${l} ${c} ${h} / ${unknown ? Math.min(1, 0.2 + flash) : 1})`;
            }
            const y = tab ? top + note.string * gap : top + gap * 4 - note.place * (gap / 2);
            if (flash > 0.02) {
                const radius = gap * 2.4;
                const gradient = ctx.createRadialGradient(x, y, 0, x, y, radius);
                const alpha = (dark ? 0.34 : 0.3) * flash;
                gradient.addColorStop(0, `${theme.glow} / ${Math.min(1, alpha * 1.8)})`);
                gradient.addColorStop(0.3, `${theme.glow} / ${alpha * 0.7})`);
                gradient.addColorStop(1, `${theme.glow} / 0)`);
                ctx.save();
                if (dark) ctx.globalCompositeOperation = "lighter";
                ctx.fillStyle = gradient;
                ctx.fillRect(x - radius, y - radius, radius * 2, radius * 2);
                ctx.restore();
            }
            if (tab) {
                const text = String(note.fret);
                const half = ctx.measureText(text).width / 2 + 1.5;
                ctx.save();
                ctx.globalCompositeOperation = "destination-out";
                ctx.fillRect(x - half, y - gap * 0.45, half * 2, gap * 0.9);
                ctx.restore();
                ctx.fillStyle = color;
                ctx.fillText(text, x, y + 0.5);
            } else {
                ctx.fillStyle = color;
                ctx.strokeStyle = color;
                ctx.beginPath();
                ctx.ellipse(x, y, gap * 0.62, gap * 0.44, -0.35, 0, Math.PI * 2);
                ctx.fill();
                ctx.lineWidth = 1.2;
                ctx.beginPath();
                ctx.moveTo(x + gap * 0.56, y - 0.5);
                ctx.lineTo(x + gap * 0.56, y - gap * 2.6);
                ctx.stroke();
            }
        });
        return working || flashing;
    }

    /** Moves the light across the button towards the job's progress, and lets the last notes fade after it ends. */
    function animateArt() {
        if (art.running) return;
        art.running = true;
        const step = () => {
            const button = $("transcribe");
            const target = parseFloat(button.style.getPropertyValue("--done")) / 100 || 0;
            art.shown += (target - art.shown) * 0.08;
            if (button.classList.contains("working")) {
                $("transcribe-label").textContent = target > 0 ? `${Math.round(art.shown * 100)}%` : "Transcribing";
            }
            if (drawTranscribeArt()) return requestAnimationFrame(step);
            art.running = false;
        };
        requestAnimationFrame(step);
    }

    async function transcribe() {
        const button = $("transcribe");
        if (button.classList.contains("failed")) clearFailures();
        if (!state?.song || button.classList.contains("working")) return;
        button.disabled = true;
        button.dataset.label = $("transcribe-label").textContent;
        art.shown = 0;
        art.passed.clear();
        button.classList.add("working");
        animateArt();
        try {
            const loop = currentLoop();
            const part = loop?.end != null ? { from: loop.start, to: loop.end } : {};
            const notes = notesTarget()?.name ?? "auto";
            const job = await follow(await api("/api/write", { song: state.song, notes, format: "json", ...part }), button);
            const data = await (await fetch(job.file)).json();
            closeSheet();
            $("sheet").hidden = false;
            showSheet(true);
            setDock(0);
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
        } catch (error) {
            if (error.message !== "Stopped") fail(button, $("notes-error"), error);
        } finally {
            button.disabled = false;
            if (!button.classList.contains("failed")) delete button.dataset.label;
            drawTranscribeLabel();
            drawTranscribeArt();
        }
    }

    /** The notes take the record's place, and Back closes them. */
    function showSheet(on) {
        $("stage").classList.toggle("notes", on);
        $("close").setAttribute("aria-label", on ? "Close notes" : "Close song");
    }

    function closeSheet() {
        sheet?.destroy();
        sheet = null;
        $("sheet").replaceChildren();
        $("sheet").hidden = true;
        showSheet(false);
    }

    // MARK: Dock

    /** How far the dock is open, from 0 for the floating transport to 1 for the sheet of tempo, instruments and notes. */
    let dockOpen = 0;

    function setDock(value, animate = true) {
        dockOpen = Math.max(0, Math.min(1, value));
        const song = $("song");
        song.classList.toggle("dragging", !animate);
        song.style.setProperty("--more-h", `${moreRoom()}px`);
        song.style.setProperty("--open", dockOpen.toFixed(3));
        song.classList.toggle("dock-open", dockOpen > 0.5);
        $("handle").setAttribute("aria-expanded", String(dockOpen > 0.5));
        $("more").inert = dockOpen < 0.5;
        if (dockOpen > 0) requestAnimationFrame(drawTranscribeArt);
    }

    /** The sheet's height: all of it, or the room between the top row and the transport, where it then scrolls. */
    function moreRoom() {
        const natural = $("more-in").scrollHeight;
        const top = $("top").getBoundingClientRect().bottom;
        const closed = $("dock").offsetHeight - $("more").offsetHeight;
        return Math.max(160, Math.min(natural, innerHeight - top - closed - 12));
    }

    /** The room that the closed dock takes at the bottom of the screen, which the record stays above. */
    function measureDock() {
        if (!open || dockOpen > 0) return;
        $("song").style.setProperty("--dock-room", `${Math.ceil($("dock").offsetHeight)}px`);
    }

    /** The handle opens the dock with a tap, or follows a finger and settles open or closed. */
    function dockHandle() {
        const handle = $("handle");
        let drag = null;
        handle.addEventListener("pointerdown", (event) => {
            if (event.button > 0) return;
            handle.setPointerCapture(event.pointerId);
            drag = { y: event.clientY, open: dockOpen, moved: false, height: moreRoom(), last: event.clientY, at: event.timeStamp, velocity: 0 };
        });
        handle.addEventListener("pointermove", (event) => {
            if (!drag) return;
            const travel = drag.y - event.clientY;
            if (!drag.moved && Math.abs(travel) < 4) return;
            drag.moved = true;
            const elapsed = event.timeStamp - drag.at;
            if (elapsed > 0) drag.velocity = (drag.last - event.clientY) / elapsed;
            drag.last = event.clientY;
            drag.at = event.timeStamp;
            setDock(drag.open + travel / drag.height, false);
        });
        const end = () => {
            if (!drag) return;
            const { moved, velocity } = drag;
            drag = null;
            if (!moved) return setDock(dockOpen > 0.5 ? 0 : 1);
            const target = Math.abs(velocity) > 0.4 ? (velocity > 0 ? 1 : 0) : dockOpen > 0.5 ? 1 : 0;
            requestAnimationFrame(() => setDock(target));
        };
        handle.addEventListener("pointerup", end);
        handle.addEventListener("pointercancel", end);
        // A click from the keyboard has no pointer before it.
        handle.addEventListener("click", (event) => {
            if (event.detail === 0) setDock(dockOpen > 0.5 ? 0 : 1);
        });
        $("scrim").addEventListener("click", () => setDock(0));
    }

    // MARK: Open

    /** A link of Spotify or of any site that yt-dlp reads plays on the Mac. */
    async function playLink(event) {
        event.preventDefault();
        const button = $("link-play");
        let link = $("link").value.trim();
        if (!link) return $("link").focus();
        preferPhone();
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
        if (row.classList.contains("failed") && uploadFile) {
            preferPhone();
            return sendFile(uploadFile);
        }
        // The picker answers outside the tap, so the audio is allowed to start here and plays once a file is picked.
        if (output !== "phone" && phoneByDefault()) player.unlock();
        $("upload-file").value = "";
        $("upload-file").click();
    }

    /** A file of this phone is sent to the Mac, with its progress as a fill in the row, and plays there. */
    async function sendFile(file) {
        const row = $("upload");
        uploadFile = file;
        clearFailures();
        progress(row, 0);
        report(`sending ${file.name} (${(file.size / 1e6).toFixed(1)} MB)`, "info");
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

    // MARK: Settings

    // MARK: Song title

    /** Where the song view shows the title and artist: below the record, on the dimmed cover, in the top row, or
     * along the grooves. Kept on this phone. */
    const TITLE_KEY = "muskey.songTitle";
    const TITLE_PLACES = ["below", "cover", "bar", "grooves"];
    function titlePlace() {
        try {
            const place = localStorage.getItem(TITLE_KEY);
            return TITLE_PLACES.includes(place) ? place : "below";
        } catch {
            return "below";
        }
    }
    document.documentElement.dataset.songTitle = titlePlace();
    $("title-choice").addEventListener("click", (event) => {
        const button = event.target.closest("button[data-title]");
        if (!button) return;
        try {
            localStorage.setItem(TITLE_KEY, button.dataset.title);
        } catch {}
        document.documentElement.dataset.songTitle = button.dataset.title;
        drawSettings();
    });

    function drawSettings() {
        const place = document.documentElement.dataset.songTitle;
        for (const button of $("title-choice").querySelectorAll("button")) button.setAttribute("aria-pressed", String(button.dataset.title === place));
        const choice = streamChoice();
        for (const button of $("stream-choice").querySelectorAll("button")) button.setAttribute("aria-pressed", String(button.dataset.stream === choice));
        $("stream-note").textContent = choice === "uncompressed" ? "~700MB/h (can stutter on slower connections)" : webCodecs ? "~70MB/h" : "~70MB/h with a 5 second buffering delay";
        $("stream-https").hidden = webCodecs || location.protocol === "https:";
    }

    function showSettings(shown) {
        $("settings").hidden = !shown;
        if (shown) drawSettings();
    }

    $("settings-open").onclick = () => showSettings(true);
    $("settings-close").onclick = () => showSettings(false);
    $("settings").addEventListener("click", (event) => {
        if (event.target === $("settings")) showSettings(false);
    });
    $("stream-choice").addEventListener("click", (event) => {
        const button = event.target.closest("button[data-stream]");
        if (!button || button.dataset.stream === streamChoice()) return;
        try {
            localStorage.setItem(STREAM_KEY, button.dataset.stream);
        } catch {}
        drawSettings();
        report(`stream: ${button.dataset.stream} picked`, "info");
        // A phone that listens switches streams inside this tap, which iOS asks of a sound that starts.
        if (output !== "phone") return;
        player.stop();
        player.start().catch((error) => report(`audio refused: ${error.name} ${error.message}`));
    });

    // MARK: Install

    /** Install Muskey floats at the bottom of Home, as on legume, 2 seconds after the page loads: with Install where the
     * browser offers its install dialog (Chrome, Android, over HTTPS), or with the steps of the Share menu on an iPhone
     * or iPad. Android always gets the button, and without the dialog (Incognito, plain HTTP) a tap on it shows the
     * steps of Chrome's menu. A hidden pill stays away for 21 days. */
    const INSTALL_HIDDEN_KEY = "muskey:install-hidden";
    const INSTALL_QUIET_DAYS = 21;
    const appleTouch = /iPhone|iPad|iPod/.test(navigator.userAgent) || (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1);
    const android = /Android/i.test(navigator.userAgent);
    let installPrompt = null;
    let installReady = false;
    let installSteps = false;

    function installHidden() {
        try {
            const at = Number(localStorage.getItem(INSTALL_HIDDEN_KEY));
            return at > 1 && Date.now() - at < INSTALL_QUIET_DAYS * 86400000;
        } catch {
            return false;
        }
    }

    function hideInstall() {
        try {
            localStorage.setItem(INSTALL_HIDDEN_KEY, String(Date.now()));
        } catch {}
        drawInstall();
    }

    function drawInstall() {
        const pill = $("install");
        const shown = installReady && !standalone && !installHidden() && !$("home").hidden && (installPrompt !== null || appleTouch || android);
        document.documentElement.classList.toggle("has-install-pill", shown);
        if (!shown) {
            pill.classList.remove("open");
            pill.hidden = true;
            return;
        }
        $("install-button").hidden = installSteps || !(installPrompt || android);
        $("install-share").hidden = Boolean(installPrompt) || android || !appleTouch;
        $("install-menu").hidden = !installSteps;
        if (pill.hidden) {
            pill.hidden = false;
            // The next frame, so the pill eases in from below.
            requestAnimationFrame(() => pill.classList.add("open"));
        }
    }

    addEventListener("beforeinstallprompt", (event) => {
        event.preventDefault();
        installPrompt = event;
        installSteps = false;
        drawInstall();
    });
    addEventListener("appinstalled", hideInstall);
    setTimeout(() => {
        installReady = true;
        drawInstall();
    }, 2000);

    // MARK: Files on the Mac

    /** What the Files screen asked for last, so an older answer that comes later is dropped. */
    let filesAsked = null;
    let filesTimer = 0;
    /** The folder that the Files screen shows, by its ID, or null at the top. */
    let filesDir = null;
    const SORT_KEY = "muskey:files-sort";
    let filesSort = (() => {
        try {
            return localStorage.getItem(SORT_KEY) === "added" ? "added" : "name";
        } catch {
            return "name";
        }
    })();

    function openFiles() {
        clearFailures();
        show("files");
        if (history.state?.files !== true) {
            filesDir = null;
            history.pushState({ files: true, dir: null }, "");
        }
        loadFiles();
    }

    /** A folder opens over the one that holds it, which keeps its place in the list for the way back. */
    function openFolder(id) {
        history.replaceState({ ...history.state, scroll: scrollY }, "");
        history.pushState({ files: true, dir: id }, "");
        filesDir = id;
        $("files-search").value = "";
        loadFiles(0);
    }

    /** The search over every folder while the search bar has words, the folder otherwise. */
    async function loadFiles(scroll) {
        const query = $("files-search").value.trim();
        const asked = `${query}|${filesDir}|${filesSort}`;
        filesAsked = asked;
        let answer;
        try {
            answer = query
                ? await api(`/api/files?q=${encodeURIComponent(query)}`)
                : await api(`/api/folder?id=${encodeURIComponent(filesDir ?? "")}&sort=${filesSort}`);
        } catch (error) {
            answer = { folders: -1, files: [], more: false, error: error.message };
        }
        if (asked !== filesAsked) return;
        $("files-title").textContent = (!query && answer.name) || "Files on the Mac";
        $("files-close").setAttribute("aria-label", filesDir ? "Close folder" : "Close files");
        $("files-more").hidden = !answer.more;
        const sections = query ? searchSections(answer) : folderSections(answer);
        if (!sections.length) {
            const empty = document.createElement("div");
            empty.className = "empty";
            empty.textContent = answer.error ?? (answer.folders === 0 ? "Add folders in Muskey's Settings > Remote to list their songs here" : query ? "No songs match" : "No songs");
            $("files-list").replaceChildren(empty);
        } else {
            $("files-list").replaceChildren(...sections);
        }
        drawLetters();
        if (scroll !== undefined) scrollTo(0, scroll);
    }

    function filesSection(label, rows, extra) {
        const section = document.createElement("section");
        section.className = "section";
        const head = document.createElement("div");
        head.className = "label";
        const text = document.createElement("span");
        text.textContent = label;
        head.append(text);
        if (extra) head.append(extra);
        const card = document.createElement("div");
        card.className = "card";
        card.append(...rows);
        section.append(head, card);
        return section;
    }

    function searchSections(answer) {
        return answer.files.length ? [filesSection("Songs", answer.files.map((file) => fileRow(file, true)))] : [];
    }

    function folderSections(answer) {
        const sections = [];
        if (answer.subfolders?.length) sections.push(filesSection("Folders", answer.subfolders.map(folderRow)));
        if (answer.recent?.length) sections.push(filesSection("Recently added", answer.recent.map((file) => fileRow(file, true))));
        if (answer.files?.length) {
            // A long list sorted by name gets a heading for each letter, and the letters down the right edge.
            const lettered = filesSort === "name" && answer.files.length > 40;
            const rows = [];
            let last = null;
            for (const file of answer.files) {
                const letter = letterOf(file.title);
                if (lettered && letter !== last) {
                    const head = document.createElement("div");
                    head.className = "letter-head";
                    head.dataset.letter = letter;
                    head.textContent = letter;
                    rows.push(head);
                    last = letter;
                }
                rows.push(fileRow(file, false));
            }
            sections.push(filesSection("Songs", rows, sortControl()));
        }
        return sections;
    }

    /** The first letter of a name without its accents, or # for a digit or a symbol. */
    function letterOf(name) {
        const first = name.normalize("NFD").replace(/[\u0300-\u036f]/g, "").charAt(0).toUpperCase();
        return first >= "A" && first <= "Z" ? first : "#";
    }

    /** Counts of five digits and more are grouped by a narrow no-break space. */
    const spaced = (count) => (count >= 10000 ? String(count).replace(/\B(?=(\d{3})+(?!\d))/g, "\u202f") : String(count));

    function fileRow(file, withFolder) {
        const row = document.createElement("button");
        row.className = "row song-row file-row";
        const texts = document.createElement("div");
        texts.className = "grow";
        const title = document.createElement("div");
        title.className = "song-title";
        title.textContent = file.title;
        texts.append(title);
        if (withFolder) {
            const folder = document.createElement("div");
            folder.className = "song-artist";
            folder.textContent = file.folder;
            texts.append(folder);
        }
        row.append(icon("music.note"), texts);
        row.onclick = () => playSong(file, row);
        return row;
    }

    function folderRow(folder) {
        const row = document.createElement("button");
        row.className = "row song-row file-row folder-row";
        const name = document.createElement("div");
        name.className = "grow song-title";
        name.textContent = folder.name;
        const chevron = document.createElement("span");
        chevron.className = "icon chevron";
        row.append(icon("folder"), name, pill(spaced(folder.count)), chevron);
        row.onclick = () => openFolder(folder.id);
        return row;
    }

    function sortControl() {
        const control = document.createElement("div");
        control.className = "sort";
        control.setAttribute("role", "group");
        control.setAttribute("aria-label", "Sort");
        for (const [value, label] of [["name", "Name"], ["added", "Added"]]) {
            const button = document.createElement("button");
            button.textContent = label;
            button.setAttribute("aria-pressed", String(filesSort === value));
            button.onclick = () => {
                if (filesSort === value) return;
                filesSort = value;
                try {
                    localStorage.setItem(SORT_KEY, value);
                } catch {}
                loadFiles(scrollY);
            };
            control.append(button);
        }
        return control;
    }

    /** The letters of the headings down the right edge. A touch on one, or a slide along them, scrolls to its songs. */
    function drawLetters() {
        const heads = [...$("files-list").querySelectorAll(".letter-head")];
        const strip = $("files-letters");
        strip.hidden = heads.length < 2;
        strip.replaceChildren(...heads.map((head) => {
            const letter = document.createElement("span");
            letter.textContent = head.dataset.letter;
            return letter;
        }));
    }

    function scrollToLetter(event) {
        const target = document.elementFromPoint(innerWidth - 12, event.clientY);
        const letter = target?.closest?.("#files-letters span")?.textContent;
        if (!letter) return;
        const head = $("files-list").querySelector(`.letter-head[data-letter="${CSS.escape(letter)}"]`);
        if (!head) return;
        // The heading stops under the bar with the search bar, which stays at the top.
        head.style.scrollMarginTop = `${$("files").querySelector(".files-top").offsetHeight}px`;
        head.scrollIntoView({ block: "start" });
    }

    $("files-letters").addEventListener("pointerdown", (event) => {
        event.preventDefault();
        $("files-letters").setPointerCapture(event.pointerId);
        scrollToLetter(event);
    });
    $("files-letters").addEventListener("pointermove", (event) => {
        if ($("files-letters").hasPointerCapture(event.pointerId)) scrollToLetter(event);
    });

    // MARK: Wiring

    // Opening the song that the Mac plays moves it to the phone, like a new one. A paused song moves on Play.
    $("now").onclick = () => {
        if (state?.playing) preferPhone();
        openSong();
    };
    $("close").onclick = () => (sheet ? closeSheet() : history.back());
    addEventListener("popstate", () => {
        if (open && history.state?.song !== true) closeSong();
        else if (!open && history.state?.files !== true && !$("files").hidden) {
            show("home");
            loadSongs();
        } else if (!open && history.state?.files === true && (history.state.dir ?? null) !== filesDir) {
            // Back from a folder to the one that holds it, at the place in the list that it was left at.
            filesDir = history.state.dir ?? null;
            $("files-search").value = "";
            loadFiles(history.state.scroll ?? 0);
        }
    });
    $("files-close").onclick = () => history.back();
    $("wide-step").addEventListener("click", (event) => {
        const button = event.target.closest("button[data-step]");
        if (button) setSpeed(speed + Number(button.dataset.step) / 100);
    });
    tempoSlider();
    dockHandle();
    $("speed-reset").onclick = () => setSpeed(1);
    $("key-reset").onclick = () => setKey(0, false);
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
        if (!file) return;
        preferPhone();
        sendFile(file);
    };
    $("mac-files").onclick = openFiles;
    $("install-button").onclick = async () => {
        // Without the browser's dialog, the steps of Chrome's menu take the button's place.
        if (!installPrompt) {
            installSteps = true;
            return drawInstall();
        }
        // The event works once: a second prompt() on it throws.
        const prompt = installPrompt;
        installPrompt = null;
        try {
            await prompt.prompt();
            const { outcome } = await prompt.userChoice;
            report(`install: ${outcome}`, "info");
            if (outcome === "accepted") return hideInstall();
        } catch (error) {
            report(`install: ${error.message}`);
            installSteps = true;
        }
        drawInstall();
    };
    $("install-hide").onclick = hideInstall;
    $("files-search").oninput = () => {
        clearTimeout(filesTimer);
        filesTimer = setTimeout(loadFiles, 200);
    };
    $("out-mac").onclick = () => {
        showOutputMenu(false);
        pickOutput("mac");
    };
    $("out-phone").onclick = () => {
        showOutputMenu(false);
        $("output-button").classList.remove("failed");
        pickOutput("phone");
    };
    $("output-button").onclick = (event) => {
        event.stopPropagation();
        showOutputMenu($("output-menu").hidden);
    };
    document.addEventListener("pointerdown", (event) => {
        if (!$("output-menu").hidden && !event.target.closest("#output-menu, #output-button")) showOutputMenu(false);
    });
    loopButton();
    stepButton("mac-back", -1);
    stepButton("mac-forward", 1);
    $("save").onclick = save;
    $("mac-play").onclick = () => {
        if (!state) return;
        // The glyph changes at once, and the next state from the Mac confirms it.
        const action = state.playing ? "pause" : "play";
        if (action === "play") preferPhone();
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
    // The record stays above the closed dock, whose height changes with the waveforms of the instruments.
    new ResizeObserver(() => {
        measureDock();
        drawTranscribeArt();
    }).observe($("dock"));

    // The song view's symbols are fetched while the home view shows, so that its icons are there when a song opens.
    for (const name of [...STEMS.map((s) => s.symbol), "chevron.left", "chevron.right", "play.fill", "pause.fill", "macbook", "iphone", "music.note", "minus", "plus", "gobackward.5", "goforward.5", "repeat", "checkmark", "exclamationmark.triangle.fill", "square.and.arrow.up", "arrow.counterclockwise"]) {
        new Image().src = `/api/symbol/${name}`;
    }

    // A reload keeps the history entry of the view that was open, and the page always starts on the home view.
    if (history.state !== null) history.replaceState(null, "");
    loadSongs();
    refreshState();
    // A locked phone that plays the Mac's sound keeps asking too, so that its lock screen shows the next song.
    setInterval(() => { if (document.visibilityState === "visible" || output === "phone") refreshState(); }, 1500);
    document.addEventListener("visibilitychange", () => { if (document.visibilityState === "visible") refreshState(); });
})();
