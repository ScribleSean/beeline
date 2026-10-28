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

@Test func rateDownloadsRequireHTTP200AndPositiveRatesAndAlwaysComplete() async {
    let url = URL(string: "https://rates.invalid/latest")!
    for (status, body, fails) in [
        (200, #"{"rates":{"USD":1.08}}"#, false),
        (500, #"{"rates":{"USD":1.08}}"#, false),
        (200, #"{"rates":{"USD":0}}"#, false),
        (200, #"{"rates":{"USD":-1}}"#, false),
        (200, #"{"rates":{"EUR":0,"USD":1.08}}"#, false),
        (200, "invalid JSON", false),
        (200, #"{"rates":{"USD":1.08}}"#, true),
        (0, #"{"rates":{"USD":1.08}}"#, false)
    ] {
        var writes = 0
        let rates = Rates(file: URL(fileURLWithPath: "/fake/rates.json"), download: { _, done in
            let response: URLResponse? = status == 0 ? URLResponse(url: url, mimeType: nil, expectedContentLength: 0, textEncodingName: nil)
                : HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)
            done(Data(body.utf8), response, fails ? URLError(.notConnectedToInternet) : nil)
        }, read: { _ in nil }, write: { _, _ in writes += 1 })
        await withCheckedContinuation { continuation in
            rates.refreshIfStale { continuation.resume() }
        }
        let valid = status == 200 && body == #"{"rates":{"USD":1.08}}"# && !fails
        #expect(writes == (valid ? 1 : 0))
        #expect((rates.current != nil) == valid)
    }
}

@Test func failedRateDownloadCanRetryAndConcurrentCallersComplete() async {
    var downloaded: ((Data?, URLResponse?, Error?) -> Void)?
    var downloads = 0
    let rates = Rates(file: URL(fileURLWithPath: "/fake/rates.json"), download: { _, done in
        downloads += 1
        downloaded = done
    }, read: { _ in nil }, write: { _, _ in })
    await withCheckedContinuation { continuation in
        var callbacks = 0
        let completed = {
            callbacks += 1
            if callbacks == 2 { continuation.resume() }
        }
        rates.refreshIfStale(done: completed)
        rates.refreshIfStale(done: completed)
        downloaded?(nil, nil, URLError(.timedOut))
    }
    #expect(downloads == 1)
    let url = URL(string: "https://rates.invalid/latest")!
    await withCheckedContinuation { continuation in
        rates.refreshIfStale { continuation.resume() }
        downloaded?(Data(#"{"rates":{"USD":1.08}}"#.utf8),
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil), nil)
    }
    #expect(downloads == 2)
    #expect(rates.current?["USD"] == 1.08)
    var freshDone = false
    rates.refreshIfStale { freshDone = true }
    #expect(freshDone)
    #expect(downloads == 2)
}

@Test func nonpositiveSavedRatesAreNotReused() {
    let data = Data("{\"fetched\":\(Date().timeIntervalSinceReferenceDate),\"rates\":{\"USD\":0}}".utf8)
    let rates = Rates(file: URL(fileURLWithPath: "/fake/rates.json"), download: { _, _ in },
                      read: { _ in data }, write: { _, _ in })
    #expect(rates.current == nil)
}
