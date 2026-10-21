import ApplicationServices
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
    // Codex 2: "Permanently delete these items? [OK]" must not run on one Return.
    #expect(Accessibility.needsConfirmInDialog("OK"))
    #expect(Accessibility.needsConfirmInDialog("Ok"))
}

// Codex 2: the confirm card shows what the dialog asks, on one short line.
@Test func theConfirmCardQuotesTheDialog() {
    #expect(Accessibility.dialogSummary("Are you sure you want to\npermanently  delete these items?") == "Are you sure you want to permanently delete these items?")
    #expect(Accessibility.dialogSummary("   ") == nil)
    #expect(Accessibility.dialogSummary(String(repeating: "a", count: 300))?.count == 120)
}

// Codex 1: a browser's commands that close many tabs or windows need Return twice.
@Test func closingManyTabsNeedsConfirming() {
    for label in ["Close Other Tabs", "Close All Tabs", "Close All Windows", "Close Tabs to the Right", "Close Others"] {
        #expect(Accessibility.isIrreversible(label), Comment(rawValue: label))
    }
    for label in ["Close Tab", "Close Window", "Close"] {
        #expect(!Accessibility.isIrreversible(label), Comment(rawValue: label))
    }
}

// Codex 4: a menu command read with one window focused must not run in another window of the same app.
@Test func menuCommandsBelongToTheWindowTheyWereReadIn() {
    // Elements made locally compare by identity without asking the app anything.
    let one = AXUIElementCreateApplication(getpid())
    let other = AXUIElementCreateApplication(1)
    #expect(Accessibility.sameWindow(one, one))
    #expect(!Accessibility.sameWindow(one, other))
    #expect(!Accessibility.sameWindow(one, nil))
    #expect(!Accessibility.sameWindow(nil, one))
    #expect(Accessibility.sameWindow(nil, nil))
}
