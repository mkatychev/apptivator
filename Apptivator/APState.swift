//
//  APState.swift
//  Apptivator
//

import SwiftyJSON
import KeyboardShortcuts
import LaunchAtLogin
import AXSwift
import os

@objcMembers class APState: NSObject {
    // Only one instance of this class should be used at a time.
    static var shared = APState(atPath: defaultConfigurationPath())

    // AX trust is checked on every hotkey fire and every AX-notification. Hitting TCC that
    // often is wasteful and on some macOS versions interacts badly with the trust cache; we
    // poll at most once per second.
    private static var axTrustCacheValue = false
    private static var axTrustCacheTime: TimeInterval = 0
    private static let axTrustCacheTTL: TimeInterval = 1.0
    static func cachedAccessibilityTrust() -> Bool {
        let now = Date().timeIntervalSinceReferenceDate
        if now - axTrustCacheTime < axTrustCacheTTL { return axTrustCacheValue }
        axTrustCacheValue = UIElement.isProcessTrusted(withPrompt: false)
        axTrustCacheTime = now
        return axTrustCacheValue
    }
    static func invalidateAccessibilityTrustCache() {
        axTrustCacheTime = 0
    }

    // A reference to the Application's AppDelegate (used to set the menu bar icon).
    let appDelegate = NSApp.delegate as! AppDelegate

    // Location of our serialised application state.
    let savePath: URL

    // Adapter around KeyboardShortcuts that handles dynamic register/unregister with deduplication.
    let monitor = ShortcutMonitor.shared
    // UserDefaults is used to provide some experimental overrides.
    let defaults: UserDefaults = UserDefaults.standard
    // A Timer to handle the delay between keypresses in a sequence. When this runs out, then the
    // sequence cancels and the user will have to start the sequence from the beginning.
    var sequenceTimer: Timer?

    // Toggle for dark mode.
    // On macOS 10.14 and later this isn't used since macOS has a global dark mode.
    var darkModeEnabled = mojaveDarkModeSupported() ? false : appleInterfaceStyleIsDark()
    // Whether or not the app should launch after login.
    private var launchAppAtLogin = LaunchAtLogin.isEnabled
    // Don't fire any shortcuts if user is recording a new shortcut.
    private var currentlyRecording = false

    // Whether or not the app is globally enabled.
    private var _isEnabled = true
    var isEnabled: Bool {
        get { return _isEnabled && !currentlyRecording }
        set {
            _isEnabled = newValue
            if newValue {
                registerShortcutsIfEnabled()
            } else {
                unregisterShortcuts()
            }
        }
    }

    // The list of application -> shortcut mappings. Made private because whenever we need to
    // unregister an entry's shortcuts otherwise its reference count will always be > 0. So we
    // provide helpers to manipulate this array.
    private var entries: [APAppEntry] = []

    private init(atPath url: URL) {
        self.savePath = url

        defaults.register(defaults: [
            "leftClickToggles": false,
            "maxShortcutsInSequence": 5,
            "sequentialShortcutDelay": 0.5,
            "matchAppleInterfaceStyle": false,
            "showPopoverOnScreenWithMouse": false
        ])

        Logger.app.info("APState initialised at \(url.path, privacy: .public)")
    }

    // Get a specific entry at the given index.
    func getEntry(at index: Int) -> APAppEntry {
        return entries[index]
    }

    // Return a slice of the entries array.
    func getEntries() -> ArraySlice<APAppEntry> {
        return entries[0..<entries.count]
    }

    // Add an entry.
    func addEntry(_ entry: APAppEntry) {
        entries.append(entry)
        registerShortcutsIfEnabled()
    }

    func removeEntry(at index: Int) {
        let entry = entries.remove(at: index)
        entry.sequence.forEach({ shortcut in
            if monitor.isShortcutRegistered(shortcut) {
                monitor.unregisterShortcut(shortcut)
            }
        })
        entry.sequence = []
        registerShortcutsIfEnabled()
    }

