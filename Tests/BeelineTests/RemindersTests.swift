import Foundation
import Testing
@testable import Beeline

private let now = Calendar.current.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 15))!

@Test func relativeTimesCountFromNowInEachUnit() throws {
    let cases: [(String, Calendar.Component, Int)] = [
        ("stretch in 30 min", .minute, 30), ("call Sam in 2 hours", .hour, 2), ("pay rent in 3 days", .day, 3), ("renew in 1 week", .weekOfYear, 1),
    ]
    for (text, unit, amount) in cases {
        let (title, due) = Reminders.splitDate(text, now: now)
        #expect(due == Calendar.current.date(byAdding: unit, value: amount, to: now), "\(text)")
        #expect(!title.lowercased().contains(" in "), "\(text) kept its time words: \(title)")
    }
}

@Test func theTimeWordsAndTheirLinkingWordLeaveTheTitle() throws {
    let (title, due) = Reminders.splitDate("water the plants on Friday at 6pm", now: now)
    #expect(title == "water the plants")
    let date = try #require(due)
    #expect(Calendar.current.component(.weekday, from: date) == 6)
    #expect(Calendar.current.component(.hour, from: date) == 18)
    let plain = Reminders.splitDate("buy milk", now: now)
    #expect(plain.0 == "buy milk" && plain.1 == nil)
}

@Test func aReminderThatIsOnlyATimeKeepsTheWordsAsItsTitle() {
    #expect(Reminders.splitDate("in 2 hours", now: now).0 == "in 2 hours")
}

@Test func onlyTheReminderAndGoalWordingsOpenTheRow() {
    for query in ["remind me to call mom", "reminder water plants", "add goal run 5k", "goal read more"] {
        #expect(Reminders.results(for: query)?.isEmpty == false, "\(query)")
    }
    for query in ["reminders", "goals", "open reminders"] {
        #expect(Reminders.results(for: query) == nil, "\(query)")
    }
}
