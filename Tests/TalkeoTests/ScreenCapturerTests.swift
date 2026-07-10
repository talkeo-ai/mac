import AppKit
import XCTest
@testable import Talkeo

final class ScreenCapturerTests: XCTestCase {
    /// The arguments contract: interactive mode, PNG pinned, output path in
    /// the temp dir. The exact flags matter — `-i` is the whole UX.
    func testLaunchesInteractivePNGCaptureIntoTempFile() {
        var arguments: [String]?
        let capturer = CLIScreenCapturer { args, onExit in
            arguments = args
            onExit(0)
        }
        let done = expectation(description: "completion")
        capturer.captureInteractive { _ in done.fulfill() }
        waitForExpectations(timeout: 2)

        XCTAssertEqual(arguments?.first, "-i")
        XCTAssertTrue(arguments?.contains("png") == true)
        let path = arguments?.last ?? ""
        XCTAssertTrue(path.hasSuffix(".png"))
        XCTAssertTrue(path.hasPrefix(FileManager.default.temporaryDirectory.path))
    }

    /// Esc in the system UI exits without writing the file. This pins the
    /// file-absence-over-exit-code contract: screencapture's exit codes
    /// aren't documented, the missing file is the reliable signal.
    func testMissingOutputFileMeansCancelled() {
        let capturer = CLIScreenCapturer { _, onExit in onExit(1) }
        let done = expectation(description: "completion")
        capturer.captureInteractive { outcome in
            if case .cancelled = outcome {} else {
                XCTFail("expected .cancelled, got \(outcome)")
            }
            done.fulfill()
        }
        waitForExpectations(timeout: 2)
    }

    func testWrittenFileDecodesToImageAndTempFileIsRemoved() {
        var outputPath: String?
        let capturer = CLIScreenCapturer { args, onExit in
            let path = args.last!
            outputPath = path
            try? Self.tinyPNG().write(to: URL(fileURLWithPath: path))
            onExit(0)
        }
        let done = expectation(description: "completion")
        capturer.captureInteractive { outcome in
            guard case .image(let image) = outcome else {
                XCTFail("expected .image, got \(outcome)")
                done.fulfill()
                return
            }
            XCTAssertTrue(image.isValid)
            // The tool's output must not accumulate in tmp.
            XCTAssertFalse(FileManager.default.fileExists(atPath: outputPath!))
            done.fulfill()
        }
        waitForExpectations(timeout: 2)
    }

    func testUndecodableFileMeansFailed() {
        let capturer = CLIScreenCapturer { args, onExit in
            try? Data("not a png".utf8).write(to: URL(fileURLWithPath: args.last!))
            onExit(0)
        }
        let done = expectation(description: "completion")
        capturer.captureInteractive { outcome in
            if case .failed = outcome {} else {
                XCTFail("expected .failed, got \(outcome)")
            }
            done.fulfill()
        }
        waitForExpectations(timeout: 2)
    }

    /// A second click on the bar button while the crosshair is already up
    /// must be dropped — two concurrent system capture sessions make no sense.
    func testReentrantCaptureIsIgnoredWhileFirstIsRunning() {
        var pendingExit: ((Int32) -> Void)?
        let capturer = CLIScreenCapturer { _, onExit in pendingExit = onExit }

        var firstCompleted = false
        capturer.captureInteractive { _ in firstCompleted = true }

        let never = expectation(description: "second completion never fires")
        never.isInverted = true
        capturer.captureInteractive { _ in never.fulfill() }
        waitForExpectations(timeout: 0.3)

        // Let the first capture finish so it doesn't leak into other tests.
        pendingExit?(1)
        let done = expectation(description: "first completion")
        DispatchQueue.main.async { done.fulfill() }
        waitForExpectations(timeout: 2)
        XCTAssertTrue(firstCompleted)
    }

    func testCompletionArrivesOnMainThread() {
        let capturer = CLIScreenCapturer { _, onExit in
            // Exit from a background queue like the real terminationHandler.
            DispatchQueue.global().async { onExit(1) }
        }
        let done = expectation(description: "completion")
        capturer.captureInteractive { _ in
            XCTAssertTrue(Thread.isMainThread)
            done.fulfill()
        }
        waitForExpectations(timeout: 2)
    }

    /// 1×1 white PNG rendered on the fly — no fixture files in the repo.
    private static func tinyPNG() -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        rep.setColor(.white, atX: 0, y: 0)
        return rep.representation(using: .png, properties: [:])!
    }
}
