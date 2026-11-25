import AppKit
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What makes the web remote installable as an app on a phone: the manifest, the icons, the launch screens that an
/// iPhone needs one of for each screen size, and the service worker that shows a page of its own when the Mac is out of
/// reach. Drawn from the artwork of Muskey's icon, which the build copies to Web/app-icon.png. The page's own side of
/// it (the insets of an installed app, the install row) is in remote.js.
enum WebApp {
    struct Device {
        init(_ width: Int, _ height: Int, _ scale: Int) {
            self.width = width
            self.height = height
            self.scale = scale
        }

        let width: Int
        let height: Int
        let scale: Int
    }

    /// Every iPhone and iPad in use, by screen size in points and pixel density. iOS makes no launch screen from the
    /// manifest the way Android does: without an image whose media query matches the device exactly, the app opens on a
    /// blank white page.
    static let devices: [Device] = [
        Device(320, 568, 2), // iPhone SE (1st)
        Device(375, 667, 2), // iPhone 8, SE (2nd and 3rd)
        Device(414, 736, 3), // iPhone 8 Plus
        Device(375, 812, 3), // iPhone X, XS, 11 Pro, 12 mini, 13 mini
        Device(414, 896, 2), // iPhone XR, 11
        Device(414, 896, 3), // iPhone XS Max, 11 Pro Max
        Device(390, 844, 3), // iPhone 12, 13, 14, 16e
        Device(428, 926, 3), // iPhone 12 Pro Max, 13 Pro Max, 14 Plus
        Device(393, 852, 3), // iPhone 14 Pro, 15, 15 Pro, 16
        Device(430, 932, 3), // iPhone 14 Pro Max, 15 Plus, 15 Pro Max, 16 Plus
        Device(402, 874, 3), // iPhone 16 Pro, 17, 17 Pro
        Device(420, 912, 3), // iPhone Air
        Device(440, 956, 3), // iPhone 16 Pro Max, 17 Pro Max
        Device(744, 1133, 2), // iPad mini (6th and 7th)
        Device(768, 1024, 2), // iPad mini (5th), older iPads
        Device(810, 1080, 2), // iPad (7th to 9th)
        Device(820, 1180, 2), // iPad (10th), iPad Air 10.9 and 11
        Device(834, 1112, 2), // iPad Pro 10.5, iPad Air (3rd)
        Device(834, 1194, 2), // iPad Pro 11 (1st to 4th)
        Device(834, 1210, 2), // iPad Pro 11 (M4 and later)
        Device(1024, 1366, 2), // iPad Pro 12.9, iPad Air 13
        Device(1032, 1376, 2), // iPad Pro 13 (M4 and later)
    ]

    /// The page's background in each appearance (`--bg` in remote.css), so the launch screen hands over to the page
    /// without a flash.
    static let lightBackground = "#faf4f0"
    static let darkBackground = "#110f10"

    /// Changes with every build, so a phone fetches the icons and launch screens of a new version.
    static let version = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"