    func sortEntries(comparator: (APAppEntry, APAppEntry) -> Bool) {
        entries.sort(by: comparator)
    }

    // Disable all shortcuts while the user is recording a new one.
    func setCurrentlyRecording(_ isRecording: Bool) {
        currentlyRecording = isRecording
    }

    // This resets the shortcut state to its initial setting. This should be called whenever a
    // an ApplicationEntry updates its sequence.
    func registerShortcutsIfEnabled() {
        if isEnabled {
            registerShortcuts(atIndex: 0, last: nil)
        }
    }

    // Unregister all previously registered application shortcuts. We only unregister the ones
    // our own entries hold, not e.g. the popover's toggle-window shortcut.
    func unregisterShortcuts() {
        entries.forEach({ entry in
            entry.sequence.forEach({ shortcut in
                if monitor.isShortcutRegistered(shortcut) {
                    monitor.unregisterShortcut(shortcut)
                }
            })
        })
    }

    // Only register the shortcuts that are expected.
    // NOTE: Ideally this should be a private function, but we need to expose it here s in order to
    // write tests for its behaviour.
    func registerShortcuts(atIndex index: Int, last: (UInt, UInt)?) {
        guard entries.count > 0 else { return }
        unregisterShortcuts()

        // Bind new shortcuts.
        var count = 0
        entries.forEach({ entry in
            if index < entry.sequence.count {
                let shortcut = entry.sequence[index]
                // If this is the first shortcut (index == 0) then bind all the first shortcut keys.
                if index == 0 {
                    if !monitor.isShortcutRegistered(shortcut) {
                        monitor.register(shortcut, withAction: { self.keyFired(1, entry, shortcut) })
                        count += 1
                    }
                    return
                }

                // If this is a sequential shortcut (index > 0), then only bind the next shortcuts
                // at the given index, whose previous shortcut was hit.
                let (lastKeyCode, lastModifierFlags) = last!
                let prev = entry.sequence[index - 1]
                if prev.cocoaKeyCode == lastKeyCode && prev.cocoaModifierFlags == lastModifierFlags {
                    if !monitor.isShortcutRegistered(shortcut) {
                        monitor.register(shortcut, withAction: { self.keyFired(index + 1, entry, shortcut) })
                        count += 1
                    }
                }
            }
        })

        Logger.app.debug("Registered \(count, privacy: .public)/\(self.entries.count, privacy: .public) shortcuts at index: \(index, privacy: .public), last: \(String(describing: last), privacy: .public).")

        // If this is a sequential shortcut, then start a timer to reset back to the initial state
        // if no other shortcuts were hit.
        if index > 0 {
            appDelegate.setMenuBarIcon(ICON_REC)
            let interval = TimeInterval(defaults.float(forKey: "sequentialShortcutDelay"))
            sequenceTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { _ in
                self.appDelegate.setMenuBarIcon(ICON_ON)
                self.sequenceTimer = nil
                self.registerShortcuts(atIndex: 0, last: nil)
                Logger.app.debug("Resetting shortcut state.")
            }
        }
    }

    // This is called when a key is hit in a sequence of shortcuts. If it's the last shortcut, it
    // will activate the app, otherwise it will just advance the sequence along.
    private func keyFired(_ i: Int, _ entry: APAppEntry, _ shortcut: KeyboardShortcuts.Shortcut) {
        if currentlyRecording { return }
        if i > 0 { sequenceTimer?.invalidate() }

        // Last shortcut in sequence: apptivate and reset shortcut state.
        if i == entry.sequence.count {
            entry.apptivate()
            registerShortcuts(atIndex: 0, last: nil)
            appDelegate.setMenuBarIcon(ICON_ON)
            Logger.app.debug("Apptivating \(entry.name, privacy: .public).")
        } else {
            // Advance shortcut state with last shortcut and the number of shortcuts hit.
            let last = (shortcut.cocoaKeyCode, shortcut.cocoaModifierFlags)
            registerShortcuts(atIndex: i, last: last)
        }
    }

