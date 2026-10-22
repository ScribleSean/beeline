import Foundation
import Testing
@testable import Beeline

@Test func keyCodesComeFromTheCurrentLayout() throws {
    for letter: Character in ["q", "v", "a"] {
        let code = try #require(Keyboard.keyCode(for: letter))
        #expect(Keyboard.character(for: code) == letter)
    }
}
