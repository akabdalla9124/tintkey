import XCTest
@testable import TintkeyKit

final class GloriousStockTests: XCTestCase {
    func testOnlyReadCommandExists() {
        XCTAssertEqual(GloriousReadCommand.allCases.map(\.rawValue), [129])
    }

    func testReadRequestLayout() {
        let b = GloriousReadRequest().bytes
        XCTAssertEqual(b.count, 256)
        XCTAssertEqual(b[0], 7)
        XCTAssertEqual(b[1], 129, "command byte must be 129 (read state)")
        XCTAssertEqual([b[2], b[3]], [1, 1])
        XCTAssertTrue(b.dropFirst(4).allSatisfy { $0 == 0 })
        for (p, l) in [(UInt8(1), UInt8(2)), (3, 3)] {
            XCTAssertEqual(GloriousReadRequest(profile: p, layer: l).bytes[1], 129)
        }
    }
}
