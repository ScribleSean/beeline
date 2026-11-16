import AppKit
import Foundation
import PDFKit
import Testing
@testable import Beeline

private func picture(_ name: String, width: Int, height: Int, in scratch: Scratch) throws -> URL {
    let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0))
    rep.setColor(.systemYellow, atX: 0, y: 0)
    let url = scratch.url.appendingPathComponent(name)
    try #require(rep.representation(using: .png, properties: [:])).write(to: url)
    return url
}

private func pixels(_ url: URL) -> (Int, Int)? {
    NSImageRep(contentsOf: url).map { ($0.pixelsWide, $0.pixelsHigh) }
}

private func typeOf(_ url: URL) -> String? {
    CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceGetType($0) as String? }
}

/// A PDF whose pages are `width` points wide, so a combined file shows which source each page came from.
private func pdf(_ name: String, pages: Int, width: CGFloat, in scratch: Scratch) throws -> URL {
    let document = PDFDocument()
    for _ in 0..<pages {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width), pixelsHigh: 100, bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                bytesPerRow: 0, bitsPerPixel: 0))
        let image = NSImage(size: NSSize(width: width, height: 100))
        image.addRepresentation(rep)
        let page = try #require(PDFPage(image: image))
        document.insert(page, at: document.pageCount)
    }
    let url = scratch.url.appendingPathComponent(name)
    try #require(document.write(to: url))
    return url
}

@Test func convertMakesACopyInTheNewFormatBesideTheOriginal() throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    let original = try picture("photo.png", width: 40, height: 20, in: scratch)

    let made = FileTools.convertPictures([original], to: "jpeg")
    #expect(made.map(\.lastPathComponent) == ["photo.jpg"])
    #expect(typeOf(try #require(made.first)) == "public.jpeg")
    #expect(typeOf(original) == "public.png", "the original stays as it was")

    let again = FileTools.convertPictures([original], to: "jpeg")
    #expect(again.map(\.lastPathComponent) == ["photo 2.jpg"], "a second convert never overwrites the first")
}

@Test func convertSkipsWhatIsNotAPicture() throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    let fake = try scratch.file("notes.png", "not an image")
    #expect(FileTools.convertPictures([fake], to: "jpeg").isEmpty)
    #expect(!scratch.exists("notes.jpg"))
}

@Test func resizeHalvesTheLongestSideOrUsesTheGivenSize() throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    let original = try picture("wide.png", width: 200, height: 100, in: scratch)

    let half = FileTools.resizePictures([original], to: nil)
    #expect(half.map(\.lastPathComponent) == ["wide small.png"])
    #expect(pixels(try #require(half.first)).map { [$0.0, $0.1] } == [100, 50])

    let sized = FileTools.resizePictures([original], to: 64)
    #expect(sized.map(\.lastPathComponent) == ["wide 64px.png"])
    #expect(pixels(try #require(sized.first)).map { [$0.0, $0.1] } == [64, 32])
    #expect(pixels(original).map { [$0.0, $0.1] } == [200, 100], "the original keeps its size")

    #expect(FileTools.resizePictures([original], to: nil).map(\.lastPathComponent) == ["wide small 2.png"])
}

@Test func combinePutsPagesInNameOrderIntoANewFile() throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    let ten = try pdf("10.pdf", pages: 1, width: 300, in: scratch)
    let two = try pdf("2.pdf", pages: 2, width: 200, in: scratch)

    let combined = try #require(FileTools.combinePDFs([ten, two]))
    #expect(combined.lastPathComponent == "Combined.pdf")
    let document = try #require(PDFDocument(url: combined))
    let widths = (0..<document.pageCount).compactMap { document.page(at: $0)?.bounds(for: .mediaBox).width }
    #expect(widths == [200, 200, 300], "2.pdf comes before 10.pdf, as Finder sorts them")
    #expect(PDFDocument(url: two)?.pageCount == 2, "the sources stay as they were")

    #expect(FileTools.combinePDFs([ten, two])?.lastPathComponent == "Combined 2.pdf")
}

@Test func combineMakesNothingFromFilesThatAreNotPDFs() throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    let a = try scratch.file("a.pdf", "not a pdf"), b = try scratch.file("b.pdf", "nor this")
    #expect(FileTools.combinePDFs([a, b]) == nil)
    #expect(FileTools.combinePDFs([]) == nil)
    #expect(!scratch.exists("Combined.pdf"))
}

@Test func renameByDateUsesEachFileCreationDateAndNeverCollides() throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    let first = try scratch.file("IMG_1.jpg"), second = try scratch.file("IMG_2.jpg")
    var parts = DateComponents()
    (parts.year, parts.month, parts.day, parts.hour, parts.minute, parts.second) = (2026, 10, 15, 10, 41, 3)
    let date = try #require(Calendar.current.date(from: parts))
    let edited = date.addingTimeInterval(86_400 * 3)  // a later edit must not decide the name
    for file in [first, second] {
        try FileManager.default.setAttributes([.creationDate: date, .modificationDate: edited], ofItemAtPath: file.path)
    }

    let renamed = FileTools.renameFilesByDate([first, second]).map(\.lastPathComponent)
    #expect(renamed == ["2026-10-15 at 10.41.03.jpg", "2026-10-15 at 10.41.03 2.jpg"])
    #expect(!scratch.exists("IMG_1.jpg") && !scratch.exists("IMG_2.jpg"))
}

extension SelectionTests {
    @Test func videosOfferASmallerCopyAndTheirAudio() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        defer { FileTools.clearSelection() }
        FileTools.useSelection([try scratch.file("clip.mov")], folder: nil)
        #expect(FileTools.results(for: "make it smaller")?.first?.title == "Make the video smaller (720p)")
        #expect(FileTools.results(for: "save the audio")?.first?.title == "Save the audio of the video")
        #expect(FileTools.results(for: "save the audio")?.first?.subtitle == "As .m4a beside the originals")
    }

    @Test func pdfsCombineOnlyWhenThereAreTwo() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        defer { FileTools.clearSelection() }
        FileTools.useSelection([try scratch.file("a.pdf")], folder: nil)
        #expect((FileTools.results(for: "combine") ?? []).isEmpty, "one PDF offers no combine row")
        FileTools.useSelection([try scratch.file("a.pdf"), try scratch.file("b.pdf")], folder: nil)
        #expect(FileTools.results(for: "merge these")?.first?.title == "Combine 2 PDFs into one")
    }
}
