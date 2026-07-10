import AppKit
import XCTest
@testable import Talkeo

final class TextRecognizerTests: XCTestCase {
    /// Real OCR on a synthetic image — Vision runs headless under
    /// `swift test`, so this exercises the actual recognition path, not a
    /// fake. Generous timeout: the first Vision invocation loads its models.
    func testRecognizesRenderedText() {
        let image = Self.rendered(text: "TALKEO CAPTURE 42")
        let done = expectation(description: "recognition")
        VisionTextRecognizer().recognizeText(in: image) { text in
            XCTAssertTrue(Thread.isMainThread)
            // Casing is the OCR model's business, content is ours.
            let upper = text?.uppercased() ?? ""
            XCTAssertTrue(upper.contains("TALKEO"), "got: \(text ?? "nil")")
            XCTAssertTrue(upper.contains("42"), "got: \(text ?? "nil")")
            done.fulfill()
        }
        waitForExpectations(timeout: 10)
    }

    func testBlankImageYieldsNil() {
        let image = Self.rendered(text: "")
        let done = expectation(description: "recognition")
        VisionTextRecognizer().recognizeText(in: image) { text in
            XCTAssertNil(text)
            done.fulfill()
        }
        waitForExpectations(timeout: 10)
    }

    /// Big black text on white — the friendliest possible OCR input, so a
    /// failure here means the pipeline is broken, not that OCR is hard.
    private static func rendered(text: String) -> CGImage {
        let size = NSSize(width: 900, height: 200)
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        (text as NSString).draw(
            at: NSPoint(x: 40, y: 60),
            withAttributes: [
                .font: NSFont.boldSystemFont(ofSize: 64),
                .foregroundColor: NSColor.black
            ]
        )
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage!
    }
}

final class CaptureActionTextTests: XCTestCase {
    func testSelectionWinsOverTranscript() {
        XCTAssertEqual(CaptureActionText.resolve(selected: "picked", transcript: "everything"), "picked")
    }

    func testWhitespaceSelectionFallsBackToTranscript() {
        XCTAssertEqual(CaptureActionText.resolve(selected: "  \n", transcript: "everything"), "everything")
    }

    func testNilSelectionUsesTranscript() {
        XCTAssertEqual(CaptureActionText.resolve(selected: nil, transcript: "everything"), "everything")
    }

    func testNothingAnywhereIsNil() {
        XCTAssertNil(CaptureActionText.resolve(selected: nil, transcript: nil))
        XCTAssertNil(CaptureActionText.resolve(selected: " ", transcript: "\n"))
    }

    func testResultsAreTrimmed() {
        XCTAssertEqual(CaptureActionText.resolve(selected: "  word \n", transcript: nil), "word")
        XCTAssertEqual(CaptureActionText.resolve(selected: nil, transcript: " text \n"), "text")
    }
}
