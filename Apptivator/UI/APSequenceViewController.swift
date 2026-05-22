//
//  APSequenceViewController.swift
//  Apptivator
//

import KeyboardShortcuts

let SEQUENCE_DETAIL_NO_SHORTCUT = "There must be at least one shortcut in a sequence."
let SEQUENCE_DETAIL_TEXT = """
To use a seqeunce, press the first shortcut (and release it), then press the next, and so on, until \
you activate the application.
"""

enum UIStates {
    case Okay
    case NoShortcuts
    case ConflictingShortcuts
}

class APSequenceViewController: NSViewController {
    // View animation lifecycle hooks.
    var beforeAdded: (() -> Void)?
    var afterAdded: (() -> Void)?
    var beforeRemoved: (() -> Void)?
    var afterRemoved: (() -> Void)?

    var referenceView: NSView!
    var defaultTextColor: NSColor!

    private struct Row {
        let name: KeyboardShortcuts.Name
        let recorder: KeyboardShortcuts.RecorderCocoa
        var shortcut: KeyboardShortcuts.Shortcut?
    }
    private var list: [Row] = []
    private var listAsSequence: [KeyboardShortcuts.Shortcut] {
        list.compactMap { $0.shortcut }
    }
    var entry: APAppEntry! {
        didSet {
            list = entry.sequence.enumerated().map { newRow(at: $0.offset, with: $0.element) }
            list.append(newRow(at: list.count, with: nil))
        }
    }

    @IBOutlet weak var titleTextField: NSTextField!
    @IBOutlet weak var detailTextField: NSTextField!
    @IBOutlet weak var tableView: NSTableView!
    @IBOutlet weak var imageView: NSImageView!
    @IBOutlet weak var saveButton: NSButton!

    @IBAction func closeButtonClick(_ sender: Any) { slideOutAndRemove() }
    @IBAction func saveButtonClick(_ sender: Any) {
        let sequence = listAsSequence

        // This is a sanity check: the save button should never be enabled without a valid sequence.
        assert(sequence.count > 0, "sequence.count must be > 0.")

        if APState.shared.checkForConflictingSequence(sequence, excluding: self.entry) == nil {
            entry.sequence = sequence
            slideOutAndRemove()
        } else {
            assertionFailure("Tried to save with a conflicting sequence.")
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        tableView.delegate = self
        tableView.dataSource = self

        imageView.image = entry.icon

        titleTextField.stringValue = entry.name
        detailTextField.stringValue = SEQUENCE_DETAIL_TEXT
        defaultTextColor = detailTextField.textColor

        updateList()
    }

    private static var nextEditorID: Int = 0
    private func makeRowName() -> KeyboardShortcuts.Name {
        Self.nextEditorID += 1
        return KeyboardShortcuts.Name("apptivator.editor.row.\(Self.nextEditorID)")
    }

    private func newRow(at index: Int, with shortcut: KeyboardShortcuts.Shortcut?) -> Row {
        let name = makeRowName()
        KeyboardShortcuts.setShortcut(shortcut, for: name)
        let recorder = KeyboardShortcuts.RecorderCocoa(for: name) { [weak self] newShortcut in
            guard let self else { return }
            if let idx = self.list.firstIndex(where: { $0.name == name }) {
                self.list[idx].shortcut = newShortcut
                self.updateList()
            }
        }
        recorder.translatesAutoresizingMaskIntoConstraints = true
        return Row(name: name, recorder: recorder, shortcut: shortcut)
    }

    private func clearAllRowBindings() {
        // The editor's row Names are scratch — clear their persisted shortcuts so they don't
        // sit around as no-op global hotkeys after the editor closes.
        for row in list {
            KeyboardShortcuts.setShortcut(nil, for: row.name)
        }
    }

    private func updateList() {
        // Remove cleared rows from the middle of the list, but keep at least one trailing empty row.
        for i in (0..<list.count).reversed() where list.count > 1 && list[i].shortcut == nil {
            let removed = list.remove(at: i)
            KeyboardShortcuts.setShortcut(nil, for: removed.name)
        }

        // Ensure there's always one more empty recorder at the end up to the max.
        let maxShortcuts = APState.shared.defaults.integer(forKey: "maxShortcutsInSequence")
        if list.last?.shortcut != nil && list.count < maxShortcuts {
            list.append(newRow(at: list.count, with: nil))
        }

        // Check for any conflicting entries.
        let sequence = listAsSequence
        if sequence.count == 0 {
            updateUI(reason: .NoShortcuts, nil)
        } else if let conflictingEntry = APState.shared.checkForConflictingSequence(sequence, excluding: entry) {
            updateUI(reason: .ConflictingShortcuts, conflictingEntry)
        } else {
            updateUI(reason: .Okay, nil)
        }

        tableView.reloadData()
    }

    func updateUI(reason: UIStates, _ conflictingEntry: APAppEntry?) {
        switch reason {
        case .ConflictingShortcuts:
            assert(conflictingEntry != nil, "conflictingEntry must be != nil")
            saveButton.isEnabled = false
            detailTextField.textColor = .red

            let boldAttribute = [NSAttributedString.Key.font: NSFont.boldSystemFont(ofSize: 11)]
            let attrString = NSMutableAttributedString(string: "Current sequence conflicts with:\n")
            attrString.append(NSAttributedString(string: conflictingEntry!.name, attributes: boldAttribute))
            attrString.append(NSAttributedString(string: ", which has the sequence:\n"))
            attrString.append(NSAttributedString(string: conflictingEntry!.shortcutString!, attributes: boldAttribute))
            detailTextField.attributedStringValue = attrString
        case .NoShortcuts:
            saveButton.isEnabled = false
            detailTextField.textColor = .red
            detailTextField.stringValue = SEQUENCE_DETAIL_NO_SHORTCUT
        case .Okay:
            saveButton.isEnabled = true
            detailTextField.textColor = defaultTextColor
            detailTextField.stringValue = SEQUENCE_DETAIL_TEXT
        }
    }

    func slideInAndAdd(to referringView: NSView) {
        beforeAdded?()
        referenceView = referringView
        self.view.frame.size = referenceView.frame.size
        self.view.frame.origin = CGPoint(x: referenceView.frame.maxX, y: referenceView.frame.minY)
        referenceView.superview!.addSubview(self.view)
        runAnimation({ _ in
            self.view.animator().frame.origin = referenceView.frame.origin
        }, done: {
            self.afterAdded?()
        })
    }

    func slideOutAndRemove() {
        beforeRemoved?()
        let destination = CGPoint(x: referenceView.frame.maxX, y: referenceView.frame.minY)
        runAnimation({ _ in
            self.view.animator().frame.origin = destination
        }, done: {
            self.clearAllRowBindings()
            self.view.removeFromSuperview()
            self.afterRemoved?()
        })
    }
}

extension APSequenceViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        return list[row].recorder
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        return false
    }
}

extension APSequenceViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        return list.count
    }
}
