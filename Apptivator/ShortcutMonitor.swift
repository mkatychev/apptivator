//
//  ShortcutMonitor.swift
//  Apptivator
//
//  Thin adapter over KeyboardShortcuts that mimics the API the sequence engine
//  used with MASShortcutMonitor: register/unregister a Shortcut with a closure,
//  and ask whether a Shortcut is currently registered. Multiple registrations
//  of the same Shortcut value coalesce to a single hotkey; all handlers fire.
//

import AppKit
import Carbon.HIToolbox
import KeyboardShortcuts

final class ShortcutMonitor {
    static let shared = ShortcutMonitor()

    private final class Slot {
        let name: KeyboardShortcuts.Name
        var handlers: [() -> Void] = []
        var isActive = false
        init(name: KeyboardShortcuts.Name) { self.name = name }
    }

    // Stable per-Shortcut slot. Once allocated, the Name + onKeyDown closure
    // live for the process lifetime; activation is toggled via setShortcut.
    private var slots: [KeyboardShortcuts.Shortcut: Slot] = [:]
    private var nextID: Int = 0

    func isShortcutRegistered(_ shortcut: KeyboardShortcuts.Shortcut?) -> Bool {
        guard let shortcut else { return false }
        return slots[shortcut]?.isActive == true
    }

    func register(_ shortcut: KeyboardShortcuts.Shortcut, withAction action: @escaping () -> Void) {
        let slot = slot(for: shortcut)
        slot.handlers.append(action)
        if !slot.isActive {
            KeyboardShortcuts.setShortcut(shortcut, for: slot.name)
            slot.isActive = true
        }
    }

    func unregisterShortcut(_ shortcut: KeyboardShortcuts.Shortcut?) {
        guard let shortcut, let slot = slots[shortcut], slot.isActive else { return }
        slot.handlers.removeAll()
        KeyboardShortcuts.setShortcut(nil, for: slot.name)
        slot.isActive = false
    }

    private func slot(for shortcut: KeyboardShortcuts.Shortcut) -> Slot {
        if let existing = slots[shortcut] { return existing }
        nextID += 1
        let name = KeyboardShortcuts.Name("apptivator.dynamic.\(nextID)")
        let slot = Slot(name: name)
        slots[shortcut] = slot
        KeyboardShortcuts.onKeyDown(for: name) { [weak slot] in
            // Snapshot — handlers may register/unregister during dispatch.
            let handlers = slot?.handlers ?? []
            for handler in handlers { handler() }
        }
        return slot
    }
}

extension KeyboardShortcuts.Shortcut {
    // Apptivator persists shortcuts as (keyCode, modifierFlags) where modifierFlags is the
    // raw value of NSEvent.ModifierFlags (Cocoa flags). MASShortcut used the same encoding.
    init(cocoaKeyCode keyCode: UInt, cocoaModifierFlags modifierFlags: UInt) {
        let cocoa = NSEvent.ModifierFlags(rawValue: modifierFlags)
        self.init(carbonKeyCode: Int(keyCode), carbonModifiers: ShortcutMonitor.carbonModifiers(from: cocoa))
    }

    var cocoaKeyCode: UInt { UInt(carbonKeyCode) }
    var cocoaModifierFlags: UInt {
        ShortcutMonitor.cocoaModifierFlags(fromCarbon: carbonModifiers).rawValue
    }
}

extension ShortcutMonitor {
    static func carbonModifiers(from cocoa: NSEvent.ModifierFlags) -> Int {
        var carbon = 0
        if cocoa.contains(.control) { carbon |= controlKey }
        if cocoa.contains(.option)  { carbon |= optionKey }
        if cocoa.contains(.shift)   { carbon |= shiftKey }
        if cocoa.contains(.command) { carbon |= cmdKey }
        return carbon
    }

    static func cocoaModifierFlags(fromCarbon carbon: Int) -> NSEvent.ModifierFlags {
        var cocoa: NSEvent.ModifierFlags = []
        if carbon & controlKey == controlKey { cocoa.insert(.control) }
        if carbon & optionKey  == optionKey  { cocoa.insert(.option) }
        if carbon & shiftKey   == shiftKey   { cocoa.insert(.shift) }
        if carbon & cmdKey     == cmdKey     { cocoa.insert(.command) }
        return cocoa
    }
}
