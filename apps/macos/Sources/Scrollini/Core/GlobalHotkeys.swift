import Carbon.HIToolbox
import Foundation

struct GlobalHotkey {
    var id: UInt32
    var binding: String
    var command: Command
    var keyCode: UInt32
    var modifiers: UInt32
    var reference: EventHotKeyRef?
}

private let scrolliniHotkeySignature: OSType = 0x5343_524C // "SCRL"

private let scrolliniGlobalHotkeyHandler: EventHandlerUPP = { _, event, userData in
    guard let event, let userData else {
        return noErr
    }

    var identifier = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &identifier
    )
    guard status == noErr, identifier.signature == scrolliniHotkeySignature else {
        return noErr
    }

    let scrollini = Unmanaged<Scrollini>.fromOpaque(userData).takeUnretainedValue()
    DispatchQueue.main.async {
        scrollini.handleRegisteredGlobalHotkey(identifier.id)
    }
    return noErr
}

extension Scrollini {
    func configureGlobalHotkeys() {
        unregisterGlobalHotkeys()

        let eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let result = InstallEventHandler(
            GetApplicationEventTarget(),
            scrolliniGlobalHotkeyHandler,
            1,
            [eventType],
            Unmanaged.passUnretained(self).toOpaque(),
            &globalHotkeyHandler
        )
        guard result == noErr else {
            globalHotkeyHandler = nil
            return
        }

        var nextID: UInt32 = 1
        for binding in commandByKeybinding.keys.sorted() {
            guard let command = commandByKeybinding[binding],
                  let specification = globalHotkeySpecification(for: binding)
            else {
                continue
            }

            globalHotkeys.append(GlobalHotkey(
                id: nextID,
                binding: binding,
                command: command,
                keyCode: specification.keyCode,
                modifiers: specification.modifiers,
                reference: nil
            ))
            nextID &+= 1
        }
        refreshGlobalHotkeysForFrontmostApp()
    }

    func unregisterGlobalHotkeys() {
        for hotkey in globalHotkeys {
            if let reference = hotkey.reference {
                UnregisterEventHotKey(reference)
            }
        }
        globalHotkeys.removeAll()
        globalHotkeyBindings.removeAll()
        if let globalHotkeyHandler {
            RemoveEventHandler(globalHotkeyHandler)
            self.globalHotkeyHandler = nil
        }
    }

    func refreshGlobalHotkeysForFrontmostApp() {
        guard globalHotkeyHandler != nil else {
            return
        }

        let excluded = frontmostAppExcludedChords()
        globalHotkeyBindings.removeAll()
        for index in globalHotkeys.indices {
            var hotkey = globalHotkeys[index]
            let shouldRegister = !excludedKeybindingSet.contains(hotkey.binding)
                && !excluded.contains(hotkey.binding)

            if !shouldRegister, let reference = hotkey.reference {
                UnregisterEventHotKey(reference)
                hotkey.reference = nil
            } else if shouldRegister, hotkey.reference == nil {
                var reference: EventHotKeyRef?
                let status = RegisterEventHotKey(
                    hotkey.keyCode,
                    hotkey.modifiers,
                    EventHotKeyID(signature: scrolliniHotkeySignature, id: hotkey.id),
                    GetApplicationEventTarget(),
                    0,
                    &reference
                )
                if status == noErr {
                    hotkey.reference = reference
                } else {
                    debugLog("global hotkey unavailable binding=\(hotkey.binding) status=\(status)")
                }
            }

            globalHotkeys[index] = hotkey
            if hotkey.reference != nil {
                globalHotkeyBindings.insert(hotkey.binding)
            }
        }
    }

    func isRegisteredGlobalHotkey(modifiers: CGEventFlags, keyCode: Int64, keyText: String) -> Bool {
        normalizedKeybindingCandidates(modifiers: modifiers, keyCode: keyCode, keyText: keyText)
            .contains(where: globalHotkeyBindings.contains)
    }

    func handleRegisteredGlobalHotkey(_ id: UInt32) {
        guard !keybindingsPaused,
              !transientSystemWindowIsActive(),
              let hotkey = globalHotkeys.first(where: { $0.id == id }),
              !excludedKeybindingSet.contains(hotkey.binding),
              !frontmostAppExcludedChords().contains(hotkey.binding)
        else {
            return
        }
        handle(hotkey.command)
    }

    func globalHotkeySpecification(for binding: String) -> (keyCode: UInt32, modifiers: UInt32)? {
        let parts = binding.split(separator: "+").map(String.init)
        guard let key = parts.last,
              let keyCode = Self.keyNamesByCode.first(where: { _, names in
                  names.contains { normalizedKeyName($0) == key }
              })?.key
        else {
            return nil
        }

        var modifiers: UInt32 = 0
        for modifier in parts.dropLast() {
            switch modifier {
            case "cmd": modifiers |= UInt32(cmdKey)
            case "ctrl": modifiers |= UInt32(controlKey)
            case "shift": modifiers |= UInt32(shiftKey)
            case "alt": modifiers |= UInt32(optionKey)
            default: return nil
            }
        }
        return (UInt32(keyCode), modifiers)
    }
}
