//
//  GlobalHotkeys.swift
//  SonosBar
//
//  Register global keyboard shortcuts that work whether or not SonosBar
//  has focus.
//
//  Why Carbon and not NSEvent.addGlobalMonitorForEvents?
//    addGlobalMonitorForEvents is observe-only — it can't consume the
//    event, so the shortcut still passes through to whatever app is
//    frontmost. RegisterEventHotKey (the only path before Cocoa-only
//    HotKey support arrives) actually claims the keystroke.
//
//  The Carbon HotKey API is one of the few macOS APIs that's still
//  C-only after twenty years. We wrap it in a tiny Swift facade.
//
//  Hotkeys aren't user-configurable in v1 — sensible defaults only.
//  Settings UI for re-binding lands in a future version.
//

import Foundation
import Carbon
import AppKit

/// Mirror of the actions a hotkey can trigger. Keeps the Carbon layer
/// dumb — it dispatches actions, the coordinator binds them to handlers.
enum HotkeyAction: Sendable, CaseIterable {
    case playPause
    case nextTrack
    case previousTrack
    case volumeUp
    case volumeDown
}

@MainActor
final class GlobalHotkeyManager {

    /// (carbon ID, keycode, modifiers)
    private struct Binding {
        let action: HotkeyAction
        let keyCode: UInt32
        let modifiers: UInt32
    }

    /// Default bindings. Cmd+Option+Ctrl prefix avoids stepping on
    /// common app shortcuts and on macOS-reserved Cmd-Tab/Cmd-Space.
    private let defaults: [Binding] = [
        Binding(action: .playPause,    keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(cmdKey | optionKey | controlKey)),
        Binding(action: .nextTrack,    keyCode: UInt32(kVK_RightArrow), modifiers: UInt32(cmdKey | optionKey | controlKey)),
        Binding(action: .previousTrack, keyCode: UInt32(kVK_LeftArrow), modifiers: UInt32(cmdKey | optionKey | controlKey)),
        Binding(action: .volumeUp,     keyCode: UInt32(kVK_UpArrow), modifiers: UInt32(cmdKey | optionKey | controlKey)),
        Binding(action: .volumeDown,   keyCode: UInt32(kVK_DownArrow), modifiers: UInt32(cmdKey | optionKey | controlKey))
    ]

    private var hotKeyRefs: [UInt32: (EventHotKeyRef, HotkeyAction)] = [:]
    private var handlerRef: EventHandlerRef?
    private var actionHandler: ((HotkeyAction) -> Void)?

    // Carbon needs a unique 4-char signature for our app's hotkeys.
    // "SoBr" — SonosBar.
    private let signature: OSType = 0x536F4272

    /// Install hotkeys and start listening. The closure is invoked on
    /// the main thread for each matching keystroke.
    func install(handler: @escaping (HotkeyAction) -> Void) {
        self.actionHandler = handler
        installCarbonHandler()
        for (i, binding) in defaults.enumerated() {
            register(binding: binding, id: UInt32(i + 1))
        }
    }

    func uninstall() {
        for (_, (ref, _)) in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
        actionHandler = nil
    }

    // MARK: - Internal

    private func installCarbonHandler() {
        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))

        // Carbon's event handler is a C function pointer. We bridge a
        // self-pointer through the userData so we can dispatch back to
        // the Swift singleton.
        let userData = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, userData -> OSStatus in
                guard let eventRef, let userData else { return noErr }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    eventRef,
                    OSType(kEventParamDirectObject),
                    OSType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr else { return status }

                let manager = Unmanaged<GlobalHotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async {
                    manager.dispatch(id: hotKeyID.id)
                }
                return noErr
            },
            1,
            &eventSpec,
            userData,
            &handlerRef
        )
    }

    private func register(binding: Binding, id: UInt32) {
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            binding.keyCode,
            binding.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == noErr, let ref {
            hotKeyRefs[id] = (ref, binding.action)
        } else {
            Log.app.error("Failed to register hotkey \(String(describing: binding.action)), status=\(status). Another app may have claimed it.")
        }
    }

    private func dispatch(id: UInt32) {
        guard let (_, action) = hotKeyRefs[id], let handler = actionHandler else { return }
        handler(action)
    }
}
