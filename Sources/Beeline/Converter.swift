import Foundation

/// An answer shown large in the bar: what kind it is, the value itself, and a line of working underneath.
struct Answer {
    let label: String
    let value: String
    let detail: String
}

/// Answers conversions typed into the bar: units ("10 km in mi"), time zones ("3pm london in new york",
/// "time in tokyo") and currencies ("100 usd in eur").
enum Converter {
    static func answer(_ query: String) -> Answer? {
        let text = normalised(query)
        return currency(text) ?? units(text) ?? time(text)
    }

    /// Lowercases, and turns "$100" into "100 usd" so currency symbols read like codes.
    private static func normalised(_ query: String) -> String {
        var text = query.lowercased().trimmingCharacters(in: .whitespaces)
        for (symbol, code) in [("$", "usd"), ("€", "eur"), ("£", "gbp"), ("¥", "jpy"), ("₹", "inr")] {
            // "$100" becomes "100 usd"; a symbol standing alone ("in $") becomes the code.
            let escaped = NSRegularExpression.escapedPattern(for: symbol)
            text = text.replacingOccurrences(of: "\(escaped)([0-9.,]+)", with: "$1 \(code)", options: .regularExpression)
            text = text.replacingOccurrences(of: symbol, with: " \(code) ")
        }
        return text.replacingOccurrences(of: "°", with: "").replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// "<number> <unit> in|to <unit>", as (number, from, to).
    private static func split(_ text: String) -> (Double, String, String)? {
        let pattern = #"^(-?[0-9][0-9.,]*)\s*([a-z/ ]+?)\s+(?:in|to|into|as)\s+([a-z/ ]+)$"#
        guard let match = text.firstMatch(of: try! Regex(pattern)),
              let number = Double(String(match.output[1].substring ?? "").replacingOccurrences(of: ",", with: "")),
              let from = match.output[2].substring, let to = match.output[3].substring else { return nil }
        return (number, String(from).trimmingCharacters(in: .whitespaces), String(to).trimmingCharacters(in: .whitespaces))
    }

    static func format(_ value: Double, money: Bool = false) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        if money {
            formatter.minimumFractionDigits = 2
            formatter.maximumFractionDigits = 2
        } else if abs(value) < 1, value != 0 {
            // Small values keep four meaningful digits: 0.4536, not 0.453592 or 0.454.
            formatter.usesSignificantDigits = true
            formatter.maximumSignificantDigits = 4
        } else {
            formatter.maximumFractionDigits = abs(value) >= 100 ? 2 : 3
        }
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    // MARK: Units

    private static let unitNames: [String: (Dimension, String)] = {
        var table: [String: (Dimension, String)] = [:]
        func add(_ unit: Dimension, _ label: String, _ names: String) {
            for name in names.split(separator: " ") { table[String(name)] = (unit, label) }
        }
        add(UnitLength.millimeters, "mm", "mm millimeter millimeters millimetre millimetres")
        add(UnitLength.centimeters, "cm", "cm centimeter centimeters centimetre centimetres")
        add(UnitLength.meters, "m", "m meter meters metre metres")
        add(UnitLength.kilometers, "km", "km kms kilometer kilometers kilometre kilometres")
        add(UnitLength.inches, "in", "inch inches")
        add(UnitLength.feet, "ft", "ft foot feet")
        add(UnitLength.yards, "yd", "yd yard yards")
        add(UnitLength.miles, "mi", "mi mile miles")
        add(UnitMass.milligrams, "mg", "mg milligram milligrams")
        add(UnitMass.grams, "g", "g gram grams")
        add(UnitMass.kilograms, "kg", "kg kgs kilo kilos kilogram kilograms")
        add(UnitMass.ounces, "oz", "oz ounce ounces")
        add(UnitMass.pounds, "lb", "lb lbs pound pounds")
        add(UnitMass.stones, "st", "stone stones")
        add(UnitTemperature.celsius, "°C", "c celsius centigrade")
        add(UnitTemperature.fahrenheit, "°F", "f fahrenheit")
        add(UnitTemperature.kelvin, "K", "k kelvin")
        add(UnitVolume.milliliters, "ml", "ml milliliter milliliters millilitre millilitres")
        add(UnitVolume.liters, "l", "l liter liters litre litres")
        add(UnitVolume.gallons, "gal", "gal gallon gallons")
        add(UnitVolume.cups, "cups", "cup cups")
        add(UnitVolume.fluidOunces, "fl oz", "floz")
        add(UnitVolume.tablespoons, "tbsp", "tbsp tablespoon tablespoons")
        add(UnitVolume.teaspoons, "tsp", "tsp teaspoon teaspoons")
        add(UnitSpeed.kilometersPerHour, "km/h", "kmh kph km/h")
        add(UnitSpeed.milesPerHour, "mph", "mph")
        add(UnitSpeed.metersPerSecond, "m/s", "m/s mps")
        add(UnitSpeed.knots, "knots", "knot knots kn")
        add(UnitInformationStorage.bytes, "B", "b byte bytes")
        add(UnitInformationStorage.kilobytes, "KB", "kb kilobyte kilobytes")
        add(UnitInformationStorage.megabytes, "MB", "mb megabyte megabytes")
        add(UnitInformationStorage.gigabytes, "GB", "gb gigabyte gigabytes")
        add(UnitInformationStorage.terabytes, "TB", "tb terabyte terabytes")
        add(UnitDuration.seconds, "s", "s sec secs second seconds")
        add(UnitDuration.minutes, "min", "min mins minute minutes")
        add(UnitDuration.hours, "h", "h hr hrs hour hours")
        add(UnitArea.squareMeters, "m²", "sqm m2")
        add(UnitArea.squareFeet, "ft²", "sqft ft2")
        add(UnitArea.acres, "acres", "acre acres")
        add(UnitArea.hectares, "ha", "ha hectare hectares")
        return table
    }()

    private static func units(_ text: String) -> Answer? {
        guard let (value, fromName, toName) = split(text),
              let (from, fromLabel) = unitNames[fromName], let (to, label) = unitNames[toName],
              // Converting between different kinds (length to mass) would crash, so it is refused.
              type(of: from) == type(of: to) else { return nil }
        let result = Measurement(value: value, unit: from).converted(to: to).value
        // Checked with `is`, because Foundation hands back private subclasses of these unit types.
        let kind = from is UnitLength ? "Length" : from is UnitMass ? "Weight" : from is UnitTemperature ? "Temperature"
            : from is UnitVolume ? "Volume" : from is UnitSpeed ? "Speed" : from is UnitInformationStorage ? "Data"
            : from is UnitDuration ? "Time" : from is UnitArea ? "Area" : "Conversion"
        let precise = NumberFormatter()
        precise.numberStyle = .decimal
        precise.maximumFractionDigits = 8
        return Answer(label: kind, value: "\(format(result)) \(label)",
                      detail: "\(format(value)) \(fromLabel) = \(precise.string(from: NSNumber(value: result)) ?? "") \(label)")
    }

    // MARK: Currency

    private static let currencyNames: [String: String] = [
        "dollar": "USD", "dollars": "USD", "bucks": "USD", "euro": "EUR", "euros": "EUR",
        "pound": "GBP", "pounds": "GBP", "quid": "GBP", "sterling": "GBP", "yen": "JPY",
        "rupee": "INR", "rupees": "INR", "yuan": "CNY", "rmb": "CNY", "won": "KRW", "franc": "CHF", "francs": "CHF",
        "peso": "MXN", "pesos": "MXN", "real": "BRL", "reais": "BRL", "rand": "ZAR", "lira": "TRY",
        "canadian dollars": "CAD", "australian dollars": "AUD",
    ]

    private static func currencyCode(_ name: String, in rates: [String: Double]) -> String? {
        let upper = name.uppercased()
        if rates[upper] != nil { return upper }
        return currencyNames[name]
    }

    private static func currency(_ text: String) -> Answer? {
        guard let rates = Rates.shared.current, let (value, fromName, toName) = split(text),
              let from = currencyCode(fromName, in: rates), let to = currencyCode(toName, in: rates),
              let fromRate = rates[from], let toRate = rates[to] else { return nil }
        // Rates are per euro, so convert through the euro.
        let rate = toRate / fromRate
        let precise = NumberFormatter()
        precise.numberStyle = .decimal
        precise.maximumFractionDigits = 4
        let day = Rates.shared.day.map { " from \($0)" } ?? ""
        return Answer(label: "Currency", value: "\(format(value * rate, money: true)) \(to)",
                      detail: "1 \(from) = \(precise.string(from: NSNumber(value: rate)) ?? "") \(to) · European Central Bank rate\(day)")
    }

    // MARK: Time zones

    private static let zoneAliases: [String: String] = [
        "sf": "America/Los_Angeles", "san francisco": "America/Los_Angeles", "la": "America/Los_Angeles",
        "seattle": "America/Los_Angeles", "pacific": "America/Los_Angeles", "pst": "America/Los_Angeles",
        "pdt": "America/Los_Angeles", "pt": "America/Los_Angeles", "nyc": "America/New_York", "ny": "America/New_York",
        "boston": "America/New_York", "eastern": "America/New_York", "est": "America/New_York", "edt": "America/New_York",
        "et": "America/New_York", "austin": "America/Chicago", "dallas": "America/Chicago", "central": "America/Chicago",
        "cst": "America/Chicago", "cdt": "America/Chicago", "mountain": "America/Denver", "mst": "America/Denver",
        "utc": "UTC", "gmt": "GMT", "uk": "Europe/London", "bst": "Europe/London", "cet": "Europe/Paris",
        "cest": "Europe/Paris", "india": "Asia/Kolkata", "ist": "Asia/Kolkata", "mumbai": "Asia/Kolkata",
        "delhi": "Asia/Kolkata", "bangalore": "Asia/Kolkata", "bengaluru": "Asia/Kolkata", "beijing": "Asia/Shanghai",
        "china": "Asia/Shanghai", "japan": "Asia/Tokyo", "jst": "Asia/Tokyo", "sydney": "Australia/Sydney",
        "aest": "Australia/Sydney", "berlin": "Europe/Berlin", "dubai": "Asia/Dubai", "toronto": "America/Toronto",
    ]

    private static func zone(_ name: String) -> TimeZone? {
        let name = name.trimmingCharacters(in: .whitespaces)
        if name == "here" || name == "local" { return .current }
        if let id = zoneAliases[name] { return TimeZone(identifier: id) }
        // "new york" matches America/New_York, "tokyo" matches Asia/Tokyo.
        let match = TimeZone.knownTimeZoneIdentifiers.first { identifier in
            identifier.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ").lowercased() } == name
        }
        return match.flatMap(TimeZone.init(identifier:))
    }

    /// "3pm", "3:30 pm", "15:00", "noon" as hour and minute.
    private static func clock(_ text: String) -> (Int, Int)? {
        if text == "noon" { return (12, 0) }
        if text == "midnight" { return (0, 0) }
        guard let match = text.firstMatch(of: try! Regex(#"^(\d{1,2})(?::(\d{2}))?\s*(am|pm)?$"#)),
              var hour = Int(match.output[1].substring ?? "") else { return nil }
        let minute = Int(match.output[2].substring ?? "") ?? 0
        let half = match.output[3].substring.map(String.init)
        if half == nil, match.output[2].substring == nil { return nil } // a bare "3" is not a time
        if half == "pm", hour < 12 { hour += 12 }
        if half == "am", hour == 12 { hour = 0 }
        guard hour < 24, minute < 60 else { return nil }
        return (hour, minute)
    }

    private static func time(_ text: String) -> Answer? {
        let display = DateFormatter()
        display.dateFormat = "h:mm a, EEE"

        // "time in tokyo", "tokyo time", "what time is it in tokyo"
        for pattern in [#"^(?:what )?time(?: is it)? in (.+)$"#, #"^(.+) time$"#] {
            if let match = text.firstMatch(of: try! Regex(pattern)), let place = match.output[1].substring,
               let target = zone(String(place)) {
                display.timeZone = target
                return Answer(label: "Time in \(name(of: target))", value: display.string(from: Date()),
                              detail: "Now, \(target.abbreviation() ?? target.identifier)")
            }
        }

        // "3pm london in new york", "3pm in tokyo" (from here)
        guard let match = text.firstMatch(of: try! Regex(#"^(.+?)\s+(?:in|to)\s+(.+)$"#)),
              let left = match.output[1].substring, let right = match.output[2].substring,
              let target = zone(String(right)) else { return nil }
        let words = left.split(separator: " ").map(String.init)
        var source = TimeZone.current
        var clockText = String(left)
        // The clock is the first one or two words; anything after is the source place.
        for count in [2, 1] where words.count >= count {
            let candidate = words.prefix(count).joined(separator: " ")
            guard clock(candidate) != nil else { continue }
            let rest = words.dropFirst(count).joined(separator: " ")
            if rest.isEmpty { clockText = candidate; break }
            if let place = zone(rest) { clockText = candidate; source = place; break }
        }
        guard let (hour, minute) = clock(clockText) else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = source
        var parts = calendar.dateComponents([.year, .month, .day], from: Date())
        parts.hour = hour
        parts.minute = minute
        guard let moment = calendar.date(from: parts) else { return nil }
        let original = DateFormatter()
        original.dateFormat = "h:mm a"
        original.timeZone = source
        display.timeZone = target
        return Answer(label: "Time in \(name(of: target))", value: display.string(from: moment),
                      detail: "\(original.string(from: moment)) in \(name(of: source))")
    }

    private static func name(of zone: TimeZone) -> String {
        return zone.identifier.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? zone.identifier
    }
}

/// Exchange rates from the European Central Bank, through the free Frankfurter service. No key and no
/// personal data: the request is a plain fetch of today's rates. Kept on disk and refreshed twice a day.
final class Rates {
    static let shared = Rates()

    private struct Saved: Codable {
        var fetched: Date
        var rates: [String: Double]
        /// The day the bank published these rates, as the service reports it.
        var day: String?
    }

    private var saved: Saved?
    private let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Beeline/rates.json")
    private var isFetching = false

    /// Rates per euro, or nil until the first fetch has finished.
    var current: [String: Double]? { saved?.rates }
    var day: String? { saved?.day }

    private init() {
        if let data = try? Data(contentsOf: file) { saved = try? JSONDecoder().decode(Saved.self, from: data) }
    }

    /// Fetches new rates when there are none or they are over twelve hours old. `done` runs on the main thread.
    func refreshIfStale(wait: Bool = false, done: @escaping () -> Void = {}) {
        if let saved, Date().timeIntervalSince(saved.fetched) < 12 * 3600 { return }
        guard !isFetching, let url = URL(string: "https://api.frankfurter.dev/v1/latest") else { return }
        isFetching = true
        let finished = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: url) { data, _, _ in
            defer { finished.signal() }
            guard let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  var rates = object["rates"] as? [String: Double] else {
                DispatchQueue.main.async { self.isFetching = false }
                return
            }
            rates["EUR"] = 1
            let fresh = Saved(fetched: Date(), rates: rates, day: object["date"] as? String)
            try? FileManager.default.createDirectory(at: self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(fresh).write(to: self.file, options: .atomic)
            DispatchQueue.main.async {
                self.saved = fresh
                self.isFetching = false
                done()
            }
            if wait { self.saved = fresh }
        }.resume()
        if wait { finished.wait() }
    }
}
