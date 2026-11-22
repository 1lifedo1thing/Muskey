import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// A song in the queue: a file, or a link that is downloaded once it plays.
struct QueueItem: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    var title: String
    var artist: String?
    var album: String?
    var duration: Double?
    var artwork: NSImage?
    /// The key and the tempo, from the keys Muskey remembers or a short listen of the file in the background.
    var key: DetectedKey?
    var bpm: Double?
    /// The details were read from the file, so they aren't read again.
    var read = false
    /// The key and the tempo were looked for.
    var analysed = false

    init(url: URL, cached: FilePlayer.Song?) {
        self.url = url
        // A link to a file is named by the file, and a page by its site until it is downloaded.
        title = url.isFileURL ? url.deletingPathExtension().lastPathComponent
            : SongName.link(url) ?? (url.host() ?? url.absoluteString).replacingOccurrences(of: "www.", with: "")
        if let cached { apply(cached: cached) }
    }

    /// The file that plays: the file itself, or the download of a link once it is downloaded.
    var file: URL? { url.isFileURL ? url : downloaded.map { URL(fileURLWithPath: $0) } }
    private var downloaded: String?

    mutating func apply(cached song: FilePlayer.Song) {
        downloaded = song.path
        if let title = song.title { self.title = title }
        artist = song.artist ?? artist
        album = song.album ?? album
        if artwork == nil, let path = song.artwork { artwork = NSImage(contentsOfFile: path) }
        read = false
    }

    struct Details {
        var title: String?
        var artist: String?
        var album: String?
        var duration: Double?
        var artwork: NSImage?
    }

    mutating func apply(_ details: Details?) {
        read = true
        guard let details else { return }
        title = details.title ?? title
        artist = details.artist ?? artist
        album = details.album ?? album
        duration = details.duration ?? duration
        artwork = artwork ?? details.artwork
    }

    /// The title, artist, album, length and cover that a file carries. A link has them once it is downloaded.
    /// A file without a title is named by `name`, or by its file without one: a download is named by its link.
    static func details(_ url: URL, name: String? = nil) async -> Details? {
        guard url.isFileURL else { return nil }
        let asset = AVURLAsset(url: url)
        let items = (try? await asset.load(.commonMetadata)) ?? []
        func string(_ key: AVMetadataKey) async -> String? {
            guard let item = AVMetadataItem.metadataItems(from: items, withKey: key, keySpace: .common).first else { return nil }
            let value = try? await item.load(.stringValue)
            return value?.isEmpty == false ? value : nil
        }
        var details = Details()
        details.title = await string(.commonKeyTitle)
        details.artist = await string(.commonKeyArtist)
        details.album = await string(.commonKeyAlbumName)
        if let seconds = try? await asset.load(.duration).seconds, seconds.isFinite, seconds > 0 { details.duration = seconds }
        if let item = AVMetadataItem.metadataItems(from: items, withKey: AVMetadataKey.commonKeyArtwork, keySpace: .common).first,
           let data = try? await item.load(.dataValue)
        {
            details.artwork = NSImage(data: data)
        }
        // A file without a title is named after the file, and a name like `Artist - Title` gives both.
        if details.title == nil {
            let named = SongName.split(name ?? url.deletingPathExtension().lastPathComponent)
            if details.artist == nil, let artist = named.artist {
                details.artist = artist
                details.title = named.title
            } else if name != nil {
                details.title = name
            }
        }
        return details
    }

    static func == (a: QueueItem, b: QueueItem) -> Bool {
        a.id == b.id && a.title == b.title && a.artist == b.artist && a.album == b.album && a.duration == b.duration
            && a.artwork === b.artwork && a.key == b.key && a.bpm == b.bpm && a.read == b.read && a.analysed == b.analysed
    }

    /// The key and the tempo of a file, from 30 seconds of it a third of the way in, the part where most songs settle
    /// into their key. About a tenth of a second of work, read off the main thread.
    static func analyse(_ file: URL, duration: Double?) async -> (key: DetectedKey?, bpm: Double?) {
        let length = duration ?? 180
        let from = max(0, length * 0.33 - 5)
        let samples = await LoopSnap.excerpt(file, from: from, to: min(length, from + 30))
        guard samples.count > Int(LoopSnap.rate * 8) else { return (nil, nil) }
        let result = samples.withUnsafeBufferPointer { ek_key($0.baseAddress, UInt32($0.count), LoopSnap.rate, KeyAnalyzer.profile) }
        let bpm = TempoDetector.bpm(samples, sourceRate: LoopSnap.rate)?.bpm
        return (DetectedKey(result), bpm)
    }
}

