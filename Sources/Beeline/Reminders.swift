import AppKit
import EventKit

/// "remind me to call Sam tomorrow at 5pm" and "goal run a 10k" create items in macOS Reminders,
/// which works offline and syncs to the phone. Goals go in a list called Goals, made the first time.
/// The first use asks for Reminders access through the standard macOS prompt.
enum Reminders {
    private static let store = EKEventStore()

    private enum Kind {
        case reminder, goal
    }

    /// Nil unless the request starts like a reminder or a goal.
    static func results(for query: String) -> [Item]? {
        // Trimmed once, then matched and cut as the same string, so leading spaces never shift the cut.
        let text = query.trimmingCharacters(in: .whitespaces)
        let lowered = text.lowercased()
        let prefixes: [(String, Kind)] = [
            ("remind me to ", .reminder), ("remind me ", .reminder), ("reminder to ", .reminder), ("reminder ", .reminder),
            ("add reminder ", .reminder), ("new goal ", .goal), ("add goal ", .goal), ("goal ", .goal),
        ]
        guard let (prefix, kind) = prefixes.first(where: { lowered.hasPrefix($0.0) }),
              lowered.count == text.count else { return nil }
        let rest = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { return [] }

        // Without access nothing could be saved, and the bar would have closed as if it were. Say so instead.
        let status = EKEventStore.authorizationStatus(for: .reminder)
        if status == .denied || status == .restricted {
            return [Item(id: "reminder:access", kind: .action, verb: "", title: "Allow Reminders for Beeline",
                         subtitle: "Privacy & Security", keywords: "",
                         icon: NSImage(systemSymbolName: "bell.slash", accessibilityDescription: nil)) {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders") {
                    NSWorkspace.shared.open(url)
                }
            }]
        }

        let (title, due) = splitDate(rest)
        let when = due.map { formatted($0) } ?? (kind == .goal ? "Goals list" : "No time set")
        let verb = kind == .goal ? "Add goal" : "Remind me to"
        let symbol = kind == .goal ? "flag" : "bell"
        return [Item(id: "reminder:new", kind: .action, verb: verb, title: title, subtitle: "\(when) · Reminders",
                     keywords: "", icon: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)) {
            save(title: title, due: due, kind: kind)
        }]
    }

    /// Finds a date or time in the words ("tomorrow at 5pm", "in 2 hours", "friday") and removes it from the title.
    static func splitDate(_ text: String, now: Date = Date()) -> (String, Date?) {
        // "in 2 hours", "in 30 min", "in 3 days": Apple's date reader misses these, so they are read here.
        let relative = #"\s*\bin (\d+) (minute|minutes|min|mins|hour|hours|hr|hrs|day|days|week|weeks)\b"#
        if let match = text.firstMatch(of: try! Regex(relative).ignoresCase()),
           let amount = Int(match.output[1].substring ?? ""), let unit = match.output[2].substring?.lowercased() {
            let component: Calendar.Component = unit.hasPrefix("min") ? .minute : unit.hasPrefix("h") ? .hour
                : unit.hasPrefix("d") ? .day : .weekOfYear
            let title = text.replacingCharacters(in: match.range, with: "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return (title.isEmpty ? text : title, Calendar.current.date(byAdding: component, value: amount, to: Date()))
        }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
              let match = detector.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              var date = match.date, let range = Range(match.range, in: text) else { return (text, nil) }
        // "at 9am" typed at 3pm means tomorrow, not a reminder already overdue. Only a time with no day is
        // moved: "yesterday" or "today" are what they say.
        let mentioned = text[range].lowercased()
        let dayWords = ["today", "yesterday", "tomorrow", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
                        "mon", "tue", "wed", "thu", "fri", "sat", "sun", "next", "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug",
                        "sep", "oct", "nov", "dec", "/", "-"]
        if date < now, now.timeIntervalSince(date) < 86_400, !dayWords.contains(where: mentioned.contains),
           let next = Calendar.current.date(byAdding: .day, value: 1, to: date) {
            date = next
        }
        var title = text.replacingCharacters(in: range, with: "").trimmingCharacters(in: .whitespaces)
        // Drop the little words the date leaves behind: "call Sam at" becomes "call Sam".
        for word in [" at", " on", " by", " in", " for"] where title.lowercased().hasSuffix(word) {
            title = String(title.dropLast(word.count))
        }
        title = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return (title.isEmpty ? text : title, date)
    }

    private static func formatted(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.doesRelativeDateFormatting = true
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private static func save(title: String, due: Date?, kind: Kind) {
        store.requestFullAccessToReminders { granted, _ in
            guard granted else {
                Log.append("reminders: access not granted")
                Actions.report("Reminders access was not given. Allow Reminders for Beeline in Privacy & Security.")
                return
            }
            guard let list = kind == .goal ? goalsList() : store.defaultCalendarForNewReminders() else {
                Log.append("reminders: no list to save to")
                Actions.report(kind == .goal ? "Couldn't make a Goals list in Reminders." : "Reminders has no default list. Turn on Reminders in iCloud, or make a list.")
                return
            }
            let reminder = EKReminder(eventStore: store)
            reminder.title = title
            reminder.calendar = list
            if let due {
                reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
                reminder.addAlarm(EKAlarm(absoluteDate: due))
            }
            do {
                try store.save(reminder, commit: true)
                Log.append("reminders: saved \(kind == .goal ? "goal" : "reminder")")
            } catch {
                Log.append("reminders: could not save (\((error as NSError).code))")
                Actions.report("Reminders couldn't save that (\((error as NSError).code)).")
            }
        }
    }

    /// The Goals list, created in the default Reminders account the first time it is needed.
    private static func goalsList() -> EKCalendar? {
        // Only a Goals list in the default account counts: a shared list with the same name elsewhere must
        // never receive personal goals.
        guard let source = store.defaultCalendarForNewReminders()?.source else { return nil }
        if let existing = store.calendars(for: .reminder).first(where: { $0.title == "Goals" && $0.source == source }) {
            return existing
        }
        let list = EKCalendar(for: .reminder, eventStore: store)
        list.title = "Goals"
        list.source = source
        do {
            try store.saveCalendar(list, commit: true)
        } catch {
            Log.append("reminders: could not make the Goals list (\((error as NSError).code))")
            return nil
        }
        return list
    }
}
