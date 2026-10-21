import Foundation
import Testing
@testable import Beeline

// H6: keystrokes use the key that types the letter on the layout in use, not a fixed US position.
@Test func keyCodesComeFromTheCurrentLayout() throws {
    for letter: Character in ["q", "v", "a"] {
        let code = try #require(Keyboard.keyCode(for: letter))
        #expect(Keyboard.character(for: code) == letter)
    }
}
