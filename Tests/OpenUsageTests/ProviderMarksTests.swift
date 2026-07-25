import XCTest
@testable import OpenUsage

@MainActor
final class ProviderMarksTests: XCTestCase {
    func testGrokResolvesToVectorMarkNotBoltFallback() {
        let mark = ProviderMarks.mark(for: "grok")
        XCTAssertNotNil(mark, "Grok must load a real vector mark instead of the bolt.fill fallback")
        XCTAssertFalse(mark?.path.isEmpty ?? true, "Grok mark must carry SVG path data")
    }

    func testDevinResolvesToVectorMark() {
        let mark = ProviderMarks.mark(for: "devin")
        XCTAssertNotNil(mark)
        XCTAssertFalse(mark?.path.isEmpty ?? true, "Devin mark must carry SVG path data")
    }

    func testStandardProviderMarksLoad() {
        for id in ["claude", "codex", "cursor"] {
            let mark = ProviderMarks.mark(for: id)
            XCTAssertNotNil(mark, "\(id) should load")
            XCTAssertFalse(mark?.path.isEmpty ?? true, "\(id) mark must carry SVG path data")
        }
    }

    func testOllamaAndQwenLoadArcBasedMarks() {
        // Ollama's llama and Qwen's knot are built from elliptical arcs — they only render because the
        // SVG parser supports `A`/`a`. A regression that drops arc support would return nil (no SVG
        // mark) and silently fall back to an SF Symbol.
        for id in ["ollama", "qwen"] {
            let mark = ProviderMarks.mark(for: id)
            XCTAssertNotNil(mark, "\(id) must load a real vector mark, not an SF Symbol fallback")
            XCTAssertFalse(mark?.path.isEmpty ?? true, "\(id) mark must carry SVG path data")
            let bounds = SVGPath.parse(mark?.path ?? "").cgPath.boundingBoxOfPath
            XCTAssertGreaterThan(bounds.width, 1, "\(id) arcs must parse to real geometry")
            XCTAssertGreaterThan(bounds.height, 1, "\(id) arcs must parse to real geometry")
            XCTAssertFalse(bounds.width.isNaN || bounds.height.isNaN, "\(id) arcs must not produce NaN")
        }
    }

    func testSVGPathParserHandlesEllipticalArcs() {
        // A full circle (radius 5, center 5,5) as two 180° arcs exercises the large-arc + sweep flags
        // and the arc→bezier conversion; the path's bounding box must match the circle's bounds.
        let circle = SVGPath.parse("M0 5 A5 5 0 1 0 10 5 A5 5 0 1 0 0 5").cgPath.boundingBoxOfPath
        XCTAssertEqual(circle.minX, 0, accuracy: 0.2)
        XCTAssertEqual(circle.minY, 0, accuracy: 0.2)
        XCTAssertEqual(circle.maxX, 10, accuracy: 0.2)
        XCTAssertEqual(circle.maxY, 10, accuracy: 0.2)

        // A relative semicircle: from (5,0) the arc bulges right, so x spans 5…10 and y spans 0…10.
        let half = SVGPath.parse("M5 0 a5 5 0 0 1 0 10").cgPath.boundingBoxOfPath
        XCTAssertEqual(half.minX, 5, accuracy: 0.2)
        XCTAssertEqual(half.maxX, 10, accuracy: 0.2)
        XCTAssertEqual(half.minY, 0, accuracy: 0.2)
        XCTAssertEqual(half.maxY, 10, accuracy: 0.2)
    }
}
