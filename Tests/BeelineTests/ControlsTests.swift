import ApplicationServices
import Foundation
import Testing
@testable import Beeline

@Test func destructiveButtonLabelsNeedConfirming() {
    for label in ["Don't Save", "Don’t Save", "Replace", "Force Quit", "Empty Bin…", "Delete", "Send", "Move to Bin"] {
        #expect(Accessibility.isIrreversible(label), Comment(rawValue: label))
    }
    for label in ["Reorder", "Paint format", "Save", "Cancel", "Keep Both", "Archive"] {
        #expect(!Accessibility.isIrreversible(label), Comment(rawValue: label))
    }
}

@Test func dialogButtonsNeedConfirmingUnlessHarmless() {
    #expect(Accessibility.needsConfirmInDialog("Löschen"))
    #expect(Accessibility.needsConfirmInDialog("Nicht sichern"))
    #expect(Accessibility.needsConfirmInDialog("Supprimer"))
    #expect(!Accessibility.needsConfirmInDialog("Cancel"))
    #expect(!Accessibility.needsConfirmInDialog("Keep Both"))
    #expect(Accessibility.needsConfirmInDialog("OK"))
    #expect(Accessibility.needsConfirmInDialog("Ok"))
}

@Test func theConfirmCardQuotesTheDialog() {
    #expect(Accessibility.dialogSummary("Are you sure you want to\npermanently  delete these items?") == "Are you sure you want to permanently delete these items?")
    #expect(Accessibility.dialogSummary("   ") == nil)
    #expect(Accessibility.dialogSummary(String(repeating: "a", count: 300))?.count == 120)
}

@Test func closingManyTabsNeedsConfirming() {
    for label in ["Close Other Tabs", "Close All Tabs", "Close All Windows", "Close Tabs to the Right", "Close Others"] {
        #expect(Accessibility.isIrreversible(label), Comment(rawValue: label))
    }
    for label in ["Close Tab", "Close Window", "Close"] {
        #expect(!Accessibility.isIrreversible(label), Comment(rawValue: label))
    }
}

@Test func menuCommandsBelongToTheWindowTheyWereReadIn() {
    // AXUIElements made locally compare by identity without asking the app anything.
    let one = AXUIElementCreateApplication(getpid())
    let other = AXUIElementCreateApplication(1)
    #expect(Accessibility.sameWindow(one, one))
    #expect(!Accessibility.sameWindow(one, other))
    #expect(!Accessibility.sameWindow(one, nil))
    #expect(!Accessibility.sameWindow(nil, one))
    #expect(Accessibility.sameWindow(nil, nil))
}
