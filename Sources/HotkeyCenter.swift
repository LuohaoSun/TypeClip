import Carbon
import AppKit

/// Carbon RegisterEventHotKey 全局热键(Hammerspoon 用的同一机制)。
/// ⌃⌘V / ⌃⌘Return; 敲入过程中再按一次任意热键 = 中断。
final class HotkeyCenter {

    static let shared = HotkeyCenter()
    private var actions: [UInt32: () -> Void] = [:]
    private var hotKeyRefs: [EventHotKeyRef?] = []
    private var installed = false
    private let signature = OSType(0x54797043) // 'TypC'

    func register(keyCode: UInt32, carbonModifiers: UInt32, id: UInt32, action: @escaping () -> Void) {
        actions[id] = action
        installHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        RegisterEventHotKey(keyCode, carbonModifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        hotKeyRefs.append(ref)
    }

    private func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(
                event,
                UInt32(kEventParamDirectObject),
                UInt32(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            if let action = HotkeyCenter.shared.actions[hotKeyID.id] {
                DispatchQueue.main.async(execute: action)
            }
            return noErr
        }, 1, &eventSpec, nil, nil)
    }
}
