import AppKit
import SwiftUI

/// The window of Add Lyrics and Edit Lyrics, for pasting the lyrics of the song on the record as plain text or LRC.
/// It sits above the HUD, which stays open behind it.
final class LyricsEditorWindowController: NSWindowController, NSWindowDelegate {
    var onClose: () -> Void = {}

    convenience init(song: String, text: String, save: @escaping (String) -> Void) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 520), styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        self.init(window: window)
        window.title = "Lyrics"
        window.subtitle = song
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 360, height: 320)
        window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        window.contentView = NSHostingView(rootView: LyricsEditorView(text: text, save: { [weak self] in
            save($0)
            self?.close()
        }, cancel: { [weak self] in self?.close() }))
        window.delegate = self
        window.center()
    }

    /// Like Settings, the window comes with a Dock icon, since macOS brings only a regular app to the front.
    func show() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_: Notification) {
        let others = NSApp.windows.contains { $0 !== window && $0.isVisible && $0.styleMask.contains(.titled) }
        if !others { NSApp.setActivationPolicy(.accessory) }
        onClose()
    }
}

private struct LyricsEditorView: View {
    @State var text: String
    let save: (String) -> Void
    let cancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            TextEditor(text: $text)
                .focused($focused)
                .onAppear { focused = true }
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(10)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("plain text or LRC")
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 15)
                            .padding(.vertical, 10)
                            .allowsHitTesting(false)
                    }
                }
            Divider()
            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save(text) }
                    .keyboardShortcut("s", modifiers: .command)
                    .buttonStyle(.borderedProminent)
            }
            .padding(12)
        }
        .background(.background)
    }
}
