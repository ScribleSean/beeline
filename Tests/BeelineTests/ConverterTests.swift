import Foundation
import Testing
@testable import Beeline

@Test func decimalCommasAreDecimalPoints() {
    #expect(Calculator.evaluate("2,5 * 4") == 10)
    #expect(Calculator.evaluate("1,500 + 1") == 1501)
    #expect(Calculator.evaluate("1,234,567 - 7") == 1_234_560)
    #expect(Calculator.evaluate("3,75 * 2") == 7.5)
    #expect(Calculator.decimalPoints("2,50") == "2.50")
}

@Test func conversionsReadDecimalCommasToo() {
    #expect(Converter.answer("1,5 km in m")?.value == "1,500 m")
    #expect(Converter.answer("1,500 m in km")?.value == "1.5 km")
}

@Test func tinyAnswersAreNotZero() {
    let shown = Calculator.format(0.000000012)
    #expect(shown != "0")
    #expect(shown.contains("1.2"))
    #expect(Calculator.format(0) == "0")
    #expect(Calculator.format(2.5) == "2.5")
}

@Test func ouncesAndCupsAreUSMeasures() {
    #expect(Converter.answer("8 fl oz in ml")?.value == "236.59 ml")
    #expect(Converter.answer("8 oz in ml")?.value == "236.59 ml")
    #expect(Converter.answer("1 cup in fl oz")?.value == "8 fl oz")
    #expect(Converter.answer("1 kg in oz")?.value == "35.274 oz")
}

@Test func seasonsAreNotTimeZones() {
    #expect(Converter.answer("christmas time") == nil)
    #expect(Converter.answer("easter time") == nil)
    #expect(Converter.answer("tokyo time") != nil)
}

@Test func differentKindsAreNotConverted() {
    #expect(Converter.answer("10 km in kg") == nil)
    #expect(Converter.answer("1 cup in kg") == nil)
    #expect(Converter.answer("5 gb in hours") == nil)
}