/// The queue, on the back of the record side of the wide layout and on the back of the card. A click selects a
/// song, ⌘ and ⇧ add to the selection, a drag moves the selected songs, a double click plays one, ⌫ removes the
/// selection, and a sideways swipe on a song removes it (to the left) or plays it next (to the right).
struct QueueView: View {
    let songs: [QueueItem]
    let current: UUID?
    @Binding var selection: Set<UUID>
    let palette: Palette
    var compact = false
    let play: (UUID) -> Void
    let remove: (Set<UUID>) -> Void
    let move: (Set<UUID>, Int) -> Void
    let playNext: (UUID) -> Void
    let close: () -> Void
    /// Where the list is in the window, or nil once it is gone.
    var frame: (CGRect?) -> Void = { _ in }
    /// Room at the start of the title row, for the ✕ of the card in its corner.
    var headerInset: CGFloat = 0

    @Environment(\.colorScheme) private var scheme
    @Environment(\.renderingPreview) private var renderingPreview
    @Environment(\.cornerLabelsShown) private var labelsShown
    @State private var closeHovered = false
    private var closeOpen: Bool { closeHovered || labelsShown }

    private var total: Double { songs.compactMap(\.duration).reduce(0, +) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Queue")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(palette.ink)
                Text(summary)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(palette.muted)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
                    // The pill of Close queue opens over the count, which steps aside while it shows.
                    .opacity(closeOpen ? 0 : 1)
                    .animation(.easeOut(duration: 0.15), value: closeOpen)
                Spacer(minLength: 0)
                Color.clear.frame(width: 20, height: 20)
            }
            .overlay(alignment: .trailing) {
                RoundButton(symbol: "xmark", help: "Close the queue (Q)", label: "Close queue", key: "Q", palette: palette, action: close)
                    .onHover { closeHovered = $0 }
            }
            .padding(.horizontal, 4)
            .padding(.leading, headerInset)
            if songs.isEmpty {
                Text("Drop songs here to add them")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(palette.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if renderingPreview {
                // ImageRenderer draws no list, so `--render` gets the rows stacked.
                VStack(spacing: 2) { ForEach(songs) { row($0) } }
                    .frame(maxHeight: .infinity, alignment: .top)
            } else {
                list
            }
        }
    }

    private var summary: String {
        let minutes = Int((total / 60).rounded())
        return "\(songs.count) song\(songs.count == 1 ? "" : "s")" + (total > 0 ? " · \(minutes) min" : "")
    }

