import XCTest
@testable import TintkeyKit

final class PerKeyTests: XCTestCase {
    func testLayoutCoversEveryLEDOnce() {
        let keys = KeyLayout.v1MaxANSI
        XCTAssertEqual(keys.count, 81)
        XCTAssertEqual(Set(keys.map(\.led)), Set(0..<81))
        XCTAssertEqual(Set(keys.map(\.id)).count, keys.count, "key ids must be unique")
    }

    func testLayoutMatchesFirmwareLEDOrder() {
        let byLED = Dictionary(uniqueKeysWithValues: KeyLayout.v1MaxANSI.map { ($0.led, $0.id) })
        XCTAssertEqual(byLED[0], "esc"); XCTAssertEqual(byLED[13], "del"); XCTAssertEqual(byLED[27], "bksp")
        XCTAssertEqual(byLED[28], "pgup"); XCTAssertEqual(byLED[29], "tab"); XCTAssertEqual(byLED[56], "enter")
        XCTAssertEqual(byLED[58], "lshift"); XCTAssertEqual(byLED[65], "m"); XCTAssertEqual(byLED[69], "rshift")
        XCTAssertEqual(byLED[70], "up"); XCTAssertEqual(byLED[74], "space"); XCTAssertEqual(byLED[80], "right")
    }

    func testSetColorsPacketLayout() {
        let p = KeychronRGB.setColorsRequest(start: 80, colors: [HSV(h: 0, s: 255, v: 255)], ledCount: 81)
        XCTAssertEqual(p, [0xA8, 0x0A, 80, 1, 0, 255, 255])
    }

    func testPacketsRefuseOutOfRangeWrites() {
        let c = HSV(h: 1, s: 2, v: 3)
        XCTAssertNil(KeychronRGB.setColorsRequest(start: 73, colors: Array(repeating: c, count: 9), ledCount: 81))
        XCTAssertNil(KeychronRGB.setColorsRequest(start: 0, colors: Array(repeating: c, count: 10), ledCount: 81))
        XCTAssertNil(KeychronRGB.setColorsRequest(start: 0, colors: [], ledCount: 81))
        XCTAssertNil(KeychronRGB.setColorsRequest(start: -1, colors: [c], ledCount: 81))
        XCTAssertNotNil(KeychronRGB.setColorsRequest(start: 72, colors: Array(repeating: c, count: 9), ledCount: 81))
        XCTAssertNil(KeychronRGB.getColorsRequest(start: 81, count: 1, ledCount: 81))
    }

    func testNoSaveCommandCanBeBuilt() {
        // Sub-command 0x02 (save to memory) must never appear in anything we can build.
        let c = HSV(h: 0, s: 0, v: 0)
        let all: [[UInt8]] = [KeychronRGB.versionRequest(), KeychronRGB.ledCountRequest(), KeychronRGB.getTypeRequest(),
                              KeychronRGB.setTypeRequest(0), KeychronRGB.getColorsRequest(start: 0, count: 9, ledCount: 81)!,
                              KeychronRGB.setColorsRequest(start: 0, colors: [c], ledCount: 81)!]
        XCTAssertFalse(all.contains { $0.count > 1 && $0[0] == 0xA8 && $0[1] == 0x02 })
    }

    func testParseColors() {
        let reply: [UInt8] = [0xA8, 0x09, 0, 10, 20, 30, 40, 50, 60]
        XCTAssertEqual(KeychronRGB.parseColors(reply, count: 2), [HSV(h: 10, s: 20, v: 30), HSV(h: 40, s: 50, v: 60)])
        XCTAssertNil(KeychronRGB.parseColors([0xA8, 0x09, 1, 0, 0, 0], count: 1), "non-zero status")
        XCTAssertNil(KeychronRGB.parseColors([0xA8, 0x09, 0, 1], count: 1), "short reply")
    }
}
