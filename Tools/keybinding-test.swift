import AppKit
import Carbon.HIToolbox

/// Drives `KeyBindingResolver` with synthesized key events. Unlike the other harnesses this one reads a real environment — the system key-binding tables — so it needs a GUI session, and a personal `~/Library/KeyBindings/DefaultKeyBinding.dict` can legitimately change what a chord resolves to. Every expectation that depends on a system default is therefore skipped (loudly) when the local tables disagree; the structural invariants below are asserted unconditionally.
@MainActor
private func key(
    _ code: Int, _ characters: String, ignoringModifiers: String? = nil,
    _ flags: NSEvent.ModifierFlags = .control, type: NSEvent.EventType = .keyDown
) -> NSEvent {
    NSEvent.keyEvent(
        with: type, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
        context: nil, characters: characters,
        charactersIgnoringModifiers: ignoringModifiers ?? characters, isARepeat: false,
        keyCode: UInt16(code))!
}

@main
@MainActor
struct KeyBindingResolverTests {
    static var failures = 0
    static var passes = 0
    static var skips = 0
    static let resolver = KeyBindingResolver()

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if condition() {
            passes += 1
        } else {
            failures += 1
            print("FAIL: \(message)")
        }
    }

    static func skip(_ message: String) {
        skips += 1
        print("SKIP: \(message)")
    }

    // MARK: - The four chords the palette takes over

    /// Each movement chord must resolve to the arrow key it stands for, so ⌃N and ↓ reach exactly one handler.
    static func movement() {
        let cases: [(name: String, event: NSEvent, selector: String, arrow: Int, character: String)] = [
            ("⌃N", key(kVK_ANSI_N, "\u{0E}", ignoringModifiers: "n"), "moveDown:", kVK_DownArrow, "\u{F701}"),
            ("⌃P", key(kVK_ANSI_P, "\u{10}", ignoringModifiers: "p"), "moveUp:", kVK_UpArrow, "\u{F700}"),
            ("⌃F", key(kVK_ANSI_F, "\u{06}", ignoringModifiers: "f"), "moveForward:", kVK_RightArrow, "\u{F703}"),
            ("⌃B", key(kVK_ANSI_B, "\u{02}", ignoringModifiers: "b"), "moveBackward:", kVK_LeftArrow, "\u{F702}")
        ]
        for test in cases {
            let resolved = resolver.selector(for: test.event).map(NSStringFromSelector)
            guard resolved == test.selector else {
                skip("\(test.name) is rebound locally to \(resolved ?? "nothing") — system default is \(test.selector)")
                continue
            }
            let arrow = resolver.movementArrow(for: test.event)
            expect(
                arrow == KeyBindingResolver.ArrowKey(code: test.arrow, character: test.character),
                "\(test.name) becomes its arrow key — got \(arrow.map { "\($0.code)" } ?? "nil"), want \(test.arrow)")
        }
    }

    // MARK: - What must be left alone

    /// The rest of the standard bindings already behave correctly in the field editor; taking one over would break editing.
    static func passThrough() {
        let cases: [(name: String, event: NSEvent, selector: String)] = [
            ("⌃A", key(kVK_ANSI_A, "\u{01}", ignoringModifiers: "a"), "moveToBeginningOfParagraph:"),
            ("⌃E", key(kVK_ANSI_E, "\u{05}", ignoringModifiers: "e"), "moveToEndOfParagraph:"),
            ("⌃K", key(kVK_ANSI_K, "\u{0B}", ignoringModifiers: "k"), "deleteToEndOfParagraph:"),
            ("⌃D", key(kVK_ANSI_D, "\u{04}", ignoringModifiers: "d"), "deleteForward:"),
            ("⌃H", key(kVK_ANSI_H, "\u{08}", ignoringModifiers: "h"), "deleteBackward:"),
            ("⌃T", key(kVK_ANSI_T, "\u{14}", ignoringModifiers: "t"), "transpose:")
        ]
        for test in cases {
            let resolved = resolver.selector(for: test.event).map(NSStringFromSelector)
            if resolved == test.selector {
                passes += 1
            } else {
                skip("\(test.name) is rebound locally to \(resolved ?? "nothing") — system default is \(test.selector)")
            }
            // Structural, so it holds under any local rebinding: only the four movement commands are ever taken over.
            expect(
                resolver.movementArrow(for: test.event) == nil,
                "\(test.name) stays with the field editor")
        }
    }

    /// A chord bound to nothing resolves to `noop:`, which the resolver reports as nil rather than as a command.
    static func unbound() {
        let event = key(kVK_ANSI_G, "\u{07}", ignoringModifiers: "g")
        if resolver.selector(for: event) == nil {
            passes += 1
        } else {
            skip("⌃G is bound locally — the system leaves it unbound")
        }
        expect(resolver.movementArrow(for: event) == nil, "an unbound chord is never substituted")
    }

    /// The ⌃ gate: without it the resolver would run on every keystroke and steal both plain typing and the bare arrows the palette already handles.
    static func gating() {
        expect(
            resolver.movementArrow(for: key(kVK_ANSI_N, "n", [])) == nil,
            "plain typing is never substituted")
        expect(
            resolver.movementArrow(for: key(kVK_DownArrow, "\u{F701}", [])) == nil,
            "a bare ↓ is left to the palette's own handler, never handled twice")
        expect(
            resolver.movementArrow(for: key(kVK_ANSI_N, "\u{0E}", ignoringModifiers: "n", type: .keyUp)) == nil,
            "only keyDown is substituted")
    }

    /// ⇧ resolves to the selection-extending twin, which the palette does not own — so ⌃⇧N still extends the selection in the field.
    static func shifted() {
        let event = key(kVK_ANSI_N, "\u{0E}", ignoringModifiers: "N", [.control, .shift])
        let resolved = resolver.selector(for: event).map(NSStringFromSelector)
        if resolved == "moveDownAndModifySelection:" {
            passes += 1
        } else {
            skip("⌃⇧N is rebound locally to \(resolved ?? "nothing")")
        }
        expect(resolver.movementArrow(for: event) == nil, "⌃⇧N extends the selection instead of moving the list")
    }

    /// Repeated lookups must not accumulate state in the probe — the same chord resolves the same way forever.
    static func stability() {
        let event = key(kVK_ANSI_N, "\u{0E}", ignoringModifiers: "n")
        let first = resolver.movementArrow(for: event)
        for _ in 0..<200 { _ = resolver.movementArrow(for: event) }
        expect(resolver.movementArrow(for: event) == first, "the probe is stateless across lookups")
    }

    static func main() {
        // NSTextView needs the shared application; `.prohibited` keeps the harness out of the Dock and the switcher.
        NSApplication.shared.setActivationPolicy(.prohibited)

        movement()
        passThrough()
        unbound()
        gating()
        shifted()
        stability()

        print("\(passes) passed, \(failures) failed, \(skips) skipped")
        if failures > 0 { exit(1) }
    }
}
