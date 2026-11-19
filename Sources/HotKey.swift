import Carbon.HIToolbox

/// A global hotkey through Carbon's RegisterEventHotKey, which needs no Accessibility permission
/// (unlike an NSEvent global monitor or an event tap). The action runs on the main thread.
/// Each hotkey has its own ID, and its handler passes on the presses of the others, so several can be registered.
final class HotKey {
    struct RegistrationError: Error, CustomStringConvertible {
        let status: OSStatus
        var description: String { "registering the hotkey failed (\(status))" }
    }

    private static var nextID: UInt32 = 1
    private let id: UInt32
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void

    init(keyCode: Int, modifiers: Int, action: @escaping () -> Void) throws {
        self.action = action
        id = Self.nextID
        Self.nextID += 1

        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        var status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var pressedID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &pressedID)
            let hotKey = Unmanaged<HotKey>.fromOpaque(context).takeUnretainedValue()
            guard pressedID.id == hotKey.id else { return OSStatus(eventNotHandledErr) }
            // The action runs after the handler returns: an action that registers the hotkeys again would otherwise
            // free this one while its handler runs, and the keys pressed after it were lost.
            let action = hotKey.action
            DispatchQueue.main.async(execute: action)
            return noErr
        }, 1, &pressed, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
        guard status == noErr else { throw RegistrationError(status: status) }

        let hotKeyID = EventHotKeyID(signature: OSType(0x4D55_534B), id: id) // "MUSK"
        status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        guard status == noErr else {
            RemoveEventHandler(handlerRef)
            handlerRef = nil
            throw RegistrationError(status: status)
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
