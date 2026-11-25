import Foundation

/// The notes of one stem as a single HTML page that a browser opens on a phone or a computer: the sheet of the notes
/// window, with tab, sheet music and the piano roll, the pages, the key and the capo, and no audio. The page is drawn by
/// `Web/sheet.js`, which the app copies into its resources with the CSS and the template next to it.
enum NotesSheet {
    /// The page for a transcription, with the view, the shift, the mode of the key and the capo that it opens with.
    /// A nil view opens the view that the window prefers for the stem. Empty when the app has no `Web` folder.
    static func html(_ fixture: NotesFixture, artist: String?, view: NotesView?, shift: Int, relative: Bool, capo: Int) -> String {
        guard let template = resource("sheet", "html"), let css = resource("sheet", "css"), let js = resource("sheet", "js"),
              let data = json(Payload(fixture: fixture, artist: artist)),
              let options = json(Options(view: view?.rawValue, shift: shift, relative: relative, capo: capo))
        else { return "" }
        return fill(template, with: [
            "TITLE": escapeHTML(fixture.title),
            "CSS": css,
            // The script sits inside a script tag, which the first "</script" in it would close.
            "JS": js.replacingOccurrences(of: "</script", with: "<\\/script", options: .caseInsensitive),
            "DATA": data,
            "OPTIONS": options,
        ])
    }

    /// The fixture as the page reads it, with the artist for the line under the title.
    private struct Payload: Encodable {
        let title: String
        let stem: String
        let key: String?
        let bpm: Double
        let duration: Double
        let beats: [Double]
        let notes: [TranscribedNote]
        let artist: String?

        init(fixture: NotesFixture, artist: String?) {
            title = fixture.title
            stem = fixture.stem
            key = fixture.key
            bpm = fixture.bpm
            duration = fixture.duration
            beats = fixture.beats
            notes = fixture.notes
            self.artist = artist
        }
    }

    private struct Options: Encodable {
        let view: String?
        let shift: Int
        let relative: Bool
        let capo: Int
    }

    private static func resource(_ name: String, _ ext: String) -> String? {
        Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Web").flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    /// JSON that can sit inside a script tag: every `<` is written as an escape, so no text in it can end the tag.
    private static func json(_ value: some Encodable) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else { return nil }
        return text.replacingOccurrences(of: "<", with: "\\u003c")
    }

    private static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Puts each part in the place of its `{{NAME}}` in one pass over the template, so a part is never searched for
    /// names again: the script or the song's title can hold `{{` without being changed.
    private static func fill(_ template: String, with parts: [String: String]) -> String {
        var out = ""
        var rest = template[...]
        while let open = rest.range(of: "{{") {
            out += rest[..<open.lowerBound]
            guard let close = rest[open.upperBound...].range(of: "}}"), let part = parts[String(rest[open.upperBound ..< close.lowerBound])] else {
                out += "{{"
                rest = rest[open.upperBound...]
                continue
            }
            out += part
            rest = rest[close.upperBound...]
        }
        return out + rest
    }
}
