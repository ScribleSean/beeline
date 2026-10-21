import AppKit
import Carbon.HIToolbox

/// Fakes keystrokes the way a person would type them. Keys are looked up in the keyboard layout in use,
/// so ⌘V is the key that types "v" on Dvorak and AZERTY too, not the key in that position on a US keyboard.
enum Keyboard {
    /// True when macOS will deliver keystrokes Beeline posts, which needs the Accessibility permission.
    /// Without it they are dropped silently.
    static var canPostKeys: Bool { CGPreflightPostEventAccess() }

    /// The key that types this character with no modifiers on the current layout, if any.
    static func keyCode(for character: Character) -> CGKeyCode? {
        guard let layout = currentLayout() else { return nil }
        for code in 0..<128 {
            if self.character(for: CGKeyCode(code), in: layout) == character { return CGKeyCode(code) }
        }
        return nil
    }

    /// The unmodified character a key types on the current layout.
    static func character(for code: CGKeyCode) -> Character? {
        currentLayout().flatMap { character(for: code, in: $0) }
    }

    /// Posts a key down and up for the key that types `character`, with the modifiers held.
    /// False when the key cannot be found or keystrokes cannot be posted.
    @discardableResult
    static func press(_ character: Character, flags: CGEventFlags) -> Bool {
        guard canPostKeys, let code = keyCode(for: character) ?? fallback[character] else { return false }
        for isDown in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: isDown)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
        return true
    }

    /// US positions, used only when the layout cannot be read at all.
    private static let fallback: [Character: CGKeyCode] = ["q": CGKeyCode(kVK_ANSI_Q), "v": CGKeyCode(kVK_ANSI_V)]

    private static func currentLayout() -> Data? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        return Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
    }

    private static func character(for code: CGKeyCode, in layout: Data) -> Character? {
        layout.withUnsafeBytes { bytes -> Character? in
            guard let base = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var deadKeys: UInt32 = 0
            var length = 0
            var characters = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(base, UInt16(code), UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                                        UInt32(kUCKeyTranslateNoDeadKeysMask), &deadKeys, 4, &length, &characters)
            guard status == noErr, length == 1 else { return nil }
            return String(utf16CodeUnits: characters, count: 1).first
        }
    }
}