    /// The tags that describe the page as an app, put in place of `<!-- app -->` in its head. iOS reads the Home Screen
    /// icon from these rather than the manifest, and picks a launch screen by media query.
    static let head: String = {
        var tags = [
            // With credentials, so the manifest can carry the link that pairs the installed app (see `manifest`).
            #"<link rel="manifest" href="/manifest.webmanifest?v=\#(version)" crossorigin="use-credentials">"#,
            #"<link rel="icon" type="image/png" sizes="64x64" href="/favicon.png?v=\#(version)">"#,
            #"<link rel="apple-touch-icon" href="/apple-touch-icon.png?v=\#(version)">"#,
        ]
        for dark in [false, true] {
            for device in devices {
                for landscape in [false, true] {
                    let (width, height) = splashSize(device, landscape: landscape)
                    let media = "(prefers-color-scheme: \(dark ? "dark" : "light")) and (device-width: \(device.width)px) and (device-height: \(device.height)px) and (-webkit-device-pixel-ratio: \(device.scale)) and (orientation: \(landscape ? "landscape" : "portrait"))"
                    tags.append(#"<link rel="apple-touch-startup-image" media="\#(media)" href="/splash/\#(width)x\#(height)-\#(dark ? "dark" : "light").png?v=\#(version)">"#)
                }
            }
        }
        return tags.joined(separator: "\n")
    }()

    /// `startURL` is the pairing link for a phone that is paired already: iOS gives an installed app cookies of its own,
    /// so the app has to pair itself each time it opens rather than count on Safari's cookie. Its `id` stays put, so a
    /// new key doesn't make it a different app.
    static func manifest(name: String, startURL: String) -> Data {
        let manifest: [String: Any] = [
            "id": "/",
            "name": name,
            "short_name": "Muskey",
            "start_url": startURL,
            "scope": "/",
            "display": "standalone",
            "orientation": "any",
            "background_color": lightBackground,
            "theme_color": lightBackground,
            "icons": [
                ["src": "/icon-192.png?v=\(version)", "sizes": "192x192", "type": "image/png", "purpose": "any"],
                ["src": "/icon-512.png?v=\(version)", "sizes": "512x512", "type": "image/png", "purpose": "any"],
                ["src": "/icon-maskable-512.png?v=\(version)", "sizes": "512x512", "type": "image/png", "purpose": "maskable"],
            ],
        ]
        return (try? JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }

    /// Keeps a page that says the Mac is out of reach, so an installed app shows it instead of the browser's error,
    /// which has no way back. Everything else goes to the network untouched. Browsers run a service worker over HTTPS
    /// only, so the page registers it on the Tailscale name.
    static let serviceWorker = """
    const VERSION = "muskey-\(version)";
    const SHELL = ["/offline", "/favicon.png?v=\(version)"];

    self.addEventListener("install", (event) => {
        event.waitUntil(caches.open(VERSION).then((cache) => cache.addAll(SHELL)).then(() => self.skipWaiting()));
    });

    self.addEventListener("activate", (event) => {
        event.waitUntil(
            caches.keys()
                .then((keys) => Promise.all(keys.filter((key) => key !== VERSION).map((key) => caches.delete(key))))
                .then(() => self.clients.claim())
        );
    });

    self.addEventListener("fetch", (event) => {
        const request = event.request;
        if (request.method !== "GET" || request.mode !== "navigate") return;
        const url = new URL(request.url);
        if (url.origin !== self.location.origin) return;
        if (url.pathname === "/" || url.pathname.startsWith("/pair/")) {
            event.respondWith(fetch(request).catch(() => caches.match("/offline")));
        }
    });
    """

    /// The page that the service worker shows while the Mac doesn't answer, with its own styles, since nothing else of
    /// the page loads then.
    static let offlinePage = """
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover">
    <meta name="color-scheme" content="light dark">
    <title>Muskey</title>
    <style>
    :root { --ink: rgb(33 20 26); --muted: rgb(74 51 61 / 0.8); --bg: rgb(250 244 240); --honey: oklch(0.84 0.13 74); --honey-ink: rgb(46 28 8);
        font-family: ui-rounded, "SF Pro Rounded", system-ui, -apple-system, "Segoe UI", Roboto, sans-serif; }
    @media (prefers-color-scheme: dark) { :root { --ink: rgb(255 247 245); --muted: rgb(232 217 219 / 0.75); --bg: rgb(17 15 16); } }
    html, body { margin: 0; height: 100%; background: var(--bg); color: var(--ink); touch-action: pan-x pan-y; -webkit-user-select: none; user-select: none; }
    body { display: grid; place-items: center; text-align: center; padding: 24px; box-sizing: border-box; }
    img { width: 88px; height: 88px; border-radius: 20px; }
    h1 { margin: 18px 0 20px; font-size: 22px; font-weight: 700; }
    button { height: 44px; padding: 0 22px; border: 0; border-radius: 22px; background: var(--honey); color: var(--honey-ink); font: inherit; font-size: 17px; font-weight: 700; }
    </style>
    </head>
    <body>
    <div>
    <img src="/favicon.png?v=\(version)" alt="">
    <h1>Mac unreachable</h1>
    <button onclick="location.reload()">Retry</button>
    </div>
    </body>
    </html>
    """

    /// The pixel size and appearance that a /splash/ name asks for, when it is one of the launch screens that `head`
    /// links to. Anything else is refused, so nobody can make the Mac draw images of any size.
    static func splashSpec(_ name: String) -> (width: Int, height: Int, dark: Bool)? {
        let parts = name.split(separator: "-")
        guard parts.count == 2, ["light", "dark"].contains(parts[1]) else { return nil }
        let size = parts[0].split(separator: "x").compactMap { Int($0) }
        guard size.count == 2 else { return nil }
        let known = devices.contains { device in
            [false, true].contains { splashSize(device, landscape: $0) == (size[0], size[1]) }
        }
        return known ? (size[0], size[1], parts[1] == "dark") : nil
    }

    private static func splashSize(_ device: Device, landscape: Bool) -> (Int, Int) {
        let (width, height) = (device.width * device.scale, device.height * device.scale)
        return landscape ? (height, width) : (width, height)
    }
}

/// Draws the app's icons and launch screens from the artwork of Muskey's icon, once each.
final class WebAppArt: @unchecked Sendable {
    static let shared = WebAppArt()

    /// The icon as a browser tab and Chrome's app launcher show it: the artwork in a rounded square, with the margin
    /// that a Mac icon has, on a clear background.
    func icon(size: Int, margin: Double = 0.1) -> Data? {
        cached("icon-\(size)-\(margin)") { [self] in
            render(width: size, height: size, opaque: false) { context in
                let inset = Double(size) * margin
                let rect = CGRect(x: inset, y: inset, width: Double(size) - 2 * inset, height: Double(size) - 2 * inset)
                drawRounded(in: context, rect: rect)
            }
        }
    }

    /// Square and opaque: iPhones round the corners themselves, and fill transparency with black.
    func fullBleed(size: Int) -> Data? {
        cached("full-\(size)") { [self] in
            render(width: size, height: size, opaque: true) { context in
                context.interpolationQuality = .high
                context.draw(source!, in: CGRect(x: 0, y: 0, width: size, height: size))
            }
        }
    }

    /// For Android, which cuts the icon to a circle or another shape that keeps only the middle 80 %. The artwork is
    /// drawn at that size, and its background runs out to the edges: each row takes the colours at the edges of the
    /// artwork's row, so the gradient behind the record carries on with no seam.
    func maskable(size: Int) -> Data? {
        cached("maskable-\(size)") { [self] in
            render(width: size, height: size, opaque: true) { context in
                guard let source, let edges else { return }
                context.interpolationQuality = .high
                let side = (Double(size) * 0.8).rounded()
                let inset = ((Double(size) - side) / 2).rounded()
                let art = CGRect(x: inset, y: inset, width: side, height: side)
                // The two edge columns, stretched across the width: the interpolation draws a gradient between them.
                context.draw(edges, in: CGRect(x: 0, y: art.minY, width: Double(size), height: art.height))
                if let top = edges.cropping(to: CGRect(x: 0, y: 0, width: 2, height: 1)),
                   let bottom = edges.cropping(to: CGRect(x: 0, y: edges.height - 1, width: 2, height: 1))
                {
                    context.draw(top, in: CGRect(x: 0, y: art.maxY, width: Double(size), height: Double(size) - art.maxY))
                    context.draw(bottom, in: CGRect(x: 0, y: 0, width: Double(size), height: art.minY))
                }
                context.draw(source, in: art)
            }
        }
    }

    /// The icon over the app's name, centred on the page's background.
    func splash(width: Int, height: Int, dark: Bool) -> Data? {
        cached("splash-\(width)x\(height)-\(dark)") { [self] in
            render(width: width, height: height, opaque: true) { context in
                let background = dark ? CGColor(srgbRed: 17 / 255, green: 15 / 255, blue: 16 / 255, alpha: 1) : CGColor(srgbRed: 250 / 255, green: 244 / 255, blue: 240 / 255, alpha: 1)
                let ink = dark ? CGColor(srgbRed: 1, green: 247 / 255, blue: 245 / 255, alpha: 1) : CGColor(srgbRed: 33 / 255, green: 20 / 255, blue: 26 / 255, alpha: 1)
                context.setFillColor(background)
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))

                let short = Double(min(width, height))
                // A third of the short side on a phone; less on an iPad, where that much looks oversized.
                let side = (short * (short < 1400 ? 0.3 : 0.22)).rounded()
                let fontSize = (short * 0.06).rounded()
                let base = NSFont.systemFont(ofSize: fontSize, weight: .bold)
                let font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: fontSize) } ?? base
                let title = NSAttributedString(string: "Muskey", attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): ink,
                ])
                let line = CTLineCreateWithAttributedString(title)
                let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
                let gap = (fontSize * 0.7).rounded()

                // Centred as one block, icon over name; Core Graphics counts y from the bottom.
                let block = side + gap + bounds.height
                let iconRect = CGRect(x: ((Double(width) - side) / 2).rounded(), y: ((Double(height) + block) / 2 - side).rounded(), width: side, height: side)
                drawRounded(in: context, rect: iconRect)
                context.textPosition = CGPoint(x: (Double(width) - bounds.width) / 2 - bounds.minX, y: iconRect.minY - gap - bounds.maxY)
                CTLineDraw(line, context)
            }
        }
    }

    private init() {
        guard let url = Bundle.main.url(forResource: "app-icon", withExtension: "png", subdirectory: "Web"),
              let file = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(file, 0, nil)
        else {
            source = nil
            edges = nil
            return
        }
        source = image
        edges = Self.edgeColumns(of: image)
        cache.totalCostLimit = 48 << 20
    }

    private let source: CGImage?
    /// The artwork's first and last columns side by side, two pixels wide.
    private let edges: CGImage?
    private let cache = NSCache<NSString, NSData>()

    private static func edgeColumns(of image: CGImage) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: 2, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let left = image.cropping(to: CGRect(x: 1, y: 0, width: 1, height: image.height)),
              let right = image.cropping(to: CGRect(x: image.width - 2, y: 0, width: 1, height: image.height))
        else { return nil }
        context.draw(left, in: CGRect(x: 0, y: 0, width: 1, height: image.height))
        context.draw(right, in: CGRect(x: 1, y: 0, width: 1, height: image.height))
        return context.makeImage()
    }

    /// The artwork in a rounded square with the corner of an iPhone icon.
    private func drawRounded(in context: CGContext, rect: CGRect) {
        guard let source else { return }
        context.saveGState()
        context.addPath(CGPath(roundedRect: rect, cornerWidth: rect.width * 0.2237, cornerHeight: rect.width * 0.2237, transform: nil))
        context.clip()
        context.interpolationQuality = .high
        context.draw(source, in: rect)
        context.restoreGState()
    }

    private func cached(_ key: String, _ make: () -> Data?) -> Data? {
        if let hit = cache.object(forKey: key as NSString) {
            return hit as Data
        }
        guard source != nil, let data = make() else { return nil }
        cache.setObject(data as NSData, forKey: key as NSString, cost: data.count)
        return data
    }

    private func render(width: Int, height: Int, opaque: Bool, draw: (CGContext) -> Void) -> Data? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        draw(context)
        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
