import Foundation
import Testing
@testable import Beeline

// M2: labels that discard work need Return twice, apostrophes and all.
@Test func destructiveButtonLabelsNeedConfirming() {
    for label in ["Don't Save", "Don’t Save", "Replace", "Force Quit", "Empty Bin…", "Delete", "Send", "Move to Bin"] {
        #expect(Accessibility.isIrreversible(label), Comment(rawValue: label))
    }
    for label in ["Reorder", "Paint format", "Save", "Cancel", "Keep Both", "Archive"] {
        #expect(!Accessibility.isIrreversible(label), Comment(rawValue: label))
    }
}

// M2: inside a sheet or dialog every button needs confirming unless it is plainly safe, in any language.
@Test func dialogButtonsNeedConfirmingUnlessHarmless() {
    #expect(Accessibility.needsConfirmInDialog("Löschen"))
    #expect(Accessibility.needsConfirmInDialog("Nicht sichern"))
    #expect(Accessibility.needsConfirmInDialog("Supprimer"))
    #expect(!Accessibility.needsConfirmInDialog("Cancel"))
    #expect(!Accessibility.needsConfirmInDialog("Keep Both"))
    #expect(!Accessibility.needsConfirmInDialog("OK"))
}
