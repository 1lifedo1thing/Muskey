import AppKit
import SwiftUI

/// The notes as A4 pages for printing: each page has the title, the instrument, the key and the tempo at the top and
/// the page number at the bottom, and between them the lines that the notes window draws, in its light colours on
/// white paper. The pages are vector drawings, so they print sharp at any size.
enum NotesPDF {
    /// A4 in points, with the margins that most printers leave.
    static let page = CGSize(width: 595, height: 842)
    static let margin: CGFloat = 32
    static let header: CGFloat = 46
    static let footer: CGFloat = 24

    @MainActor static func write(_ score: Score, title: String, artist: String?, view: NotesView, to url: URL) throws {
        let area = CGSize(width: page.width - margin * 2, height: page.height - margin * 2 - header - footer)
        let layout = NotesLayout(score: score, view: view, size: area)
        let painter = NotesPainter(score: score, layout: layout, byBar: score.notesByBar, ink: Palette.of(.light).ink, paper: .white,
                                   accent: NotesAccent.color(.light), until: .infinity)
        var box = CGRect(origin: .zero, size: page)
        guard let context = CGContext(url as CFURL, mediaBox: &box, [kCGPDFContextTitle: title as CFString] as CFDictionary) else {
            throw CocoaError(.fileWriteUnknown)
        }
        for number in 0 ..< layout.pages {
            let renderer = ImageRenderer(content: NotesPDFPage(painter: painter, page: number, pages: layout.pages, title: title, artist: artist,
                                                               details: details(score)))
            renderer.proposedSize = ProposedViewSize(page)
            context.beginPDFPage(nil)
            renderer.render { _, draw in draw(context) }
            context.endPDFPage()
        }
        context.closePDF()
    }

    /// The instrument, the key, the tempo and the capo, as the notes window's status bar names them.
    private static func details(_ score: Score) -> String {
        var parts = [score.stem.name]
        if let key = score.key { parts.append(key.name) }
        parts.append("\(Int(score.bpm.rounded())) BPM")
        if score.capo > 0 { parts.append("Capo \(score.capo)") }
        return parts.joined(separator: " · ")
    }
}

private struct NotesPDFPage: View {
    let painter: NotesPainter
    let page: Int
    let pages: Int
    let title: String
    let artist: String?
    let details: String

    var body: some View {
        let ink = Palette.of(.light).ink
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 15, weight: .bold, design: .rounded))
                    if let artist, !artist.isEmpty {
                        Text(artist).font(.system(size: 10, weight: .medium, design: .rounded)).foregroundStyle(ink.opacity(0.6))
                    }
                }
                Spacer()
                Text(details).font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundStyle(ink.opacity(0.7))
            }
            .frame(height: NotesPDF.header, alignment: .top)
            Canvas { context, _ in
                painter.draw(&context, page: page, rows: 0 ..< painter.layout.linesPerPage)
            }
            .frame(width: painter.layout.size.width, height: painter.layout.size.height)
            Text("\(page + 1) of \(pages)")
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(ink.opacity(0.5))
                .frame(maxWidth: .infinity, alignment: .center)
                .frame(height: NotesPDF.footer, alignment: .bottom)
        }
        .foregroundStyle(ink)
        .padding(NotesPDF.margin)
        .frame(width: NotesPDF.page.width, height: NotesPDF.page.height, alignment: .topLeading)
        .background(Color.white)
        .environment(\.colorScheme, .light)
    }
}
