import Carbon.HIToolbox
import Foundation

/// The key that types a character in the keyboard layout that is selected now. A character like `?` sits on another
/// key in each layout: Shift and / on a US keyboard, Shift and ß on a German one, Shift and the comma key on a French one.
struct LayoutKey: Equatable {
    let code: Int
    /// Carbon modifiers: `shiftKey`, `optionKey`, or both.
    let modifiers: Int

    var shift: Bool { modifiers & shiftKey != 0 }
    var option: Bool { modifiers & optionKey != 0 }

    /// The key for `?`, found again whenever another keyboard layout is selected.
    static var questionMark: LayoutKey? {
        let id = currentLayoutID
        if id != cachedLayout || cachedQuestionMark == nil {
            cachedLayout = id
            cachedQuestionMark = find("?")
        }
        // A layout that can't be read, or has no ?, gets the key of a US keyboard.
        return cachedQuestionMark ?? LayoutKey(code: kVK_ANSI_Slash, modifiers: shiftKey)
    }

    private nonisolated(unsafe) static var cachedLayout: String?
    private nonisolated(unsafe) static var cachedQuestionMark: LayoutKey?

    private static var currentLayoutID: String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let id = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
        else { return nil }
        return Unmanaged<CFString>.fromOpaque(id).takeUnretainedValue() as String
    }

    /// Tries every key with no modifier, Shift, Option and both, and takes the first that types `character`.
    static func find(_ character: String) -> LayoutKey? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> LayoutKey? in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return nil }
            for modifiers in [0, shiftKey, optionKey, optionKey | shiftKey] {
                for code in 0 ..< 128 {
                    var deadKeys: UInt32 = 0
                    var length = 0
                    var characters = [UniChar](repeating: 0, count: 4)
                    let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), UInt32((modifiers >> 8) & 0xFF),
                                                UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys,
                                                characters.count, &length, &characters)
                    if status == noErr, length > 0, String(utf16CodeUnits: characters, count: length) == character {
                        return LayoutKey(code: code, modifiers: modifiers)
                    }
                }
            }
            return nil
        }
    }
}