    private var list: some View {
        List(selection: $selection) {
            ForEach(songs) { song in
                row(song)
                    .tag(song.id)
                    .listRowInsets(EdgeInsets(top: 1, leading: 2, bottom: 1, trailing: 2))
                    .listRowSeparator(.hidden)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) { remove([song.id]) } label: { Label("Remove", systemImage: "trash") }
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button { playNext(song.id) } label: { Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") }
                            .tint(StripColors.solid(.honey, scheme).fill)
                    }
            }
            .onMove { from, to in
                let ids = Set(from.map { songs[$0].id })
                move(ids, to)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, compact ? 34 : 38)
        .contextMenu(forSelectionType: UUID.self) { ids in
            if let id = ids.first, ids.count == 1 {
                Button("Play") { play(id) }
                Button("Play Next") { playNext(id) }
            }
            Button(ids.count > 1 ? "Remove \(ids.count) Songs" : "Remove", role: .destructive) { remove(ids) }
        } primaryAction: { ids in
            if let id = ids.first { play(id) }
        }
        .onDeleteCommand { remove(selection) }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame($0) }
        .onDisappear { frame(nil) }
    }

    private func row(_ song: QueueItem) -> some View {
        let playing = song.id == current
        return HStack(spacing: 8) {
            ZStack {
                if let artwork = song.artwork {
                    Image(nsImage: artwork).resizable().aspectRatio(contentMode: .fill)
                } else {
                    palette.ink.opacity(0.1)
                    Image(systemName: "music.note").font(.system(size: 11, weight: .semibold)).foregroundStyle(palette.muted)
                }
                if playing {
                    Color.black.opacity(0.35)
                    Image(systemName: "waveform").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                }
            }
            .frame(width: compact ? 28 : 30, height: compact ? 28 : 30)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(song.title)
                    .font(.system(size: 12, weight: playing ? .heavy : .bold, design: .rounded))
                    .foregroundStyle(playing ? StripColors.text(.honey, scheme) : palette.ink)
                if let artist = song.artist {
                    Text(artist)
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(palette.muted)
                }
            }
            .lineLimit(1)
            .truncationMode(.tail)
            Spacer(minLength: 2)
            VStack(alignment: .trailing, spacing: 1) {
                if let key = song.key {
                    Text(key.short)
                        .font(.system(size: 10.5, weight: .heavy, design: .rounded))
                        .foregroundStyle(palette.ink.opacity(0.85))
                }
                if let bpm = song.bpm {
                    Text("\(Int(bpm.rounded()))")
                        .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(palette.muted)
                        .monospacedDigit()
                } else if !song.analysed {
                    ProgressView().controlSize(.mini).scaleEffect(0.6).frame(width: 12, height: 10)
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .help([song.title, song.artist, song.album].compactMap { $0 }.joined(separator: " · "))
    }
}

/// Turns a view over around its vertical axis like a record sleeve: the front until it is edge on, then the back,
/// drawn the right way round. With Reduce Motion on, the two crossfade.
struct FlipCard<Front: View, Back: View>: View {
    let flipped: Bool
    @ViewBuilder var front: Front
    @ViewBuilder var back: Back
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            front
                .opacity(flipped ? 0 : 1)
                .overlay { back.opacity(flipped ? 1 : 0) }
                .animation(.easeOut(duration: 0.15), value: flipped)
        } else {
            Turn(angle: flipped ? 180 : 0, front: front, back: back)
                .animation(FlipCard.turn, value: flipped)
        }
    }

    /// The turn of the queue: short, since Q opens it many times, and without a bounce.
    static var turn: Animation { .smooth(duration: 0.38) }
}

/// The turn itself. The front keeps its place in the layout, and the back is laid over it, so both sides have the
/// size of the front.
private struct Turn<Front: View, Back: View>: View, Animatable {
    var angle: Double
    let front: Front
    let back: Back
    var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }

    var body: some View {
        let backShown = angle > 90
        // At rest neither side is rotated, so the list of the queue takes clicks and scrolls where it is drawn.
        let turning = angle > 0 && angle < 180
        front
            .opacity(backShown ? 0 : 1)
            .allowsHitTesting(!backShown)
            .overlay {
                back
                    .opacity(backShown ? 1 : 0)
                    .allowsHitTesting(backShown)
                    .rotation3DEffect(.degrees(turning ? 180 : 0), axis: (0, 1, 0))
            }
            .rotation3DEffect(.degrees(turning ? angle : 0), axis: (0, 1, 0), perspective: 0.4)
    }
}

/// Where a drop lands, from the two zones that a drag of songs over the HUD shows.
enum DropZone: Equatable {
    case playNow
    case add
    /// The add zone with ⌥ held: the songs go right after the song that plays.
    case addNext
}

