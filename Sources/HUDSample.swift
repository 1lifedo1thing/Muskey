import AppKit
import SwiftUI

/// The real HUD with a made-up song, for the pictures in Settings > HUD: the same view as the panel, with its glass,
/// scaled down to fit a tile and cropped to the glass.
@MainActor enum HUDSample {
    static let track = NowPlaying.Track(title: "Paper Lanterns", artist: "Mira Vale", album: "Low Tide Radio", duration: 238, elapsed: 102,
                                        timestamp: Date().timeIntervalSince1970, rate: 0, bundleID: nil)
    static let cover = sampleCover()

    /// C♯ minor moved 3 semitones down, with the key picker open, as in the HUD after a listen.
    static func model(card: Bool, relative: Bool) -> HUDModel {
        let model = HUDModel()
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
        let id = "\(card) \(relative) \(scheme)"
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
    @Environment(\.colorScheme) private var scheme
    @State private var model: HUDModel

    init(card: Bool, relative: Bool, keysOnly: Bool = false) {
        self.card = card
        self.relative = relative
        self.keysOnly = keysOnly
        _model = State(initialValue: HUDSample.model(card: card, relative: relative))
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
}
