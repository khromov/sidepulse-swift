import XCTest
@testable import SidePulseCore

/// Expected values were produced by the Python implementation.
final class LEDTextTests: XCTestCase {
    func testDecodeEscapesMatchesPython() {
        let vectors: [(String, String)] = [
            (#"a\x\\n\n\ "#, "a\\x\\n\n\\ "),
            (#"off\n#FF00FF pulse"#, "off\n#FF00FF pulse"),
            (#"abc\"#, "abc\\"),
            (#"\"#, "\\"),
            ("", ""),
            (#"\t\r\q"#, "\t\r\\q"),
            (#"\\\\n"#, "\\\\n"),
            ("\u{E9}\\n\u{1F600}", "\u{E9}\n\u{1F600}"),
        ]
        for (input, expected) in vectors {
            XCTAssertEqual(LedText.decodeEscapes(input), expected, input)
        }
    }

    func testDecodeEscapesWorksOnScalarsNotGraphemes() {
        // The backslash shares a grapheme with the combining mark but must still be seen, and kept
        // as a non-escape.
        XCTAssertEqual(LedText.decodeEscapes("\\\u{301}"), "\\\u{301}")
        XCTAssertEqual(LedText.decodeEscapes("\\n\u{301}"), "\n\u{301}")
    }

    func testDecodeEscapesDecodesOnlyOnce() {
        let once = LedText.decodeEscapes(#"off\\n#FF0000"#)
        XCTAssertEqual(once, "off\\n#FF0000")
        XCTAssertEqual(once.unicodeScalars.count, 12)
    }

    func testLineCountMatchesPythonSplitlines() {
        let vectors: [(String, Int)] = [
            ("", 0), ("a", 1), ("a\n", 1), ("\n\n", 2), ("a\nb", 2), ("a\r\nb", 2), ("a\rb", 2),
            ("a\r\n", 1), ("\r\n\r\n", 2), ("a\n\nb", 3), ("\r", 1), ("\n\r", 2), ("x\r\r\n", 2),
        ]
        for (input, expected) in vectors {
            XCTAssertEqual(LedText.lineCount(input), expected, input.debugDescription)
        }
    }

    /// Deliberate deviation: Python's `splitlines` also splits on VT, FF, FS/GS/RS, NEL and U+2028/U+2029.
    func testOnlyCommonSeparatorsSplitLines() {
        for separator in ["\u{0B}", "\u{0C}", "\u{1C}", "\u{1D}", "\u{1E}", "\u{85}", "\u{2028}", "\u{2029}"] {
            XCTAssertEqual(LedText.splitLines("a\(separator)b"), ["a\(separator)b"], separator.debugDescription)
        }
    }

    func testSplitLinesDropsSeparatorsAndTrailingNewline() {
        XCTAssertEqual(LedText.splitLines("a\r\nb\rc\n"), ["a", "b", "c"])
        XCTAssertEqual(LedText.splitLines("a\n\nb"), ["a", "", "b"])
        XCTAssertEqual(LedText.splitLines(""), [])
        XCTAssertEqual(LedText.splitLines("\u{E9}\n\u{1F600}"), ["\u{E9}", "\u{1F600}"])
    }

    func testValidateAcceptsProgramsAtTheLimits() throws {
        try LedText.validate(" ")
        try LedText.validate(String(repeating: "x", count: 512))
        try LedText.validate(Array(repeating: "off", count: 20).joined(separator: "\n"))
        try LedText.validate(String(repeating: "off\n", count: 20))
        try LedText.validate(String(repeating: "\n", count: 20))
    }

    func testValidateRejectsWithPythonMessages() {
        let vectors: [(String, String)] = [
            ("", "LED program is empty."),
            (String(repeating: "x", count: 513), "LED program is 513 bytes; max is 512."),
            (String(repeating: "\u{E9}", count: 257), "LED program is 514 bytes; max is 512."),
            (Array(repeating: "off", count: 21).joined(separator: "\n"), "LED program has 21 lines; max is 20."),
            (String(repeating: "\n", count: 21), "LED program has 21 lines; max is 20."),
        ]
        for (program, message) in vectors {
            XCTAssertThrowsError(try LedText.validate(program)) { error in
                XCTAssertEqual(error as? LedError, .invalidProgram(message))
                XCTAssertEqual(error.localizedDescription, message)
            }
        }
    }

    func testErrorDescriptions() {
        XCTAssertEqual(LedError.noDevice.localizedDescription,
                       "No SidePulse Pro or SidePulse Dot device found. Mount the device, or pass --device /path/to/SidePulseDot.")
        XCTAssertEqual(LedError.multipleDevices(["/Volumes/A", "/Volumes/B"]).localizedDescription,
                       "Multiple possible devices found. Pass --device with one of:\n  /Volumes/A\n  /Volumes/B")
        XCTAssertEqual(LedError.unknownAnimation("nope").localizedDescription, "Unknown animation: nope")
    }
}
