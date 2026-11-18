import SwiftUI

/// A project that Muskey is built on, with the ways to give to it that the project lists itself.
struct Project: Identifiable {
    struct Gift: Identifiable {
        let name: String
        let symbol: String
        let url: URL
        var id: String { name }
    }

    let name: String
    /// What Muskey uses it for.
    let use: String
    let site: URL
    var gifts: [Gift] = []
    var id: String { name }

    private static func url(_ string: String) -> URL { URL(string: string)! }
    private static func sponsors(_ account: String) -> Gift {
        Gift(name: "GitHub Sponsors", symbol: "heart.fill", url: url("https://github.com/sponsors/\(account)"))
    }

    /// The projects that take sponsors or donations, each with the links from its own site, README or FUNDING.yml.
    static let sponsored: [Project] = [
        Project(name: "LRCLIB", use: "Synced lyrics", site: url("https://lrclib.net"), gifts: [
            sponsors("tranxuanthang"),
            Gift(name: "Buy Me a Coffee", symbol: "cup.and.saucer.fill", url: url("https://www.buymeacoffee.com/thangtran")),
            Gift(name: "PayPal", symbol: "creditcard.fill", url: url("https://paypal.me/tranxuanthang98")),
        ]),
        Project(name: "lrc.red", use: "Lyrics", site: url("https://lrc.red"), gifts: [
            Gift(name: "Donate", symbol: "gift.fill", url: url("https://lrc.red/donate")),
        ]),
        Project(name: "yt-dlp", use: "Songs from links", site: url("https://github.com/yt-dlp/yt-dlp"), gifts: [
            // yt-dlp has no fund of its own: its FUNDING.yml points at the list of maintainers, each with their links.
            Gift(name: "Maintainers", symbol: "person.2.fill", url: url("https://github.com/yt-dlp/yt-dlp/blob/master/Maintainers.md#maintainers")),
        ]),
        Project(name: "whisper.cpp", use: "Lyrics timing with Whisper", site: url("https://github.com/ggml-org/whisper.cpp"), gifts: [
            sponsors("ggerganov"),
        ]),
        Project(name: "FFmpeg", use: "Audio conversion for yt-dlp", site: url("https://ffmpeg.org"), gifts: [
            Gift(name: "Donate", symbol: "gift.fill", url: url("https://ffmpeg.org/donations.html")),
            sponsors("FFmpeg"),
        ]),
    ]

    /// The projects that take no donations, credited with a link to their site.
    static let credited: [Project] = [
        Project(name: "Essentia", use: "Key detection", site: url("https://essentia.upf.edu")),
        Project(name: "Rubber Band", use: "Pitch change", site: url("https://breakfastquay.com/rubberband/")),
        Project(name: "AMLL TTML DB", use: "Word-timed lyrics", site: url("https://github.com/amll-dev/amll-ttml-db")),
        Project(name: "NetEase Cloud Music", use: "Lyrics", site: url("https://music.163.com")),
        Project(name: "BS-RoFormer", use: "Instruments and vocals", site: url("https://arxiv.org/abs/2309.02612")),
        Project(name: "MVSep", use: "Winds", site: url("https://mvsep.com")),
        Project(name: "LAME", use: "MP3 files", site: url("https://lame.sourceforge.io")),
        Project(name: "mpg123", use: "MP3 files", site: url("https://www.mpg123.de")),
        Project(name: "Sparkle", use: "Updates", site: url("https://sparkle-project.org")),
    ]
}

/// The About pane: the app's icon, name and version as in the About pane of the other lowtechguys apps, then the
/// projects that Muskey is built on, with buttons for sponsoring them.
struct AboutPane: View {
    var body: some View {
        Form {
            Section {
                ForEach(Project.sponsored) { project in
                    LabeledContent {
                        HStack(spacing: 6) {
                            ForEach(project.gifts) { GiftButton(gift: $0) }
                        }
                    } label: {
                        ProjectName(project: project)
                    }
                }
            } header: {
                VStack(spacing: 0) {
                    AboutHeader()
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Projects behind Muskey")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text("Muskey is free, but if you want to show your support, feel free to sponsor the projects that made it possible.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 10)
                }
            }
            Section("Also built with") {
                ForEach(Project.credited) { project in
                    LabeledContent {
                        Text(project.use).foregroundStyle(.secondary)
                    } label: {
                        Link(project.name, destination: project.site)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// The icon, name, version and links, laid out like the About pane of Cling, Clop and rcmd.
private struct AboutHeader: View {
    @Environment(\.openURL) private var openURL
    private static let changelog = URL(string: "https://files.lowtechguys.com/muskey/changelog.html")!
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 112, height: 112)
            Text("Muskey")
                .font(.system(size: 44, weight: .black, design: .rounded))
                .foregroundStyle(.primary)
                .padding(.top, -4)
            Button { openURL(Self.changelog) } label: {
                Text("v\(version)").font(.system(size: 13, design: .monospaced))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Open the changelog")
            HStack(spacing: 20) {
                Link("Website", destination: URL(string: "https://lowtechguys.com/muskey")!)
                Link("Source", destination: URL(string: "https://github.com/FuzzyIdeas/Muskey")!)
                Link("Changelog", destination: Self.changelog)
            }
            .underline()
            .opacity(0.75)
            .padding(.top, 4)
            VStack(spacing: 4) {
                Text("Made by \"The low-tech guys\"")
                    .font(.system(size: 11, design: .rounded))
                Text("© \(String(Calendar.current.component(.year, from: Date()))) THE LOW TECH GUYS")
                    .font(.system(size: 10, design: .rounded))
                    .opacity(0.7)
            }
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }
}

private struct ProjectName: View {
    let project: Project

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Link(project.name, destination: project.site)
                .foregroundStyle(.primary)
            Text(project.use)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}

/// A pill in the pink of GitHub's sponsor heart, which opens the page where the project takes the money.
private struct GiftButton: View {
    let gift: Project.Gift
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    private var pink: Color {
        scheme == .dark ? Color(.sRGB, red: 0.86, green: 0.38, blue: 0.64) : Color(.sRGB, red: 0.75, green: 0.22, blue: 0.54)
    }

    var body: some View {
        Button { openURL(gift.url) } label: {
            Label(gift.name, systemImage: gift.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(pink)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(pink.opacity(hovering ? 0.22 : 0.13)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(gift.url.absoluteString)
        .fixedSize()
    }
}
