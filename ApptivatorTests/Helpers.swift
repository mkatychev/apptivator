//
//  Helpers.swift
//  ApptivatorTests
//

import XCTest
import KeyboardShortcuts
@testable import Apptivator

let KEY_A: UInt = 0
let KEY_B: UInt = 11
let KEY_C: UInt = 8
let KEY_D: UInt = 2
let KEY_E: UInt = 14
let KEY_F: UInt = 3
let KEY_G: UInt = 5
let OPT: UInt = 524288
let CMD: UInt = 1048576
let CMD_SHIFT: UInt = 1179648

func shortcut(withKeyCode keyCode: UInt, modifierFlags: UInt) -> KeyboardShortcuts.Shortcut {
    KeyboardShortcuts.Shortcut(cocoaKeyCode: keyCode, cocoaModifierFlags: modifierFlags)
}

func entry(atURL url: URL, sequence: [KeyboardShortcuts.Shortcut]) -> APAppEntry {
    let entry = APAppEntry(url: url, config: nil)!
    entry.sequence = sequence
    return entry
}
