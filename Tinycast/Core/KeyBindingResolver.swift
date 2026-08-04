import AppKit
import Carbon.HIToolbox

/// Resolves a key event into the selector macOS's own key-binding tables map it to — AppKit's `StandardKeyBinding.dict` plus whatever the user overrides in `~/Library/KeyBindings/DefaultKeyBinding.dict`. That is where the Emacs chords (⌃N/⌃P/⌃A/⌃E/⌃K/⌃Y…) already live, so the palette reads the binding instead of hardcoding a key code and inherits every user rebinding for free.
@MainActor
final class KeyBindingResolver {
    /// The arrow key a movement chord stands for. The palette already routes all four, so a resolved chord joins that one path rather than forking a second copy of it.
    struct ArrowKey: Equatable {
        let code: Int
        let character: String
    }

    /// The only four commands the palette takes over. Every other standard binding (⌃A/⌃E/⌃K/⌃Y/⌃D/⌃H/⌃T) already does the right thing in the field editor and is deliberately absent; `moveUp:`/`moveDown:` are dead ends in a single-line field, and the horizontal pair has to reach the emoji grid.
    private static let movementArrows: [Selector: ArrowKey] = [
        #selector(NSStandardKeyBindingResponding.moveDown(_:)): ArrowKey(code: kVK_DownArrow, character: "\u{F701}"),
        #selector(NSStandardKeyBindingResponding.moveUp(_:)): ArrowKey(code: kVK_UpArrow, character: "\u{F700}"),
        #selector(NSStandardKeyBindingResponding.moveForward(_:)): ArrowKey(code: kVK_RightArrow, character: "\u{F703}"),
        #selector(NSStandardKeyBindingResponding.moveBackward(_:)): ArrowKey(code: kVK_LeftArrow, character: "\u{F702}")
    ]

    /// Detached on purpose: `interpretKeyEvents` resolves against the system tables without the view ever entering a window or becoming first responder, so the probe costs one allocation and never renders.
    private final class Probe: NSTextView {
        var captured: Selector?
        // Deliberately does not call super — the probe reports the command, it must never perform it.
        override func doCommand(by selector: Selector) { captured = selector }
        // Swallowed so a chord that resolves to text can't accumulate in the probe's storage.
        override func insertText(_ string: Any, replacementRange: NSRange) {}
    }

    /// An unbound chord resolves to `noop:` rather than to nothing, which is what makes "not bound" distinguishable from "bound to something the palette doesn't own".
    private static let noop = Selector(("noop:"))
    private lazy var probe = Probe(frame: .zero)

    /// The editing command `event` means, or nil when the chord is unbound or opens a multi-stroke sequence.
    func selector(for event: NSEvent) -> Selector? {
        probe.captured = nil
        probe.interpretKeyEvents([event])
        guard let captured = probe.captured else {
            // Nothing captured means a pending multi-stroke sequence; drop it so the next lookup starts clean.
            probe.inputContext?.discardMarkedText()
            return nil
        }
        return captured == Self.noop ? nil : captured
    }

    /// The arrow key `event` stands for, or nil when the palette should leave the event alone. Gated on ⌃ so ordinary typing never reaches the resolver and a bare arrow is never handled twice.
    func movementArrow(for event: NSEvent) -> ArrowKey? {
        guard event.type == .keyDown, event.modifierFlags.contains(.control),
            let selector = selector(for: event)
        else { return nil }
        return Self.movementArrows[selector]
    }
}
