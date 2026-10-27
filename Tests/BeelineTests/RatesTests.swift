import Foundation
import Testing
@testable import Beeline

// Hand-written Frankfurter-shaped response; these tests never download rates.
@Test func currencyRatesParseSavedResponse() throws {
    let fixture = try #require(Bundle.module.url(forResource: "currency-rates", withExtension: "json", subdirectory: "Fixtures"))
    let parsed = try #require(Rates.parse(Data(contentsOf: fixture)))
    #expect(parsed.day == "2026-10-26")
    #expect(parsed.rates == ["EUR": 1, "AUD": 1.6523, "CAD": 1.5124, "CHF": 0.9342,
                             "GBP": 0.8657, "INR": 97.234, "JPY": 163.45, "USD": 1.0876])
}

@Test func currencyRatesRejectMalformedOrPartialResponses() {
    for response in [
        #"{"amount":1,"base":"EUR","date":"2026-10-26","rates":{"USD":1.08"#,
        #"{"amount":1,"base":"EUR","date":"2026-10-26"}"#,
        #"{"rates":{}}"#,
        #"{"rates":{"USD":1.08,"GBP":"unavailable"}}"#,
        #"{"rates":null}"#,
        "[]"
    ] {
        #expect(Rates.parse(Data(response.utf8)) == nil, "Rejected response: \(response)")
    }
}
