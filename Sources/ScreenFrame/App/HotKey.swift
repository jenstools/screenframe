import Carbon.HIToolbox

/// A system-wide shortcut via Carbon's RegisterEventHotKey, which needs no permissions.
final class HotKey {
    private var reference: EventHotKeyRef?
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var installed = false

    init?(keyCode: Int, modifiers: Int, id: UInt32, handler: @escaping () -> Void) {
        if !Self.installed {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var hotKeyID = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                  MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
                DispatchQueue.main.async { HotKey.handlers[hotKeyID.id]?() }
                return noErr
            }, 1, &spec, nil, nil)
            Self.installed = true
        }
        let hotKeyID = EventHotKeyID(signature: OSType(0x5346_524D), id: id) // 'SFRM'
        guard RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &reference) == noErr else {
            return nil
        }
        Self.handlers[id] = handler
    }

    deinit {
        if let reference { UnregisterEventHotKey(reference) }
    }
}
