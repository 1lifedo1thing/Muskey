import AppKit
import SwiftUI

/// The real HUD with a made-up song, for the pictures in Settings > HUD: the same view as the panel, with its glass,
/// scaled down to fit a tile and cropped to the glass.
@MainActor enum HUDSample {
    static let track = NowPlaying.Track(title: "Paper Lanterns", artist: "Mira Vale", album: "Low Tide Radio", duration: 238, elapsed: 102,
                                        timestamp: Date().timeIntervalSince1970, rate: 0, bundleID: nil)
    static let cover = sampleCover()

    /// A queue of seven songs for the renders, with the second one playing, one still waiting for its key, and one
    /// link that isn't downloaded yet.
    static let queue: [QueueItem] = {
        let songs: [(String, String, Double, Int, Bool, Double?, (Double, Double, Double)?)] = [
            ("Copper Kettle", "Odd Harbour", 201, 7, false, 98, (0.72, 0.42, 0.2)),
            ("Paper Lanterns", "Mira Vale", 238, 1, true, 124, nil),
            ("Night Bus", "The Lindens", 187, 2, false, 132, (0.2, 0.24, 0.45)),
            ("Orchard Road", "Saffron June", 254, 9, true, 86, (0.38, 0.55, 0.3)),
            ("Lowlight", "Marrow & Pine", 223, 4, false, 110, (0.5, 0.3, 0.45)),
            ("Tidewater", "Hollis Gray", 266, 0, false, nil, (0.25, 0.45, 0.55)),
            ("Slow Parade", "Ines Calder", 0, 0, false, nil, nil),
        ]
        return songs.enumerated().map { index, song in
            var item = QueueItem(url: URL(fileURLWithPath: "/Music/\(song.0).m4a"), cached: nil)
            item.title = song.0
            item.artist = song.1
            item.duration = song.2 > 0 ? song.2 : nil
            item.read = true
            item.artwork = index == 1 ? cover : song.6.flatMap { sampleTile(red: $0.0, green: $0.1, blue: $0.2) }
            item.analysed = song.5 != nil
            item.key = song.5 == nil ? nil : DetectedKey(pitchClass: song.3, minor: song.4)
            item.bpm = song.5
            return item
        }
    }()

