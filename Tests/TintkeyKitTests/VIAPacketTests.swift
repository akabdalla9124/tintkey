import XCTest
@testable import TintkeyKit

final class VIAPacketTests: XCTestCase {
    func testPacketPadsTo32Bytes() {
        let p = VIAClient.packet([0x07, 3, 4, 85, 255])
        XCTAssertEqual(p.count, 32)
        XCTAssertEqual(Array(p.prefix(5)), [0x07, 3, 4, 85, 255])
        XCTAssertTrue(p.dropFirst(5).allSatisfy { $0 == 0 })
    }

    func testPacketTruncatesOversizedInput() {
        XCTAssertEqual(VIAClient.packet([UInt8](repeating: 9, count: 40)).count, 32)
    }

    func testReplyMatchingRequiresEchoedCommandChannelValue() {
        let req = VIAClient.packet([0x08, 3, 4])
        XCTAssertTrue(VIAClient.matches(request: req, reply: [0x08, 3, 4, 171, 255]))
        XCTAssertFalse(VIAClient.matches(request: req, reply: [0x08, 3, 1, 255, 0]), "stale brightness reply")
        XCTAssertFalse(VIAClient.matches(request: req, reply: [0x07, 3, 4, 0, 0]))
        XCTAssertFalse(VIAClient.matches(request: req, reply: [0x08]))
    }

    func testProtocolVersionMatchesOnCommandOnly() {
        XCTAssertTrue(VIAClient.matches(request: VIAClient.packet([0x01]), reply: [0x01, 0x00, 0x0C]))
    }
}