    // This checks the given sequences to see if it conflicts with another sequence. Shortcut
    // sequences must have unique prefixes, so that each one can be distinguished from another.
    // See `APSequenceViewController.updateUIWith()`.
    func checkForConflictingSequence(_ otherSequence: [KeyboardShortcuts.Shortcut], excluding otherEntry: APAppEntry?) -> APAppEntry? {
        // It doesn't make sense to call this function with an empty sequence.
        assert(otherSequence.count > 0, "tried to check sequence with count == 0")

        return entries.first(where: { entry in
            if entry.sequence.count == 0 || entry === otherEntry { return false }
            var wasConflict = true
            for (a, b) in zip(otherSequence, entry.sequence) {
                if a != b {
                    wasConflict = false
                    break
                }
            }

            return wasConflict
        })
    }

    // Loads the app state (JSON) from disk - if the file exists, otherwise it does nothing.
    func loadFromDisk() {
        // Reset the state before loading from disk.
        currentlyRecording = false
        _isEnabled = true
        sequenceTimer = nil

        // Default to the current interface style on macOS versions below 10.14.
        if !mojaveDarkModeSupported() { darkModeEnabled = appleInterfaceStyleIsDark() }

        // Unregister shortcuts and remove all entries.
        unregisterShortcuts()
        entries.removeAll()

        do {
            let jsonString = try String(contentsOf: savePath, encoding: .utf8)
            try loadFromString(jsonString)
        } catch {
            // Ignore error when there's no file.
            let err = error as NSError
            if err.domain != NSCocoaErrorDomain && err.code != CocoaError.fileReadNoSuchFile.rawValue {
                Logger.app.error("Unexpected error loading application state from disk: \(error.localizedDescription, privacy: .public)")
            }
        }

        registerShortcutsIfEnabled()
    }

    func loadFromString(_ jsonString: String) throws {
        if let dataFromString = jsonString.data(using: .utf8, allowLossyConversion: false) {
            let json = try JSON(data: dataFromString)
            for (key, value):(String, JSON) in json {
                switch key {
                // Only care about dark mode on macOS versions below 10.14.
                case "darkModeEnabled":
                    if !mojaveDarkModeSupported() { darkModeEnabled = value.bool ?? false }
                case "appIsEnabled":
                    isEnabled = value.bool ?? true
                case "entries":
                    entries = APAppEntry.deserialiseList(fromJSON: value)
                default:
                    Logger.app.warning("unknown key '\(key, privacy: .public)' encountered in json")
                }
            }

            if !mojaveDarkModeSupported() && APState.shared.defaults.bool(forKey: "matchAppleInterfaceStyle") {
                darkModeEnabled = appleInterfaceStyleIsDark()
            }

            Logger.app.info("Loaded config from disk")
        }
    }

    // Saves the app state to disk, creating the parent directories if they don't already exist.
    func saveToDisk() {
        var json: JSON = [
            "appIsEnabled": _isEnabled,
            "entries": APAppEntry.serialiseList(entries: getEntries())
        ]

        // Only bother saving whether dark mode is enabled or not on macOS versions below 10.14.
        if !mojaveDarkModeSupported() {
            json["darkModeEnabled"].boolValue = darkModeEnabled
        }

        do {
            if let jsonString = json.rawString() {
                let configDir = savePath.deletingLastPathComponent()
                try FileManager.default.createDirectory(atPath: configDir.path, withIntermediateDirectories: true, attributes: nil)
                try jsonString.write(to: savePath, atomically: false, encoding: .utf8)
                Logger.app.info("Saved config to disk")
            } else {
                Logger.app.error("Could not serialise config")
            }
        } catch {
            Logger.app.error("Unexpected error saving application state to disk: \(error.localizedDescription, privacy: .public)")
        }
    }
}