    private static func sampleTile(red: Double, green: Double, blue: Double) -> NSImage? {
        let base = Color(red: red, green: green, blue: blue)
        let tile = ZStack {
            LinearGradient(colors: [base.mix(with: .white, by: 0.25), base, base.mix(with: .black, by: 0.35)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().fill(.white.opacity(0.18)).frame(width: 26, height: 26).offset(x: 12, y: -10)
        }
        .frame(width: 60, height: 60)
        let renderer = ImageRenderer(content: tile)
        renderer.scale = 2
        return renderer.nsImage
    }

    /// A made-up waveform for the sample song: verses, a louder chorus in the middle, and a beat at 124 BPM.
    static let waveform: SongWaveform = {
        var levels = Data(count: SongWaveform.slots(for: 238))
        var seed: UInt64 = 7
        for i in 0 ..< levels.count {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let noise = Double(seed >> 33) / Double(1 << 31)
            let t = Double(i) / SongWaveform.rate
            let section = t < 8 ? t / 8 * 0.4 : 0.5 + 0.2 * sin(t / 17) + (t > 62 && t < 104 || t > 160 && t < 202 ? 0.25 : 0)
            let beat = 0.72 + 0.28 * pow(max(0, cos(t * .pi * 2 * 124 / 60)), 8)
            levels[i] = UInt8(min(255, max(1, section * beat * (0.78 + 0.22 * noise) * 250)))
        }
        return SongWaveform(duration: 238, levels: levels)
    }()

    /// C♯ minor moved 3 semitones down, with the key picker open, as in the HUD after a listen.
    static func model(card: Bool, relative: Bool, waveform: (shown: Bool, style: WaveformStyle)? = nil) -> HUDModel {
        let model = HUDModel()
        model.wave.waveform = Self.waveform
        model.waveformShown = waveform?.shown ?? Preferences.shared.waveform
        model.waveformStyle = waveform?.style ?? Preferences.shared.waveformStyle
        model.card = card
        model.relativeKeys = relative
        model.phase = .done
        model.key = DetectedKey(pitchClass: 1, minor: true)
        model.progress = 1
        model.shift = -3
        model.picking = true
        model.track = track
        model.artwork = cover
        model.playing = true
        return model
    }

    private static var glassRects: [String: CGRect] = [:]

    /// Where the glass sits in the panel, in points, from a render with a flat stand-in for the glass, which is
    /// opaque where the glass is and clear around it.
    static func glass(card: Bool, relative: Bool, scheme: ColorScheme) -> CGRect? {
        let id = "\(card) \(relative) \(scheme) \(Preferences.shared.waveform)"
        if let rect = glassRects[id] { return rect }
        let view = HUDView(model: model(card: card, relative: relative))
            .frame(width: HUDPanel.size.width, height: HUDPanel.size.height)
            .environment(\.colorScheme, scheme)
            .environment(\.renderingPreview, true)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        guard let image = renderer.cgImage, let rect = opaqueBounds(image) else { return nil }
        glassRects[id] = rect
        return rect
    }

    /// The bounds of the pixels that are mostly opaque, which leaves out the soft shadow around the glass.
    private static func opaqueBounds(_ image: CGImage) -> CGRect? {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0 ..< height {
            for x in 0 ..< width where pixels[(y * width + x) * 4 + 3] > 200 {
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        // The bitmap's rows run from the top, like the view's points.
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
}

/// The live HUD in a tile, with its own model, so nothing in it reaches the real HUD. `keysOnly` shows the key column of
/// the wide layout without the record.
struct HUDSampleView: View {
    let card: Bool
    let relative: Bool
    var keysOnly = false
    /// The waveform as a tile in Settings shows it, or nil for the waveform that Settings has.
    var waveform: (shown: Bool, style: WaveformStyle)?
    @Environment(\.colorScheme) private var scheme
    @State private var model: HUDModel

    init(card: Bool, relative: Bool, keysOnly: Bool = false, waveform: (shown: Bool, style: WaveformStyle)? = nil) {
        self.card = card
        self.relative = relative
        self.keysOnly = keysOnly
        self.waveform = waveform
        _model = State(initialValue: HUDSample.model(card: card, relative: relative, waveform: waveform))
    }

    var body: some View {
        GeometryReader { proxy in
            if let glass = HUDSample.glass(card: card, relative: relative, scheme: scheme) {
                let shown = keysOnly ? CGRect(x: glass.minX, y: glass.minY, width: glass.width * 0.68, height: glass.height) : glass
                let room = CGSize(width: proxy.size.width - 20, height: proxy.size.height - 20)
                let scale = min(room.width / shown.width, room.height / shown.height)
                HUDView(model: model)
                    .frame(width: HUDPanel.size.width, height: HUDPanel.size.height)
                    .allowsHitTesting(false)
                    .scaleEffect(scale, anchor: .topLeading)
                    .offset(x: proxy.size.width / 2 - shown.midX * scale, y: proxy.size.height / 2 - shown.midY * scale)
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                    .mask {
                        RoundedRectangle(cornerRadius: keysOnly ? 8 : 26 * scale, style: .continuous)
                            .frame(width: shown.width * scale + (keysOnly ? 0 : 12), height: shown.height * scale + (keysOnly ? 0 : 12))
                    }
            }
        }
        .onChange(of: relative) { model.relativeKeys = relative }
        .accessibilityHidden(true)
    }
}

/// The wallpaper of the main screen, for the pictures of the HUD, which floats over it.
@MainActor enum Wallpaper {
    /// Read at most 1200 pixels wide, since a wallpaper can be 6K and the tiles are small.
    static let image: NSImage? = {
        guard let screen = NSScreen.main, let url = NSWorkspace.shared.desktopImageURL(for: screen),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                          kCGImageSourceThumbnailMaxPixelSize: 1200] as CFDictionary)
        else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }()

    /// Small thumbnails of each screen's wallpaper, by the wallpaper's file, for reading how light a part of it is.
    private static var thumbnails: [URL: CGImage] = [:]

    private static func thumbnail(for screen: NSScreen) -> CGImage? {
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        if let cached = thumbnails[url] { return cached }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                          kCGImageSourceThumbnailMaxPixelSize: 400] as CFDictionary)
        else { return nil }
        thumbnails[url] = image
        return image
    }

    /// The average luminance, from 0 to 1, of the wallpaper under `rect` (in screen points, as NSScreen frames are),
    /// or of the main screen's whole wallpaper. The wallpaper is taken to fill its screen, which is how macOS shows it
    /// unless it was set to fit or to tile.
    static func luminance(under rect: CGRect? = nil, on screen: NSScreen? = nil) -> Double? {
        guard let screen = screen ?? NSScreen.main, let image = thumbnail(for: screen) else { return nil }
        let frame = screen.frame
        let width = CGFloat(image.width), height = CGFloat(image.height)
        var crop = CGRect(x: 0, y: 0, width: width, height: height)
        if let rect {
            let scale = max(width / frame.width, height / frame.height)
            let left = (width - frame.width * scale) / 2, top = (height - frame.height * scale) / 2
            crop = CGRect(x: left + (rect.minX - frame.minX) * scale, y: top + (frame.maxY - rect.maxY) * scale,
                          width: rect.width * scale, height: rect.height * scale).intersection(crop).integral
        }
        guard !crop.isEmpty, let part = image.cropping(to: crop) else { return nil }
        // Drawn down to 4 by 4 pixels, which averages the part well enough for a choice of text colour.
        var pixels = [UInt8](repeating: 0, count: 4 * 4 * 4)
        guard let context = CGContext(data: &pixels, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .medium
        context.draw(part, in: CGRect(x: 0, y: 0, width: 4, height: 4))
        var total = 0.0
        for index in 0 ..< 16 {
            let pixel = index * 4
            total += MiniBackground.luminance(red: Double(pixels[pixel]) / 255, green: Double(pixels[pixel + 1]) / 255, blue: Double(pixels[pixel + 2]) / 255)
        }
        return total / 16
    }
}