/// The two zones that cover the HUD while songs are dragged over it: Play Now on the left, which replaces the queue,
/// and Add to Queue on the right, which adds them at its end, or after the song that plays with ⌥ held. With no queue
/// to add to (`zone` nil), Play Now alone covers the HUD.
struct DropZones: View {
    let zone: DropZone?
    let palette: Palette
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 12) {
            if let zone {
                tile("Play Now", symbol: "play.fill", detail: "replaces the queue", hot: zone == .playNow)
                tile(zone == .addNext ? "Play Next" : "Add to Queue", symbol: zone == .addNext ? "text.line.first.and.arrowtriangle.forward" : "plus",
                     hot: zone == .add || zone == .addNext, hint: true)
            } else {
                tile("Play Now", symbol: "play.fill", hot: true)
            }
        }
        .padding(16)
        .allowsHitTesting(false)
    }

    /// A zone over the blurred HUD: dark and translucent, and amber with the drag over it, so the HUD still shows
    /// through both.
    private func tile(_ title: String, symbol: String, detail: String? = nil, hot: Bool, hint: Bool = false) -> some View {
        let amber = StripColors.solid(.honey, scheme).fill
        // The darker amber of the light scheme's chips reads on the pale zone; the bright one reads on the dark zone.
        let text = hot ? (scheme == .dark ? amber : StripColors.text(.honey, scheme)) : palette.ink
        return VStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .bold))
            Text(title)
                .font(.system(size: 16, weight: .heavy, design: .rounded))
            if let detail {
                Text(detail)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(palette.muted)
            }
            if hint {
                HStack(spacing: 4) {
                    Keycap(text: "⌥", palette: palette, small: true)
                    Text("play next")
                }
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(palette.muted)
                .opacity(zone == .addNext ? 0 : 1)
            }
        }
        .foregroundStyle(text)
        .shadow(color: .black.opacity(scheme == .dark ? 0.35 : 0), radius: 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(hot ? amber.opacity(scheme == .dark ? 0.16 : 0.34) : (scheme == .dark ? Color.black.opacity(0.3) : Color.white.opacity(0.5)))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(hot ? amber.opacity(0.9) : palette.ink.opacity(0.35), style: StrokeStyle(lineWidth: 2, dash: [6, 5])))
        }
        .animation(.easeOut(duration: 0.1), value: hot)
    }
}

/// Songs dragged over the HUD. While the queue has songs, the left half plays them now and the right half adds them
/// to the queue, after the song that plays with ⌥ held. With an empty queue, a drop anywhere plays them.
struct SongDrop: DropDelegate {
    let model: HUDModel
    static let types: [UTType] = [.fileURL, .url, .plainText]

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: Self.types) }

    func dropEntered(info: DropInfo) {
        model.dropTargeted = true
        place(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        place(info)
        return DropProposal(operation: .copy)
    }

    func dropExited(info _: DropInfo) {
        model.dropTargeted = false
        model.dropZone = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        let zone = model.dropZone
        model.dropTargeted = false
        model.dropZone = nil
        let providers = info.itemProviders(for: Self.types)
        guard !providers.isEmpty else { return false }
        let model = model
        Task { @MainActor in
            var urls: [URL] = []
            // In the order they were dragged, which is the order they play in.
            for provider in providers {
                if let song = await Self.load(provider) { urls.append(song.url) }
            }
            guard !urls.isEmpty else { return }
            switch zone {
            case .add: model.onAdd(urls, false)
            case .addNext: model.onAdd(urls, true)
            case .playNow, nil: model.onOpen(urls)
            }
        }
        return true
    }

    private func place(_ info: DropInfo) {
        guard !model.queue.isEmpty, !model.otherPlayer else { return model.dropZone = nil }
        let width = model.glassFrame.width
        model.dropZone = info.location.x < width / 2 ? .playNow : NSEvent.modifierFlags.contains(.option) ? .addNext : .add
    }

    private static func load(_ provider: NSItemProvider) async -> DroppedSong? {
        await withCheckedContinuation { continuation in
            _ = provider.loadTransferable(type: DroppedSong.self) { result in
                continuation.resume(returning: try? result.get())
            }
        }
    }
}
